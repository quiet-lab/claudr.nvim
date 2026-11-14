-- Режимы вопросов по коду: именованный набор из наставления агенту (дополнение к системному
-- запросу), модели и набора инструментов. Встроенный режим один — «вопрос по коду» (`code`);
-- остальные регистрирует пользователь или другой плагин.
local M = {}

--- Инструменты чтения: набор по умолчанию, если режим не задаёт иного.
M.READ_TOOLS = { "Read", "Grep", "Glob" }

M.DEFAULT = "code"

---@class claudr.QuestionMode
---@field name string
---@field desc string|nil описание для перечней
---@field prompt string|nil наставление агенту — дополнение к системному запросу
---@field model string|nil модель; без неё — настройка `code_questions.model`
---@field tools string[]|nil встроенные инструменты; без них — инструменты чтения

---@type table<string, claudr.QuestionMode>
local modes = {}

--- Регистрирует режим; повторная регистрация имени заменяет прежний.
---@param name string
---@param spec { desc: string|nil, prompt: string|nil, model: string|nil, tools: string[]|nil }
function M.register(name, spec)
  assert(type(name) == "string" and name ~= "", "режим: нужно имя")
  spec = spec or {}
  modes[name] = {
    name = name,
    desc = spec.desc,
    prompt = spec.prompt,
    model = spec.model,
    tools = spec.tools and vim.deepcopy(spec.tools) or nil,
  }
end

--- Режим по имени или `nil`.
function M.get(name)
  return modes[name]
end

--- Имена режимов по алфавиту.
function M.names()
  local names = vim.tbl_keys(modes)
  table.sort(names)
  return names
end

M.register(M.DEFAULT, {
  desc = "вопрос по коду",
  prompt = table.concat({
    "You answer questions about the code of the project in the current working directory.",
    "Read the code you need with the read-only tools; do not propose to change files.",
    "Refer to code locations as path:line with the path relative to the project root.",
    "Answer in the language of the question.",
  }, " "),
})

return M
