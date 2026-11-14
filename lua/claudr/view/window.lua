-- Общее устройство видов узлов: плавающее окно, буфер только для чтения, учёт открытых видов
-- и их освобождение. Вид освобождается (процесс завершается, наблюдение закрывается) при
-- удалении буфера и при закрытии окна; таймеров нет.
local M = {}

-- буфер → вид
local views = {}

local function editor_size()
  return vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
end

--- Размер окна в пределах редактора (с учётом рамки).
function M.clamp(width, height)
  local cols, lines = editor_size()
  width = math.max(1, math.min(math.floor(width), cols - 2))
  height = math.max(1, math.min(math.floor(height), lines - 2))
  return width, height
end

local function geometry(width, height)
  local cols, lines = editor_size()
  local w, h = M.clamp(width, height)
  return {
    relative = "editor",
    width = w,
    height = h,
    row = math.max(0, math.floor((lines - h - 2) / 2)),
    col = math.max(0, math.floor((cols - w - 2) / 2)),
  }
end

local function title_text(title, width)
  title = (title or "claudr"):gsub("[\r\n]", " ")
  local max = math.max(1, width - 4)
  if vim.fn.strdisplaywidth(title) > max then
    title = vim.fn.strcharpart(title, 0, max - 1) .. "…"
  end
  return " " .. title .. " "
end

--- Открывает плавающее окно для буфера `buf`: `opts.title`, `opts.width`, `opts.height`
--- (по умолчанию — четыре пятых редактора). Курсор переходит в окно.
function M.open_float(buf, opts)
  opts = opts or {}
  local cols, lines = editor_size()
  local cfg = geometry(opts.width or cols * 0.8, opts.height or lines * 0.8)
  cfg.border = "rounded"
  cfg.style = "minimal"
  cfg.title = title_text(opts.title, cfg.width)
  cfg.title_pos = "center"
  return vim.api.nvim_open_win(buf, true, cfg)
end

--- Меняет размер плавающего окна (размер ограничивается редактором).
function M.resize(win, width, height)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, geometry(width, height))
  end
end

--- Новый буфер вида: без файла, удаляется при скрытии.
function M.scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  return buf
end

--- Заменяет строки буфера только для чтения.
function M.set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Дописывает строки в конец буфера только для чтения; пустой буфер заполняется с начала.
function M.append_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) or #lines == 0 then
    return
  end
  vim.bo[buf].modifiable = true
  local count = vim.api.nvim_buf_line_count(buf)
  local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  if count == 1 and first == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, count, count, false, lines)
  end
  vim.bo[buf].modifiable = false
end

--- Регистрирует вид `v` (`v.buf`, `v.win`, `v.dispose()`): `q` закрывает окно, удаление
--- буфера или закрытие окна освобождают вид один раз.
function M.register(v)
  views[v.buf] = v
  local buf = v.buf
  vim.keymap.set("n", "q", function()
    M.close(v)
  end, { buffer = buf, nowait = true, silent = true, desc = "claudr: закрыть вид" })
  local function release()
    if v.released then
      return
    end
    v.released = true
    views[buf] = nil
    v.dispose()
  end
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = release })
  if v.win then
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(v.win),
      once = true,
      callback = function()
        release()
        -- буфер терминала с работающей программой окно само не удаляет
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end)
      end,
    })
  end
  return v
end

--- Закрывает вид: окно и буфер.
function M.close(v)
  if v.win and vim.api.nvim_win_is_valid(v.win) then
    pcall(vim.api.nvim_win_close, v.win, true)
  end
  if vim.api.nvim_buf_is_valid(v.buf) then
    pcall(vim.api.nvim_buf_delete, v.buf, { force = true })
  end
end

--- Закрывает все открытые виды.
function M.close_all()
  for _, v in pairs(vim.tbl_values(views)) do
    M.close(v)
  end
end

--- Открытые виды: список.
function M.list()
  return vim.tbl_values(views)
end

--- Вид, показанный в буфере `buf`, или nil.
function M.get(buf)
  return views[buf]
end

return M
