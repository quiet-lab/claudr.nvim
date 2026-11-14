-- Разбор записей Claude Code: строки транскрипта, реплики диалога, вызовы фоновых команд,
-- блоки <task-notification>, результаты TaskStop и Agent, meta.json субагентов.
-- Единственное место, знающее эти форматы (спецификация claude-code-data). Неизвестные виды
-- записей, поля и значения пропускаются без ошибки.
local M = {}

local function str(v)
  return type(v) == "string" and v or nil
end

local function tbl(v)
  return type(v) == "table" and v or nil
end

--- Запись из строки JSON или nil (повреждённая строка, не объект).
function M.decode(line)
  local ok, rec = pcall(vim.json.decode, line)
  if ok and type(rec) == "table" and not (rec[1] ~= nil and vim.islist(rec)) then
    return rec
  end
  return nil
end

--- Текст содержимого сообщения: строка как есть, у списка блоков — текстовые блоки через
--- перевод строки. nil — текста нет.
local function content_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n")
end

local function is_notification_record(rec)
  local origin = tbl(rec.origin)
  return origin ~= nil and origin.kind == "task-notification"
end

--- Реплика диалога `{role, text}` из записи или nil для служебных записей: записи без текста
--- (только вызовы и результаты инструментов, размышления), служебные вставки (`isMeta`),
--- доставленные уведомления о фоновых задачах.
function M.reply(rec)
  local message = tbl(rec.message)
  if not message then
    return nil
  end
  if rec.type == "user" then
    if rec.isMeta == true or is_notification_record(rec) then
      return nil
    end
    local text = content_text(message.content)
    if not text or text:find("^%s*<task%-notification>") then
      return nil
    end
    return { role = "user", text = text }
  elseif rec.type == "assistant" then
    local text = content_text(message.content)
    if not text then
      return nil
    end
    return { role = "assistant", text = text }
  end
  return nil
end

--- Реплики из списка строк транскрипта.
function M.replies(lines)
  local out = {}
  for _, line in ipairs(lines) do
    local rec = M.decode(line)
    local r = rec and M.reply(rec)
    if r then
      out[#out + 1] = r
    end
  end
  return out
end

local STATUSES = { completed = true, failed = true, killed = true }

local function tag(block, name)
  local v = block:match("<" .. name .. ">(.-)</" .. name .. ">")
  return v and vim.trim(v) or nil
end

--- Блоки <task-notification> из текста: список `{task_id, tool_use_id, output_file, status,
--- exit_code, summary, event}`. Блок без `task-id` пропускается.
function M.notifications(text)
  local out = {}
  if type(text) ~= "string" or not text:find("<task-notification>", 1, true) then
    return out
  end
  for block in text:gmatch("<task%-notification>(.-)</task%-notification>") do
    local n = {
      task_id = tag(block, "task%-id"),
      tool_use_id = tag(block, "tool%-use%-id"),
      output_file = tag(block, "output%-file"),
      status = tag(block, "status"),
      summary = tag(block, "summary"),
      event = tag(block, "event"),
    }
    if n.summary then
      local code = n.summary:match("exit code (%-?%d+)")
      n.exit_code = code and tonumber(code) or nil
    end
    if n.task_id and n.task_id ~= "" then
      out[#out + 1] = n
    end
  end
  return out
end

-- Тексты записи, где может лежать блок уведомления: queue-operation (`content`), user
-- (содержимое сообщения), attachment queued_command (`prompt`).
local function notification_texts(rec)
  if rec.type == "queue-operation" then
    return { str(rec.content) }
  elseif rec.type == "user" then
    local message = tbl(rec.message)
    return { message and content_text(message.content) }
  elseif rec.type == "attachment" then
    local att = tbl(rec.attachment)
    if att and att.type == "queued_command" then
      return { content_text(att.prompt) }
    end
  end
  return {}
end

--- Учёт сессии: вызовы инструментов, фоновые команды, итоговые уведомления, остановки.
--- Всё хранится по идентификаторам, поэтому одно событие, записанное несколько раз или
--- в разных транскриптах, учитывается один раз.
function M.ledger()
  return {
    uses = {}, -- id вызова инструмента → {name, input, owner}
    commands = {}, -- id задачи → {id, owner, command, description, output_file, tool_use_id, monitor}
    finals = {}, -- id задачи → итоговое уведомление (со status)
    stops = {}, -- id задачи → true (результат TaskStop)
    agent_results = {}, -- id агента → status результата вызова Agent
  }
end

local function result_text(block)
  return content_text(block.content)
end

-- Сведения результата инструмента: `toolUseResult` записи (у транскриптов субагентов его нет)
-- либо текст результата, если это объект JSON.
local function result_info(rec, block)
  local tur = tbl(rec.toolUseResult)
  if tur then
    return tur
  end
  local text = result_text(block)
  if text and text:find("^%s*{") then
    return M.decode(text) or {}
  end
  return {}
end

local function on_tool_result(ledger, rec, block, owner)
  local use = ledger.uses[block.tool_use_id]
  if not use then
    return
  end
  local text = result_text(block) or ""
  local input = use.input
  if use.name == "Bash" and input.run_in_background == true then
    local info = result_info(rec, block)
    local id = str(info.backgroundTaskId) or text:match("background with ID: ([%w_%-]+)")
    if id then
      ledger.commands[id] = {
        id = id,
        owner = owner,
        command = str(input.command),
        description = str(input.description),
        output_file = text:match("written to: (.-%.output)"),
        tool_use_id = block.tool_use_id,
        monitor = false,
      }
    end
  elseif use.name == "Monitor" then
    local info = result_info(rec, block)
    local id = str(info.taskId) or text:match("Monitor started %(task ([%w_%-]+)")
    if id then
      ledger.commands[id] = {
        id = id,
        owner = owner,
        command = str(input.command),
        description = str(input.description),
        output_file = text:match("written to: (.-%.output)"),
        tool_use_id = block.tool_use_id,
        monitor = true,
      }
    end
  elseif use.name == "TaskStop" then
    if block.is_error == true then
      return
    end
    local info = result_info(rec, block)
    local id = str(info.task_id)
    if id then
      ledger.stops[id] = true
    end
  elseif use.name == "Agent" or use.name == "Task" then
    local info = result_info(rec, block)
    local id = str(info.agentId)
    if id and str(info.status) == "completed" then
      ledger.agent_results[id] = "completed"
    end
  end
end

local function feed(ledger, rec, owner)
  for _, text in ipairs(notification_texts(rec)) do
    for _, n in ipairs(M.notifications(text)) do
      -- промежуточные уведомления (Monitor) без status задачу не завершают
      if n.status and STATUSES[n.status] then
        ledger.finals[n.task_id] = n
      end
    end
  end
  local message = tbl(rec.message)
  local content = message and tbl(message.content)
  if not content then
    return
  end
  if rec.type == "assistant" then
    for _, block in ipairs(content) do
      if type(block) == "table" and block.type == "tool_use" and str(block.id) then
        ledger.uses[block.id] = {
          name = str(block.name),
          input = tbl(block.input) or {},
          owner = owner,
        }
      end
    end
  elseif rec.type == "user" then
    for _, block in ipairs(content) do
      if type(block) == "table" and block.type == "tool_result" and str(block.tool_use_id) then
        on_tool_result(ledger, rec, block, owner)
      end
    end
  end
end

--- Учитывает запись транскрипта владельца `owner` (nil — сессия, иначе id субагента).
--- Запись с непонятными значениями пропускается.
function M.feed(ledger, rec, owner)
  pcall(feed, ledger, rec, owner)
end

--- Субагент из разобранного meta.json: поля `agent_type`, `description`, `tool_use_id`,
--- `spawn_depth`, `parent_id`, `model`, `finished`.
function M.subagent(id, meta)
  return {
    id = id,
    agent_type = str(meta.agentType),
    description = str(meta.description),
    tool_use_id = str(meta.toolUseId),
    spawn_depth = type(meta.spawnDepth) == "number" and meta.spawnDepth or nil,
    parent_id = str(meta.parentAgentId),
    model = str(meta.model),
    finished = meta.finished == true,
  }
end

--- Имя файла в subagents/: вид ("meta" | "transcript") и id субагента или nil (посторонний).
function M.subagent_file(name)
  local id = name:match("^agent%-([%w_%-]+)%.meta%.json$")
  if id then
    return "meta", id
  end
  id = name:match("^agent%-([%w_%-]+)%.jsonl$")
  if id then
    return "transcript", id
  end
  return nil
end

--- Состояние сессии из учёта и meta.json субагентов (`metas`: id → meta, `paired`: id → true
--- для субагентов, у которых есть и транскрипт). `owner_alive == false` — панель владельца
--- завершила процесс или закрыта.
function M.build(ledger, metas, paired, owner_alive)
  local subagents, tasks = {}, {}
  for id, meta in pairs(metas) do
    if paired[id] then
      local s = M.subagent(id, meta)
      local final = ledger.finals[id]
      if final and (final.status == "completed" or final.status == "killed") then
        s.stop = final.status
      elseif final and final.status == "failed" then
        s.stop = "failed"
      else
        s.stop = ledger.agent_results[id]
      end
      if s.finished or s.stop then
        s.status = "finished"
      elseif owner_alive == false then
        s.status = "orphaned"
      else
        s.status = "running"
      end
      subagents[id] = s
    end
  end
  for id, c in pairs(ledger.commands) do
    local final = ledger.finals[id]
    local task = {
      id = id,
      owner = c.owner,
      command = c.command,
      description = c.description,
      output_file = c.output_file or (final and final.output_file) or nil,
      tool_use_id = c.tool_use_id,
      monitor = c.monitor,
    }
    if final then
      task.result = final.status
      task.exit_code = final.exit_code
    elseif ledger.stops[id] then
      task.result = "killed"
    end
    if task.result then
      task.status = "finished"
    elseif owner_alive == false then
      task.status = "orphaned"
    else
      task.status = "running"
    end
    tasks[id] = task
  end
  return { subagents = subagents, tasks = tasks }
end

return M
