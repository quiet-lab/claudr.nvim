-- Подписи пунктов запроса разрешения из данных элемента `permission_suggestions`
-- (спецификация agent-dialogs, решение D29): вид элемента, инструмент и содержимое правила,
-- каталоги, режим и место сохранения. Подпись русская и не повторяет текст экрана Claude Code.
local M = {}

local destinations = {
  session = "сессия",
  localSettings = "местные настройки проекта",
  projectSettings = "настройки проекта",
  userSettings = "пользовательские настройки",
}

local behaviors = {
  allow = "разрешать",
  deny = "запрещать",
  ask = "спрашивать",
}

--- Место сохранения словами; неизвестное значение остаётся как есть, пустое — «место не
--- указано».
function M.destination(dest)
  if type(dest) ~= "string" or dest == "" then
    return "место не указано"
  end
  return destinations[dest] or dest
end

local function rule_text(rule)
  if type(rule) ~= "table" or type(rule.toolName) ~= "string" then
    return nil
  end
  local content = rule.ruleContent
  if type(content) == "string" and content ~= "" then
    return string.format("%s(%s)", rule.toolName, content)
  end
  return rule.toolName .. " (любой вызов)"
end

local function names(list)
  local out = {}
  for _, v in ipairs(type(list) == "table" and list or {}) do
    if type(v) == "string" then
      out[#out + 1] = v
    end
  end
  return out
end

local function body(item)
  local kind = item.type
  if kind == "addRules" then
    local rules = {}
    for _, rule in ipairs(type(item.rules) == "table" and item.rules or {}) do
      rules[#rules + 1] = rule_text(rule)
    end
    local verb = type(item.behavior) == "string" and (behaviors[item.behavior] or item.behavior)
    local text = table.concat(rules, "; ")
    return vim.trim("Правило: " .. (verb and (verb .. " ") or "") .. text)
  elseif kind == "addDirectories" then
    local dirs = names(item.directories)
    return vim.trim(
      (#dirs == 1 and "Каталог: " or "Каталоги: ") .. table.concat(dirs, ", ")
    )
  elseif kind == "setMode" then
    return "Режим: " .. tostring(item.mode)
  end
  return type(kind) == "string" and kind or "неизвестный элемент"
end

--- Подпись пункта элемента: `<что делает> — <место сохранения>`. Элемент неизвестного вида
--- показывается видом и местом.
function M.suggestion(item)
  if type(item) ~= "table" then
    return "неизвестный элемент — " .. M.destination(nil)
  end
  return body(item) .. " — " .. M.destination(item.destination)
end

return M
