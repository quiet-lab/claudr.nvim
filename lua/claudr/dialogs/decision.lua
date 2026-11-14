-- Решения хука `PermissionRequest` (спецификация agent-dialogs, решение D28): таблица видов
-- запроса и действий в одном модуле. Каждая функция возвращает вывод хука целиком; форму
-- вывода при расхождении с версией Claude Code правят только здесь.
--
-- | запрос и действие                 | решение хука                                  |
-- | разрешение, «разрешить один раз»  | allow                                          |
-- | разрешение, пункт элемента        | allow + updatedPermissions: элемент как есть   |
-- | вопрос, ответ                     | allow + updatedInput: questions и answers      |
-- | план, «подтвердить»               | allow + updatedInput: исходный tool_input      |
-- | вопрос, множественный выбор      | метка с запятой — в двойных кавычках           |
-- | любой вид, «отказать»             | deny                                           |
-- | любой вид, «отказать с пояснением»| deny + message                                 |
-- | любой вид, «отказать и прервать»  | deny + interrupt = true                        |
local M = {}

local function output(decision)
  return {
    hookSpecificOutput = {
      hookEventName = "PermissionRequest",
      decision = decision,
    },
  }
end

--- «Разрешить один раз».
function M.allow_once()
  return output({ behavior = "allow" })
end

--- Пункт элемента `permission_suggestions`: сам элемент без изменений.
function M.allow_suggestion(item)
  return output({ behavior = "allow", updatedPermissions = { item } })
end

--- Ответ на вопрос: `questions` как пришли, `answers` — объект «текст вопроса → значение».
--- Без ответов решение не собирается: `nil, причина` (голое `allow` у вопроса ничего не делает).
function M.answer(questions, answers)
  if type(answers) ~= "table" or next(answers) == nil then
    return nil, "нет ответов"
  end
  return output({
    behavior = "allow",
    updatedInput = { questions = questions, answers = answers },
  })
end

--- Подтверждение плана: исходный `tool_input` запроса.
function M.approve_plan(tool_input)
  return output({ behavior = "allow", updatedInput = tool_input })
end

--- «Отказать».
function M.deny()
  return output({ behavior = "deny" })
end

--- «Отказать с пояснением»: `message` — текст из окна ввода как есть.
function M.deny_message(text)
  return output({ behavior = "deny", message = text })
end

--- «Отказать и прервать»: ход останавливается как при Escape, пояснения нет.
function M.deny_interrupt()
  return output({ behavior = "deny", interrupt = true })
end

--- Значение ответа множественного выбора: метки отмеченных пунктов (в порядке пунктов,
--- порядок задаёт вызывающий) через запятую с пробелом; метка с запятой берётся в двойные
--- кавычки, как отвечает панель Claude Code (`"Cheese, aged", Olives`).
function M.multi_value(labels)
  local out = {}
  for i, label in ipairs(labels) do
    out[i] = label:find(",", 1, true) and ('"' .. label .. '"') or label
  end
  return table.concat(out, ", ")
end

return M
