-- Вид плана (`ExitPlanMode`): текст плана и действия. Режим после подтверждения плагин не
-- выбирает: его определяет Claude Code.
local common = require("claudr.dialogs.views.common")
local decision = require("claudr.dialogs.decision")

local M = {}

M.TITLE = "План агента"

---@param ctx table
function M.screen(ctx)
  local r = ctx.req.request
  local header = {}
  if r.plan_file then
    header[#header + 1] = "Файл плана: " .. r.plan_file
  end
  vim.list_extend(header, common.split(r.plan or "(текста плана нет)"))
  local items = {
    {
      text = "подтвердить",
      run = function()
        ctx.decide(decision.approve_plan(ctx.req.tool_input))
      end,
    },
    common.deny_comment_item(ctx),
    {
      text = "отказать",
      run = function()
        ctx.decide(decision.deny())
      end,
    },
    common.interrupt_item(ctx),
  }
  return {
    header = header,
    items = items,
    footer = {
      "Режим после подтверждения определяет Claude Code.",
    },
  }
end

return M
