-- Запуск дополнительной сессии Claude Code (спецификация session-launch, решение D19).
--
-- Новая вкладка: `tab.create` (без рабочего каталога), затем `agent.start` с видом `claude`
-- в корневой панели созданной вкладки. Деление: `pane.split` выбранной панели, затем
-- `agent.start` в созданной. `agent.start` идёт без `timeout_ms`: сервер отвечает сразу,
-- плагин сообщает «агент запускается», а готовность (`idle`) или диалог доверия (`blocked`)
-- узнаёт по состоянию панели в снимке, перечитанном по событию. Созданное при ошибке
-- не закрывается, повторного `agent.start` нет. Появление узла в дереве — по событиям
-- herdr, без особой обработки. Сроков, таймеров и опроса нет.
local commands = require("claudr.commands")
local herdr = require("claudr.herdr")

local M = {}

M.KIND = "claude"

local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO)
end

local function present(v)
  return v ~= nil and v ~= vim.NIL and v ~= ""
end

local function error_text(method, err)
  return ("claudr: %s: %s: %s"):format(method, tostring(err.code), tostring(err.message))
end

local function done(opts, err, result)
  if opts.on_done then
    opts.on_done(err, result)
  end
end

-- Сообщение о недоступности сервера; `true`, если сервера нет.
local function server_missing()
  local st = herdr.state()
  if st.status == "connected" then
    return false
  end
  local text = "claudr: сервер herdr недоступен, ничего не создано"
  if st.status == "stopped" then
    text = text
      .. " (подключение не запущено: откройте дерево командой :Claudr tree)"
  elseif present(st.message) then
    text = text .. " (" .. st.message .. ")"
  end
  notify(text, vim.log.levels.ERROR)
  return true
end

-- Имя агента для `agent.start`: протокол требует имя; берётся от идентификатора панели.
local function agent_name(pane_id)
  return "claudr-" .. pane_id:gsub("[^%w]+", "-")
end

-- Запись панели `pane_id` в снимке или `nil`.
local function find_pane(snapshot, pane_id)
  for _, p in ipairs(snapshot and snapshot.panes or {}) do
    if p.pane_id == pane_id then
      return p
    end
  end
end

local READY_HINT = "ответьте на диалог подключением с вводом (:Claudr attach, клавиша i в дереве) "
  .. "или клавишами (:Claudr keys, клавиша K в дереве); повторный запуск не выполняется"

--- Слежение за готовностью агента в панели `pane_id` после ответа `agent.start`: по
--- снимку, перечитанному после события `pane.agent_status_changed`. `blocked` (диалог
--- доверия) даёт одно сообщение «не готов», слежение продолжается; `idle` (готов) или
--- исчезновение панели дают сообщение и снимают подписку. Сроков, таймеров и опроса нет.
local function watch_ready(pane_id)
  local seen, blocked = false, false
  local unsubscribe
  local function check(st, events)
    if st.status ~= "connected" then
      return false
    end
    local p = find_pane(st.snapshot, pane_id)
    if p then
      seen = true
      if p.agent_status == "idle" then
        notify(("claudr: агент в панели %s готов"):format(pane_id))
        return true
      elseif p.agent_status == "blocked" and not blocked then
        blocked = true
        notify(
          ("claudr: агент в панели %s не готов: ждёт ответа на диалог доверия к каталогу; %s"):format(
            pane_id,
            READY_HINT
          ),
          vim.log.levels.WARN
        )
      end
      return false
    end
    local closed = seen and not st.stale
    for _, ev in ipairs(events or {}) do
      if ev.event == "pane_closed" and type(ev.data) == "table" and ev.data.pane_id == pane_id then
        closed = true
      end
    end
    if closed then
      notify(
        ("claudr: панель %s закрыта до готовности агента"):format(
          pane_id
        ),
        vim.log.levels.WARN
      )
    end
    return closed
  end
  if check(herdr.state()) then
    return
  end
  unsubscribe = herdr.subscribe(function(st, events)
    if unsubscribe and check(st, events) then
      unsubscribe()
      unsubscribe = nil
    end
  end)
end

--- Запуск агента `claude` в панели `pane_id` без `timeout_ms`: сервер отвечает сразу, не
--- дожидаясь готовности; готовность сообщает `watch_ready`. Ошибка сервера, в том числе
--- `agent_not_ready`, показывается кодом и текстом; панель остаётся, повторного запуска нет.
local function start_agent(pane_id, opts)
  herdr.request(
    "agent.start",
    { name = agent_name(pane_id), kind = M.KIND, pane_id = pane_id },
    function(err, result)
      if err then
        if err.code == "server_unavailable" then
          notify(
            ("claudr: сервер herdr недоступен: агент в панели %s не запущен, панель оставлена"):format(
              pane_id
            ),
            vim.log.levels.ERROR
          )
        else
          notify(
            error_text("agent.start", err)
              .. (" (панель %s оставлена, повторный запуск не выполняется)"):format(
                pane_id
              ),
            vim.log.levels.ERROR
          )
        end
        done(opts, err, { pane_id = pane_id })
        return
      end
      local agent = result and result.agent or {}
      local session = type(agent.agent_session) == "table" and agent.agent_session.value or nil
      local text = ("claudr: агент Claude Code запускается в панели %s"):format(
        pane_id
      )
      if present(session) then
        text = text .. (" (сессия %s)"):format(session)
      else
        session = nil
      end
      notify(text .. "…")
      watch_ready(pane_id)
      done(opts, nil, { pane_id = pane_id, session_id = session, agent = agent })
    end
  )
end

local function launch_tab(workspace_id, opts)
  herdr.request("tab.create", { workspace_id = workspace_id }, function(err, result)
    if err then
      notify(error_text("tab.create", err), vim.log.levels.ERROR)
      done(opts, err)
      return
    end
    local pane = result and result.root_pane
    if type(pane) ~= "table" or not present(pane.pane_id) then
      local e =
        { code = "invalid_response", message = "в ответе tab.create нет root_pane" }
      notify(error_text("tab.create", e), vim.log.levels.ERROR)
      done(opts, e)
      return
    end
    start_agent(pane.pane_id, opts)
  end)
end

local function launch_split(pane_id, direction, opts)
  herdr.request(
    "pane.split",
    { target_pane_id = pane_id, direction = direction },
    function(err, result)
      if err then
        notify(error_text("pane.split", err), vim.log.levels.ERROR)
        done(opts, err)
        return
      end
      local pane = result and result.pane
      if type(pane) ~= "table" or not present(pane.pane_id) then
        local e = { code = "invalid_response", message = "в ответе pane.split нет pane" }
        notify(error_text("pane.split", e), vim.log.levels.ERROR)
        done(opts, e)
        return
      end
      start_agent(pane.pane_id, opts)
    end
  )
end

-- Выбор из перечня; `cb(choice)`.
local function select(items, prompt, format, cb)
  vim.ui.select(items, { prompt = prompt, format_item = format }, function(choice)
    if choice ~= nil then
      cb(choice)
    end
  end)
end

local function select_workspace(cb)
  local list = herdr.state().snapshot.workspaces or {}
  if #list == 0 then
    notify("claudr: нет workspace", vim.log.levels.WARN)
    return
  end
  select(list, "Workspace:", function(w)
    return present(w.label) and ("%s (%s)"):format(w.label, w.workspace_id) or w.workspace_id
  end, function(w)
    cb(w.workspace_id)
  end)
end

-- Панели workspace или вкладки (по полю `field`) для выбора деления.
local function select_pane(field, id, cb)
  local tabs = {}
  for _, t in ipairs(herdr.state().snapshot.tabs or {}) do
    tabs[t.tab_id] = present(t.label) and t.label or t.tab_id
  end
  local panes = {}
  for _, p in ipairs(herdr.state().snapshot.panes or {}) do
    if p[field] == id then
      panes[#panes + 1] = p
    end
  end
  table.sort(panes, function(a, b)
    return a.pane_id < b.pane_id
  end)
  if #panes == 0 then
    notify("claudr: нет панелей для деления", vim.log.levels.WARN)
    return
  end
  select(panes, "Панель для деления:", function(p)
    local what = present(p.agent) and p.agent or tostring(p.foreground_process)
    return ("%s / %s (%s)"):format(tabs[p.tab_id] or p.tab_id, p.pane_id, what)
  end, function(p)
    cb(p.pane_id)
  end)
end

local DIRECTIONS = { { id = "right", text = "вправо" }, { id = "down", text = "вниз" } }

local function select_direction(cb)
  select(DIRECTIONS, "Направление деления:", function(d)
    return d.text
  end, function(d)
    cb(d.id)
  end)
end

local function target_node(opts)
  local node = opts.node
  if not node and not (opts.workspace_id or opts.pane_id) then
    node = require("claudr.tree.view").node_at_cursor()
  end
  -- у субагента и фоновой команды своей панели, вкладки и workspace для запуска нет:
  -- цель выбирается из перечня
  if node and (node.kind == "subagent" or node.kind == "task") then
    return nil
  end
  return node
end

local function workspace_of(node)
  if node.kind == "workspace" then
    return node.id
  end
  return node.data and node.data.workspace_id
end

-- Деление: панель из узла, перечня вкладки или перечня workspace, затем направление.
local function split_flow(node, opts)
  local function with_pane(pane_id)
    if opts.direction then
      launch_split(pane_id, opts.direction, opts)
    else
      select_direction(function(direction)
        launch_split(pane_id, direction, opts)
      end)
    end
  end
  if opts.pane_id then
    with_pane(opts.pane_id)
  elseif node and node.kind == "pane" then
    with_pane(node.id)
  elseif node and node.kind == "tab" then
    select_pane("tab_id", node.id, with_pane)
  elseif node and node.kind == "workspace" then
    select_pane("workspace_id", node.id, with_pane)
  elseif opts.workspace_id then
    select_pane("workspace_id", opts.workspace_id, with_pane)
  else
    select_workspace(function(ws)
      select_pane("workspace_id", ws, with_pane)
    end)
  end
end

local function tab_flow(node, opts)
  local ws = opts.workspace_id or (node and workspace_of(node))
  if present(ws) then
    launch_tab(ws, opts)
  else
    select_workspace(function(id)
      launch_tab(id, opts)
    end)
  end
end

local MODES = {
  { id = "tab", text = "в новой вкладке" },
  { id = "split", text = "делением панели" },
}

--- Запуск сессии. `opts`: `node` (узел дерева; без него — узел под курсором дерева),
--- `mode` ("tab" — новая вкладка, "split" — деление панели; без него для вкладки и панели
--- спрашивается, для workspace и без узла — новая вкладка), `direction` ("right"|"down"),
--- `workspace_id`, `pane_id`, `on_done(err, result)` (`result = {pane_id, session_id}`).
---@param opts table|nil
function M.launch(opts)
  opts = opts or {}
  if server_missing() then
    done(opts, { code = "server_unavailable" })
    return
  end
  local node = target_node(opts)
  local mode = opts.mode
  if not mode and opts.pane_id then
    mode = "split"
  end
  local function run(m)
    if m == "split" then
      split_flow(node, opts)
    else
      tab_flow(node, opts)
    end
  end
  if mode then
    run(mode)
  elseif node and (node.kind == "tab" or node.kind == "pane") then
    select(MODES, "Запуск сессии:", function(m)
      return m.text
    end, function(m)
      run(m.id)
    end)
  else
    run("tab")
  end
end

local function complete(arglead, args)
  local words = {}
  if #args == 0 then
    words = { "tab", "split" }
  elseif args[1] == "split" and #args == 1 then
    words = { "right", "down" }
  end
  return vim.tbl_filter(function(w)
    return vim.startswith(w, arglead)
  end, words)
end

--- Регистрирует подкоманду и действие дерева.
function M.setup()
  commands.register("launch", function(args)
    local mode, direction
    if args[1] == "tab" or args[1] == "split" then
      mode = args[1]
      direction = args[2]
    end
    if direction and direction ~= "right" and direction ~= "down" then
      notify(
        "claudr: направление деления: right или down",
        vim.log.levels.ERROR
      )
      return
    end
    M.launch({ mode = mode, direction = direction })
  end, {
    desc = "запустить сессию Claude Code (tab — вкладка, split [right|down] — деление)",
    complete = complete,
  })
  require("claudr.tree.view").register_action("launch", {
    key = "L",
    desc = "запустить сессию Claude Code",
    run = function(node)
      M.launch({ node = node })
    end,
  })
end

return M
