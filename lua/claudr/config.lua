-- Настройки плагина: значения по умолчанию и доступ к ним.
local M = {}

---@class claudr.Config
---@field show_finished boolean показывать завершённые субагенты и фоновые команды в дереве
---@field message_input claudr.MessageInputConfig
---@field code_questions claudr.CodeQuestionsConfig
local defaults = {
  show_finished = true,
  message_input = {
    -- клавиши отправки в окне ввода (нормальный режим и режим вставки); `:w` работает всегда
    send = { "<S-CR>", "<S-Space>" },
    -- ведущий пробел перед текстом, начинающимся с «/» или «!» (решение D31)
    guard_commands = false,
    -- клавиша окна ввода в виде панели; `false` — не назначать
    key = "m",
  },
  code_questions = {
    model = "sonnet",
    fork_from_base = false,
    -- mcp не задан по умолчанию: без MCP-сервера проекта плагин работает. Значение —
    -- описание `{ mcpServers = {…} }`, таблица «каталог проекта → описание» или
    -- функция `fn(project_dir) -> описание|nil`.
  },
}

---@class claudr.MessageInputConfig
---@field send string[] клавиши отправки в окне ввода
---@field guard_commands boolean добавлять ведущий пробел к тексту, начинающемуся с «/» или «!»
---@field key string|false клавиша окна ввода в виде панели

---@class claudr.CodeQuestionsConfig
---@field model string модель отвечающего процесса
---@field fork_from_base boolean ответвлять новую тему от базовой сессии (в этой версии не поддерживается)
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
