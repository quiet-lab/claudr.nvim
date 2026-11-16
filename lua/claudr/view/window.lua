-- Общее устройство видов узлов: обычный буфер в окне, из которого открыто дерево (решения
-- D50, D51), учёт открытых видов и их освобождение. Вид освобождается (процесс завершается,
-- наблюдение закрывается) при удалении буфера и при закрытии окна, в котором он показан;
-- уход из буфера в файл (например, `gd` на ссылке) вид не освобождает, `<C-o>` возвращает в
-- него, а новый вид в окне закрывает прежний вид окна, кроме подключения с вводом (D68).
-- Плавающее окно (`open_float`) остаётся окнам, которые не виды узлов: буфер диалога агента.
-- Таймеров нет.
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

local function is_normal(win)
  return vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ""
    and not vim.wo[win].winfixbuf
end

local function is_tree(win)
  local tree_buf = require("claudr.tree.view").buf()
  return tree_buf ~= nil and vim.api.nvim_win_get_buf(win) == tree_buf
end

local function usable(win)
  return win and win ~= 0 and is_normal(win) and not is_tree(win)
end

--- Окно для вида узла: текущее окно, если оно обычное и не окно дерева (вид открыт командой
--- или из другого вида); иначе окно, из которого открыто дерево; иначе предыдущее окно;
--- иначе любое другое обычное окно вкладки; иначе `nil` (нужно новое окно).
function M.target_window()
  local cur = vim.api.nvim_get_current_win()
  if usable(cur) then
    return cur
  end
  local origin = require("claudr.tree.view").origin_win()
  if usable(origin) then
    return origin
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if usable(prev) then
    return prev
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then
      return win
    end
  end
  return nil
end

-- Настройки окна вида: местные для окна и буфера, поэтому после ухода из буфера окно
-- возвращается к своим обычным.
local VIEW_WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = false,
  list = false,
  spell = false,
  colorcolumn = "",
}

-- Закрывает вид `prev`, вытесненный из окна буфером `buf`: только если это другой вид, не
-- подключение с вводом (его терминал принимает ввод пользователя и закрывается только явно) и
-- его буфер больше нигде не показан. Окно уже показывает `buf`, поэтому остаётся на месте.
local function replace(prev, buf)
  if not prev or prev.released or prev.buf == buf or prev.kind == "attach" then
    return
  end
  if not vim.api.nvim_buf_is_valid(prev.buf) or #vim.fn.win_findbuf(prev.buf) > 0 then
    return
  end
  pcall(vim.api.nvim_buf_delete, prev.buf, { force = true })
end

--- Показывает буфер вида `buf` в окне `M.target_window()` (без него — в новом окне справа
--- от дерева), делает окно текущим и записывает уход из прежнего буфера в список переходов.
--- Буфер не удаляется при уходе из окна: `<C-o>` возвращает в вид. Возвращает окно.
function M.open_view(buf, opts)
  opts = opts or {}
  local win = M.target_window()
  -- прежний вид окна заменяется новым (решение D68): после показа нового буфера он закрывается
  local prev = win and views[vim.api.nvim_win_get_buf(win)]
  if not win then
    vim.cmd("rightbelow vertical new")
    win = vim.api.nvim_get_current_win()
    -- пустой буфер нового окна не нужен
    local blank = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)
    if blank ~= buf and vim.api.nvim_buf_is_valid(blank) then
      pcall(vim.api.nvim_buf_delete, blank, { force = true })
    end
  else
    vim.api.nvim_set_current_win(win)
    vim.cmd("normal! m'")
    local ok = pcall(vim.api.nvim_win_set_buf, win, buf)
    if not ok then
      -- прежний буфер окна не отпускает (например, `winfixbuf`): новое окно
      vim.cmd("rightbelow vertical split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end
  end
  vim.bo[buf].bufhidden = "hide"
  replace(prev, buf)
  for name, value in pairs(VIEW_WINDOW_OPTIONS) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  if opts.title then
    pcall(
      vim.api.nvim_buf_set_name,
      buf,
      ("claudr://%s [%d]"):format((opts.title:gsub("[\r\n]", " ")), buf)
    )
  end
  return win
end

--- Окно, в котором сейчас показан вид `v` (его собственное, иначе первое, где виден буфер) или `nil`.
function M.win_of(v)
  if v.win and vim.api.nvim_win_is_valid(v.win) and vim.api.nvim_win_get_buf(v.win) == v.buf then
    return v.win
  end
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return nil
  end
  return vim.fn.win_findbuf(v.buf)[1]
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
    -- закрытие окна, в котором вид открыт, закрывает вид, если буфер нигде больше не показан
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(v.win),
      once = true,
      callback = function()
        -- закрываемое окно ещё числится среди окон буфера
        for _, other in ipairs(vim.fn.win_findbuf(buf)) do
          if other ~= v.win then
            return
          end
        end
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

-- Освобождает окно `win` от буфера `buf`, не закрывая окно: альтернативный буфер окна,
-- иначе пустой.
local function leave_window(win, buf)
  local alt = vim.api.nvim_win_call(win, function()
    return vim.fn.bufnr("#")
  end)
  if alt < 1 or alt == buf or not vim.api.nvim_buf_is_valid(alt) then
    alt = vim.api.nvim_create_buf(true, false)
  end
  pcall(vim.api.nvim_win_set_buf, win, alt)
end

--- Закрывает вид: буфер удаляется, а окна, где он был показан, остаются на месте с прежним
--- (альтернативным) буфером; плавающие окна закрываются.
function M.close(v)
  if not vim.api.nvim_buf_is_valid(v.buf) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(v.buf)) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    else
      leave_window(win, v.buf)
    end
  end
  pcall(vim.api.nvim_buf_delete, v.buf, { force = true })
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
