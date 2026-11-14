-- Клиент сокета API herdr (спецификация herdr-client): один общий экземпляр.
--
-- Сервер обслуживает в соединении запросов один запрос, поэтому каждый запрос (`ping`,
-- `session.snapshot`, запросы вызывающих) идёт своим соединением. Порядок подключения:
-- `ping` с проверкой протокола, затем подписка на события жизненного цикла, после
-- `subscription_started` — `session.snapshot`. Подписки по панелям держит отдельное
-- соединение, оно пересобирается по составу панелей последнего снимка; конец этой подписки
-- после кадра ошибки (подписанная панель закрыта) — сигнал перечитать снимок. События
-- служат только сигналом перечитать снимок; перечитывания идут по одному, событие во время
-- чтения вызывает ещё одно. Потерю сервера клиент замечает по отказу в подключении, концу
-- потока подписки без кадра или ошибке `server_unavailable` подписке; обрыв соединения
-- запроса — ошибка только этого запроса. Возвращение сервера — по созданию файла сокета
-- (уведомление файловой системы). Таймеров и опроса нет.
--
-- Обратные вызовы `vim.uv` идут в быстром контексте: здесь нет `vim.api` и `vim.fn`,
-- подписчики и вызывающие получают результат через `vim.schedule`.
local uv = vim.uv
local conn = require("claudr.herdr.conn")
local watch = require("claudr.herdr.watch")

local M = {}

M.MIN_PROTOCOL = 22

-- События жизненного цикла workspace, вкладок и панелей; подписка без параметров.
local LIFECYCLE = {
  "workspace.created",
  "workspace.updated",
  "workspace.metadata_updated",
  "workspace.renamed",
  "workspace.moved",
  "workspace.reordered",
  "workspace.closed",
  "workspace.focused",
  "tab.created",
  "tab.closed",
  "tab.focused",
  "tab.renamed",
  "tab.moved",
  "pane.created",
  "pane.updated",
  "pane.closed",
  "pane.moved",
  "pane.exited",
  "pane.agent_detected",
  "layout.updated",
}

-- Подписки, привязанные к панели.
local PANE_EVENTS = { "pane.output_changed", "pane.agent_status_changed" }

local NO_SERVER = "сервер herdr недоступен"
local NOT_READY = "подключение к серверу herdr не завершено"

local function empty_snapshot()
  return { workspaces = {}, tabs = {}, panes = {} }
end

local S = {
  started = false,
  gen = 0, -- поколение подключения: ответы и события прежних поколений отбрасываются
  status = "stopped",
  message = nil,
  snapshot = empty_snapshot(),
  stale = false,
  inflight = {}, -- запросы в полёте: объекты `conn.request`
  sub = nil, -- соединение подписки на события жизненного цикла
  pane_sub = nil, -- соединение подписок по панелям
  pane_new = nil, -- пересобираемая подписка по панелям, ещё не начатая
  pane_key = nil, -- состав панелей действующей подписки по панелям
  failed_key = nil, -- состав, отклонённый сервером: повтор только при другом составе
  reading = false,
  dirty = false,
  watcher = nil,
  events = 0, -- число полученных событий (для тестов)
}

local subscribers = {}

--- Путь сокета: `HERDR_SOCKET_PATH`, без неё — `herdr.sock` в каталоге конфигурации
--- herdr (`$XDG_CONFIG_HOME/herdr`, без неё — `~/.config/herdr`).
function M.socket_path()
  local p = uv.os_getenv("HERDR_SOCKET_PATH")
  if p and p ~= "" then
    return p
  end
  local cfg = uv.os_getenv("XDG_CONFIG_HOME")
  if not cfg or cfg == "" then
    cfg = uv.os_homedir() .. "/.config"
  end
  return cfg .. "/herdr/herdr.sock"
end

--- Текущее состояние: `{status, message, snapshot, stale}`. `status` — "stopped",
--- "connecting", "connected", "no_server", "incompatible"; `stale` — кэш снимка устарел
--- (пришло событие или сервер потерян). Таблицу снимка изменять нельзя.
function M.state()
  return { status = S.status, message = S.message, snapshot = S.snapshot, stale = S.stale }
end

-- Вызов подписчиков в обычном контексте; несколько уведомлений подряд сливаются в одно.
local flush_scheduled = false
local function notify()
  if flush_scheduled then
    return
  end
  flush_scheduled = true
  vim.schedule(function()
    flush_scheduled = false
    local st = M.state()
    for _, s in ipairs({ unpack(subscribers) }) do
      if s.active then
        local events = s.queue
        s.queue = {}
        local ok, err = pcall(s.cb, st, events)
        if not ok then
          vim.notify(
            "claudr: ошибка подписчика herdr: " .. tostring(err),
            vim.log.levels.ERROR
          )
        end
      end
    end
  end)
end

local function set_status(status, message)
  S.status = status
  S.message = message
  notify()
end

local function close_all()
  for _, key in ipairs({ "sub", "pane_sub", "pane_new" }) do
    if S[key] then
      S[key]:close()
      S[key] = nil
    end
  end
  local inflight = S.inflight
  S.inflight = {}
  for h in pairs(inflight) do
    h.close()
  end
  S.pane_key = nil
  S.failed_key = nil
  S.reading = false
  S.dirty = false
end

local function close_watcher()
  if S.watcher then
    S.watcher:close()
    S.watcher = nil
  end
end

local connect

-- Вид отказа в подключении по тексту ошибки libuv: "missing" — файла сокета нет,
-- "refused" — файл есть, но сервер не принимает; иначе `nil`.
local function refusal(text)
  if type(text) ~= "string" then
    return nil
  end
  if text:match("^ENOENT") or text:match("^ENOTDIR") then
    return "missing"
  end
  if text:match("^ECONNREFUSED") then
    return "refused"
  end
  return nil
end

-- Запрос своим соединением; `cb(err, result)` в быстром контексте.
local function send(method, params, cb)
  local h
  local finished = false
  h = conn.request(M.socket_path(), method, params, function(err, result)
    finished = true
    if h then
      S.inflight[h] = nil
    end
    cb(err, result)
  end)
  if not finished then
    S.inflight[h] = true
  end
end

-- Ждать создания файла сокета. `check` — файл мог появиться между неудачным подключением
-- (файла не было) и постановкой наблюдения: проверить его один раз после постановки.
local function arm_watch(check)
  close_watcher()
  local gen = S.gen
  local path = M.socket_path()
  local w
  w = watch.start(path, function()
    if gen ~= S.gen or not S.started or S.watcher ~= w then
      return
    end
    S.watcher = nil
    connect()
  end)
  S.watcher = w
  if check and watch.exists(path) then
    close_watcher()
    connect()
  end
end

-- Сервер недоступен: соединения закрываются, кэш устаревает, клиент ждёт файла сокета.
local function go_no_server(check)
  S.gen = S.gen + 1
  close_all()
  S.stale = true
  set_status("no_server", NO_SERVER)
  arm_watch(check)
end

local function go_incompatible(message)
  S.gen = S.gen + 1
  close_all()
  S.stale = true
  set_status("incompatible", message)
  arm_watch(false)
end

local refresh

local function on_event(frame)
  S.events = S.events + 1
  local ev = { event = frame.event, data = frame.data }
  for _, s in ipairs(subscribers) do
    if s.active then
      table.insert(s.queue, ev)
    end
  end
  S.stale = true
  refresh()
end

local resync

-- Открыть соединение подписки `list`. `on_started()` — после `subscription_started`,
-- `on_rejected(err)` — сервер отклонил запрос (кроме `server_unavailable`). `on_ended()`
-- (только у подписки по панелям) — сервер прислал кадр ошибки, кроме `events_lost`
-- и `server_unavailable`, и закрыл поток: так herdr завершает подписку, когда подписанная
-- панель закрыта. Без `on_ended` и при конце потока без такого кадра — «нет сервера».
local function open_sub(gen, list, on_started, on_rejected, on_ended)
  local c
  local ended = false
  c = conn.open(M.socket_path(), {
    on_open = function(err)
      if gen ~= S.gen then
        return
      end
      if err then
        go_no_server(refusal(err) == "missing")
        return
      end
      c:request("events.subscribe", { subscriptions = list }, function(rerr)
        -- Подписка, закрытая самим клиентом (замена, `events_lost`), уже не нужна.
        if gen ~= S.gen or c.closed_by_client then
          return
        end
        if rerr then
          if rerr.code == "server_unavailable" then
            go_no_server(false)
          else
            on_rejected(rerr)
          end
          return
        end
        on_started()
      end)
    end,
    on_event = function(frame)
      if gen == S.gen then
        on_event(frame)
      end
    end,
    on_error = function(err)
      if gen ~= S.gen then
        return
      end
      local code = type(err) == "table" and err.code or nil
      if code == "events_lost" then
        resync()
      elseif code ~= "server_unavailable" and on_ended then
        ended = true
      end
    end,
    on_close = function()
      if gen ~= S.gen then
        return
      end
      if ended then
        on_ended()
      else
        go_no_server(false)
      end
    end,
  })
  return c
end

local function pane_ids(snap)
  local ids = {}
  for _, p in ipairs(snap.panes or {}) do
    if type(p.pane_id) == "string" then
      table.insert(ids, p.pane_id)
    end
  end
  table.sort(ids)
  return ids
end

-- Привести подписку по панелям к составу последнего снимка.
local function sync_pane_subs()
  if S.pane_new or S.status ~= "connected" then
    return -- пересборка уже идёт; после неё снимок перечитывается и состав сверяется снова
  end
  local ids = pane_ids(S.snapshot)
  local key = table.concat(ids, "\n")
  if key == S.pane_key or key == S.failed_key then
    return
  end
  if #ids == 0 then
    if S.pane_sub then
      S.pane_sub:close()
      S.pane_sub = nil
    end
    S.pane_key = key
    return
  end
  local list = {}
  for _, id in ipairs(ids) do
    for _, ev in ipairs(PANE_EVENTS) do
      table.insert(list, { type = ev, pane_id = id })
    end
  end
  local gen = S.gen
  local c
  c = open_sub(gen, list, function()
    S.pane_new = nil
    if S.pane_sub then
      S.pane_sub:close()
    end
    S.pane_sub = c
    S.pane_key = key
    S.failed_key = nil
    -- События новой панели между снимком и подпиской не потеряны: снимок перечитывается.
    refresh()
  end, function()
    -- Одна неверная запись отклоняет весь запрос: состав изменился, нужен новый снимок.
    S.pane_new = nil
    c:close()
    S.failed_key = key
    refresh()
  end, function()
    -- Подписанная панель закрыта, сервер завершил подписку: подписка пересобирается
    -- по новому снимку, общая подписка не затрагивается.
    if S.pane_sub == c then
      S.pane_sub = nil
      S.pane_key = nil
    end
    S.stale = true
    refresh()
  end)
  S.pane_new = c
end

refresh = function()
  if not S.sub or (S.status ~= "connecting" and S.status ~= "connected") then
    return
  end
  if S.reading then
    S.dirty = true
    return
  end
  S.reading = true
  S.dirty = false
  local gen = S.gen
  send("session.snapshot", nil, function(err, result)
    if gen ~= S.gen then
      return
    end
    S.reading = false
    if err then
      -- Обрыв соединения запроса — ошибка этого чтения, а не потеря сервера: остановку
      -- сервера сообщает подписка. Кэш остаётся устаревшим до следующего события.
      local kind = refusal(err.connect_error)
      if kind then
        go_no_server(kind == "missing")
      elseif S.dirty then
        refresh()
      end
      return
    end
    S.snapshot = (result and result.snapshot) or empty_snapshot()
    S.stale = S.dirty
    set_status("connected", nil)
    if S.dirty then
      refresh()
    end
    sync_pane_subs()
  end)
end

-- Подписка на события жизненного цикла, затем снимок.
local function subscribe_lifecycle(gen)
  local list = {}
  for _, name in ipairs(LIFECYCLE) do
    table.insert(list, { type = name })
  end
  S.sub = open_sub(gen, list, function()
    refresh()
  end, function(err)
    go_incompatible(
      "herdr отклонил подписку на события: "
        .. tostring(err.message or err.code)
    )
  end)
end

-- `events_lost`: кэш устарел, подписки открываются заново, затем новый снимок.
resync = function()
  S.stale = true
  for _, key in ipairs({ "sub", "pane_sub", "pane_new" }) do
    if S[key] then
      S[key]:close()
      S[key] = nil
    end
  end
  S.pane_key = nil
  S.failed_key = nil
  subscribe_lifecycle(S.gen)
end

connect = function()
  S.gen = S.gen + 1
  local gen = S.gen
  close_all()
  close_watcher()
  set_status("connecting", nil)
  send("ping", nil, function(perr, result)
    if gen ~= S.gen then
      return
    end
    if perr then
      -- Файла нет — проверить его после постановки наблюдения; файл есть, но сервер
      -- не принимает или не ответил — ждать только события файловой системы.
      go_no_server(refusal(perr.connect_error) == "missing")
      return
    end
    local protocol = type(result) == "table" and tonumber(result.protocol) or nil
    if not protocol or protocol < M.MIN_PROTOCOL then
      go_incompatible(
        string.format(
          "herdr: требуется протокол %d и новее, найден %s",
          M.MIN_PROTOCOL,
          type(result) == "table" and tostring(result.protocol) or "nil"
        )
      )
      return
    end
    subscribe_lifecycle(gen)
  end)
end

--- Подключиться к серверу; без сервера — состояние "no_server" и ожидание файла сокета.
function M.start()
  if S.started then
    return
  end
  S.started = true
  connect()
end

--- Отключиться: соединения и наблюдение закрываются, ждущие запросы получают
--- `server_unavailable`, состояние — "stopped". Подписчики сохраняются.
function M.stop()
  S.started = false
  S.gen = S.gen + 1
  close_all()
  close_watcher()
  S.snapshot = empty_snapshot()
  S.stale = false
  set_status("stopped", nil)
end

--- Подписка на состояние: `cb(state, events)` в обычном контексте после применённого
--- снимка или смены состояния; `events` — события `{event, data}`, накопленные с прошлого
--- вызова. Возвращает функцию отписки.
function M.subscribe(cb)
  local s = { cb = cb, queue = {}, active = true }
  table.insert(subscribers, s)
  return function()
    s.active = false
    for i, x in ipairs(subscribers) do
      if x == s then
        table.remove(subscribers, i)
        break
      end
    end
  end
end

--- Запрос к серверу своим соединением; `cb(err, result)` в обычном контексте,
--- `err = {code, message}`. Без подключения — сразу `server_unavailable`, ничего
--- не откладывается. Обрыв соединения до ответа — `server_unavailable` этому запросу;
--- отказ в подключении к тому же переводит клиента в «нет сервера».
function M.request(method, params, cb)
  if S.status ~= "connected" then
    local message = S.message
    if S.status == "connecting" then
      message = NOT_READY
    end
    cb({ code = "server_unavailable", message = message or NO_SERVER })
    return
  end
  local gen = S.gen
  send(method, params, function(err, result)
    if err and err.connect_error then
      local kind = refusal(err.connect_error)
      if kind and gen == S.gen then
        go_no_server(kind == "missing")
      end
      err = { code = err.code, message = NO_SERVER }
    end
    vim.schedule(function()
      cb(err, result)
    end)
  end)
end

--- Чтение вывода панели `pane.read`. `opts.source` ("recent_unwrapped" по умолчанию,
--- "recent", "visible"), `opts.lines`, `opts.format` ("text" по умолчанию или "ansi").
--- `cb(err, read)`, `read = {text, revision, truncated, source, format, …}`.
function M.read_pane(pane_id, opts, cb)
  opts = opts or {}
  local params = {
    pane_id = pane_id,
    source = opts.source or "recent_unwrapped",
    format = opts.format or "text",
    lines = opts.lines,
  }
  M.request("pane.read", params, function(err, result)
    if err then
      cb(err)
      return
    end
    cb(nil, result and result.read)
  end)
end

--- Идентификатор сессии Claude Code панели: `agent_session.value` у панели с
--- `agent = "claude"`, иначе `nil`.
function M.session_id(pane)
  if type(pane) ~= "table" or pane.agent ~= "claude" then
    return nil
  end
  local s = pane.agent_session
  if type(s) == "table" and type(s.value) == "string" then
    return s.value
  end
  return nil
end

-- Только для тестов: число полученных событий.
function M._events()
  return S.events
end

-- Только для тестов: идёт ли чтение снимка и ждёт ли оно повторного.
function M._reading()
  return S.reading, S.dirty
end

return M
