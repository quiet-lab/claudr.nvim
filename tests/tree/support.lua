-- Общие помощники тестов дерева: двойник herdr, образцы Claude Code, запуск модели.
local t = require("helpers.t")
local double = require("helpers.herdr_double")
local fixtures = require("helpers.fixtures")
local hsupport = require("herdr.support")
local u = require("data.util")
local herdr = require("claudr.herdr")
local model = require("claudr.tree.model")
local config = require("claudr.config")

local M = {}

M.double = double
M.fixtures = fixtures

local current

--- Окружение теста: каталог данных Claude Code с образцами `samples`, двойник herdr со
--- снимком `snapshot`, запущенная модель, подписки клиента по всем панелям. Возвращает
--- двойник.
function M.env(snapshot, samples)
  M.claude_dir = u.fresh(samples)
  local d = double.start({ dir = hsupport.dir("tree"), snapshot = snapshot })
  current = d
  model.start()
  hsupport.wait_status(herdr, "connected")
  local ids = {}
  for _, p in ipairs(snapshot.panes or {}) do
    ids[#ids + 1] = p.pane_id
  end
  if #ids > 0 then
    hsupport.wait_pane_subscriptions(d, ids)
    -- после начала подписки по панелям клиент перечитывает снимок ещё раз
    t.wait(function()
      local reading = herdr._reading()
      return d:count("session.snapshot") >= 2 and not reading
    end, "снимок после подписки по панелям")
  end
  return d
end

--- Уборка после теста: модель, клиент, двойник, настройки.
function M.reset()
  model.stop()
  herdr.stop()
  if current then
    current:close()
    current = nil
  end
  config.setup({})
end

--- Ждать, пока узел `id` не будет удовлетворять `pred(node)` (без `pred` — пока не появится).
function M.wait_node(id, pred, msg)
  t.wait(function()
    local n = model.get(id)
    return n ~= nil and (pred == nil or pred(n))
  end, msg or ("узел " .. id))
  return model.get(id)
end

--- Ждать исчезновения узла `id`.
function M.wait_gone(id, msg)
  t.wait(function()
    return model.get(id) == nil
  end, msg or ("исчезновение узла " .. id))
end

--- Идентификаторы детей узла.
function M.children(id)
  local n = model.get(id)
  return n and vim.deepcopy(n.children) or nil
end

--- Панель снимка двойника с сессией образца `sample`.
function M.claude_pane(pane_id, sample, extra)
  local o = {
    pane_id = pane_id,
    agent = "claude",
    display_agent = "opus",
    agent_status = "idle",
    session = fixtures.session_id(sample),
    terminal_title = "✳ задача " .. pane_id,
    terminal_title_stripped = "задача " .. pane_id,
  }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return double.pane(o)
end

--- Снимок из одного workspace `w1` с вкладкой `w1:t1` и панелями `panes`.
function M.snapshot(panes)
  return {
    workspaces = { double.workspace({ workspace_id = "w1", label = "ws1" }) },
    tabs = { double.tab({ tab_id = "w1:t1", label = "main" }) },
    panes = panes,
  }
end

M.settle = u.settle
M.count_reads = u.count_reads
M.timer_count = u.timer_count
M.fs_event_count = u.fs_event_count

return M
