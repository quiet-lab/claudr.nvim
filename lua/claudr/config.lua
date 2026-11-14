-- Настройки плагина: значения по умолчанию и доступ к ним.
local M = {}

---@class claudr.Config
---@field show_finished boolean показывать завершённые субагенты и фоновые команды в дереве
---@field code_questions claudr.CodeQuestionsConfig
local defaults = {
  show_finished = true,
  code_questions = {
    model = "sonnet",
    fork_from_base = false,
    -- mcp не задан по умолчанию: без MCP-сервера проекта плагин работает.
  },
}

---@class claudr.CodeQuestionsConfig
---@field model string модель отвечающего процесса
---@field fork_from_base boolean ответвлять новую тему от базовой сессии проекта
---@field mcp table|nil описание MCP-сервера проекта (необязательно)

local current = vim.deepcopy(defaults)

--- Применяет пользовательские настройки поверх значений по умолчанию.
---@param opts table|nil
function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return current
end

--- Текущие настройки (до `setup` — значения по умолчанию).
---@return claudr.Config
function M.get()
  return current
end

--- Значения по умолчанию (копия).
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
