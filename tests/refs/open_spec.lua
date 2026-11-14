-- Открытие файла по ссылке в том же окне (спецификация file-references).
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
    local other_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local plugin_win = vim.api.nvim_get_current_win()
    local buf = s.plugin_buffer({ "ссылка lua/foo.lua:42:7 в виде" }, project.dir)
    s.cursor_on("foo")
    s.press("gd")
    t.eq(name_of(0), project.foo)
    t.eq(
      vim.api.nvim_get_current_win(),
      plugin_win,
      "файл открыт в том же окне"
    )
    t.eq(vim.api.nvim_win_get_cursor(plugin_win), { 42, 6 }, "строка 42, столбец 7")
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 2, "новых окон нет")
    t.ok(vim.api.nvim_win_is_valid(other_win), "соседнее окно осталось")
    t.ok(vim.api.nvim_buf_is_valid(buf), "буфер плагина жив")
  end)

  it("Возврат в буфер плагина", function()
    local buf = s.plugin_buffer({ "ссылка lua/foo.lua:42:7 в виде" }, project.dir)
    s.cursor_on("foo")
    local at = vim.api.nvim_win_get_cursor(0)
    s.press("gd")
    t.eq(name_of(0), project.foo)
    s.press("<C-o>")
    t.eq(vim.api.nvim_get_current_buf(), buf, "в окне снова буфер плагина")
    t.eq(vim.api.nvim_win_get_cursor(0), at, "курсор на прежнем месте")
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

  it(
    "единственное окно вкладки: файл открывается в нём",
    function()
      local buf = s.plugin_buffer({ "lua/foo.lua:3" }, project.dir)
      local plugin_win = vim.api.nvim_get_current_win()
      t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
      s.cursor_on("foo")
      s.press("gd")
      t.eq(#vim.api.nvim_tabpage_list_wins(0), 1, "новых окон нет")
      t.eq(name_of(0), project.foo)
      t.eq(vim.api.nvim_get_current_win(), plugin_win)
      t.eq(vim.api.nvim_win_get_cursor(0)[1], 3)
      t.ok(vim.api.nvim_buf_is_valid(buf), "буфер плагина жив")
    end
  )

  it(
    "Переход из плавающего окна: файл открывается в окне редактирования",
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

  it(
    "Переход из плавающего окна без окна редактирования",
    function()
      local only = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = "nofile"
      vim.api.nvim_win_set_buf(only, buf)
      local fbuf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "lua/foo.lua:3" })
      local float = vim.api.nvim_open_win(
        fbuf,
        true,
        { relative = "editor", row = 1, col = 1, width = 30, height = 5, style = "minimal" }
      )
      refs.attach(fbuf, {
        cwd = function()
          return project.dir
        end,
      })
      t.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
      s.press("gd")
      t.eq(#vim.api.nvim_tabpage_list_wins(0), 3, "открылось новое окно")
      t.eq(name_of(0), project.foo)
      t.ok(vim.api.nvim_win_is_valid(float), "плавающее окно осталось")
      t.ok(vim.api.nvim_get_current_win() ~= only)
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
