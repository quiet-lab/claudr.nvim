-- Модель дерева (спецификация agent-tree, решение D17): узлы без буферов и окон.
--
-- Источники: снимок клиента herdr (workspace, вкладки, панели) и слежение модуля данных
-- Claude Code за сессией каждой панели с агентом Claude Code (субагенты и фоновые команды).
-- Модель целиком перестраивается из `state.snapshot` при каждом вызове подписчика herdr и
-- при каждом уведомлении модуля данных; список событий herdr нужен только для `pane_exited`,
-- которого в снимке нет. Таймеров и опроса нет.
--
-- Узел: `{ id, kind, pane_kind, label, text_label, state, icon, color, parent, children,
-- data, owner_pane }`:
--   kind       "workspace" | "tab" | "pane" | "subagent" | "task";
--   pane_kind  у панели — "agent" | "command", у остальных nil;
--   label      подпись без состояния; у workspace — «<символ> <label>» по токену `symbol`;
--   text_label у workspace — `label` без символа (для режима `icons = "text"`), иначе nil;
--   state      у панели с агентом, вкладки и workspace — `agent_status` как есть; у субагента
--              и команды — "running" | "finished" | "orphaned"; иначе nil;
--   icon       состояние значка: "idle" | "working" | "blocked" | "done" | "unknown" или
--              неизвестное значение `agent_status` как есть; nil — значка состояния нет
--              (панель с командой, нет `agent_status`). Кадры выбирает отображение;
--   color      цвет подписи `#RRGGBB` из токена `color` workspace у workspace, его вкладок и
--              панелей с агентом, иначе nil;
--   parent     идентификатор родителя или nil; children — идентификаторы детей по порядку;
--   data       исходная запись (снимка herdr или модуля данных);
--   owner_pane у субагента и команды — идентификатор панели владельца.
-- Идентификаторы: workspace, вкладка, панель — как в herdr; субагент и фоновая команда —
-- `<панель владельца>/<идентификатор субагента или задачи>`.
local herdr = require("claudr.herdr")
local data = require("claudr.data")
local config = require("claudr.config")

local M = {}

local S = {
  started = false,
  unsubscribe = nil,
  nodes = {},
  roots = {},
  status = { status = "stopped" },
  snapshot = { workspaces = {}, tabs = {}, panes = {} },
  -- панель → { sid, handle, alive }: слежение за сессией Claude Code панели
  sessions = {},
  -- панель → номер вызова подписчика herdr, в котором пришло `pane_exited`: процесс панели
  -- завершён
  exited = {},
  batch = 0,
  syncing = false,
}

local subscribers = {}

local function present(v)
  return v ~= nil and v ~= vim.NIL and v ~= ""
end

local function str(v)
  if present(v) then
    return tostring(v)
  end
  return nil
end

local function notify()
  for _, s in ipairs({ unpack(subscribers) }) do
    if s.active then
      local ok, err = pcall(s.cb, M)
      if not ok then
        vim.notify(
          "claudr: ошибка подписчика дерева: " .. tostring(err),
          vim.log.levels.ERROR
        )
      end
    end
  end
end

-- Подписи ------------------------------------------------------------------------------

local function join(parts)
  local out = {}
  for _, p in ipairs(parts) do
    if present(p) then
      out[#out + 1] = tostring(p)
    end
  end
  return table.concat(out, " ")
end

local function pane_kind(p)
  return present(p.agent) and "agent" or "command"
end

local function pane_label(p)
  if pane_kind(p) == "agent" then
    local title = str(p.terminal_title_stripped) or str(p.terminal_title)
    return join({ str(p.display_agent) or str(p.agent), title })
  end
  return join({ str(p.foreground_process), str(p.cwd) or str(p.foreground_cwd) })
end

local function subagent_label(s)
  local label = join({ str(s.description), present(s.agent_type) and ("(" .. s.agent_type .. ")") })
  if label == "" then
    label = s.id
  end
  if s.status == "finished" and s.stop == "killed" then
    label = label .. ", остановлен"
  end
  return label
end

local function task_label(t)
  local label = str(t.description) or str(t.command) or t.id
  if t.status == "finished" then
    if t.result == "killed" then
      label = label .. ", остановлена"
    end
    if t.exit_code ~= nil and t.exit_code ~= vim.NIL then
      label = label .. ", код выхода " .. tostring(t.exit_code)
    end
  end
  return label
end

-- Значки и цвета ------------------------------------------------------------------------

-- Состояние значка субагента и фоновой команды (решение D41).
local TASK_ICON = { running = "working", finished = "done", orphaned = "unknown" }

--- Цвет токена `color` в виде `#RRGGBB` или nil, если это не цвет `#RGB`/`#RRGGBB`.
function M.color(v)
  if type(v) ~= "string" then
    return nil
  end
  local hex = v:match("^#(%x+)$")
  if not hex then
    return nil
  end
  if #hex == 3 then
    hex = hex:gsub(".", "%0%0")
  elseif #hex ~= 6 then
    return nil
  end
  return "#" .. hex:lower()
end

local function tokens_of(w)
  return type(w.tokens) == "table" and w.tokens or {}
end

--- Подпись workspace: «<символ> <label>»; без символа или при `label`, уже начинающемся с
--- символа, — `label`.
local function workspace_label(w)
  local label = str(w.label) or w.workspace_id
  local symbol = str(tokens_of(w).symbol)
  if not symbol or vim.startswith(label, symbol) then
    return label
  end
  return symbol .. " " .. label
end

-- Слежение за сессиями -----------------------------------------------------------------

local rebuild

local function on_session_change()
  if not S.syncing then
    rebuild()
  end
end

local function close_session(pane_id)
  local s = S.sessions[pane_id]
  if s then
    S.sessions[pane_id] = nil
    if s.alive then
      s.handle:set_owner_alive(false)
    end
    s.handle:close()
  end
end

local function open_session(pane_id, sid)
  local h = data.watch_session(sid, on_session_change)
  S.sessions[pane_id] = { sid = sid, handle = h, alive = true }
end

-- Привести слежение за сессиями к снимку и событиям.
local function sync_sessions(panes)
  S.syncing = true
  local seen = {}
  for _, p in ipairs(panes) do
    local id = p.pane_id
    seen[id] = true
    local sid = herdr.session_id(p)
    local s = S.sessions[id]
    if s and sid and s.sid ~= sid then
      -- смена сессии: прежняя больше не принадлежит панели
      close_session(id)
      S.exited[id] = nil
      s = nil
    end
    if sid and not s then
      -- `pane_exited` из прежних вызовов относится к процессу без этой сессии
      if S.exited[id] and S.exited[id] ~= S.batch then
        S.exited[id] = nil
      end
      open_session(id, sid)
      s = S.sessions[id]
    elseif not sid and s and not S.exited[id] then
      -- выход агента: панель вернулась к оболочке
      close_session(id)
      s = nil
    end
    if s and S.exited[id] and s.alive then
      s.alive = false
      s.handle:set_owner_alive(false)
    end
  end
  for id in pairs(S.sessions) do
    if not seen[id] then
      close_session(id) -- панель закрыта
    end
  end
  for id in pairs(S.exited) do
    if not seen[id] then
      S.exited[id] = nil
    end
  end
  S.syncing = false
end

-- Построение ---------------------------------------------------------------------------

local function sorted(list, key)
  local items = {}
  for i, rec in ipairs(list) do
    local n = tonumber(rec.number)
    if not n and type(rec[key]) == "string" then
      n = tonumber(rec[key]:match("(%d+)$"))
    end
    items[#items + 1] = { rec = rec, n = n or math.huge, i = i }
  end
  table.sort(items, function(a, b)
    if a.n ~= b.n then
      return a.n < b.n
    end
    return a.i < b.i
  end)
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = it.rec
  end
  return out
end

local function add(nodes, node, parent_id)
  node.children = {}
  node.parent = parent_id
  nodes[node.id] = node
  if parent_id and nodes[parent_id] then
    table.insert(nodes[parent_id].children, node.id)
  end
  return node
end

-- Субагенты и фоновые команды сессии под узлом панели.
local function add_session(nodes, pane_id, st)
  local prefix = pane_id .. "/"
  local subs = {}
  for id, s in pairs(st.subagents or {}) do
    subs[#subs + 1] = s
    nodes[prefix .. id] = {
      id = prefix .. id,
      kind = "subagent",
      label = subagent_label(s),
      state = s.status,
      icon = TASK_ICON[s.status] or str(s.status),
      data = s,
      owner_pane = pane_id,
      children = {},
    }
  end
  table.sort(subs, function(a, b)
    local da, db = tonumber(a.spawn_depth) or 1, tonumber(b.spawn_depth) or 1
    if da ~= db then
      return da < db
    end
    return a.id < b.id
  end)
  for _, s in ipairs(subs) do
    local node = nodes[prefix .. s.id]
    local parent = pane_id
    if present(s.parent_id) and nodes[prefix .. s.parent_id] then
      parent = prefix .. s.parent_id
    end
    node.parent = parent
    table.insert(nodes[parent].children, node.id)
  end
  local tasks = {}
  for _, t in pairs(st.tasks or {}) do
    tasks[#tasks + 1] = t
  end
  table.sort(tasks, function(a, b)
    return a.id < b.id
  end)
  for _, t in ipairs(tasks) do
    local parent = pane_id
    if present(t.owner) and nodes[prefix .. t.owner] then
      parent = prefix .. t.owner
    end
    add(nodes, {
      id = prefix .. t.id,
      kind = "task",
      label = task_label(t),
      state = t.status,
      icon = TASK_ICON[t.status] or str(t.status),
      data = t,
      owner_pane = pane_id,
    }, parent)
  end
end

local function build(snap)
  local nodes, roots = {}, {}
  local workspaces = sorted(snap.workspaces or {}, "workspace_id")
  local ws_by_id = {}
  for _, w in ipairs(workspaces) do
    if present(w.workspace_id) then
      ws_by_id[w.workspace_id] = w
    end
  end
  -- Родитель workspace: запись с `parent_workspace_id`, если она есть в снимке и не даёт цикла.
  local function parent_of(w)
    local pid = str(w.parent_workspace_id)
    if not pid or not ws_by_id[pid] then
      return nil
    end
    local seen, cur = { [w.workspace_id] = true }, pid
    while cur do
      if seen[cur] then
        return nil
      end
      seen[cur] = true
      cur = str(ws_by_id[cur].parent_workspace_id)
      if cur and not ws_by_id[cur] then
        cur = nil
      end
    end
    return pid
  end
  for _, w in ipairs(workspaces) do
    if present(w.workspace_id) then
      nodes[w.workspace_id] = {
        id = w.workspace_id,
        kind = "workspace",
        label = workspace_label(w),
        text_label = str(w.label) or w.workspace_id,
        state = str(w.agent_status),
        icon = str(w.agent_status),
        color = M.color(tokens_of(w).color),
        data = w,
        children = {},
      }
    end
  end
  for _, w in ipairs(workspaces) do
    local node = nodes[w.workspace_id]
    if node then
      node.parent = parent_of(w)
      if not node.parent then
        roots[#roots + 1] = node.id
      end
    end
  end
  -- цвет подписи по workspace записи
  local function color_of(ws_id)
    local w = present(ws_id) and ws_by_id[ws_id]
    return w and M.color(tokens_of(w).color) or nil
  end
  for _, t in ipairs(sorted(snap.tabs or {}, "tab_id")) do
    if present(t.tab_id) then
      local parent = nodes[t.workspace_id] and t.workspace_id or nil
      add(nodes, {
        id = t.tab_id,
        kind = "tab",
        label = str(t.label) or t.tab_id,
        state = str(t.agent_status),
        icon = str(t.agent_status),
        color = color_of(t.workspace_id),
        data = t,
      }, parent)
      if not parent then
        roots[#roots + 1] = t.tab_id
      end
    end
  end
  for _, p in ipairs(sorted(snap.panes or {}, "pane_id")) do
    if present(p.pane_id) then
      local parent = (nodes[p.tab_id] and nodes[p.tab_id].kind == "tab" and p.tab_id)
        or (nodes[p.workspace_id] and p.workspace_id)
        or nil
      local kind = pane_kind(p)
      add(nodes, {
        id = p.pane_id,
        kind = "pane",
        pane_kind = kind,
        label = pane_label(p),
        state = kind == "agent" and str(p.agent_status) or nil,
        icon = kind == "agent" and str(p.agent_status) or nil,
        color = kind == "agent" and color_of(p.workspace_id) or nil,
        data = p,
      }, parent)
      if not parent then
        roots[#roots + 1] = p.pane_id
      end
      local s = S.sessions[p.pane_id]
      if s then
        add_session(nodes, p.pane_id, s.handle:state())
      end
    end
  end
  -- вложенные workspace идут после вкладок своего родителя
  for _, w in ipairs(workspaces) do
    local node = nodes[w.workspace_id]
    if node and node.parent then
      table.insert(nodes[node.parent].children, node.id)
    end
  end
  return nodes, roots
end

rebuild = function()
  local snap = S.snapshot
  sync_sessions(snap.panes or {})
  S.nodes, S.roots = build(snap)
  notify()
end

local function on_herdr(state, events)
  S.batch = S.batch + 1
  for _, ev in ipairs(events or {}) do
    if ev.event == "pane_exited" and type(ev.data) == "table" and present(ev.data.pane_id) then
      S.exited[ev.data.pane_id] = S.batch
    end
  end
  S.status = { status = state.status, message = state.message }
  S.snapshot = state.snapshot or { workspaces = {}, tabs = {}, panes = {} }
  rebuild()
end

-- Публичный API -------------------------------------------------------------------------

--- Запускает модель: подключение клиента herdr и подписка на его состояние. Повторный
--- вызов безвреден.
function M.start()
  if S.started then
    return
  end
  S.started = true
  S.unsubscribe = herdr.subscribe(on_herdr)
  herdr.start()
  on_herdr(herdr.state(), {})
end

--- Останавливает модель: отписка от клиента, слежение за сессиями закрывается, узлы
--- очищаются. Клиент herdr не останавливается. Подписчики сохраняются.
function M.stop()
  if S.unsubscribe then
    S.unsubscribe()
    S.unsubscribe = nil
  end
  S.started = false
  S.snapshot = { workspaces = {}, tabs = {}, panes = {} }
  S.syncing = true
  for id in pairs(S.sessions) do
    close_session(id)
  end
  S.syncing = false
  S.exited = {}
  S.status = { status = "stopped" }
  S.nodes, S.roots = {}, {}
  notify()
end

--- Запущена ли модель.
function M.started()
  return S.started
end

--- Узел по идентификатору или nil.
function M.get(id)
  return S.nodes[id]
end

--- Корневые узлы по порядку (узлы, а не идентификаторы).
function M.roots()
  local out = {}
  for _, id in ipairs(S.roots) do
    out[#out + 1] = S.nodes[id]
  end
  return out
end

--- Дочерние узлы узла `id` по порядку (узлы).
function M.children(id)
  local node = S.nodes[id]
  local out = {}
  for _, cid in ipairs(node and node.children or {}) do
    out[#out + 1] = S.nodes[cid]
  end
  return out
end

--- Все узлы, удовлетворяющие `pred(node)` (без `pred` — все), в порядке обхода дерева.
function M.find(pred)
  local out = {}
  local function walk(id)
    local node = S.nodes[id]
    if not node then
      return
    end
    if not pred or pred(node) then
      out[#out + 1] = node
    end
    for _, cid in ipairs(node.children) do
      walk(cid)
    end
  end
  for _, id in ipairs(S.roots) do
    walk(id)
  end
  return out
end

--- Состояние клиента herdr: `{status, message}`; "no_server" — нет сервера.
function M.status()
  return S.status
end

--- Подписка на изменения модели: `cb(model)` после каждого перестроения. Возвращает
--- функцию отписки.
function M.subscribe(cb)
  local s = { cb = cb, active = true }
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

--- Показ завершённых субагентов и фоновых команд (настройка `show_finished`).
function M.show_finished()
  return config.get().show_finished ~= false
end

--- Задаёт показ завершённых узлов и уведомляет подписчиков.
function M.set_show_finished(value)
  config.get().show_finished = value and true or false
  notify()
end

--- Переключает показ завершённых узлов; возвращает новое значение.
function M.toggle_finished()
  M.set_show_finished(not M.show_finished())
  return M.show_finished()
end

--- Виден ли узел при текущем показе завершённых: завершённый субагент или команда скрыт,
--- если показ выключен и под ним нет видимых узлов (работающих или оборванных).
function M.visible(node)
  if not node then
    return false
  end
  if M.show_finished() then
    return true
  end
  if (node.kind == "subagent" or node.kind == "task") and node.state == "finished" then
    for _, cid in ipairs(node.children) do
      if M.visible(S.nodes[cid]) then
        return true
      end
    end
    return false
  end
  return true
end

-- Только для тестов: слежение за сессиями по панелям.
function M._sessions()
  return S.sessions
end

-- Только для тестов: панели с полученным `pane_exited`.
function M._exited()
  return S.exited
end

return M
