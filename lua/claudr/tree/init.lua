-- Дерево workspace, вкладок, панелей, субагентов и фоновых команд (спецификация agent-tree).
-- Модель — claudr.tree.model, отображение — claudr.tree.view.
local commands = require("claudr.commands")

local M = {}

--- Регистрирует подкоманды дерева.
function M.setup()
  commands.register("tree", function()
    require("claudr.tree.view").open()
  end, { desc = "открыть дерево агентов" })
  commands.register("toggle-finished", function()
    local shown = require("claudr.tree.model").toggle_finished()
    vim.notify(
      shown and "claudr: завершённые узлы показаны"
        or "claudr: завершённые узлы скрыты",
      vim.log.levels.INFO
    )
  end, {
    desc = "показать или скрыть завершённые субагенты и фоновые команды",
  })
end

return M
