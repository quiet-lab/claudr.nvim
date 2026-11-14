-- Общие части видов буфера диалога: разбиение текста на строки, пункты отказов и запрос
-- пояснения через окно ввода. Решения собирает только `claudr.dialogs.decision`.
local decision = require("claudr.dialogs.decision")

local M = {}

--- Строки текста (переводы строк внутри значения не допускаются в строке буфера).
---@param text string|nil
---@return string[]
function M.split(text)
  return vim.split((text or ""):gsub("\r", ""), "\n", { plain = true })
end

--- Строки текста с отступом `indent`.
---@param text string|nil
---@param indent string
---@return string[]
function M.indented(text, indent)
  local out = {}
  for _, line in ipairs(M.split(text)) do
    out[#out + 1] = indent .. line
  end
  return out
end

--- «Отказать с пояснением»: окно ввода, текст уходит в `message` отказа.
---@param ctx table
---@return table
function M.deny_comment_item(ctx)
  return {
    text = "отказать с пояснением",
    run = function()
      ctx.ask("Пояснение к отказу", "deny", function(text)
        return ctx.decide(decision.deny_message(text))
      end)
    end,
  }
end

--- Пункты «отказать», «отказать с пояснением», «отказать и прервать» (по порядку).
---@param ctx table
---@return table[]
function M.deny_items(ctx)
  return {
    {
      text = "отказать",
      run = function()
        ctx.decide(decision.deny())
      end,
    },
    M.deny_comment_item(ctx),
    M.interrupt_item(ctx),
  }
end

function M.interrupt_item(ctx)
  return {
    text = "отказать и прервать",
    run = function()
      ctx.decide(decision.deny_interrupt())
    end,
  }
end

return M
