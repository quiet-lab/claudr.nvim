-- Вид workspace и вкладки — перечень панелей (спецификация node-view, решение D4).
local t = require("helpers.t")
local s = require("view.support")
local view = require("claudr.view")
local model = require("claudr.tree.model")
local double = s.double

after_each(function()
  s.reset()
end)

local function env()
  s.big_editor()
  local d = s.env(
    s.snapshot({
      s.claude_pane("w1:p1", "owner-dialogue", { agent_status = "working" }),
      double.pane({ pane_id = "w1:p2", foreground_process = "cargo", cwd = "/src" }),
    }),
    { "owner-dialogue" }
  )
  s.wait_node("w1:p2")
  return d
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("Контейнеры — перечень панелей", function()
  it("Вкладка с двумя панелями", function()
    env()
    local v = view.open(model.get("w1:t1"))
    t.eq(v.kind, "panes")
    local l = lines(v.buf)
    t.eq(#l, 2)
    t.match(l[1], "^A opus .*%[working%]$")
    t.match(l[2], "^%$ cargo /src$")
    -- первая панель сама не выбрана: открыт только перечень
    t.eq(#view.views(), 1)
    vim.api.nvim_win_set_cursor(v.win, { 2, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    t.eq(#view.views(), 2)
    local pv
    for _, x in ipairs(view.views()) do
      if x ~= v then
        pv = x
      end
    end
    s.track(pv)
    t.eq(pv.kind, "observe")
    t.eq(pv.node_id, "w1:p2")
  end)

  it("перечень workspace — панели всех его вкладок", function()
    env()
    local v = view.open(model.get("w1"))
    t.eq(#lines(v.buf), 2)
    local pv = s.track(require("claudr.view.panes").select(v, 1))
    t.eq(pv.node_id, "w1:p1")
  end)

  it("Состояние в перечне меняется", function()
    local d = env()
    local v = view.open(model.get("w1:t1"))
    t.match(lines(v.buf)[1], "%[working%]")
    d:set_agent_status("w1:p1", "blocked")
    t.wait(function()
      return lines(v.buf)[1]:find("[blocked]", 1, true) ~= nil
    end, "новое состояние в строке")
    s.close_win(v)
  end)
end)

describe("Подписи панелей в перечне", function()
  it(
    "многострочные подписи показываются одной строкой",
    function()
      s.big_editor()
      s.env(
        s.snapshot({
          double.pane({ pane_id = "w1:p1", foreground_process = "tool\nsecond", cwd = "/src" }),
        }),
        { "owner-dialogue" }
      )
      s.wait_node("w1:p1")
      local v = view.open(model.get("w1:t1"))
      t.eq(lines(v.buf), { "$ tool second /src" })
    end
  )
end)
