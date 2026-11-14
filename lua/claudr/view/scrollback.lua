-- Прокрутка истории панели (спецификация node-view): чтение `pane.read` только по запросу
-- пользователя, в пределах, которые даёт сервер (не больше 1000 строк). Вид только для
-- чтения. Полноэкранная программа отдаёт вместо истории текущий экран: признак — последние
-- строки (`recent_unwrapped`) совпадают с экраном (`visible`); тогда вид показывает экран
-- и сообщает, что истории нет. По событиям панели чтение не выполняется.
local herdr = require("claudr.herdr")
local window = require("claudr.view.window")

local M = {}

M.LINES = 1000
M.NO_HISTORY =
  "истории нет: сервер отдаёт только текущий экран программы"

-- Строки текста без пробелов в конце строк и без пустых строк в конце.
local function normalize(text)
  local clean = (text or ""):gsub("\r", "")
  local lines = vim.split(clean, "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("%s+$", "")
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

local function render(v, recent, visible)
  local lines = normalize(recent.text)
  local screen = normalize(visible.text)
  v.no_history = not recent.truncated and vim.deep_equal(lines, screen)
  if v.no_history then
    vim.notify("claudr: " .. M.NO_HISTORY, vim.log.levels.INFO)
    table.insert(lines, 1, "[" .. M.NO_HISTORY .. "]")
  end
  if #lines == 0 then
    lines = { "" }
  end
  window.set_lines(v.buf, lines)
  if v.win and vim.api.nvim_win_is_valid(v.win) then
    vim.api.nvim_win_set_cursor(v.win, { #lines, 0 })
  end
end

--- Открывает историю панели `node`. Возвращает вид; строки приходят по ответу сервера.
function M.open(node)
  local pane_id = node.id
  local buf = window.scratch()
  vim.bo[buf].modifiable = false
  local win = window.open_float(buf, {
    title = "история: " .. require("claudr.tree.view").one_line(node.label or pane_id),
  })
  local v = { kind = "scrollback", node_id = pane_id, buf = buf, win = win }
  vim.b[buf].claudr_node_id = pane_id
  function v.dispose() end
  window.register(v)

  local got = {}
  local failed = false
  local function done(key, err, read)
    if v.released or failed then
      return
    end
    if err or not read then
      failed = true
      local msg = err and (err.message or err.code) or "пустой ответ"
      window.set_lines(buf, { "[история недоступна: " .. tostring(msg) .. "]" })
      return
    end
    got[key] = read
    if got.recent and got.visible then
      render(v, got.recent, got.visible)
    end
  end
  herdr.read_pane(pane_id, { source = "recent_unwrapped", lines = M.LINES }, function(err, read)
    done("recent", err, read)
  end)
  herdr.read_pane(pane_id, { source = "visible" }, function(err, read)
    done("visible", err, read)
  end)
  return v
end

return M
