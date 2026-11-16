-- Подключение буфера диалога: команда `:Claudr dialog`, действие дерева, клавиша вида панели.
local t = require("helpers.t")
local ds = require("dialogs.support")
local s = ds.ms.tree
local commands = require("claudr.commands")
local buffer = require("claudr.dialogs.buffer")
local view = require("claudr.tree.view")
local model = require("claudr.tree.model")

local pending, rec

before_each(function()
  pending, rec = ds.setup()
end)

after_each(function()
  if view.buf() then
    vim.api.nvim_buf_delete(view.buf(), { force = true })
  end
  ds.reset()
  s.reset()
end)

local function env()
  local sample = "subagent-command"
  s.env(s.snapshot({ s.claude_pane("w1:p1", sample, { agent_status = "blocked" }) }), sample)
  s.wait_node("w1:p1")
end

describe("Открытие буфера диалога", function()
  it("Подкоманда dialog с идентификатором панели", function()
    env()
    require("claudr").setup()
    t.ok(commands.get("dialog"), "подкоманда зарегистрирована")
    ds.add(pending, "permission-bash")
    commands.run("dialog", { "w1:p1" })
    t.ok(buffer.current())
    t.match(ds.text(), "Инструмент: Bash")
  end)

  it("Действие дерева на узле панели", function()
    env()
    require("claudr").setup()
    local action = view.action("dialog")
    t.eq(action.key, "d")
    ds.add(pending, "permission-bash")
    action.run(model.get("w1:p1"))
    t.ok(buffer.current())
  end)

  it(
    "Действие дерева на строке вкладки — запрос агента вкладки",
    function()
      env()
      require("claudr").setup()
      ds.add(pending, "permission-bash")
      view.action("dialog").run(model.get("w1:t1"))
      t.ok(buffer.current())
    end
  )

  it("Запроса нет: сообщение", function()
    env()
    require("claudr").setup()
    commands.run("dialog", { "w1:p1" })
    t.ok(ds.ms.noted(rec, "нет ждущего запроса"))
  end)

  it("Клавиша в виде панели", function()
    env()
    require("claudr").setup()
    ds.add(pending, "permission-bash")
    local v = require("claudr.view").open(model.get("w1:p1"))
    t.eq(vim.fn.maparg("d", "n", false, true).desc, "claudr: буфер диалога")
    ds.press("d")
    t.ok(buffer.current())
    t.eq(vim.bo.filetype, "claudr-dialog")
    require("claudr.view").close_all()
    t.ok(v)
  end)
end)
