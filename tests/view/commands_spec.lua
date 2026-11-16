-- Подкоманды и действия дерева возможности подключения к узлам.
local t = require("helpers.t")
local s = require("view.support")
local view = require("claudr.view")
local commands = require("claudr.commands")
local double = s.double

after_each(function()
  s.reset()
end)

local function env()
  s.big_editor()
  view.setup()
  local d = s.env(s.snapshot({ double.pane({ pane_id = "w1:p1" }) }))
  s.wait_node("w1:p1")
  return d
end

describe("подкоманды и клавиши", function()
  it(
    "setup регистрирует подкоманды и действия дерева",
    function()
      view.setup()
      for _, name in ipairs({ "view", "attach", "scrollback" }) do
        t.ok(commands.get(name), "подкоманда " .. name)
      end
      local tree_view = require("claudr.tree.view")
      t.eq(tree_view.action("view").key, "<CR>")
      t.eq(tree_view.action("attach").key, "i")
      t.eq(tree_view.action("scrollback").key, "S")
    end
  )

  it(
    ":Claudr view <узел> открывает вид, attach без аргумента берёт панель вида",
    function()
      local d = env()
      commands.run("view", { "w1:p1" })
      local v = s.track(view.views()[1])
      t.eq(v.kind, "observe")
      t.eq(commands.get("view").complete("w1", {}), { "w1", "w1:t1", "w1:p1" })
      t.eq(commands.get("attach").complete("w1", {}), { "w1:p1" })
      -- в буфере вида наблюдения подкоманда без аргумента относится к его панели
      commands.run("attach", {})
      local a
      for _, x in ipairs(view.views()) do
        if x.kind == "attach" then
          a = x
        end
      end
      s.track(a)
      t.eq(a.node_id, "w1:p1")
      s.wait_text(a.buf, "fake herdr: terminal", "экран подключения")
      t.ok(d:attached(a.node.data.terminal_id), "подключено с вводом")
    end
  )

  it("ввод на вкладке без агента — панель вкладки", function()
    env()
    commands.run("attach", { "w1:t1" })
    local a = s.track(view.views()[1])
    t.eq(a.kind, "attach")
    t.eq(a.node_id, "w1:p1")
  end)
end)
