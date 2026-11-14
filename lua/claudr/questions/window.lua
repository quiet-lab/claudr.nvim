-- Окно ответа темы: буфер только для чтения сбоку, показ вопросов и ответов темы, переход
-- по ссылкам `файл:строка`. Буфер у каждой темы свой; содержимое строится из модели темы
-- (claudr.questions.topic) и перерисовывается при каждом её изменении.
local M = {}

local NAME_PREFIX = "claudr://topic/"

--- Клавиши окна ответа (буферные, режим normal).
M.keys = {
  ask = "a",
  retry = "R",
  jump = "<CR>",
  jump_alt = "gf",
  close = "q",
}

---@type table<integer, string> буфер → идентификатор сессии темы
local buf_topic = {}

--- Идентификатор темы буфера или `nil`.
function M.topic_of(bufnr)
  return buf_topic[bufnr or vim.api.nvim_get_current_buf()]
end

local function lines_of(text)
  return vim.split(text, "\n", { plain = true })
end

local function render_lines(topic)
  local out = {}
  local function add(s)
    vim.list_extend(out, lines_of(s))
  end
  local rec = topic.record or {}
  add("# " .. (rec.title or topic.id))
  local meta = {}
  if rec.mode then
    meta[#meta + 1] = "режим: " .. rec.mode
  end
  if rec.file then
    meta[#meta + 1] = rec.file .. (rec.symbol and (" · " .. rec.symbol) or "")
  end
  if #meta > 0 then
    add(table.concat(meta, " · "))
  end
  if topic.unavailable then
    add("")
    add(
      "Содержимое недоступно: транскрипт сессии темы не найден."
    )
  end
  for _, e in ipairs(topic.entries) do
    add("")
    add(e.status == "queued" and "## Вопрос (в очереди)" or "## Вопрос")
    add("")
    add(e.question)
    if e.status ~= "queued" then
      add("")
      add("## Ответ")
      add("")
      if e.answer ~= "" then
        add(e.answer)
      elseif e.status == "running" then
        add("…")
      end
      if e.status == "error" then
        add("")
        add("**Ошибка:** " .. (e.error or "неизвестная причина"))
        add(("Повторить вопрос — клавиша `%s`."):format(M.keys.retry))
      end
    end
  end
  return out
end

local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
end

--- Перерисовывает буфер темы, если он есть. Окна, стоявшие в конце буфера, остаются в конце:
--- ответ дописывается у них на глазах.
function M.render(topic)
  local bufnr = topic.buf
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local old_count = vim.api.nvim_buf_line_count(bufnr)
  local follow = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_get_cursor(win)[1] >= old_count then
      follow[#follow + 1] = win
    end
  end
  local lines = render_lines(topic)
  set_lines(bufnr, lines)
  for _, win in ipairs(follow) do
    vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  end
end

--- Текст буфера темы (для проверок).
function M.text(topic)
  if not topic.buf or not vim.api.nvim_buf_is_valid(topic.buf) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(topic.buf, 0, -1, false), "\n")
end

-- ---------- ссылки ----------

local LINK = "([%w_%.%-/~]+):(%d+)"

--- Ссылка `файл:строка` под курсором (или первая в строке): путь и номер строки.
---@param line string
---@param col integer столбец курсора в байтах с нуля
function M.link_at(line, col)
  local first
  local init = 1
  while true do
    local s, e, path, lnum = line:find(LINK, init)
    if not s then
      break
    end
    if path:find("[%./]") and not path:match("^%d+$") then
      local link = { path = path, line = tonumber(lnum) }
      first = first or link
      if col + 1 >= s and col + 1 <= e then
        return link
      end
    end
    init = e + 1
  end
  return first
end

local function is_edit_window(win)
  local b = vim.api.nvim_win_get_buf(win)
  return vim.bo[b].buftype == ""
    and not buf_topic[b]
    and vim.api.nvim_win_get_config(win).relative == ""
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
  vim.cmd("topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
  return win
end

--- Переход по ссылке под курсором окна ответа: файл открывается в окне редактирования на
--- указанной строке. Относительный путь берётся от каталога проекта темы.
---@param topic table
function M.jump(topic)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local link = M.link_at(line, cursor[2])
  if not link then
    vim.notify(
      "claudr: под курсором нет ссылки файл:строка",
      vim.log.levels.WARN
    )
    return false
  end
  local path = vim.fs.normalize(link.path)
  if not vim.startswith(path, "/") then
    path = vim.fs.joinpath(topic.record.project_dir, path)
  end
  if not vim.uv.fs_stat(path) then
    vim.notify("claudr: файл не найден: " .. link.path, vim.log.levels.WARN)
    return false
  end
  local win = edit_window()
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(win, { math.min(link.line, count), 0 })
  return true
end

-- ---------- буфер и окно ----------

--- Создаёт буфер темы (если его нет) и вешает клавиши.
---@param topic table
---@param actions { ask: fun(), retry: fun(), jump: fun() }
function M.ensure_buffer(topic, actions)
  if topic.buf and vim.api.nvim_buf_is_valid(topic.buf) then
    return topic.buf
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  topic.buf = bufnr
  buf_topic[bufnr] = topic.id
  vim.api.nvim_buf_set_name(bufnr, NAME_PREFIX .. topic.id)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = false
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true, desc = desc })
  end
  map(M.keys.ask, actions.ask, "claudr: вопрос в этой теме")
  map(
    M.keys.retry,
    actions.retry,
    "claudr: повторить вопрос после ошибки"
  )
  map(M.keys.jump, actions.jump, "claudr: перейти по ссылке файл:строка")
  map(
    M.keys.jump_alt,
    actions.jump,
    "claudr: перейти по ссылке файл:строка"
  )
  map(M.keys.close, function()
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_close(0, false)
    end
  end, "claudr: закрыть окно ответа")
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      buf_topic[bufnr] = nil
      if topic.buf == bufnr then
        topic.buf = nil
      end
    end,
  })
  M.render(topic)
  return bufnr
end

--- Показывает буфер темы в окне сбоку; окно у каждой темы своё. Возвращает окно.
---@param topic table
---@param opts { focus: boolean|nil }|nil
function M.show(topic, opts)
  opts = opts or {}
  local bufnr = topic.buf
  local origin = vim.api.nvim_get_current_win()
  local win = vim.fn.win_findbuf(bufnr)[1]
  if not win or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    -- другое окно темы в этой вкладке — делится по горизонтали, иначе новое окно справа
    local other
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if buf_topic[vim.api.nvim_win_get_buf(w)] then
        other = w
        break
      end
    end
    if other then
      vim.api.nvim_set_current_win(other)
      vim.cmd("belowright split")
    else
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_width(0, math.max(40, math.floor(vim.o.columns * 0.4)))
    end
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
  end
  if opts.focus then
    vim.api.nvim_set_current_win(win)
  elseif vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  return win
end

return M
