-- Предпросмотр ссылки и его закрытие по событиям редактора (спецификация file-references).
local t = require("helpers.t")
local s = require("refs.support")
local refs = require("claudr.refs")

local project, src_win, src_buf

before_each(function()
  s.reset()
  project = s.project()
  src_buf = s.plugin_buffer(
    { "см. lua/foo.lua:42 и short.txt:42", "вторая строка", "третья" },
    project.dir
  )
  src_win = vim.api.nvim_get_current_win()
end)

after_each(function()
  refs.close_preview()
end)

local function preview_lines()
  local win = refs.preview_win()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

describe("Предпросмотр", function()
  it("Предпросмотр на строке", function()
    s.cursor_on("foo")
    s.press("K")
    local win = refs.preview_win()
    t.ok(win and vim.api.nvim_win_is_valid(win), "окно открыто")
    t.eq(vim.api.nvim_win_get_config(win).relative ~= "", true, "плавающее окно")
    local buf = vim.api.nvim_win_get_buf(win)
    t.eq(preview_lines()[42], "local line42 = 42")
    t.eq(vim.api.nvim_win_get_cursor(win)[1], 42, "строка 42 выбрана")
    local info = vim.fn.getwininfo(win)[1]
    t.ok(info.topline <= 42 and 42 <= info.botline, "строка 42 видна")
    local marks = vim.api.nvim_buf_get_extmarks(buf, refs.NS, 0, -1, { details = true })
    t.eq(#marks, 1)
    t.eq(marks[1][2], 41, "выделена строка 42")
    t.eq(marks[1][4].line_hl_group, "ClaudrRefLine")
    t.eq(vim.bo[buf].filetype, "lua", "подсветка по типу файла")
    t.eq(vim.bo[buf].modifiable, false)
    t.eq(vim.bo[buf].readonly, true)
    t.ok(
      not pcall(vim.api.nvim_buf_set_lines, buf, 0, 1, false, { "x" }),
      "правка запрещена"
    )
    t.eq(vim.api.nvim_get_current_win(), src_win, "фокус в исходном буфере")
    t.eq(vim.api.nvim_get_current_buf(), src_buf)
  end)

  it("Строка за концом файла", function()
    s.cursor_on("short.txt")
    s.press("K")
    local lines = preview_lines()
    t.eq(#lines, 10)
    local win = refs.preview_win()
    t.eq(vim.api.nvim_win_get_cursor(win)[1], 10)
    local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), refs.NS, 0, -1, {})
    t.eq(marks[1][2], 9, "выделена десятая строка")
    t.eq(lines[10], "short 10")
  end)

  it(
    "повторное нажатие заменяет окно, а не копит окна",
    function()
      s.cursor_on("foo")
      s.press("K")
      local first = refs.preview_win()
      s.press("K")
      t.ok(not vim.api.nvim_win_is_valid(first), "прежнее окно закрыто")
      t.ok(vim.api.nvim_win_is_valid(refs.preview_win()))
    end
  )
end)

describe("Закрытие предпросмотра", function()
  it("Движение курсора", function()
    s.cursor_on("foo")
    s.press("K")
    local win = refs.preview_win()
    t.ok(vim.api.nvim_win_is_valid(win))
    -- в тесте нет главного цикла ввода, поэтому событие редактора вызывается явно
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = src_buf })
    t.ok(refs.preview_win() == nil, "окно закрыто")
    t.ok(not vim.api.nvim_win_is_valid(win))
    t.eq(vim.api.nvim_get_current_win(), src_win)
  end)

  it("прежнее положение курсора окно не закрывает", function()
    s.cursor_on("foo")
    s.press("K")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = src_buf })
    t.ok(refs.preview_win(), "окно открыто")
  end)

  it("Escape", function()
    s.cursor_on("foo")
    s.press("K")
    local win = refs.preview_win()
    s.press("<Esc>")
    t.ok(not vim.api.nvim_win_is_valid(win), "окно закрыто")
    t.eq(
      vim.api.nvim_get_current_win(),
      src_win,
      "фокус остался в исходном буфере"
    )
    t.eq(
      vim.fn.maparg("<Esc>", "n", false, true),
      vim.empty_dict(),
      "временная клавиша снята"
    )
  end)

  it("выход из буфера закрывает окно", function()
    s.cursor_on("foo")
    s.press("K")
    local win = refs.preview_win()
    vim.cmd("new")
    t.ok(not vim.api.nvim_win_is_valid(win), "окно закрыто")
  end)

  it(
    "прежняя привязка Escape возвращается после закрытия",
    function()
      vim.keymap.set("n", "<Esc>", function()
        vim.g.claudr_prev_esc = true
      end, { buffer = src_buf })
      s.cursor_on("foo")
      s.press("K")
      s.press("<Esc>")
      t.eq(vim.g.claudr_prev_esc, nil)
      s.press("<Esc>")
      t.eq(vim.g.claudr_prev_esc, true, "прежняя привязка действует")
      vim.g.claudr_prev_esc = nil
    end
  )

  it("в коде нет таймеров", function()
    local path = vim.fs.joinpath(t.root, "lua", "claudr", "refs.lua")
    local text = table.concat(vim.fn.readfile(path), "\n")
    for _, word in ipairs({ "defer_fn", "new_timer", "timer_start" }) do
      t.ok(not text:find(word, 1, true), word)
    end
  end)
end)
