-- Ждущие запросы в дереве (agent-tree, «Состояние панели с агентом»): узел показывает число
-- своих запросов, узел панели — и запросов субагентов; перерисовка по подписке перечня.
local t = require("helpers.t")
local ds = require("dialogs.support")
local s = ds.ms.tree
local samples = require("helpers.hook_samples")
local model = require("claudr.tree.model")
local view = require("claudr.tree.view")

local pending

before_each(function()
  pending = ds.setup()
end)

after_each(function()
  if view.buf() then
    vim.api.nvim_buf_delete(view.buf(), { force = true })
  end
  ds.reset()
  s.reset()
end)

local function env()
  -- субагент образца завершён: показ завершённых включается явно
  require("claudr.config").setup({ show_finished = true })
  local sample = "subagent-command"
  s.env(s.snapshot({ s.claude_pane("w1:p1", sample, { agent_status = "blocked" }) }), sample)
  s.wait_node("w1:p1")
  view.open()
end

local function line(id)
  return view.lines()[view.line_of(id)]
end

-- Идентификатор первого субагента панели w1:p1 в дереве.
local function subagent_id()
  for _, cid in ipairs(model.get("w1:p1").children) do
    if model.get(cid).kind == "subagent" then
      return cid
    end
  end
end

describe("Ждущие запросы", function()
  it("Ждущие запросы", function()
    env()
    t.eq(line("w1:p1"):find("ждут", 1, true), nil, "без запросов числа нет")
    ds.add(pending, "permission-bash")
    ds.add(pending, "permission-read")
    t.match(
      line("w1:p1"),
      "opus задача w1:p1 %[ждут: 2%]$",
      "число после подписи"
    )
  end)

  it("Субагент и главная сессия", function()
    env()
    local sid = subagent_id()
    t.ok(sid, "в образце есть субагент")
    local input = samples.input("subagent")
    input.agent_id = sid:match("/(.+)$")
    pending.add(input, "w1:p1")
    ds.add(pending, "permission-bash")
    t.match(line(sid), "%[ждут: 1%]")
    t.match(line("w1:p1"), "%[ждут: 2%]")
  end)

  it("Число убывает вместе с запросом", function()
    env()
    local req = ds.add(pending, "permission-bash")
    t.match(line("w1:p1"), "%[ждут: 1%]")
    pending.set_state(req, "answered_elsewhere")
    t.eq(line("w1:p1"):find("ждут", 1, true), nil)
  end)

  it("Подписка снимается вместе с буфером дерева", function()
    env()
    t.eq(#pending.subs, 1)
    vim.api.nvim_buf_delete(view.buf(), { force = true })
    t.eq(#pending.subs, 0)
  end)
end)
