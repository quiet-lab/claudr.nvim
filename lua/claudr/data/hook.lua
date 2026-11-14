-- Разбор входа хука `PermissionRequest` и записей транскрипта диалогов (спецификации
-- claude-code-data и agent-dialogs): вход хука превращается в запись «запрос», записи
-- `assistant`, `user` и `attachment` — в вызовы инструментов, результаты и решения хука.
-- Единственное место, знающее эти форматы. Неизвестные поля, инструменты, блоки и вложения
-- пропускаются без ошибки; чистые функции, ничего не читают и не пишут.
local M = {}

local function str(v)
  return type(v) == "string" and v or nil
end

local function tbl(v)
  return type(v) == "table" and v or nil
end

local function is_list(v)
  return type(v) == "table" and (next(v) == nil or vim.islist(v))
end

-- Вопросы `AskUserQuestion`: пункты без метки и вопросы без текста пропускаются.
local function parse_questions(tool_input)
  local out = {}
  local raw = tool_input.questions
  if not is_list(raw) then
    return out
  end
  for _, item in ipairs(raw) do
    local text = tbl(item) and str(item.question)
    if text then
      local options = {}
      for _, o in ipairs(is_list(item.options) and item.options or {}) do
        local label = tbl(o) and str(o.label)
        if label then
          options[#options + 1] = { label = label, description = str(o.description) }
        end
      end
      out[#out + 1] = {
        question = text,
        header = str(item.header),
        multi = item.multiSelect == true,
        options = options,
      }
    end
  end
  return out
end

-- Содержимое запроса разрешения: команда, файл и текст (содержимое Write, новый текст Edit).
local function parse_content(tool_input)
  return {
    command = str(tool_input.command),
    description = str(tool_input.description),
    file_path = str(tool_input.file_path),
    text = str(tool_input.content) or str(tool_input.new_string),
    raw = tool_input,
  }
end

-- Элементы `permission_suggestions` как пришли; поле может отсутствовать, быть `null` или
-- пустым массивом — тогда список пуст.
local function parse_suggestions(v)
  local out = {}
  if is_list(v) then
    for _, item in ipairs(v) do
      out[#out + 1] = item
    end
  end
  return out
end

--- Запрос из входа хука (таблица, разобранная из JSON) или `nil, причина`.
---
--- `{ kind = "permission"|"question"|"plan", tool_name, tool_input, session_id,
---    transcript_path, cwd, permission_mode, agent_id?, agent_type?,
---    suggestions = { <элементы как пришли> },
---    questions = { { question, header?, multi, options = { { label, description? } } } }
---      (вид question), plan?, plan_file? (вид plan),
---    content = { command?, description?, file_path?, text?, raw } (вид permission) }`
function M.parse_input(input)
  if type(input) ~= "table" or is_list(input) and next(input) ~= nil then
    return nil, "вход хука не объект"
  end
  local tool_name = str(input.tool_name)
  if not tool_name or tool_name == "" then
    return nil, "во входе хука нет tool_name"
  end
  local tool_input = input.tool_input
  if tool_input == nil or tool_input == vim.NIL then
    tool_input = {}
  elseif type(tool_input) ~= "table" then
    return nil, "tool_input не объект"
  end
  local req = {
    tool_name = tool_name,
    tool_input = tool_input,
    session_id = str(input.session_id),
    transcript_path = str(input.transcript_path),
    cwd = str(input.cwd),
    permission_mode = str(input.permission_mode),
    agent_id = str(input.agent_id),
    agent_type = str(input.agent_type),
    suggestions = parse_suggestions(input.permission_suggestions),
  }
  if tool_name == "AskUserQuestion" then
    req.kind = "question"
    req.questions = parse_questions(tool_input)
    if #req.questions == 0 then
      return nil, "в AskUserQuestion нет вопросов"
    end
  elseif tool_name == "ExitPlanMode" then
    req.kind = "plan"
    req.plan = str(tool_input.plan)
    req.plan_file = str(tool_input.planFilePath)
  else
    req.kind = "permission"
    req.content = parse_content(tool_input)
  end
  return req
end

--- Вызовы инструментов записи `assistant`: `{ { id, name, input }, … }` в порядке блоков;
--- блоки без идентификатора или имени и записи других видов пропускаются.
function M.tool_uses(rec)
  local out = {}
  local message = type(rec) == "table" and rec.type == "assistant" and tbl(rec.message)
  local content = message and message.content
  if not is_list(content) then
    return out
  end
  for _, block in ipairs(content) do
    if tbl(block) and block.type == "tool_use" then
      local id, name = str(block.id), str(block.name)
      if id and name then
        out[#out + 1] = { id = id, name = name, input = tbl(block.input) or {} }
      end
    end
  end
  return out
end

--- Результаты вызовов записи `user`: `{ { tool_use_id, is_error }, … }`; `is_error` — булево.
function M.tool_results(rec)
  local out = {}
  local message = type(rec) == "table" and rec.type == "user" and tbl(rec.message)
  local content = message and message.content
  if not is_list(content) then
    return out
  end
  for _, block in ipairs(content) do
    if tbl(block) and block.type == "tool_result" then
      local id = str(block.tool_use_id)
      if id then
        out[#out + 1] = { tool_use_id = id, is_error = block.is_error == true }
      end
    end
  end
  return out
end

--- Решение хука из вложения транскрипта: `{ decision, tool_use_id }` (`decision` — `allow` или
--- `deny`) или `nil` для любой другой записи.
function M.decision_attachment(rec)
  local att = type(rec) == "table" and rec.type == "attachment" and tbl(rec.attachment)
  if not att or att.type ~= "hook_permission_decision" then
    return nil
  end
  local decision, id = str(att.decision), str(att.toolUseID)
  if not decision or not id then
    return nil
  end
  return { decision = decision, tool_use_id = id }
end

--- События диалогов из строк транскрипта по порядку записей и блоков:
--- `{ type = "call", id, name, input }` (вызов инструмента), `{ type = "result", id, is_error }`
--- (результат вызова), `{ type = "decision", id, decision }` (вложение решения хука); `id` —
--- идентификатор вызова. Повреждённые строки и записи других видов пропускаются.
function M.events(lines)
  local decode = require("claudr.data.parse").decode
  local out = {}
  for _, line in ipairs(lines or {}) do
    local rec = decode(line)
    if rec then
      for _, u in ipairs(M.tool_uses(rec)) do
        out[#out + 1] = { type = "call", id = u.id, name = u.name, input = u.input }
      end
      for _, r in ipairs(M.tool_results(rec)) do
        out[#out + 1] = { type = "result", id = r.tool_use_id, is_error = r.is_error }
      end
      local d = M.decision_attachment(rec)
      if d then
        out[#out + 1] = { type = "decision", id = d.tool_use_id, decision = d.decision }
      end
    end
  end
  return out
end

--- Глубокое равенство значений JSON: порядок ключей не важен, `vim.NIL` равен `vim.NIL`.
function M.equal_input(a, b)
  return vim.deep_equal(a, b)
end

--- Равенство входа запроса и входа вызова в транскрипте для одного инструмента. У `ExitPlanMode`
--- Claude Code подставляет во вход хука текст плана из файла, а запись `tool_use` хранит то, что
--- прислала модель, поэтому поле `plan` не сравнивается (остальные, в том числе `planFilePath`,
--- — по значению); у прочих инструментов — `equal_input`.
function M.same_call(tool_name, a, b)
  if tool_name == "ExitPlanMode" and type(a) == "table" and type(b) == "table" then
    local x, y = vim.deepcopy(a), vim.deepcopy(b)
    x.plan, y.plan = nil, nil
    return vim.deep_equal(x, y)
  end
  return M.equal_input(a, b)
end

return M
