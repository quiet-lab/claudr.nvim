-- Вид запроса разрешения: инструмент и содержимое, пункты по порядку — «разрешить один
-- раз», по пункту на каждый элемент `permission_suggestions`, отказы (D29).
local common = require("claudr.dialogs.views.common")
local decision = require("claudr.dialogs.decision")
local labels = require("claudr.dialogs.labels")

local M = {}

M.TITLE = "Запрос разрешения"

local function content_lines(r)
  local c = r.content or { raw = r.tool_input }
  local out = {}
  if c.command then
    out[#out + 1] = "Команда:"
    vim.list_extend(out, common.indented(c.command, "  "))
    if c.description then
      out[#out + 1] = "Описание: " .. c.description
    end
  elseif c.file_path then
    out[#out + 1] = "Файл: " .. c.file_path
    if c.text then
      out[#out + 1] = "Текст:"
      vim.list_extend(out, common.indented(c.text, "  "))
    end
  else
    out[#out + 1] = "Вход инструмента:"
    vim.list_extend(out, common.indented(vim.inspect(c.raw or r.tool_input), "  "))
  end
  return out
end

---@param ctx table
function M.screen(ctx)
  local r = ctx.req.request
  local header = { "Инструмент: " .. tostring(r.tool_name) }
  vim.list_extend(header, content_lines(r))
  local items = {
    {
      text = "разрешить один раз",
      run = function()
        ctx.decide(decision.allow_once())
      end,
    },
  }
  for _, item in ipairs(r.suggestions or {}) do
    items[#items + 1] = {
      text = labels.suggestion(item),
      run = function()
        ctx.decide(decision.allow_suggestion(item))
      end,
    }
  end
  vim.list_extend(items, common.deny_items(ctx))
  return {
    header = header,
    items = items,
    footer = {
      "Пункт «перейти в режим auto» хук не отдаёт: он остаётся терминалу (T — передать диалог терминалу).",
    },
  }
end

return M
