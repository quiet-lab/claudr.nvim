-- Точка входа плагина: `require("claudr").setup(opts)`.
local M = {}

-- Постоянный список модулей возможностей; каждый регистрирует свои подкоманды в `setup()`.
local feature_modules = {
  "claudr.tree",
  "claudr.view",
  "claudr.messaging",
  "claudr.launch",
  "claudr.history",
  "claudr.questions",
}

--- Применяет настройки и подключает модули возможностей. Ничего не запускает:
--- подключение к herdr и слежение начинаются по подкомандам.
---@param opts table|nil
function M.setup(opts)
  require("claudr.config").setup(opts)
  require("claudr.commands").define()
  for _, name in ipairs(feature_modules) do
    require(name).setup()
  end
end

return M
