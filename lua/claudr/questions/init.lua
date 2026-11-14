-- Вопросы по коду (спецификация code-questions): темы — отдельные сессии Claude Code,
-- запущенные процессом `claude -p` в каталоге проекта, с окном ответа сбоку. Тема не занимает
-- панель herdr и не входит в дерево.
local registry = require("claudr.questions.registry")
local topic_mod = require("claudr.questions.topic")
local window = require("claudr.questions.window")
local context = require("claudr.questions.context")
local modes = require("claudr.questions.modes")

local M = {}

M.registry = registry

local TITLE_LEN = 60

--- Каталог проекта для буфера: корень по маркеру `.git` от файла буфера, иначе текущий
--- рабочий каталог Neovim.
---@param bufnr integer|nil
function M.project_dir(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local root = vim.api.nvim_buf_get_name(bufnr) ~= "" and vim.fs.root(bufnr, ".git") or nil
  local dir = root or vim.fn.getcwd()
  return vim.uv.fs_realpath(dir) or vim.fs.normalize(dir)
end

local function title_of(question)
  local first = vim.trim(vim.split(vim.trim(question), "\n", { plain = true })[1] or "")
  if vim.fn.strchars(first) > TITLE_LEN then
    first = vim.fn.strcharpart(first, 0, TITLE_LEN) .. "…"
  end
  return first
end

local function actions_for(topic)
  return {
    ask = function()
      M.continue(topic.id)
    end,
    retry = function()
      if not topic_mod.retry(topic) then
        vim.notify(
          "claudr: в теме нет вопроса с ошибкой",
          vim.log.levels.INFO
        )
      end
    end,
  }
end

local function show(topic, opts)
  window.ensure_buffer(topic, actions_for(topic))
  window.render(topic)
  return window.show(topic, opts)
end

local function input(prompt, cb)
  vim.ui.input({ prompt = prompt }, function(text)
    if text and vim.trim(text) ~= "" then
      cb(text)
    end
  end)
end

--- Новая тема из буфера с кодом.
---@param opts { kind: "cursor"|"selection"|"file"|nil, range: integer[]|nil, mode: string|nil, bufnr: integer|nil, question: string|nil, on_topic: fun(topic)|nil }|nil
function M.ask(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  -- из окна ответа вопрос продолжает тему этого окна
  local own = window.topic_of(bufnr)
  if own then
    return M.continue(own, opts)
  end
  local mode = opts.mode or modes.DEFAULT
  if not modes.get(mode) then
    vim.notify("claudr: неизвестный режим " .. mode, vim.log.levels.ERROR)
    return
  end
  local kind = opts.kind or (opts.range and "selection") or "cursor"
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or { 1, 0 }
  local project_dir = M.project_dir(bufnr)
  local req = {
    bufnr = bufnr,
    kind = kind,
    range = opts.range,
    cursor = cursor,
    project_dir = project_dir,
  }
  -- пакет контекста и текст вопроса собираются одновременно
  local packet, question
  local function go()
    if not (packet and question) then
      return
    end
    local id = topic_mod.new_session_id()
    -- запись реестра — до запуска процесса
    local record = registry.create({
      session_id = id,
      project_dir = project_dir,
      title = title_of(question),
      mode = mode,
      file = packet.file ~= "" and packet.file or nil,
      symbol = packet.symbol,
    })
    local topic = topic_mod.load(record)
    show(topic)
    topic_mod.submit(topic, question, context.format(question, packet))
    if opts.on_topic then
      opts.on_topic(topic)
    end
  end
  context.collect(req, function(p)
    packet = p
    go()
  end)
  if opts.question then
    question = opts.question
    go()
  else
    input("Вопрос: ", function(text)
      question = text
      go()
    end)
  end
end

--- Вопрос по последнему выделению в буфере (строки отметок `'<` и `'>`).
function M.ask_selection(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local s = vim.api.nvim_buf_get_mark(bufnr, "<")[1]
  local e = vim.api.nvim_buf_get_mark(bufnr, ">")[1]
  if s == 0 or e == 0 then
    vim.notify("claudr: в буфере нет выделения", vim.log.levels.WARN)
    return
  end
  opts.kind = "selection"
  opts.range = { math.min(s, e), math.max(s, e) }
  return M.ask(opts)
end

--- Вопрос по текущему файлу: в вопрос уходит содержимое буфера, включая несохранённые правки.
function M.ask_file(opts)
  opts = opts or {}
  opts.kind = "file"
  opts.range = nil
  return M.ask(opts)
end

--- Продолжение темы: вопрос уходит процессом с `--resume` (или в очередь темы).
---@param session_id string
---@param opts { question: string|nil }|nil
function M.continue(session_id, opts)
  opts = opts or {}
  local record = registry.get(session_id)
  if not record then
    vim.notify("claudr: темы нет в реестре", vim.log.levels.ERROR)
    return
  end
  local topic = topic_mod.load(record)
  local function send(text)
    show(topic, { focus = window.topic_of() == topic.id })
    topic_mod.submit(topic, text)
  end
  -- вопрос уходит после чтения прежних реплик: новый вопрос встаёт после них
  topic_mod.restore(topic, function()
    if opts.question then
      send(opts.question)
    else
      input("Вопрос в теме: ", send)
    end
  end)
  return topic
end

--- Открывает окно темы; закрытая тема восстанавливается из транскрипта без запуска процесса.
---@param session_id string
---@param opts { focus: boolean|nil }|nil
function M.open_topic(session_id, opts)
  local record = registry.get(session_id)
  if not record then
    vim.notify("claudr: темы нет в реестре", vim.log.levels.ERROR)
    return
  end
  local topic = topic_mod.load(record)
  topic_mod.restore(topic)
  show(topic, { focus = not opts or opts.focus ~= false })
  return topic
end

--- Записи тем проекта для перечня: запись реестра и признак «содержимое недоступно».
---@param project_dir string|nil
function M.topic_items(project_dir)
  local items = {}
  for _, rec in ipairs(registry.list(project_dir or M.project_dir())) do
    -- содержимое есть, пока есть транскрипт сессии или тема ещё отвечает
    local loaded = topic_mod.get(rec.session_id)
    local available = topic_mod.transcript(rec.session_id) ~= nil
      or (loaded ~= nil and loaded.proc ~= nil)
    items[#items + 1] = { record = rec, unavailable = not available }
  end
  return items
end

--- Строка перечня тем.
function M.format_item(item)
  local rec = item.record
  local parts = { rec.title or rec.session_id }
  if rec.file then
    parts[#parts + 1] = rec.file .. (rec.symbol and (":" .. rec.symbol) or "")
  end
  parts[#parts + 1] = os.date("%Y-%m-%d %H:%M", math.floor(rec.last_used_at or 0))
  local text = table.concat(parts, " · ")
  if item.unavailable then
    text = text .. " (содержимое недоступно)"
  end
  return text
end

--- Перечень тем проекта (`vim.ui.select`); выбранная тема открывается.
function M.topics(opts)
  opts = opts or {}
  local items = M.topic_items(opts.project_dir)
  if #items == 0 then
    vim.notify(
      "claudr: в проекте нет тем вопросов по коду",
      vim.log.levels.INFO
    )
    return
  end
  vim.ui.select(items, {
    prompt = "Темы вопросов по коду",
    format_item = M.format_item,
    kind = "claudr.topic",
  }, function(item)
    if item then
      M.open_topic(item.record.session_id)
    end
  end)
end

--- Открывает тему проекта с самым поздним временем последнего обращения.
function M.last_topic(opts)
  opts = opts or {}
  local rec = registry.latest(opts.project_dir or M.project_dir())
  if not rec then
    vim.notify(
      "claudr: в проекте нет тем вопросов по коду",
      vim.log.levels.INFO
    )
    return
  end
  return M.open_topic(rec.session_id)
end

--- Регистрирует режим (см. claudr.questions.modes).
M.register_mode = modes.register

--- Регистрирует дополнительный поставщик контекста для типа файла.
M.register_provider = context.register

local function complete_modes(arglead)
  return vim.tbl_filter(function(n)
    return vim.startswith(n, arglead)
  end, modes.names())
end

local function selection_from_visual()
  local s, e = vim.fn.line("v"), vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return { math.min(s, e), math.max(s, e) }
end

function M.setup()
  local commands = require("claudr.commands")
  commands.register("ask", function(args)
    M.ask({ mode = args[1] })
  end, {
    desc = "вопрос по коду под курсором (новая тема)",
    complete = complete_modes,
  })
  commands.register("ask-selection", function(args)
    M.ask_selection({ mode = args[1] })
  end, {
    desc = "вопрос по последнему выделению (новая тема)",
    complete = complete_modes,
  })
  commands.register("ask-file", function(args)
    M.ask_file({ mode = args[1] })
  end, {
    desc = "вопрос по текущему файлу (новая тема)",
    complete = complete_modes,
  })
  commands.register("topics", function()
    M.topics()
  end, { desc = "перечень тем вопросов по коду проекта" })
  commands.register("topic-last", function()
    M.last_topic()
  end, { desc = "последняя тема вопросов по коду" })

  vim.keymap.set("n", "<Plug>(claudr-ask)", function()
    M.ask()
  end, { desc = "claudr: вопрос по коду под курсором" })
  vim.keymap.set("x", "<Plug>(claudr-ask)", function()
    M.ask({ kind = "selection", range = selection_from_visual() })
  end, { desc = "claudr: вопрос по выделению" })
  vim.keymap.set("n", "<Plug>(claudr-ask-file)", function()
    M.ask_file()
  end, { desc = "claudr: вопрос по текущему файлу" })
  vim.keymap.set("n", "<Plug>(claudr-topics)", function()
    M.topics()
  end, { desc = "claudr: перечень тем вопросов по коду" })
  vim.keymap.set("n", "<Plug>(claudr-topic-last)", function()
    M.last_topic()
  end, { desc = "claudr: последняя тема вопросов по коду" })
end

return M
