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
    -- base_session не задана: ответвляться не от чего, пока её не задали.
    -- mcp не задан по умолчанию: без MCP-сервера проекта плагин работает. Значение —
    -- описание `{ mcpServers = {…} }`, таблица «каталог проекта → описание» или
    -- функция `fn(project_dir) -> описание|nil`.
  },
}

---@class claudr.CodeQuestionsConfig
---@field model string модель отвечающего процесса
---@field fork_from_base boolean ответвлять новую тему от базовой сессии проекта
---@field base_session string|table|function|nil базовая сессия для fork_from_base
---@field mcp table|function|nil MCP-сервер проекта как источник знаний (необязательно)

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
