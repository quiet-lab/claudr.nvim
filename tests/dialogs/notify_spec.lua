-- Сообщение об ожидании ответа (agent-dialogs, D33): окно и фокус не меняются, экран панели
-- не читается.
local t = require("helpers.t")
local ds = require("dialogs.support")
local s = ds.ms.tree
local window = require("claudr.view.window")
local buffer = require("claudr.dialogs.buffer")
local notify = require("claudr.dialogs.notify")

local pending, rec

before_each(function()
  pending, rec = ds.setup()
end)

after_each(function()
  ds.reset()
  s.reset()
end)

-- Окружение: панель w1:p1 в состоянии `status`; открытый вид панели, если `with_view`.
local function env(status, with_view)
  local sample = "subagent-command"
  local d = s.env(s.snapshot({ s.claude_pane("w1:p1", sample, { agent_status = status }) }), sample)
  s.wait_node("w1:p1")
  notify.start()
  if with_view then
    local buf = window.scratch()
    local win = window.open_float(buf, { title = "наблюдение" })
    window.register({
      kind = "observe",
      node_id = "w1:p1",
      buf = buf,
      win = win,
      dispose = function() end,
    })
  end
  return d
end

local function block(d)
  d:set_agent_status("w1:p1", "blocked")
  s.wait_node("w1:p1", function(n)
    return n.state == "blocked"
  end)
end

describe("Сообщение об ожидании ответа", function()
  it("Запрос есть", function()
    local d = env("working", true)
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    ds.add(pending, "permission-bash")
    block(d)
    ds.ms.wait_note(rec, "ждущих запросов диалога — 1")
    t.ok(ds.ms.noted(rec, ":Claudr dialog w1:p1"))
    t.eq(vim.api.nvim_get_current_win(), win, "окно прежнее")
    t.eq(vim.api.nvim_get_current_buf(), buf)
    t.eq(buffer.current(), nil, "буфер диалога не открыт")
    t.eq(#rec.selects, 0, "вопросов пользователю нет")
  end)

  it(
    "Запроса нет: сообщение и предложение подключения, pane.read не вызывается",
    function()
      local d = env("working", true)
      local win = vim.api.nvim_get_current_win()
      block(d)
      ds.ms.wait_note(rec, "запроса хука нет")
      t.ok(ds.ms.noted(rec, ":Claudr attach w1:p1"))
      t.eq(vim.api.nvim_get_current_win(), win)
      t.eq(d:count("pane.read"), 0)
      t.eq(d:count("pane.send_keys"), 0)
      t.eq(d:count("pane.send_text"), 0)
    end
  )

  it("Запрос пришёл позже перехода в blocked", function()
    local d = env("working", true)
    block(d)
    ds.ms.wait_note(rec, "запроса хука нет")
    ds.add(pending, "permission-bash")
    ds.ms.wait_note(rec, "ждущих запросов диалога — 1")
    t.eq(buffer.current(), nil)
  end)

  it("Вид панели не открыт: сообщения нет", function()
    local d = env("working", false)
    ds.add(pending, "permission-bash")
    block(d)
    s.settle()
    t.eq(#rec.notes, 0, vim.inspect(rec.notes))
  end)

  it("Панель уже была в blocked: перехода нет", function()
    env("blocked", true)
    s.settle()
    t.eq(#rec.notes, 0)
  end)
end)
