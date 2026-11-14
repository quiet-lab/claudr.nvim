-- Темы вопросов по коду во время работы Neovim: модель темы (вопросы и ответы), отвечающий
-- процесс `claude -p` и очередь вопросов темы. В теме работает не больше одного процесса
-- (D21); разные темы отвечают одновременно. Ответ приходит по событиям вывода и выхода
-- процесса, без таймеров и опроса.
local registry = require("claudr.questions.registry")
local stream = require("claudr.questions.stream")
local modes = require("claudr.questions.modes")
local window = require("claudr.questions.window")

local M = {}

--- Исполняемый файл Claude Code.
M.executable = "claude"

---@class claudr.TopicEntry
---@field question string текст вопроса для показа
---@field prompt string текст, который уходит процессу (вопрос и пакет контекста)
---@field answer string накопленный текст ответа
---@field status "queued"|"running"|"done"|"error"
---@field error string|nil причина ошибки

---@class claudr.Topic
---@field id string идентификатор сессии
---@field record table запись реестра
---@field entries claudr.TopicEntry[]
---@field queue claudr.TopicEntry[]
---@field proc vim.SystemObj|nil
---@field has_session boolean сессия уже создана (продолжать через --resume)
---@field unavailable boolean|nil транскрипт темы не найден
---@field buf integer|nil

---@type table<string, claudr.Topic>
local topics = {}

local listeners = {}

--- Подписка на изменения тем: `cb(topic)` после каждого изменения модели. Возвращает отписку.
function M.subscribe(cb)
  listeners[cb] = true
  return function()
    listeners[cb] = nil
  end
end

local function changed(topic)
  window.render(topic)
  for cb in pairs(listeners) do
    pcall(cb, topic)
  end
end

local function data_module()
  local ok, data = pcall(require, "claudr.data")
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

--- Путь транскрипта сессии темы или `nil` (не найден или модуль данных недоступен).
function M.transcript(session_id)
  local data = data_module()
  if data and data.find_transcript then
    return data.find_transcript(session_id)
  end
  return nil
end

--- Тема по идентификатору сессии, если она загружена.
function M.get(session_id)
  return topics[session_id]
end

--- Все загруженные темы.
function M.all()
  return topics
end

--- Новый идентификатор сессии (UUID версии 4).
function M.new_session_id()
  local bytes = assert(vim.uv.random(16))
  local b = { bytes:byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do
    hex[i] = ("%02x"):format(b[i])
  end
  local s = table.concat(hex)
  return ("%s-%s-%s-%s-%s"):format(
    s:sub(1, 8),
    s:sub(9, 12),
    s:sub(13, 16),
    s:sub(17, 20),
    s:sub(21)
  )
end

local function config()
  return require("claudr.config").get().code_questions or {}
end

--- Описание MCP-сервера проекта по настройке `code_questions.mcp` или `nil`.
--- Настройка — описание вида `{ mcpServers = {…} }` для всех проектов, таблица
--- «каталог проекта → описание» или функция `fn(project_dir) -> описание|nil`.
function M.mcp_for(project_dir)
  local mcp = config().mcp
  if type(mcp) == "function" then
    mcp = mcp(project_dir)
  elseif type(mcp) == "table" and mcp.mcpServers == nil then
    mcp = mcp[project_dir]
  end
  if type(mcp) == "table" and type(mcp.mcpServers) == "table" and next(mcp.mcpServers) then
    return mcp
  end
  return nil
end

--- Базовая сессия проекта для ответвления или `nil`: только при `fork_from_base = true`
--- и заданной `base_session` (идентификатор или функция `fn(project_dir) -> идентификатор`).
local function base_session(project_dir)
  local cfg = config()
  if cfg.fork_from_base ~= true then
    return nil
  end
  local base = cfg.base_session
  if type(base) == "function" then
    base = base(project_dir)
  elseif type(base) == "table" then
    base = base[project_dir]
  end
  return type(base) == "string" and base ~= "" and base or nil
end

--- Аргументы отвечающего процесса для темы.
---@param topic claudr.Topic
---@return string[]
function M.args(topic)
  local rec = topic.record
  local mode = modes.get(rec.mode) or modes.get(modes.DEFAULT)
  local cfg = config()
  local tools = mode.tools or modes.READ_TOOLS
  local allowed = vim.deepcopy(tools)
  local args = {
    M.executable,
    "-p",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--model",
    mode.model or cfg.model or "sonnet",
    "--tools",
    table.concat(tools, ","),
  }
  if mode.prompt and mode.prompt ~= "" then
    vim.list_extend(args, { "--append-system-prompt", mode.prompt })
  end
  local mcp = M.mcp_for(rec.project_dir)
  if mcp then
    local names = vim.tbl_keys(mcp.mcpServers)
    table.sort(names)
    for _, name in ipairs(names) do
      allowed[#allowed + 1] = "mcp__" .. name
    end
    vim.list_extend(args, { "--mcp-config", vim.json.encode(mcp), "--strict-mcp-config" })
  end
  if #allowed > 0 then
    vim.list_extend(args, { "--allowedTools", table.concat(allowed, ",") })
  end
  if topic.has_session then
    vim.list_extend(args, { "--resume", topic.id })
  else
    local base = base_session(rec.project_dir)
    if base then
      vim.list_extend(args, { "--resume", base, "--fork-session" })
    end
    vim.list_extend(args, { "--session-id", topic.id })
  end
  return args
end

--- Тема в памяти для записи реестра; при первом обращении сведения о сессии берутся
--- из транскрипта.
---@param record table
---@return claudr.Topic
function M.load(record)
  local topic = topics[record.session_id]
  if topic then
    topic.record = record
    return topic
  end
  topic = {
    id = record.session_id,
    record = record,
    entries = {},
    queue = {},
    has_session = false,
  }
  topics[topic.id] = topic
  return topic
end

--- Заполняет тему из транскрипта её сессии, не запуская процесс. Транскрипта нет — тема
--- помечается «содержимое недоступно».
---@param topic claudr.Topic
function M.restore(topic)
  if topic.proc or #topic.entries > 0 then
    return
  end
  local path = M.transcript(topic.id)
  local data = data_module()
  local replies = path and data and data.read_dialogue and data.read_dialogue(path)
  if not replies then
    topic.unavailable = true
    changed(topic)
    return
  end
  topic.unavailable = false
  topic.has_session = true
  local context = require("claudr.questions.context")
  local entry
  for _, r in ipairs(replies) do
    if r.role == "user" then
      entry = {
        question = context.strip(r.text or ""),
        prompt = r.text or "",
        answer = "",
        status = "done",
      }
      topic.entries[#topic.entries + 1] = entry
    elseif r.role == "assistant" and entry then
      local text = r.text or ""
      entry.answer = entry.answer == "" and text or (entry.answer .. "\n\n" .. text)
    end
  end
  changed(topic)
end

local start

local function next_in_queue(topic)
  local entry = table.remove(topic.queue, 1)
  if entry then
    start(topic, entry)
  end
end

local function tail(text, n)
  text = vim.trim(text or "")
  if #text > n then
    text = "…" .. text:sub(-n)
  end
  return text
end

---@param topic claudr.Topic
---@param entry claudr.TopicEntry
start = function(topic, entry)
  entry.status = "running"
  entry.answer = ""
  entry.error = nil
  if not topic.has_session and M.transcript(topic.id) then
    topic.has_session = true
  end
  local ok_touch, rec = pcall(registry.touch, topic.id)
  if ok_touch and rec then
    topic.record = rec
  end
  local result, stderr = nil, {}
  local parser = stream.new({
    on_text = function(chunk)
      entry.answer = entry.answer .. chunk
      changed(topic)
    end,
    on_init = function()
      -- сессия создана: следующий вопрос продолжает её
      topic.has_session = true
    end,
    on_result = function(frame)
      result = frame
    end,
  })
  local function on_exit(res)
    parser:finish()
    topic.proc = nil
    if result and result.is_error ~= true and res.code == 0 then
      entry.status = "done"
      if entry.answer == "" and type(result.result) == "string" then
        entry.answer = result.result
      end
    else
      entry.status = "error"
      local reason
      if result and result.is_error == true then
        reason = "ответ завершился ошибкой: "
          .. tostring(result.result or result.subtype)
      elseif res.signal and res.signal ~= 0 then
        reason = ("процесс claude прерван сигналом %d"):format(res.signal)
      elseif res.code ~= 0 then
        reason = ("процесс claude завершился с кодом %d"):format(res.code)
      else
        reason = "процесс claude завершился до конца ответа"
      end
      local err = tail(table.concat(stderr), 400)
      if err ~= "" then
        reason = reason .. ": " .. err
      end
      entry.error = reason
      topic.failed = entry
    end
    changed(topic)
    next_in_queue(topic)
  end
  local ok, proc = pcall(vim.system, M.args(topic), {
    cwd = topic.record.project_dir,
    stdin = entry.prompt,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          parser:feed(data)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        stderr[#stderr + 1] = data
      end
    end,
  }, function(res)
    vim.schedule(function()
      on_exit(res)
    end)
  end)
  if not ok then
    entry.status = "error"
    entry.error = "не удалось запустить claude: " .. tostring(proc)
    topic.failed = entry
    changed(topic)
    next_in_queue(topic)
    return
  end
  topic.proc = proc
  changed(topic)
end

--- Отправляет вопрос в тему: сразу, если процесс темы не работает, иначе в очередь темы.
---@param topic claudr.Topic
---@param question string текст вопроса для показа
---@param prompt string|nil текст для процесса (по умолчанию — вопрос)
function M.submit(topic, question, prompt)
  local entry = { question = question, prompt = prompt or question, answer = "", status = "queued" }
  topic.entries[#topic.entries + 1] = entry
  topic.unavailable = false
  if topic.proc or #topic.queue > 0 then
    topic.queue[#topic.queue + 1] = entry
    changed(topic)
    return entry
  end
  start(topic, entry)
  return entry
end

--- Повторяет вопрос, на котором произошла ошибка, без повторного ввода.
---@param topic claudr.Topic
function M.retry(topic)
  local failed = topic.failed
  if not failed then
    return nil
  end
  topic.failed = nil
  return M.submit(topic, failed.question, failed.prompt)
end

--- Забывает темы в памяти (как после перезапуска Neovim); работающие процессы не трогает.
function M._reset()
  topics = {}
end

--- Работает ли процесс темы.
function M.busy(topic)
  return topic.proc ~= nil
end

return M
