-- Буфер плана (agent-dialogs): текст плана, подтверждение, отказы.
local t = require("helpers.t")
local samples = require("helpers.hook_samples")
local ds = require("dialogs.support")
local buffer = require("claudr.dialogs.buffer")
local input = require("claudr.input")

local pending

before_each(function()
  pending = ds.setup()
end)

after_each(function()
  ds.reset()
end)

local function open()
  local req = ds.add(pending, "plan")
  buffer.open(req)
  return req
end

describe("Подтверждение плана", function()
  it("Текст плана и действия", function()
    open()
    t.match(ds.text(), "# Plan: create plan%-out%.txt")
    t.match(ds.text(), "Reading `plan%-out%.txt` returns `x`%.")
    t.match(
      ds.text(),
      "1%. подтвердить\n  2%. отказать с пояснением\n  3%. отказать\n  4%. отказать и прервать"
    )
    t.match(
      ds.text(),
      "Режим после подтверждения определяет Claude Code"
    )
  end)

  it("Подтверждение", function()
    local req = open()
    ds.choose("1%. подтвердить")
    t.eq(#pending.decided, 1)
    local d = ds.last_decision(pending)
    t.eq(d.behavior, "allow")
    t.eq(d.updatedInput, req.tool_input)
    t.eq(pending.decided[1].output, samples.output("plan-allow"))
  end)

  it("Правка плана", function()
    local req = open()
    ds.choose("отказать с пояснением")
    local win = input.window({ kind = "dialog", key = req.id .. "/deny" })
    ds.ms.set_text(win.buf, "добавьте шаг проверки")
    ds.ms.write(win.buf)
    local d = ds.last_decision(pending)
    t.eq(d.behavior, "deny")
    t.eq(d.message, "добавьте шаг проверки")
  end)

  it("Отказ и отказ с прерыванием", function()
    open()
    ds.choose("%d%. отказать$")
    t.eq(ds.last_decision(pending), samples.output("deny").hookSpecificOutput.decision)
    buffer.close()
    open()
    ds.choose("отказать и прервать")
    t.eq(ds.last_decision(pending), samples.output("deny-interrupt").hookSpecificOutput.decision)
  end)
end)
