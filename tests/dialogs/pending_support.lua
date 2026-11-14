-- Общие помощники тестов перечня запросов хука: двойник herdr с панелью Claude Code, каталог
-- данных Claude Code с транскриптами образцов hook_samples, двойник хука, запуск перечня.
local t = require("helpers.t")
local double = require("helpers.herdr_double")
local hook_double = require("helpers.hook_double")
local samples = require("helpers.hook_samples")
local hsupport = require("herdr.support")
local u = require("data.util")
local herdr = require("claudr.herdr")
local model = require("claudr.tree.model")
local config = require("claudr.config")
local pending = require("claudr.dialogs.pending")
local socket = require("claudr.dialogs.socket")

local M = {}

M.samples = samples
M.PANE = "w1:p1"
M.SUB_NODE = M.PANE .. "/" .. samples.agent_id

local current

-- Путь транскрипта сессии образцов в каталоге данных Claude Code.
function M.transcript()
  return M.claude_dir .. "/projects/-srv-demo-alpha/" .. samples.session_id .. ".jsonl"
end

-- Путь транскрипта субагента образцов.
function M.sub_transcript()
  return M.claude_dir
    .. "/projects/-srv-demo-alpha/"
    .. samples.session_id
    .. "/subagents/agent-"
    .. samples.agent_id
    .. ".jsonl"
end

local function write(path, text, mode)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, mode or "w"))
  f:write(text)
  f:close()
end

--- Записи образца транскрипта `name` (список таблиц); `from`, `to` — срез по номерам.
function M.records(name, from, to)
  local recs = samples.records(name, M.claude_dir)
  return vim.list_slice(recs, from, to)
end

--- Дописывает записи в файл транскрипта (создаёт его при необходимости).
function M.append(path, recs)
  local lines = {}
  for _, r in ipairs(recs) do
    lines[#lines + 1] = vim.json.encode(r)
  end
  write(path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""), "a")
end

--- Запись `assistant` с вызовами `uses` (`{ {id, name, input}, … }`).
function M.uses_record(uses)
  local content = {}
  for _, x in ipairs(uses) do
    content[#content + 1] = { type = "tool_use", id = x.id, name = x.name, input = x.input }
  end
  return {
    type = "assistant",
    sessionId = samples.session_id,
    message = { role = "assistant", content = content },
  }
end

--- Запись `user` с результатом вызова `id`.
function M.result_record(id, is_error)
  return {
    type = "user",
    sessionId = samples.session_id,
    message = {
      role = "user",
      content = { { type = "tool_result", tool_use_id = id, content = "ok", is_error = is_error } },
    },
  }
end

--- Вложение `hook_permission_decision` для вызова `id`.
function M.decision_record(id, decision)
  return {
    type = "attachment",
    sessionId = samples.session_id,
    attachment = {
      type = "hook_permission_decision",
      decision = decision or "allow",
      toolUseID = id,
      hookEvent = "PermissionRequest",
    },
  }
end

--- Окружение теста: каталог данных Claude Code (транскрипт сессии с записями `opts.records`,
--- при `opts.subagent` — субагент образцов с meta.json и транскриптом из `opts.sub_records`),
--- двойник herdr с панелью Claude Code `w1:p1` этой сессии, запущенные модель дерева и перечень.
--- Возвращает двойник herdr.
function M.env(opts)
  opts = opts or {}
  M.claude_dir = u.fresh()
  M.append(M.transcript(), opts.records or M.records("bash-pending", 1, 1))
  if opts.subagent then
    local meta = M.sub_transcript():gsub("%.jsonl$", ".meta.json")
    write(meta, vim.json.encode({ agentType = "general-purpose", description = "sub" }))
    M.append(M.sub_transcript(), opts.sub_records or M.records("subagent", 1, 1))
  end
  local snapshot = {
    workspaces = { double.workspace({ workspace_id = "w1", label = "ws1" }) },
    tabs = { double.tab({ tab_id = "w1:t1", label = "main" }) },
    panes = {
      double.pane({
        pane_id = M.PANE,
        agent = "claude",
        agent_status = "blocked",
        session = samples.session_id,
      }),
    },
  }
  local d = double.start({ dir = hsupport.dir("dlg"), snapshot = snapshot })
  current = d
  model.start()
  hsupport.wait_status(herdr, "connected")
  t.wait(function()
    return model.get(M.PANE) ~= nil
  end, "узел панели")
  if opts.subagent then
    t.wait(function()
      return model.get(M.SUB_NODE) ~= nil
    end, "узел субагента")
  end
  assert(pending.start())
  return d
end

--- Уборка после теста.
function M.reset()
  hook_double.stop_all()
  pending.stop()
  model.stop()
  herdr.stop()
  if current then
    current:close()
    current = nil
  end
  config.setup({})
end

--- Окружение хука по умолчанию: панель `w1:p1` и сервер двойника.
function M.hook_env(over)
  local env = { HERDR_PANE_ID = M.PANE, HERDR_SOCKET_PATH = current.socket_path }
  for k, v in pairs(over or {}) do
    env[k] = v ~= vim.NIL and v or nil
  end
  return env
end

--- Вход образца `name` с заменой полей `tool_input` из `over`.
function M.input(name, over)
  local input = samples.input(name, M.claude_dir)
  for k, v in pairs(over or {}) do
    input.tool_input[k] = v
  end
  return input
end

--- Запускает двойника хука со входом `input` и ждёт, пока запрос появится в перечне.
--- Возвращает двойника и запрос.
function M.request(input, env)
  local before = #pending.list()
  local h = hook_double.spawn({ socket = socket.path(), input = input, env = env or M.hook_env() })
  t.wait(function()
    return #pending.list() > before
  end, "запрос в перечне")
  return h, pending.list()[before + 1]
end

--- Ждёт, пока запрос не окажется в состоянии `state`.
function M.wait_state(req, state)
  t.wait(function()
    return req.state == state
  end, "состояние " .. state)
end

--- Ждёт идентификатора вызова запроса.
function M.wait_id(req)
  t.wait(function()
    return req.tool_use_id ~= nil
  end, "идентификатор вызова")
  return req.tool_use_id
end

M.settle = u.settle
M.count_reads = u.count_reads
M.timer_count = u.timer_count
M.fs_event_count = u.fs_event_count

return M
