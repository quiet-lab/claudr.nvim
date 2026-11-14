-- Отображение дерева: буфер и окно Neovim, перерисовка по событиям модели, клавиши,
-- регистрация действий для других модулей (спецификация agent-tree, решения D2 и D17).
local t = require("helpers.t")
local s = require("tree.support")
local model = require("claudr.tree.model")
local view = require("claudr.tree.view")
local double = s.double

after_each(function()
  view.close()
  s.reset()
end)

local function has_line(pattern)
  for _, line in ipairs(view.lines()) do
    if line:find(pattern) then
      return true
    end
  end
  return false
end

local function wait_line(pattern, msg)
  t.wait(function()
    return has_line(pattern)
  end, msg or ("строка " .. pattern))
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("Открытие дерева", function()
  it("подкоманда tree открывает буфер дерева в окне", function()
    require("claudr").setup()
    s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "subagent-command"),
        double.pane({ pane_id = "w1:p2", foreground_process = "cargo", cwd = "/src" }),
      }),
      "subagent-command"
    )
    vim.cmd("Claudr tree")
    local buf = vim.api.nvim_get_current_buf()
    t.eq(buf, view.buf())
    t.eq(vim.api.nvim_buf_get_name(buf), view.BUF_NAME)
    t.eq(vim.bo[buf].modifiable, false)
    t.eq(vim.bo[buf].filetype, "claudr-tree")
    wait_line("&.*Wait for background sleep command output")
    local lines = view.lines()
    t.eq(lines[1], "▾ W ws1")
    t.eq(lines[2], "  ▾ T main")
    t.match(lines[3], "^    ▾ A opus задача w1:p1 %[idle%]$")
    t.match(
      lines[4],
      "^      ▾ S Проверка фонового Bash с кодом выхода %(general%-purpose%) %[завершён%]$"
    )
    t.match(lines[5], "^          & Wait for background sleep command output %[завершён%]$")
    t.eq(lines[#lines], "      $ cargo /src")
    -- повторный вызов не открывает второе окно
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    vim.cmd("wincmd p")
    vim.cmd("Claudr tree")
    t.eq(#vim.api.nvim_tabpage_list_wins(0), wins)
    t.eq(vim.api.nvim_get_current_buf(), buf)
  end)

  it("дерево показывает состояние «нет сервера»", function()
    view.open()
    t.wait(function()
      return model.status().status == "no_server"
    end, "нет сервера")
    t.match(view.lines()[1], "^herdr: нет сервера")
  end)
end)

describe("Перерисовка", function()
  it("строка панели меняется по событию herdr", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    view.open()
    wait_line("%[idle%]")
    view.focus("w1:p1/a0000000000000005")
    d:set_agent_status("w1:p1", "blocked")
    wait_line("A opus задача w1:p1 %[blocked%]")
    t.eq(
      view.node_at_cursor().id,
      "w1:p1/a0000000000000005",
      "курсор остался на узле"
    )
  end)

  it(
    "переключение показа завершённых скрывает их строки",
    function()
      local d = s.env(
        s.snapshot({
          s.claude_pane("w1:p1", "subagent-nested"),
          s.claude_pane("w1:p2", "owner-killed"),
          s.claude_pane("w1:p3", "command-orphaned"),
        }),
        { "subagent-nested", "owner-killed", "command-orphaned" }
      )
      view.open()
      d:pane_exited("w1:p3")
      wait_line("%[оборван%]")
      t.ok(has_line("outer"))
      press("F")
      t.eq(model.show_finished(), false)
      t.ok(not has_line("outer"), "завершённый скрыт")
      t.ok(not has_line("inner"), "завершённый вложенный скрыт")
      t.ok(has_line("sleeper2.*%[работает%]"), "работающий остаётся")
      t.ok(has_line("%[оборван%]"), "оборванный остаётся")
      press("F")
      t.ok(has_line("outer"))
    end
  )
end)

describe("Клавиши и действия", function()
  it("свёртывание узла прячет его детей", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-nested") }), "subagent-nested")
    view.open()
    wait_line("inner")
    t.ok(view.focus("w1:p1"))
    press("<Tab>")
    t.ok(not has_line("outer"), "дети свёрнуты")
    t.match(view.lines()[view.line_of("w1:p1")], "▸ A")
    press("za")
    t.ok(has_line("outer"))
  end)

  it(
    "register_action вызывает действие над узлом под курсором",
    function()
      s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-nested") }), "subagent-nested")
      local got = {}
      view.register_action("probe", {
        key = "X",
        desc = "проверочное действие",
        run = function(node)
          got[#got + 1] = node.id
        end,
      })
      view.open()
      wait_line("inner")
      t.ok(view.focus("w1:p1/a0000000000000001"))
      t.eq(view.node_at_cursor().id, "w1:p1/a0000000000000001")
      press("X")
      t.eq(got, { "w1:p1/a0000000000000001" })
      -- действие, зарегистрированное после открытия, тоже получает клавишу
      view.register_action("probe2", {
        key = "Y",
        run = function(node)
          got[#got + 1] = "Y:" .. node.kind
        end,
      })
      view.focus("w1:t1")
      press("Y")
      t.eq(got[2], "Y:tab")
      local keys = {}
      for _, k in ipairs(view.keys()) do
        keys[k.key] = k.desc
      end
      t.eq(keys.X, "проверочное действие")
      t.eq(keys.Y, "probe2")
    end
  )

  it("node_at_cursor вне узла — nil", function()
    view.open()
    t.wait(function()
      return model.status().status == "no_server"
    end, "нет сервера")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    t.eq(view.node_at_cursor(), nil)
  end)

  it("q закрывает окно дерева", function()
    view.open()
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    press("q")
    t.eq(#vim.api.nvim_tabpage_list_wins(0), wins - 1)
    t.ok(view.buf(), "буфер остаётся")
  end)
end)
