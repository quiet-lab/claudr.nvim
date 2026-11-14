-- Открытие файла по ссылке в окне редактирования (спецификация file-references).
local t = require("helpers.t")
local s = require("refs.support")
local refs = require("claudr.refs")

local project

before_each(function()
  s.reset()
  project = s.project()
end)

local function name_of(buf)
  return vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
end

describe("Открытие файла", function()
  it("Открытие на строке и столбце", function()
    local edit_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local plugin_win = vim.api.nvim_get_current_win()
    local buf = s.plugin_buffer({ "ссылка lua/foo.lua:42:7 в виде" }, project.dir)
    s.cursor_on("foo")
    s.press("gd")
    t.eq(name_of(0), project.foo)
    t.eq(
      vim.api.nvim_get_current_win(),
      edit_win,
      "файл открыт в окне редактирования"
    )
    t.eq(vim.api.nvim_win_get_cursor(edit_win), { 42, 6 }, "строка 42, столбец 7")
    t.ok(vim.api.nvim_win_is_valid(plugin_win), "окно плагина осталось")
    t.eq(vim.api.nvim_win_get_buf(plugin_win), buf, "буфер плагина на месте")
  end)

  it(
    "открытие без строки и столбца — с начала файла",
    function()
      vim.cmd("vsplit")
      s.plugin_buffer({ project.short }, project.dir)
      s.cursor_on("short")
      s.press("gd")
      t.eq(name_of(0), project.short)
      t.eq(vim.api.nvim_win_get_cursor(0), { 1, 0 })
    end
  )

  it(
    "строка за концом файла и столбец за концом строки сводятся к последним",
    function()
      vim.cmd("vsplit")
      s.plugin_buffer({ "short.txt:42:99" }, project.dir)
      s.cursor_on("short")
      s.press("gd")
      t.eq(vim.api.nvim_win_get_cursor(0), { 10, 7 })
    end
  )

  it("Нет окна редактирования", function()
    local buf = s.plugin_buffer({ "lua/foo.lua:3" }, project.dir)
    local plugin_win = vim.api.nvim_get_current_win()
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    s.cursor_on("foo")
    s.press("gd")
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 2, "открылось новое окно")
    t.eq(name_of(0), project.foo)
    t.eq(vim.api.nvim_win_get_cursor(0)[1], 3)
    t.eq(vim.api.nvim_win_get_buf(plugin_win), buf, "буфер плагина на месте")
    t.ok(vim.api.nvim_get_current_win() ~= plugin_win)
  end)

  it(
    "вид в плавающем окне остаётся, файл открывается в окне редактирования",
    function()
      local edit_win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "lua/foo.lua:42:7" })
      local float = vim.api.nvim_open_win(
        buf,
        true,
        { relative = "editor", row = 1, col = 1, width = 30, height = 5, style = "minimal" }
      )
      refs.attach(buf, {
        cwd = function()
          return project.dir
        end,
      })
      s.press("gd")
      t.ok(vim.api.nvim_win_is_valid(float), "плавающее окно осталось")
      t.eq(vim.api.nvim_get_current_win(), edit_win)
      t.eq(name_of(0), project.foo)
      t.eq(vim.api.nvim_win_get_cursor(edit_win), { 42, 6 })
    end
  )

  it("открытие закрывает предпросмотр", function()
    vim.cmd("vsplit")
    s.plugin_buffer({ "lua/foo.lua:3" }, project.dir)
    s.cursor_on("foo")
    s.press("K")
    t.ok(refs.preview_win())
    s.press("gd")
    t.eq(refs.preview_win(), nil)
  end)
end)
