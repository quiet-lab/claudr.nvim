-- Ссылки на файлы в буферах плагина (спецификация file-references): путь под курсором
-- (`файл`, `файл:строка`, `файл:строка:столбец`), предпросмотр в плавающем окне и открытие
-- файла в окне, из которого сделан переход. Клавиши назначаются только в буферах, которые
-- подключены через `M.attach`; вне ссылки клавиша ведёт себя как без плагина. Закрытие
-- предпросмотра идёт по событиям редактора, таймеров нет.
local config = require("claudr.config")

local M = {}

M.NS = vim.api.nvim_create_namespace("claudr.refs")

-- Знаки, которые ограничивают путь: пробельные, кавычки, обратный апостроф, скобки.
local DELIM = "[%s\"'`()%[%]{}<>]"
-- Завершающие знаки, которые в путь и номера не входят.
local TRAILING = "[%.,;:]+$"

---@type table<integer, { cwd: fun(): string|nil }> подключённые буферы
local attached = {}

-- ---------- разбор ----------

-- Юникодные пробелы (U+00A0, U+2000–U+200B, U+202F, U+205F, U+3000) заменяются пробелами
-- той же длины в байтах: Claude Code ставит неразрывный пробел после знаков `⎿` и `●` и
-- перед путём, и такой пробел иначе вошёл бы в путь; смещения в строке не меняются.
local function blank_spaces(line)
  line = line:gsub("\xc2\xa0", "  ")
  line = line:gsub("\xe2\x80[\x80-\x8b\xaf]", "   ")
  line = line:gsub("\xe2\x81\x9f", "   ")
  line = line:gsub("\xe3\x80\x80", "   ")
  return line
end

--- Ссылка под курсором по тексту строки, без проверки файла. Возвращает список вариантов
--- разбора от самого полного (`файл:строка:столбец`) к самому короткому (весь текст как
--- путь): `{ { path, line|nil, col|nil }, … }`; `nil`, если курсор не на ссылке.
---@param line string
---@param col integer столбец курсора в байтах с нуля
---@return table[]|nil
function M.parse(line, col)
  line = blank_spaces(line)
  local idx = col + 1
  if idx < 1 or idx > #line or line:sub(idx, idx):find(DELIM) then
    return nil
  end
  local s, e = idx, idx
  while s > 1 and not line:sub(s - 1, s - 1):find(DELIM) do
    s = s - 1
  end
  while e < #line and not line:sub(e + 1, e + 1):find(DELIM) do
    e = e + 1
  end
  local token = line:sub(s, e)
  local trimmed = token:gsub(TRAILING, "")
  if trimmed == "" or idx > s + #trimmed - 1 then
    return nil
  end
  local out = {}
  local p, l, c = trimmed:match("^(.+):(%d+):(%d+)$")
  if p then
    out[#out + 1] = { path = p, line = tonumber(l), col = tonumber(c) }
  end
  p, l = trimmed:match("^(.+):(%d+)$")
  if p then
    out[#out + 1] = { path = p, line = tonumber(l) }
  end
  out[#out + 1] = { path = trimmed }
  return out
end

--- Полный путь к существующему файлу или `nil`: относительный путь берётся от `cwd`,
--- каталог и несуществующий путь не годятся.
---@param path string
---@param cwd string|nil
---@return string|nil
function M.resolve(path, cwd)
  local full = path
  if not (path:sub(1, 1) == "/" or path:sub(1, 1) == "~") then
    if not cwd or cwd == "" then
      return nil
    end
    full = vim.fs.joinpath(cwd, path)
  end
  full = vim.fs.normalize(full)
  local st = vim.uv.fs_stat(full)
  if st and st.type == "file" then
    return full
  end
  return nil
end

--- Ссылка по строке и столбцу: `{ path = <полный путь>, line, col }` или `nil`.
---@param line string
---@param col integer
---@param cwd string|nil
function M.link_in(line, col, cwd)
  for _, cand in ipairs(M.parse(line, col) or {}) do
    local full = M.resolve(cand.path, cwd)
    if full then
      return { path = full, line = cand.line, col = cand.col }
    end
  end
  return nil
end

--- Ссылка под курсором окна `win` (по умолчанию текущего) в подключённом буфере.
---@param win integer|nil
function M.link_at_cursor(win)
  win = win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local reg = attached[buf]
  if not reg then
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1] or ""
  return M.link_in(line, cur[2], reg.cwd())
end

-- ---------- предпросмотр ----------

local preview = nil -- { win, buf, src, augroup, esc }

--- Окно предпросмотра, если открыто.
function M.preview_win()
  return preview and preview.win or nil
end

--- Закрывает предпросмотр (окно, автокоманды, временную клавишу Escape).
function M.close_preview()
  local p = preview
  if not p then
    return
  end
  preview = nil
  pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
  if vim.api.nvim_buf_is_valid(p.src) then
    pcall(vim.keymap.del, "n", "<Esc>", { buffer = p.src })
    if p.esc then
      pcall(vim.fn.mapset, "n", false, p.esc)
    end
  end
  if vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  if vim.api.nvim_buf_is_valid(p.buf) then
    pcall(vim.api.nvim_buf_delete, p.buf, { force = true })
  end
end

local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    return { "" }
  end
  return lines
end

local function highlight(buf, path, lines)
  local ft = vim.filetype.match({ filename = path, contents = lines })
  if not ft then
    return
  end
  vim.bo[buf].filetype = ft
  local lang = vim.treesitter.language.get_lang(ft)
  if lang then
    pcall(vim.treesitter.start, buf, lang)
  end
end

--- Открывает предпросмотр ссылки `link` из окна `win` (по умолчанию текущего). Фокус
--- остаётся в исходном окне. Возвращает окно предпросмотра.
---@param link { path: string, line: integer|nil }
---@param win integer|nil
function M.show_preview(link, win)
  M.close_preview()
  vim.api.nvim_set_hl(0, "ClaudrRefLine", { link = "Visual", default = true })
  win = win or vim.api.nvim_get_current_win()
  local src = vim.api.nvim_win_get_buf(win)
  local lines = read_lines(link.path)
  local lnum = math.max(1, math.min(link.line or 1, #lines))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
  highlight(buf, link.path, lines)
  vim.api.nvim_buf_set_extmark(buf, M.NS, lnum - 1, 0, {
    line_hl_group = "ClaudrRefLine",
    end_row = lnum - 1,
    priority = 200,
  })

  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 1, 100, vim.o.columns - 4)
  local height = math.min(#lines, 20, vim.o.lines - 6)
  height = math.max(height, 1)
  local below = vim.fn.screenrow() + height + 3 <= vim.o.lines
  local pwin = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = below and 1 or -(height + 2),
    col = 0,
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " " .. vim.fn.fnamemodify(link.path, ":t") .. ":" .. lnum .. " ",
    title_pos = "center",
    focusable = false,
  })
  vim.wo[pwin].cursorline = true
  vim.wo[pwin].wrap = false
  vim.api.nvim_win_set_cursor(pwin, { lnum, 0 })
  vim.api.nvim_win_call(pwin, function()
    vim.cmd("normal! zz")
  end)

  local group = vim.api.nvim_create_augroup("claudr.refs.preview", { clear = true })
  local origin = vim.api.nvim_win_get_cursor(win)
  local p = { win = pwin, buf = buf, src = src, augroup = group }
  preview = p
  local function close()
    if preview == p then
      M.close_preview()
    end
  end
  -- Закрытие по событиям редактора: движение курсора, выход из буфера или окна, смена режима.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = src,
    callback = function()
      -- отложенное событие о прежнем положении курсора окно не закрывает
      if
        vim.api.nvim_win_is_valid(win) and vim.deep_equal(vim.api.nvim_win_get_cursor(win), origin)
      then
        return
      end
      close()
    end,
  })
  vim.api.nvim_create_autocmd(
    { "BufLeave", "BufHidden", "BufWipeout", "InsertEnter", "TermEnter" },
    { group = group, buffer = src, callback = close }
  )
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = close,
  })
  -- Escape: пока предпросмотр открыт, клавиша закрывает его; прежняя привязка возвращается.
  local prev = vim.fn.maparg("<Esc>", "n", false, true)
  p.esc = (type(prev) == "table" and prev.buffer == 1 and prev.lhs) and prev or nil
  vim.keymap.set("n", "<Esc>", close, {
    buffer = src,
    nowait = true,
    silent = true,
    desc = "claudr: закрыть предпросмотр",
  })
  return pwin
end

-- ---------- открытие ----------

-- Окно редактирования: окно с обычным буфером в обычном (не плавающем) окне.
local function is_edit_window(win)
  return vim.api.nvim_win_get_config(win).relative == ""
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

local function edit_window()
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and is_edit_window(prev) then
    return prev
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_edit_window(win) then
      return win
    end
  end
  return nil
end

--- Открывает файл ссылки на строке и столбце: в окне, из которого сделан переход (обычный
--- `:edit`, уход записывается в список переходов, `<C-o>` возвращает в буфер плагина); если
--- текущее окно плавающее, файл открывается в окне редактирования, без него — в новом окне.
--- Возвращает окно или `nil`.
---@param link { path: string, line: integer|nil, col: integer|nil }
function M.open(link)
  M.close_preview()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    win = edit_window()
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("topleft vsplit")
      win = vim.api.nvim_get_current_win()
    end
  end
  vim.cmd("normal! m'")
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(link.path))
  if not ok then
    vim.notify(
      "claudr: не удалось открыть файл: " .. tostring(err),
      vim.log.levels.WARN
    )
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local lnum = math.max(1, math.min(link.line or 1, vim.api.nvim_buf_line_count(buf)))
  local text = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local bcol = 0
  if link.col and link.col > 1 then
    local idx = vim.fn.byteidx(text, link.col - 1)
    bcol = idx >= 0 and idx or #text
  end
  bcol = math.min(bcol, math.max(#text - 1, 0))
  vim.api.nvim_win_set_cursor(win, { lnum, bcol })
  return win
end

-- ---------- клавиши ----------

-- Выполняет привязку `m` (словарь `maparg`/`nvim_get_keymap`) вместо клавиши плагина.
local function run_mapping(m)
  if m.callback then
    local res = m.callback()
    if m.expr == 1 and type(res) == "string" and res ~= "" then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(res, true, false, true), "n", false)
    end
    return
  end
  local rhs = m.rhs or ""
  if m.expr == 1 then
    rhs = tostring(vim.api.nvim_eval(rhs))
  end
  local keys = vim.api.nvim_replace_termcodes(rhs, true, false, true)
  vim.api.nvim_feedkeys(keys, (m.noremap == 1 and "n" or "m") .. "i", false)
end

-- Обычное действие клавиши: привязка буфера до плагина, затем глобальная, затем встроенное.
local function fallback(key, prev)
  if prev then
    return run_mapping(prev)
  end
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.lhs == key and m.buffer ~= 1 then
      return run_mapping(m)
    end
  end
  local count = vim.v.count > 0 and tostring(vim.v.count) or ""
  vim.cmd("normal! " .. count .. key)
end

local function map_key(buf, key, action)
  if not key or key == false or key == "" then
    return
  end
  local prev = vim.fn.maparg(key, "n", false, true)
  prev = (type(prev) == "table" and prev.buffer == 1 and prev.lhs) and prev or nil
  vim.keymap.set("n", key, function()
    local link = M.link_at_cursor()
    if link then
      action(link)
    else
      fallback(key, prev)
    end
  end, { buffer = buf, nowait = true, silent = true, desc = "claudr: ссылка на файл" })
end

--- Подключает ссылки на файлы к буферу плагина с содержимым Claude Code: клавиши
--- предпросмотра и открытия (настройка `file_references`).
---@param bufnr integer
---@param opts { cwd: fun(): string|nil } рабочий каталог сессии владельца буфера
function M.attach(bufnr, opts)
  assert(type(opts) == "table" and type(opts.cwd) == "function", "refs.attach: нужен opts.cwd")
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if attached[bufnr] then
    attached[bufnr].cwd = opts.cwd
    return
  end
  attached[bufnr] = { cwd = opts.cwd }
  local keys = config.get().file_references or {}
  map_key(bufnr, keys.preview, function(link)
    M.show_preview(link)
  end)
  map_key(bufnr, keys.open, M.open)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      attached[bufnr] = nil
    end,
  })
end

--- Буфер подключён к ссылкам (для проверок).
function M.is_attached(bufnr)
  return attached[bufnr] ~= nil
end

return M
