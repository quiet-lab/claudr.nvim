-- Буфер диалога (agent-dialogs): открытие, чтение, несколько запросов, ссылки на файлы.
local t = require("helpers.t")
local ds = require("dialogs.support")
local s = ds.ms.tree
local dialogs = require("claudr.dialogs")
local buffer = require("claudr.dialogs.buffer")
local model = require("claudr.tree.model")

local pending, rec

local function env()
  local sample = "subagent-command"
  s.env(s.snapshot({ s.claude_pane("w1:p1", sample) }), sample)
  s.wait_node("w1:p1")
end

before_each(function()
  pending, rec = ds.setup()
end)

after_each(function()
  ds.reset()
  s.reset()
end)

describe("Буфер диалога", function()
  it("Открытие с узла", function()
    env()
    ds.add(pending, "permission-bash")
    t.eq(dialogs.open_for_node(model.get("w1:p1")), true)
    t.eq(vim.bo.filetype, "claudr-dialog")
    t.eq(vim.bo.modifiable, false)
    t.eq(vim.bo.buftype, "nofile")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    t.match(
      ds.lines()[row],
      "1%. разрешить один раз",
      "курсор на первом пункте"
    )
    t.eq(buffer.current().win, vim.api.nvim_get_current_win())
    t.ok(
      not pcall(vim.api.nvim_buf_set_lines, 0, 0, 1, false, { "x" }),
      "буфер только для чтения"
    )
  end)

  it(
    "Открытие из вида панели по идентификатору панели",
    function()
      env()
      ds.add(pending, "permission-bash")
      t.eq(dialogs.has_pending("w1:p1"), true)
      t.eq(dialogs.open_for_pane("w1:p1"), true)
      t.match(ds.text(), "Инструмент: Bash")
    end
  )

  it("Запроса нет", function()
    env()
    t.eq(dialogs.has_pending("w1:p1"), false)
    t.eq(dialogs.open_for_node(model.get("w1:p1")), false)
    t.ok(ds.ms.noted(rec, "нет ждущего запроса"))
    t.eq(buffer.current(), nil)
    t.eq(dialogs.open_for_pane("w1:p1"), false)
  end)

  it(
    "Несколько запросов: выбор и переход к следующему",
    function()
      env()
      local first = ds.add(pending, "permission-bash")
      local second = ds.add(pending, "permission-write")
      rec = ds.ms.stub({ select = { 2 } })
      t.eq(dialogs.open_for_node(model.get("w1:p1")), true)
      t.eq(#rec.selects, 1)
      t.eq(#rec.selects[1].items, 2)
      t.eq(buffer.current().req, second)
      t.match(ds.text(), "Инструмент: Write")
      t.match(ds.text(), "Ждущих запросов у панели: 2")
      ds.press("<Tab>")
      t.eq(buffer.current().req, first)
      t.match(ds.text(), "Инструмент: Bash")
      ds.press("<Tab>")
      t.eq(buffer.current().req, second)
    end
  )

  it(
    "Переход к следующему при одном запросе сообщает",
    function()
      env()
      ds.add(pending, "permission-bash")
      dialogs.open_for_pane("w1:p1")
      ds.press("<Tab>")
      t.ok(ds.ms.noted(rec, "других ждущих запросов нет"))
    end
  )

  it(
    "Запрос субагента открывается с узла субагента",
    function()
      env()
      local req = ds.add(pending, "subagent")
      local sub = { id = "w1:p1/" .. req.agent_id, kind = "subagent", children = {} }
      t.eq(dialogs.open_for_node(sub), true)
      t.eq(buffer.current().req, req)
      t.match(ds.text(), "субагент")
    end
  )

  it("Окно и фокус не меняются без команды", function()
    env()
    local win = vim.api.nvim_get_current_win()
    ds.add(pending, "permission-bash")
    ds.add(pending, "question-single")
    t.eq(
      vim.api.nvim_get_current_win(),
      win,
      "поступление запросов не меняет окно"
    )
    t.eq(buffer.current(), nil)
  end)

  it("Ссылки на файлы подключены к буферу диалога", function()
    env()
    ds.add(pending, "permission-write")
    dialogs.open_for_pane("w1:p1")
    t.eq(require("claudr.refs").is_attached(vim.api.nvim_get_current_buf()), true)
  end)

  it(
    "Закрытие буфера забывает закрытый запрос, ждущий остаётся",
    function()
      env()
      local req = ds.add(pending, "permission-bash")
      dialogs.open_for_pane("w1:p1")
      buffer.close()
      t.eq(#pending.forgotten, 0)
      t.eq(#pending.reqs, 1)
      dialogs.open_for_pane("w1:p1")
      pending.set_state(req, "answered_elsewhere")
      buffer.close()
      t.eq(#pending.forgotten, 1)
      t.eq(#pending.subs, 0, "подписка снята")
    end
  )
end)
