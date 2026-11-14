-- Общие помощники тестов ссылок на файлы: проект с файлами, буфер плагина со ссылками,
-- нажатие клавиш.
local t = require("helpers.t")
local refs = require("claudr.refs")

local M = {}

local counter = 0

--- Новый проект во временном каталоге: `lua/foo.lua` (50 строк), `short.txt` (10 строк),
--- каталог `docs`. Возвращает `{ dir, foo, short }` (пути без символьных ссылок).
function M.project()
  counter = counter + 1
  local dir = vim.fs.joinpath(t.tmpdir(), ("refs%d"):format(counter), "src")
  vim.fn.mkdir(vim.fs.joinpath(dir, "lua"), "p")
  vim.fn.mkdir(vim.fs.joinpath(dir, "docs"), "p")
  dir = assert(vim.uv.fs_realpath(dir))
  local foo_lines = {}
  for i = 1, 50 do
    foo_lines[i] = ("local line%d = %d"):format(i, i)
  end
  local short_lines = {}
  for i = 1, 10 do
    short_lines[i] = ("short %d"):format(i)
  end
  local foo = vim.fs.joinpath(dir, "lua", "foo.lua")
  local short = vim.fs.joinpath(dir, "short.txt")
  vim.fn.writefile(foo_lines, foo)
  vim.fn.writefile(short_lines, short)
  return { dir = dir, foo = foo, short = short }
end

--- Чистое состояние: одно окно с пустым буфером, настройки по умолчанию, без предпросмотра.
function M.reset(opts)
  refs.close_preview()
  vim.cmd("silent! only")
  vim.cmd("enew")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  require("claudr").setup(opts)
end

--- Буфер плагина (nofile) с текстом `lines` в текущем окне; ссылки подключены, каталог —
--- `cwd`. Возвращает номер буфера.
function M.plugin_buffer(lines, cwd)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  refs.attach(buf, {
    cwd = function()
      return cwd
    end,
  })
  return buf
end

--- Ставит курсор текущего окна на первое вхождение `needle` в буфере (простой текст).
function M.cursor_on(needle, shift)
  local buf = vim.api.nvim_get_current_buf()
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local s = l:find(needle, 1, true)
    if s then
      vim.api.nvim_win_set_cursor(0, { i, s - 1 + (shift or 0) })
      return
    end
  end
  error("в буфере нет текста: " .. needle)
end

--- Нажатие клавиш в нормальном режиме (привязки учитываются).
function M.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

return M
