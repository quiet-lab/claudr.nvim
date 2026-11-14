-- Общее окно ввода текста (спецификация message-input, решение D30): сообщение агенту,
-- свободный ответ на вопрос и пояснение к отказу — один набор текста с разной целью отправки.
--
-- Плавающее окно с обычным редактируемым буфером (`acwrite`). Текст отправляется сохранением
-- (`:w`) и клавишами из настройки `message_input.send` (по умолчанию Shift+Enter и
-- Shift+Space, в нормальном режиме и в режиме вставки). Черновик хранится в памяти по цели
-- (вид + ключ): закрытие без отправки его сохраняет, успешная отправка очищает. Окно
-- обновляет черновик по событиям буфера (`nvim_buf_attach`), таймеров и опроса нет.
local config = require("claudr.config")
local window = require("claudr.view.window")

local M = {}

---@type table<string, string> черновики: ключ цели → текст
local drafts = {}
---@type table<string, table> открытые окна: ключ цели → состояние
local open_windows = {}
local counter = 0

local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO)
end

local function draft_key(target)
  return tostring(target.kind) .. "\0" .. tostring(target.key)
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function do_close(w, keep_draft)
  if not keep_draft then
    w.finished = true
    drafts[w.key] = nil
  end
  if open_windows[w.key] == w then
    open_windows[w.key] = nil
  end
  -- Отправка клавишей из режима вставки закрывает окно, не выходя из режима: без выхода
  -- режим вставки перешёл бы в прежнее окно (буфер диалога, вид панели), где клавиши
  -- нормального режима не действуют.
  local leave_insert = w.win
    and vim.api.nvim_win_is_valid(w.win)
    and vim.api.nvim_get_current_win() == w.win
    and vim.fn.mode():sub(1, 1) == "i"
  if w.win and vim.api.nvim_win_is_valid(w.win) then
    pcall(vim.api.nvim_win_close, w.win, true)
  end
  if leave_insert then
    vim.cmd("stopinsert")
  end
  if vim.api.nvim_buf_is_valid(w.buf) then
    pcall(vim.api.nvim_buf_delete, w.buf, { force = true })
  end
end

-- Закрытие из обработчика записи откладывается до конца команды: после `:wq` команда
-- `:q` иначе закрыла бы уже следующее окно.
local function close(w, keep_draft)
  w.busy = false
  if w.in_write then
    vim.schedule(function()
      do_close(w, keep_draft)
    end)
  else
    do_close(w, keep_draft)
  end
end

local function submit(w)
  if w.busy or not vim.api.nvim_buf_is_valid(w.buf) then
    return
  end
  local text = buf_text(w.buf)
  if vim.trim(text) == "" then
    notify(
      "claudr: текст пуст, ничего не отправлено",
      vim.log.levels.WARN
    )
    return
  end
  local async = w.on_submit(text, function(keep_draft)
    close(w, keep_draft == true)
  end, function()
    w.busy = false
  end)
  if async == true then
    w.busy = true
  end
end

local function footer_text(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k
  end
  return " " .. table.concat(parts, " / ") .. " или :w — отправить "
end

--- Открывает окно ввода. `opts`: `title`; `target = { kind, key }` — цель и ключ черновика
--- (разные пары — разные черновики); `on_submit(text, close, release)` — вызывается при
--- отправке непустого текста: `close()` закрывает окно и очищает черновик (`close(true)`
--- закрывает, сохранив черновик); окно без вызова `close` остаётся. Если `on_submit`
--- вернул `true` (завершение асинхронное), окно занято, повторные отправки игнорируются,
--- пока не вызван `close` или `release()`. Для уже открытой цели окно только получает
--- фокус. Возвращает `{ buf, win, key }`.
---@param opts table
function M.open(opts)
  local target = opts.target or { kind = "text", key = "" }
  local key = draft_key(target)
  local existing = open_windows[key]
  if
    existing
    and vim.api.nvim_win_is_valid(existing.win)
    and vim.api.nvim_buf_is_valid(existing.buf)
  then
    vim.api.nvim_set_current_win(existing.win)
    return existing
  end

  local cfg = config.get().message_input
  counter = counter + 1
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "claudr-input"
  vim.api.nvim_buf_set_name(buf, "claudr://input/" .. counter)
  local draft = drafts[key]
  if draft then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(draft, "\n", { plain = true }))
  end
  vim.bo[buf].modified = false

  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight - 1
  local win = window.open_float(buf, {
    title = opts.title,
    width = math.min(80, math.floor(cols * 0.7)),
    height = math.min(12, math.max(3, math.floor(lines * 0.4))),
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  pcall(vim.api.nvim_win_set_config, win, {
    footer = footer_text(cfg.send),
    footer_pos = "center",
  })

  local w = { buf = buf, win = win, key = key, on_submit = opts.on_submit, busy = false }
  open_windows[key] = w

  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if w.finished or not vim.api.nvim_buf_is_valid(buf) then
        return true
      end
      local text = buf_text(buf)
      drafts[key] = text ~= "" and text or nil
      -- закрытие без отправки не требует `:q!`: буфер всегда считается сохранённым
      vim.bo[buf].modified = false
    end,
  })

  local group = vim.api.nvim_create_augroup("claudr.input." .. counter, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      w.in_write = true
      local ok, err = pcall(submit, w)
      w.in_write = false
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
      end
      if not ok then
        error(err, 0)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      if open_windows[key] == w then
        open_windows[key] = nil
      end
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })

  for _, k in ipairs(cfg.send) do
    vim.keymap.set(
      { "n", "i" },
      k,
      function()
        submit(w)
      end,
      { buffer = buf, nowait = true, silent = true, desc = "claudr: отправить текст" }
    )
  end

  local last = vim.api.nvim_buf_line_count(buf)
  local len = #vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1]
  vim.api.nvim_win_set_cursor(win, { last, len })
  vim.cmd("startinsert!")
  return w
end

--- Черновик цели (`{ kind, key }`) или `nil`.
---@param target table
function M.draft(target)
  return drafts[draft_key(target)]
end

--- Открытое окно цели или `nil`.
---@param target table
function M.window(target)
  return open_windows[draft_key(target)]
end

--- Закрывает все окна, сохраняя черновики; `forget = true` ещё и стирает их (тесты).
---@param forget boolean|nil
function M.reset(forget)
  local all = {}
  for _, w in pairs(open_windows) do
    all[#all + 1] = w
  end
  for _, w in ipairs(all) do
    do_close(w, true)
  end
  if forget then
    drafts = {}
  end
end

return M
