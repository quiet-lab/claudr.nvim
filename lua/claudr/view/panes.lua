-- Вид workspace и вкладки — перечень их панелей (спецификация node-view, решение D4):
-- подпись и состояние каждой панели, обновление по уведомлениям модели дерева. Выбор строки
-- (`<CR>`) открывает вид панели; первая панель сама не выбирается.
local model = require("claudr.tree.model")
local tree_view = require("claudr.tree.view")
local window = require("claudr.view.window")

local M = {}

--- Панели узла: у вкладки — её панели, у workspace — панели его вкладок и панели без вкладки
--- (без вложенных workspace).
function M.panes_of(node)
  local out = {}
  for _, child in ipairs(model.children(node.id)) do
    if child.kind == "pane" then
      out[#out + 1] = child
    elseif child.kind == "tab" and node.kind == "workspace" then
      for _, p in ipairs(model.children(child.id)) do
        if p.kind == "pane" then
          out[#out + 1] = p
        end
      end
    end
  end
  return out
end

--- Строка перечня для панели.
function M.line(pane)
  local icon = tree_view.ICONS[pane.pane_kind] or "?"
  local text = icon .. " " .. (pane.label ~= "" and pane.label or pane.id)
  local state = tree_view.state_text(pane)
  if state then
    text = text .. " [" .. state .. "]"
  end
  return text
end

local function render(v)
  if v.released then
    return
  end
  local node = model.get(v.node_id)
  v.line_ids = {}
  if not node then
    window.set_lines(v.buf, { "[узел закрыт]" })
    return
  end
  local lines = {}
  for _, p in ipairs(M.panes_of(node)) do
    lines[#lines + 1] = M.line(p)
    v.line_ids[#lines] = p.id
  end
  if #lines == 0 then
    lines = { "[панелей нет]" }
  end
  window.set_lines(v.buf, lines)
end

--- Открывает перечень панелей workspace или вкладки. `open_pane(node)` — открытие вида
--- выбранной панели.
function M.open(node, open_pane)
  local buf = window.scratch()
  vim.bo[buf].modifiable = false
  local win = window.open_float(buf, { title = "панели: " .. (node.label or node.id) })
  local v = { kind = "panes", node_id = node.id, buf = buf, win = win, line_ids = {} }
  vim.b[buf].claudr_node_id = node.id
  function v.dispose()
    if v.unsubscribe then
      v.unsubscribe()
      v.unsubscribe = nil
    end
  end
  window.register(v)
  vim.keymap.set("n", "<CR>", function()
    M.select(v)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "claudr: открыть вид панели",
  })
  v.unsubscribe = model.subscribe(function()
    render(v)
  end)
  v.open_pane = open_pane
  render(v)
  return v
end

--- Открывает вид панели на строке `row` перечня `v` (по умолчанию — строка под курсором).
function M.select(v, row)
  if not row then
    if not (v.win and vim.api.nvim_win_is_valid(v.win)) then
      return
    end
    row = vim.api.nvim_win_get_cursor(v.win)[1]
  end
  local id = v.line_ids[row]
  local pane = id and model.get(id)
  if pane then
    return v.open_pane(pane)
  end
end

return M
