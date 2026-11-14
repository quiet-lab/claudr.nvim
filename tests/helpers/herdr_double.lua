-- Двойник сервера herdr для тестов: Unix-сокет на `vim.uv` в процессе теста, кадры JSON
-- по строке. Кадры повторяют наблюдавшиеся у herdr 0.9.5 (протокол 22): ключи по алфавиту,
-- в ответе `id` первым. Как у herdr, соединение обслуживает один запрос: после ответа (кроме
-- начатой подписки) двойник закрывает соединение, на второй запрос в том же соединении
-- закрывает его без ответа; подписка по панелям при закрытии подписанной панели получает
-- кадр ошибки `pane_not_found` и закрывается. Управляется тестом: снимок, события, ошибки, удержание ответов,
-- остановка и перезапуск. Поддельный `herdr` (tests/helpers/fake_bin/herdr) управляется
-- через каталог `fake_herdr/` рядом с сокетом.
--
-- Обработчики запросов выполняются в обратных вызовах `vim.uv` (быстрый контекст): в них
-- нет `vim.fn` и `vim.api`. Таймеров и опроса нет.
local json = require("helpers.herdr_double.json")

local uv = vim.uv
local M = {}

M.VERSION = "0.9.5"
M.PROTOCOL = 22
-- Каталог управления поддельным `herdr` относительно каталога сокета.
M.FAKE_DIR = "fake_herdr"

-- Тексты ошибок настоящего сервера (`%s` — цель, имя агента или идентификатор).
local MESSAGES = {
  agent_blocked = "agent %s is blocked and requires interactive input",
  agent_not_ready = "agent %s is blocked during startup and is not ready for prompts",
  agent_not_found = "agent target %s not found",
  not_found = "%s not found",
  pane_not_found = "pane %s not found",
  tab_not_found = "tab %s not found",
  workspace_not_found = "workspace %s not found",
  agent_pane_not_found = "pane %s not found",
  server_unavailable = "request handling failed: app response channel closed",
  events_lost = "event subscription fell behind retained history; resubscribe and resync with session.snapshot",
}

-- Виды записей подписки из схемы протокола 22; по-панельные требуют `pane_id`.
local GENERAL_SUBSCRIPTIONS = {}
for _, name in ipairs({
  "workspace.created",
  "workspace.updated",
  "workspace.metadata_updated",
  "workspace.renamed",
  "workspace.moved",
  "workspace.reordered",
  "workspace.closed",
  "workspace.focused",
  "worktree.created",
  "worktree.opened",
  "worktree.removed",
  "tab.created",
  "tab.closed",
  "tab.focused",
  "tab.renamed",
  "tab.moved",
  "pane.created",
  "pane.closed",
  "pane.updated",
  "pane.focused",
  "pane.moved",
  "pane.exited",
  "pane.agent_detected",
  "layout.updated",
}) do
  GENERAL_SUBSCRIPTIONS[name] = true
end
local PANE_SUBSCRIPTIONS = {
  ["pane.output_matched"] = true,
  ["pane.output_changed"] = true,
  ["pane.agent_status_changed"] = true,
  ["pane.scroll_changed"] = true,
}

local function copy(v)
  return vim.deepcopy(v, true)
end

local function dict(t)
  return setmetatable(t or {}, getmetatable(vim.empty_dict()))
end

local function is_nil(v)
  return v == nil or v == vim.NIL
end

-- Номер из окончания идентификатора (`w1:p3` → 3); идентификатор может содержать буквы.
local function id_number(id, sep)
  return tonumber(tostring(id):match(sep .. "(%d+)$"))
end

local terminal_counter = 0
local function next_terminal_id()
  terminal_counter = terminal_counter + 1
  return string.format("term_%014x", 0x66035be7000000 + terminal_counter)
end

local session_counter = 0
local function next_session_id()
  session_counter = session_counter + 1
  return string.format("00000000-0000-4000-8000-%012d", session_counter)
end

-- Помощники построения записей снимка ----------------------------------------------------

--- Запись workspace с правдоподобными значениями по умолчанию.
function M.workspace(o)
  o = o or {}
  local id = o.workspace_id or "w1"
  local n = id_number(id, "w") or 1
  local rec = {
    workspace_id = id,
    number = n,
    label = "ws" .. n,
    focused = false,
    pane_count = 1,
    tab_count = 1,
    active_tab_id = id .. ":t1",
    agent_status = "unknown",
    tokens = dict({ symbol = "📁" }),
  }
  for k, v in pairs(o) do
    rec[k] = v
  end
  return rec
end

--- Запись вкладки; `workspace_id` по умолчанию берётся из `tab_id`.
function M.tab(o)
  o = o or {}
  local id = o.tab_id or ((o.workspace_id or "w1") .. ":t1")
  local rec = {
    tab_id = id,
    workspace_id = o.workspace_id or id:match("^(.*):t[^:]*$") or "w1",
    number = id_number(id, ":t") or 1,
    focused = false,
    pane_count = 1,
    agent_status = "unknown",
  }
  rec.label = tostring(rec.number)
  for k, v in pairs(o) do
    rec[k] = v
  end
  return rec
end

--- Запись панели. `session = "<id>"` — краткая запись `agent_session`; у панели с
--- `agent = "claude"` без `session` идентификатор сессии создаётся сам.
function M.pane(o)
  o = o or {}
  local id = o.pane_id or ((o.workspace_id or "w1") .. ":p1")
  local ws = o.workspace_id or id:match("^(.*):p[^:]*$") or "w1"
  local rec = {
    pane_id = id,
    workspace_id = ws,
    tab_id = o.tab_id or (ws .. ":t1"),
    terminal_id = next_terminal_id(),
    agent_status = "unknown",
    cwd = "/work/project",
    foreground_cwd = o.cwd or "/work/project",
    foreground_process = "bash",
    focused = false,
    revision = 0,
    scroll = dict({ max_offset_from_bottom = 0, offset_from_bottom = 0, viewport_rows = 40 }),
  }
  local session = o.session
  for k, v in pairs(o) do
    if k ~= "session" then
      rec[k] = v
    end
  end
  if rec.agent and not rec.agent_session then
    if session or rec.agent == "claude" then
      rec.agent_session = dict({
        agent = rec.agent,
        kind = "id",
        source = "herdr:" .. rec.agent,
        value = session or next_session_id(),
      })
    end
    rec.display_agent = rec.display_agent or "haiku"
    rec.tokens = rec.tokens or dict()
    if rec.foreground_process == "bash" then
      rec.foreground_process = rec.agent
    end
  end
  return rec
end

-- Объект двойника ----------------------------------------------------------------------

local D = {}
D.__index = D

local function find(list, key, id)
  for i, rec in ipairs(list) do
    if rec[key] == id then
      return rec, i
    end
  end
end

function D:_pane(id)
  return find(self.state.panes, "pane_id", id)
end

function D:_tab(id)
  return find(self.state.tabs, "tab_id", id)
end

function D:_workspace(id)
  return find(self.state.workspaces, "workspace_id", id)
end

--- Задаёт содержимое снимка: `{workspaces=…, tabs=…, panes=…}` в формате herdr. Счётчики,
--- `agents`, `layouts` и поля фокуса снимок вычисляет сам при каждом запросе.
function D:set_snapshot(tbl)
  tbl = copy(tbl or {})
  self.state = {
    workspaces = tbl.workspaces or {},
    tabs = tbl.tabs or {},
    panes = tbl.panes or {},
    focused_workspace_id = tbl.focused_workspace_id,
    focused_tab_id = tbl.focused_tab_id,
    focused_pane_id = tbl.focused_pane_id,
  }
  self.agent_names = {}
  for _, p in ipairs(self.state.panes) do
    if p.agent and p.name then
      self.agent_names[p.name] = p.pane_id
    end
  end
end

local function agent_record(p, name)
  local rec = {
    agent = p.agent,
    agent_session = p.agent_session,
    agent_status = p.agent_status,
    completion_seq = p.completion_seq or 0,
    state_change_seq = p.state_change_seq or 0,
    cwd = p.cwd,
    display_agent = p.display_agent,
    focused = p.focused,
    foreground_cwd = p.foreground_cwd,
    pane_id = p.pane_id,
    revision = p.revision,
    tab_id = p.tab_id,
    terminal_id = p.terminal_id,
    terminal_title = p.terminal_title,
    terminal_title_stripped = p.terminal_title_stripped,
    tokens = p.tokens or dict(),
    workspace_id = p.workspace_id,
  }
  if name then
    rec.name = name
    rec.interactive_ready = p.agent_status ~= "blocked"
  end
  return rec
end

function D:_agent_name(pane_id)
  for name, id in pairs(self.agent_names) do
    if id == pane_id then
      return name
    end
  end
end

--- Снимок в виде, который отдаёт `session.snapshot` (поле `snapshot` ответа).
function D:snapshot()
  local st = self.state
  local ws_tabs, ws_panes, tab_panes = {}, {}, {}
  for _, t in ipairs(st.tabs) do
    ws_tabs[t.workspace_id] = (ws_tabs[t.workspace_id] or 0) + 1
  end
  for _, p in ipairs(st.panes) do
    ws_panes[p.workspace_id] = (ws_panes[p.workspace_id] or 0) + 1
    tab_panes[p.tab_id] = tab_panes[p.tab_id] or {}
    table.insert(tab_panes[p.tab_id], p)
  end
  local snap = {
    version = M.VERSION,
    protocol = self.protocol,
    workspaces = {},
    tabs = {},
    panes = {},
    layouts = {},
    agents = {},
  }
  for _, w in ipairs(st.workspaces) do
    local rec = copy(w)
    rec.tab_count = ws_tabs[w.workspace_id] or 0
    rec.pane_count = ws_panes[w.workspace_id] or 0
    table.insert(snap.workspaces, rec)
  end
  for _, t in ipairs(st.tabs) do
    local rec = copy(t)
    local panes = tab_panes[t.tab_id] or {}
    rec.pane_count = #panes
    table.insert(snap.tabs, rec)
    local layout_panes = {}
    for i, p in ipairs(panes) do
      local w = math.floor(120 / #panes)
      table.insert(layout_panes, {
        focused = p.focused or false,
        pane_id = p.pane_id,
        rect = { height = 40, width = w, x = (i - 1) * w, y = 0 },
      })
    end
    table.insert(snap.layouts, {
      area = { height = 40, width = 120, x = 0, y = 0 },
      focused_pane_id = panes[1] and panes[1].pane_id or vim.NIL,
      panes = layout_panes,
      splits = {},
      tab_id = t.tab_id,
      workspace_id = t.workspace_id,
      zoomed = false,
    })
  end
  for _, p in ipairs(st.panes) do
    table.insert(snap.panes, copy(p))
    if p.agent then
      table.insert(snap.agents, agent_record(copy(p), self:_agent_name(p.pane_id)))
    end
  end
  local first_ws, first_tab, first_pane = st.workspaces[1], st.tabs[1], st.panes[1]
  snap.focused_workspace_id = st.focused_workspace_id or (first_ws and first_ws.workspace_id)
  snap.focused_tab_id = st.focused_tab_id or (first_tab and first_tab.tab_id)
  snap.focused_pane_id = st.focused_pane_id or (first_pane and first_pane.pane_id)
  return snap
end

-- Соединения ---------------------------------------------------------------------------

function D:_write(c, line)
  if not c or c.closed then
    return
  end
  c.pipe:write(line .. "\n")
end

-- Закрыть соединение. `flush` — дождаться отправки записанных кадров (shutdown), иначе
-- закрыть сразу без кадра.
function D:_close_conn(c, flush)
  if c.closed then
    return
  end
  c.closed = true
  self.connections[c.id] = nil
  self:_refresh_subscriptions()
  if flush then
    c.pipe:shutdown(function()
      c.pipe:close()
    end)
  else
    c.pipe:close()
  end
end

function D:_refresh_subscriptions()
  local list = {}
  for _, c in pairs(self.connections) do
    if c.sub then
      table.insert(list, { conn = c.id, id = c.sub_id, subscriptions = c.sub })
    end
  end
  table.sort(list, function(a, b)
    return a.conn < b.conn
  end)
  self.subscriptions = list
end

-- Отправка ответа с учётом удержания. `after(c)` выполняется после записи кадра.
function D:_reply(c, method, line, after)
  if self.holds["*"] or self.holds[method] then
    table.insert(self.held, { conn = c, method = method, line = line, after = after })
    return
  end
  self:_write(c, line)
  if after then
    after(c)
  end
end

-- Закрыть соединение после ответа: настоящий сервер обслуживает в соединении один запрос.
local function close_after(self)
  return function(conn)
    self:_close_conn(conn, true)
  end
end

function D:_on_line(c, line)
  if line == "" then
    return
  end
  if c.served then
    -- Второй запрос в том же соединении: herdr сбрасывает соединение без ответа.
    self:_close_conn(c, false)
    return
  end
  c.served = true
  local ok, req = pcall(vim.json.decode, line)
  if not ok or type(req) ~= "table" then
    self:_write(c, json.error("", "invalid_request", "invalid request json"))
    self:_close_conn(c, true)
    return
  end
  local params = is_nil(req.params) and dict() or req.params
  local method = req.method
  local id = is_nil(req.id) and "" or req.id
  table.insert(self.requests, { method = method, params = params, conn = c.id, id = id })

  local fail = self.failures[method] and table.remove(self.failures[method], 1)
  if fail then
    if method == "agent.start" and fail.code == "agent_not_ready" then
      -- Настоящий сервер оставляет агента в панели в состоянии blocked.
      self:_start_agent(params, "blocked")
    end
    local target = params.name or params.target or params.pane_id or ""
    local message = fail.message or string.format(MESSAGES[fail.code] or "%s", target)
    self:_reply(c, method, json.error(id, fail.code, message), close_after(self))
    return
  end

  local handler = self.handlers[method]
  if not handler then
    self:_reply(
      c,
      method,
      json.error(id, "invalid_request", "unknown method " .. tostring(method)),
      close_after(self)
    )
    return
  end
  local result, err_code, err_message = handler(self, params, c, id)
  if err_code then
    self:_reply(c, method, json.error(id, err_code, err_message), close_after(self))
  elseif result then
    -- Начатая подписка остаётся открытой под поток событий.
    local after = not c.sub and close_after(self) or nil
    self:_reply(c, method, json.response(id, result), after)
  end
end

function D:_accept()
  local pipe = uv.new_pipe(false)
  self.server:accept(pipe)
  self.conn_seq = self.conn_seq + 1
  local c = { id = self.conn_seq, pipe = pipe, buf = "" }
  self.connections[c.id] = c
  pipe:read_start(function(err, chunk)
    if err or not chunk then
      self:_close_conn(c, false)
      return
    end
    c.buf = c.buf .. chunk
    while true do
      local nl = c.buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = c.buf:sub(1, nl - 1)
      c.buf = c.buf:sub(nl + 1)
      self:_on_line(c, line)
    end
  end)
end

function D:_listen()
  uv.fs_unlink(self.socket_path)
  local server = uv.new_pipe(false)
  local ok, err = server:bind(self.socket_path)
  if not ok then
    server:close()
    error(
      "herdr_double: не удалось создать сокет "
        .. self.socket_path
        .. ": "
        .. tostring(err)
    )
  end
  server:listen(128, function(lerr)
    if not lerr then
      self:_accept()
    end
  end)
  self.server = server
end

-- Методы сервера -----------------------------------------------------------------------

local handlers = {}

handlers["ping"] = function(self)
  local result = { type = "pong", version = M.VERSION, protocol = self.protocol }
  for k, v in pairs(self.ping_extra or {}) do
    result[k] = v
  end
  return result
end

handlers["session.snapshot"] = function(self)
  return { type = "session_snapshot", snapshot = self:snapshot() }
end

handlers["events.subscribe"] = function(self, params, c, id)
  local subs = params.subscriptions
  if type(subs) ~= "table" then
    return nil, "invalid_params", "missing field `subscriptions`"
  end
  for _, s in ipairs(subs) do
    local t = s.type
    if PANE_SUBSCRIPTIONS[t] then
      if is_nil(s.pane_id) then
        return nil, "invalid_params", "missing field `pane_id`"
      end
      if not self:_pane(s.pane_id) then
        return nil, "pane_not_found", string.format(MESSAGES.pane_not_found, s.pane_id)
      end
    elseif not GENERAL_SUBSCRIPTIONS[t] then
      return nil, "invalid_params", "unknown subscription type " .. tostring(t)
    end
  end
  c.sub = subs
  c.sub_id = id
  self:_refresh_subscriptions()
  return { type = "subscription_started" }
end

local function strip_ansi(s)
  return (s:gsub("\27%[[%d;?]*[%a]", ""):gsub("\27%][^\27\7]*\7", ""):gsub("\27%][^\27]*\27\\", ""))
end

local function rstrip(s)
  return (s:gsub("%s+$", ""))
end

-- Деление строки без последовательностей оформления на строки экрана по ширине.
local function wrap(line, width)
  if line:find("\27", 1, true) then
    return { line }
  end
  local rows, cur, n = {}, {}, 0
  for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if n == width then
      table.insert(rows, table.concat(cur))
      cur, n = {}, 0
    end
    table.insert(cur, ch)
    n = n + 1
  end
  table.insert(rows, table.concat(cur))
  return rows
end

local function tail(list, n)
  local out = {}
  for i = math.max(1, #list - n + 1), #list do
    table.insert(out, list[i])
  end
  return out
end

handlers["pane.read"] = function(self, params)
  local p = self:_pane(params.pane_id)
  if not p then
    return nil, "pane_not_found", string.format(MESSAGES.pane_not_found, tostring(params.pane_id))
  end
  local out = self.outputs[p.pane_id] or { lines = { "" } }
  local width, height = out.width or 120, out.height or 40
  local source = params.source
  local format = is_nil(params.format) and "text" or params.format
  local requested = is_nil(params.lines) and 80 or params.lines

  local logical = out.lines or { "" }
  local rows = {}
  for _, l in ipairs(logical) do
    vim.list_extend(rows, wrap(l, width))
  end

  local picked, truncated
  if out.fullscreen or source == "visible" or source == "detection" then
    -- Полноэкранная программа: истории нет, все источники дают текущий экран.
    picked = tail(out.fullscreen and logical or rows, height)
    truncated = false
  elseif source == "recent" or source == "recent_unwrapped" then
    local n = math.min(requested, 1000)
    local list = source == "recent" and rows or logical
    picked = tail(list, n)
    truncated = #list > n or requested > 1000
  else
    return nil, "invalid_params", "unknown variant `" .. tostring(source) .. "`"
  end

  local text
  if format == "ansi" and source ~= "detection" then
    text = table.concat(picked, "\r\n")
  else
    local clean = {}
    for i, l in ipairs(picked) do
      clean[i] = rstrip(strip_ansi(l))
    end
    text = table.concat(clean, "\n")
    if source ~= "recent_unwrapped" then
      text = text .. "\n"
    end
  end
  return {
    type = "pane_read",
    read = {
      pane_id = p.pane_id,
      workspace_id = p.workspace_id,
      tab_id = p.tab_id,
      source = source,
      format = format,
      revision = p.revision,
      truncated = truncated,
      text = text,
    },
  }
end

handlers["pane.send_keys"] = function(self, params)
  if not self:_pane(params.pane_id) then
    return nil, "pane_not_found", string.format(MESSAGES.pane_not_found, tostring(params.pane_id))
  end
  return { type = "ok" }
end

handlers["pane.send_text"] = function(self, params)
  if not self:_pane(params.pane_id) then
    return nil, "pane_not_found", string.format(MESSAGES.pane_not_found, tostring(params.pane_id))
  end
  return { type = "ok" }
end

function D:_resolve_agent(target)
  local pane_id = self.agent_names[target] or target
  local p = self:_pane(pane_id)
  if p and p.agent then
    return p, self:_agent_name(p.pane_id) or target
  end
end

handlers["agent.prompt"] = function(self, params)
  local p, name = self:_resolve_agent(params.target)
  if not p then
    return nil, "agent_not_found", string.format(MESSAGES.agent_not_found, tostring(params.target))
  end
  if p.agent_status == "blocked" then
    return nil, "agent_blocked", string.format(MESSAGES.agent_blocked, name)
  end
  p.completion_seq = (p.completion_seq or 0) + 1
  return { type = "agent_prompted", agent = agent_record(copy(p), name) }
end

-- Запуск агента в панели: запись в снимке и события, как у настоящего сервера. Первое
-- событие состояния — `unknown` без поля `agent`, затем `pane_agent_detected`; состояние
-- `status` (кроме `unknown`) приходит следующим событием `pane.agent_status_changed`.
-- Возвращает панель и запись агента на момент до смены состояния.
function D:_start_agent(params, status)
  local p = self:_pane(params.pane_id)
  if not p then
    return nil
  end
  local kind = params.kind or "claude"
  p.agent = kind
  p.display_agent = p.display_agent or "haiku"
  p.foreground_process = kind
  p.agent_status = "unknown"
  p.tokens = p.tokens or dict()
  p.agent_session = dict({
    agent = kind,
    kind = "id",
    source = "herdr:" .. kind,
    value = next_session_id(),
  })
  if params.name then
    self.agent_names[params.name] = p.pane_id
  end
  self:emit("pane.agent_status_changed", {
    agent_status = "unknown",
    display_agent = p.display_agent,
    pane_id = p.pane_id,
    workspace_id = p.workspace_id,
  })
  self:emit("pane_agent_detected", {
    agent = kind,
    pane_id = p.pane_id,
    workspace_id = p.workspace_id,
  })
  local started = agent_record(copy(p), params.name)
  if params.name then
    started.interactive_ready = false
  end
  if status ~= "unknown" then
    self:set_agent_status(p.pane_id, status)
  end
  return p, started
end

-- Без `timeout_ms` настоящий сервер отвечает сразу, готовности не ждёт: запись агента в
-- состоянии `unknown`, состояние после запуска (`start_status`) приходит событием. С
-- `timeout_ms` сервер ждёт: состояние `blocked` даёт ошибку `agent_not_ready` (агент
-- остаётся в панели), иное — запись агента в этом состоянии.
handlers["agent.start"] = function(self, params)
  if not self:_pane(params.pane_id) then
    return nil,
      "agent_pane_not_found",
      string.format(MESSAGES.agent_pane_not_found, tostring(params.pane_id))
  end
  local status = self.start_status
  local p, rec = self:_start_agent(params, status)
  if not is_nil(params.timeout_ms) then
    if status == "blocked" then
      return nil,
        "agent_not_ready",
        string.format(MESSAGES.agent_not_ready, params.name or params.pane_id)
    end
    rec = agent_record(copy(p), params.name)
  end
  return { type = "agent_info", agent = rec }
end

function D:_new_pane(ws, tab_id)
  local max = 0
  for _, p in ipairs(self.state.panes) do
    if p.workspace_id == ws then
      max = math.max(max, id_number(p.pane_id, ":p") or 0)
    end
  end
  local p = M.pane({ pane_id = ws .. ":p" .. (max + 1), workspace_id = ws, tab_id = tab_id })
  table.insert(self.state.panes, p)
  return p
end

handlers["tab.create"] = function(self, params)
  local ws_id = params.workspace_id
  if is_nil(ws_id) then
    ws_id = self:snapshot().focused_workspace_id
  end
  local ws = ws_id and self:_workspace(ws_id)
  if not ws then
    return nil, "workspace_not_found", string.format(MESSAGES.workspace_not_found, tostring(ws_id))
  end
  local max = 0
  for _, t in ipairs(self.state.tabs) do
    if t.workspace_id == ws_id then
      max = math.max(max, id_number(t.tab_id, ":t") or 0, t.number or 0)
    end
  end
  local tab = M.tab({ tab_id = ws_id .. ":t" .. (max + 1), workspace_id = ws_id, number = max + 1 })
  if not is_nil(params.label) then
    tab.label = params.label
  end
  table.insert(self.state.tabs, tab)
  local pane = self:_new_pane(ws_id, tab.tab_id)
  self:emit("tab_created", { tab = copy(tab) })
  self:emit("pane_created", { pane = copy(pane) })
  return { type = "tab_created", tab = copy(tab), root_pane = copy(pane) }
end

handlers["pane.split"] = function(self, params)
  local target = params.target_pane_id
  if is_nil(target) then
    target = self:snapshot().focused_pane_id
  end
  local src = target and self:_pane(target)
  if not src then
    return nil, "pane_not_found", string.format(MESSAGES.pane_not_found, tostring(target))
  end
  local pane = self:_new_pane(src.workspace_id, src.tab_id)
  self:emit("pane_created", { pane = copy(pane) })
  return { type = "pane_info", pane = copy(pane) }
end

D.handlers = handlers

-- Управление из теста ------------------------------------------------------------------

--- Событие всем подпискам, подписанным на него. Общие события (`pane_created`) получают
--- поле `type` в данных и доходят до записей `pane.created`; по-панельные (`pane.output_changed`)
--- идут без `type` подпискам с тем же видом и `pane_id`. Возвращает число получивших.
function D:emit(event, data)
  data = copy(data or dict())
  local general = not event:find(".", 1, true)
  local sub_type = event
  if general then
    if data.type == nil then
      data.type = event
    end
    sub_type = event:gsub("_", ".", 1)
  end
  local line = json.encode({ data = data, event = event })
  local delivered = 0
  for _, s in ipairs(self.subscriptions) do
    for _, rec in ipairs(s.subscriptions) do
      if rec.type == sub_type and (general or rec.pane_id == data.pane_id) then
        self:_write(self.connections[s.conn], line)
        delivered = delivered + 1
        break
      end
    end
  end
  if event == "pane_closed" and not is_nil(data.pane_id) then
    self:_end_pane_subscriptions(data.pane_id)
  end
  return delivered
end

-- Подписанная панель закрыта: каждая подписка с записью этой панели получает кадр
-- `{"id":<id подписки>,"error":{"code":"pane_not_found",…}}`, затем конец потока.
function D:_end_pane_subscriptions(pane_id)
  for _, s in ipairs(vim.list_slice(self.subscriptions)) do
    for _, rec in ipairs(s.subscriptions) do
      if rec.pane_id == pane_id then
        local c = self.connections[s.conn]
        self:_write(
          c,
          json.error(s.id, "pane_not_found", string.format(MESSAGES.pane_not_found, pane_id))
        )
        self:_close_conn(c, true)
        break
      end
    end
  end
end

--- Произвольная строка всем соединениям подписки (без перевода строки в `line`).
function D:emit_raw(line)
  for _, s in ipairs(self.subscriptions) do
    self:_write(self.connections[s.conn], line)
  end
end

--- Ошибка `events_lost` и закрытие всех соединений подписки.
function D:events_lost(message)
  for _, s in ipairs(vim.list_slice(self.subscriptions)) do
    local c = self.connections[s.conn]
    self:_write(c, json.error(s.id, "events_lost", message or MESSAGES.events_lost))
    self:_close_conn(c, true)
  end
end

--- Следующий вызов `method` ответит ошибкой `code` (текст по умолчанию — как у herdr).
--- Соединение после ответа закрывается, как после любого ответа, кроме начатой подписки.
function D:fail(method, code, message)
  self.failures[method] = self.failures[method] or {}
  table.insert(self.failures[method], { code = code, message = message })
end

--- Удерживать ответы на `method` (без аргумента — на все методы) до `release`.
--- Ответ вычисляется в момент запроса, отправляется при отпуске.
function D:hold(method)
  self.holds[method or "*"] = true
end

--- Отправить удержанные ответы на `method` (без аргумента — все) и снять удержание.
--- `opts.order = "reverse"` — в обратном порядке поступления (так же по умолчанию после
--- `reply_order("reverse")`).
function D:release(method, opts)
  self.holds[method or "*"] = nil
  if not method then
    self.holds = {}
  end
  local keep, out = {}, {}
  for _, h in ipairs(self.held) do
    if not method or h.method == method then
      table.insert(out, h)
    else
      table.insert(keep, h)
    end
  end
  self.held = keep
  local order = (opts and opts.order) or (self.reverse and "reverse") or "normal"
  if order == "reverse" then
    local rev = {}
    for i = #out, 1, -1 do
      table.insert(rev, out[i])
    end
    out = rev
  end
  for _, h in ipairs(out) do
    self:_write(h.conn, h.line)
    if h.after then
      h.after(h.conn)
    end
  end
end

--- Порядок ответов: "reverse" удерживает все ответы до `release()`, который отправит их
--- в обратном порядке; "normal" отправляет удержанные по порядку и снимает удержание.
function D:reply_order(order)
  if order == "reverse" then
    self.reverse = true
    self:hold()
  else
    self.reverse = false
    self:release()
  end
end

--- Число удержанных ответов на `method` (без аргумента — всех).
function D:held_count(method)
  local n = 0
  for _, h in ipairs(self.held) do
    if not method or h.method == method then
      n = n + 1
    end
  end
  return n
end

--- Число полученных запросов `method`.
function D:count(method)
  local n = 0
  for _, r in ipairs(self.requests) do
    if r.method == method then
      n = n + 1
    end
  end
  return n
end

--- Последний полученный запрос `method` или `nil`.
function D:last(method)
  for i = #self.requests, 1, -1 do
    if self.requests[i].method == method then
      return self.requests[i]
    end
  end
end

--- Протокол, который сообщает `ping`; `extra` — дополнительные поля ответа.
function D:set_protocol(n, extra)
  self.protocol = n
  self.ping_extra = extra
end

--- Вывод панели для `pane.read`: `lines` — логические строки (могут содержать
--- последовательности оформления ANSI), `width`/`height` — размер экрана (120×40),
--- `fullscreen` — полноэкранная программа (истории нет), `revision` — новая ревизия панели.
function D:set_output(pane_id, o)
  self.outputs[pane_id] = {
    lines = o.lines or { "" },
    width = o.width,
    height = o.height,
    fullscreen = o.fullscreen,
  }
  local p = self:_pane(pane_id)
  if p and o.revision then
    p.revision = o.revision
  end
end

--- Состояние, которого агент достигает после `agent.start` (по умолчанию "idle"):
--- "idle", "blocked" (диалог доверия) или "unknown" — состояние не меняется, пока тест
--- не вызовет `set_agent_status`.
function D:set_start_status(status)
  self.start_status = status
end

--- Смена состояния агента панели: запись в снимке и событие `pane.agent_status_changed`.
function D:set_agent_status(pane_id, status)
  local p = assert(self:_pane(pane_id), "нет панели " .. pane_id)
  p.agent_status = status
  p.state_change_seq = (p.state_change_seq or 0) + 1
  return self:emit("pane.agent_status_changed", {
    agent = p.agent,
    agent_status = status,
    pane_id = p.pane_id,
    workspace_id = p.workspace_id,
  })
end

--- Завершение процесса в панели: `pane_updated` и `pane_exited` (без кода выхода).
--- `opts.vanish` — панель исчезает из снимка без `pane_closed`, а с ней вкладка и workspace,
--- если в них не осталось панелей (без `tab_closed`/`workspace_closed`), как у herdr при
--- выходе процесса в единственной панели.
function D:pane_exited(pane_id, opts)
  local p, idx = self:_pane(pane_id)
  assert(p, "нет панели " .. pane_id)
  p.revision = (p.revision or 0) + 1
  local rec = copy(p)
  if opts and opts.vanish then
    table.remove(self.state.panes, idx)
    local tab_left, ws_left = false, false
    for _, q in ipairs(self.state.panes) do
      tab_left = tab_left or q.tab_id == p.tab_id
      ws_left = ws_left or q.workspace_id == p.workspace_id
    end
    if not tab_left then
      local _, ti = self:_tab(p.tab_id)
      if ti then
        table.remove(self.state.tabs, ti)
      end
    end
    if not ws_left then
      local _, wi = self:_workspace(p.workspace_id)
      if wi then
        table.remove(self.state.workspaces, wi)
      end
    end
  end
  self:emit("pane_updated", { pane = rec })
  self:emit("pane_exited", { pane_id = p.pane_id, workspace_id = p.workspace_id })
  if opts and opts.vanish then
    self:_end_pane_subscriptions(p.pane_id)
  end
end

--- Остановка сервера: соединения закрываются без кадра, файл сокета удаляется.
function D:stop()
  for _, c in pairs(self.connections) do
    self:_close_conn(c, false)
  end
  self.held = {}
  if self.server then
    self.server:close()
    self.server = nil
  end
  uv.fs_unlink(self.socket_path)
  self.running = false
end

--- Запуск сервера заново на том же пути: файл сокета создаётся снова (событие файловой
--- системы `rename` в каталоге сокета). Снимок сохраняется, как при восстановлении сессии.
function D:restart()
  if self.running then
    self:stop()
  end
  self:_listen()
  self.running = true
end

--- Полное завершение двойника в конце теста: остановка и возврат `HERDR_SOCKET_PATH`.
function D:close()
  self:stop()
  if self.env_set then
    if self.prev_env then
      uv.os_setenv("HERDR_SOCKET_PATH", self.prev_env)
    else
      uv.os_unsetenv("HERDR_SOCKET_PATH")
    end
    self.env_set = false
  end
end

-- Поддельный `herdr`: управление и журнал ------------------------------------------------

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function append_file(path, s)
  local f = assert(io.open(path, "ab"))
  f:write(s)
  f:close()
end

-- Запись файла заменой (новый файл и переименование), чтобы читатель не увидел половину.
local function replace_file(path, s)
  local tmp = path .. ".new"
  local f = assert(io.open(tmp, "wb"))
  f:write(s)
  f:close()
  assert(os.rename(tmp, path))
end

local function safe_name(s)
  return (tostring(s):gsub("[^%w%-_.:]", "_"))
end

--- Вызовы поддельного `herdr`: список `{argv = {...}, pid = n}` в порядке вызова.
function D:calls()
  local out = {}
  local s = read_file(self.fake_dir .. "/calls.jsonl") or ""
  for line in s:gmatch("[^\n]+") do
    table.insert(out, vim.json.decode(line))
  end
  return out
end

--- Кадр терминала для `herdr terminal session observe <target>`: `bytes` — сырой вывод ANSI
--- (двойник кодирует base64), `opts.full` (первый кадр наблюдателя — полный),
--- `opts.width`/`opts.height` (120×40). Номер `seq` ставит процесс наблюдения.
function D:frame(target, bytes, opts)
  opts = opts or {}
  local rec = {
    bytes = vim.base64.encode(bytes),
    full = opts.full or false,
    width = opts.width or 120,
    height = opts.height or 40,
  }
  append_file(
    self.fake_dir .. "/observe/" .. safe_name(target) .. ".frames",
    json.encode(rec) .. "\n"
  )
end

--- Экран, который рисует `herdr terminal attach <terminal_id>`.
function D:set_attach_screen(terminal_id, text)
  replace_file(self.fake_dir .. "/attach/" .. safe_name(terminal_id) .. ".screen", text)
end

--- Пометить терминал занятым другим клиентом с вводом (не поддельным процессом).
function D:mark_attached(terminal_id)
  replace_file(self.fake_dir .. "/attach/" .. safe_name(terminal_id) .. ".busy", "external")
end

--- Кто держит терминал: pid поддельного клиента строкой, "external" или `nil`.
function D:attached(terminal_id)
  local s = read_file(self.fake_dir .. "/attach/" .. safe_name(terminal_id) .. ".busy")
  if s and s ~= "" then
    return s
  end
end

--- Ввод, полученный поддельными клиентами `terminal attach` для терминала (байты как есть,
--- без клавиш отключения `Ctrl+b q`).
function D:attach_input(terminal_id)
  return read_file(self.fake_dir .. "/attach/" .. safe_name(terminal_id) .. ".input") or ""
end

-- Создание -----------------------------------------------------------------------------

--- Запуск двойника: `opts.dir` — каталог (сокет `<dir>/herdr.sock`), `opts.snapshot` —
--- начальный снимок, `opts.protocol` (22), `opts.env` (`false` — не задавать
--- `HERDR_SOCKET_PATH`, по умолчанию задаётся на время жизни двойника).
function M.start(opts)
  opts = opts or {}
  local dir = assert(opts.dir, "herdr_double.start: нужен opts.dir")
  local d = setmetatable({
    dir = dir,
    socket_path = dir .. "/herdr.sock",
    fake_dir = dir .. "/" .. M.FAKE_DIR,
    protocol = opts.protocol or M.PROTOCOL,
    connections = {},
    conn_seq = 0,
    requests = {},
    subscriptions = {},
    failures = {},
    holds = {},
    held = {},
    outputs = {},
    agent_names = {},
    start_status = "idle",
  }, D)
  for _, sub in ipairs({ "", "/observe", "/attach" }) do
    uv.fs_mkdir(d.fake_dir .. sub, 493)
  end
  d:set_snapshot(opts.snapshot)
  d:_listen()
  d.running = true
  if opts.env ~= false then
    d.prev_env = uv.os_getenv("HERDR_SOCKET_PATH")
    uv.os_setenv("HERDR_SOCKET_PATH", d.socket_path)
    d.env_set = true
  end
  return d
end

return M
