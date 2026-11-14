-- Сообщение об ожидании ответа (спецификация agent-dialogs, D33): когда у панели с открытым
-- видом агент переходит в `blocked`, плагин только сообщает — о ждущем запросе и команде
-- открытия буфера диалога либо, без запроса (сессия без хука, диалог вне хука), о том, что
-- агент ждёт ответа, и о подключении с вводом. Окно и фокус не меняются, экран панели не
-- читается. Источник — уведомления модели дерева (события herdr) и перечня запросов.
local model = require("claudr.tree.model")
local window = require("claudr.view.window")

local M = {}

local prev = {} -- панель → прежнее состояние
local noticed = {} -- панель в `blocked` → "request" | "none": что уже сообщено
local unsub_model, unsub_pending

local function pending()
  local ok, p = pcall(require, "claudr.dialogs.pending")
  return ok and p or nil
end

-- Есть ли открытый вид панели (кроме самого буфера диалога).
local function view_open(pane_id)
  for _, v in ipairs(window.list()) do
    if
      v.node_id == pane_id
      and v.kind ~= "dialog"
      and v.win
      and vim.api.nvim_win_is_valid(v.win)
    then
      return true
    end
  end
  return false
end

local function pane_count(node)
  local p = pending()
  if not p then
    return 0
  end
  local ok, n = pcall(p.count, node)
  return ok and n or 0
end

local function say_request(node, n)
  vim.notify(
    (
      "claudr: агент %s ждёт ответа: ждущих запросов диалога — %d; откройте его командой "
      .. ":Claudr dialog %s (в виде панели — клавиша диалога)"
    ):format(node.label or node.id, n, node.id),
    vim.log.levels.WARN
  )
end

local function say_none(node)
  vim.notify(
    (
      "claudr: агент %s ждёт ответа на диалог (запроса хука нет); подключитесь с вводом "
      .. "командой :Claudr attach %s"
    ):format(node.label or node.id, node.id),
    vim.log.levels.WARN
  )
end

local function on_model()
  local seen = {}
  for _, node in
    ipairs(model.find(function(n)
      return n.kind == "pane" and n.pane_kind == "agent"
    end))
  do
    seen[node.id] = true
    local before, now = prev[node.id], node.state
    prev[node.id] = now
    if now ~= "blocked" then
      noticed[node.id] = nil
    elseif before ~= nil and before ~= "blocked" and view_open(node.id) then
      local n = pane_count(node)
      if n > 0 then
        noticed[node.id] = "request"
        say_request(node, n)
      else
        noticed[node.id] = "none"
        say_none(node)
      end
    end
  end
  for id in pairs(prev) do
    if not seen[id] then
      prev[id] = nil
      noticed[id] = nil
    end
  end
end

-- Запрос пришёл после перехода в `blocked`: сообщение об ожидании дополняется запросом.
local function on_pending(req, event)
  if event ~= "added" or noticed[req.pane_id] ~= "none" then
    return
  end
  local node = model.get(req.pane_id)
  if node and node.state == "blocked" and view_open(node.id) then
    noticed[node.id] = "request"
    say_request(node, pane_count(node))
  end
end

--- Подписывается на модель дерева и перечень запросов. Повторный вызов безвреден.
function M.start()
  M.stop()
  unsub_model = model.subscribe(on_model)
  local p = pending()
  if p then
    unsub_pending = p.subscribe(on_pending)
  end
end

--- Снимает подписки и забывает состояния.
function M.stop()
  if unsub_model then
    unsub_model()
    unsub_model = nil
  end
  if unsub_pending then
    unsub_pending()
    unsub_pending = nil
  end
  prev, noticed = {}, {}
end

return M
