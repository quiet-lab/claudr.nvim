-- Область и настройка клавиш, обычное поведение вне ссылки (спецификация file-references).
local t = require("helpers.t")
local s = require("refs.support")
local refs = require("claudr.refs")

local project

before_each(function()
  s.reset()
  project = s.project()
  vim.g.claudr_kw = nil
  vim.g.claudr_hit = nil
  vim.cmd("command! -nargs=* ClaudrKw let g:claudr_kw = <q-args>")
  vim.o.keywordprg = ":ClaudrKw"
end)

after_each(function()
  refs.close_preview()
  pcall(vim.cmd, "delcommand ClaudrKw")
  pcall(vim.keymap.del, "n", "K")
  pcall(vim.keymap.del, "n", "gd")
  vim.o.keywordprg = ""
end)

describe("Вне ссылки — обычное поведение", function()
  it("Слово, не являющееся ссылкой", function()
    s.plugin_buffer({ "обычное слово word и lua/foo.lua:3" }, project.dir)
    s.cursor_on("word")
    s.press("K")
    t.eq(vim.g.claudr_kw, "word", "выполнено обычное действие K")
    t.eq(refs.preview_win(), nil, "предпросмотра нет")
  end)

  it(
    "действие, назначенное в буфере до плагина, сохраняется",
    function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(0, buf)
      vim.keymap.set("n", "K", function()
        vim.g.claudr_hit = "buffer"
      end, { buffer = buf })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "word" })
      refs.attach(buf, {
        cwd = function()
          return project.dir
        end,
      })
      s.press("K")
      t.eq(vim.g.claudr_hit, "buffer")
    end
  )

  it("глобальная привязка клавиши сохраняется", function()
    vim.keymap.set("n", "K", function()
      vim.g.claudr_hit = "global"
    end)
    s.plugin_buffer({ "word" }, project.dir)
    s.press("K")
    t.eq(vim.g.claudr_hit, "global")
  end)

  it(
    "gd вне ссылки не открывает файл и не создаёт окон",
    function()
      s.plugin_buffer({ "word lua/missing.lua:3" }, project.dir)
      s.cursor_on("word")
      local before = #vim.api.nvim_tabpage_list_wins(0)
      pcall(s.press, "gd")
      t.eq(#vim.api.nvim_tabpage_list_wins(0), before)
      t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)):find("foo.lua", 1, true), nil)
    end
  )
end)

describe("Область и настройка клавиш", function()
  it("Буфер вне плагина", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "lua/foo.lua:3" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    s.press("K")
    t.eq(vim.g.claudr_kw, "lua", "обычная клавиша")
    t.eq(refs.preview_win(), nil)
    t.eq(vim.fn.maparg("K", "n", false, true), vim.empty_dict())
    t.ok(not refs.is_attached(buf))
  end)

  it("Переназначение", function()
    s.reset({ file_references = { preview = "gp", open = "go" } })
    vim.cmd("command! -nargs=* ClaudrKw let g:claudr_kw = <q-args>")
    s.plugin_buffer({ "lua/foo.lua:3" }, project.dir)
    s.cursor_on("foo")
    s.press("gp")
    t.ok(refs.preview_win(), "предпросмотр открыла новая клавиша")
    refs.close_preview()
    s.cursor_on("foo")
    s.press("K")
    t.eq(vim.g.claudr_kw, "foo", "K ведёт себя обычно")
    vim.cmd("vsplit")
    s.plugin_buffer({ "lua/foo.lua:3" }, project.dir)
    s.cursor_on("foo")
    s.press("go")
    t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), project.foo)
  end)

  it("клавиша отключается значением false", function()
    s.reset({ file_references = { preview = false } })
    local buf = s.plugin_buffer({ "lua/foo.lua:3" }, project.dir)
    t.eq(vim.fn.maparg("K", "n", false, true), vim.empty_dict())
    t.ok(vim.fn.maparg("gd", "n", false, true).buffer == 1, "открытие осталось")
    t.ok(refs.is_attached(buf))
  end)

  it("Терминальный буфер", function()
    local edit_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    local chan = vim.api.nvim_open_term(buf, {})
    refs.attach(buf, {
      cwd = function()
        return project.dir
      end,
    })
    vim.api.nvim_chan_send(chan, "ошибка в lua/foo.lua:5:3\r\n")
    t.wait(function()
      return table
        .concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        :find("foo.lua", 1, true)
    end, "текст терминала")
    vim.cmd("stopinsert")
    s.cursor_on("foo")
    s.press("gd")
    t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), project.foo)
    t.eq(vim.api.nvim_get_current_win(), edit_win)
    t.eq(vim.api.nvim_win_get_cursor(edit_win), { 5, 2 })
    t.ok(
      vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal",
      "терминал на месте"
    )
  end)
end)
