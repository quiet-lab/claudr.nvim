-- Буфер диалога (спецификация agent-dialogs, D22, D28, D33): запрос хука показывается
-- обычным буфером только для чтения, курсор — на первом пункте, Enter на пункте — ответ.
-- Буфер один на весь Neovim: при открытии другого запроса меняется его содержимое. Окно и
-- фокус плагин сам не меняет — буфер открывается только по команде пользователя. Состояния
-- запроса приходят подпиской `pending.subscribe`; таймеров и опроса нет, к панели
-- (`pane.send_keys`, `pane.send_text`, `pane.read`) обращений нет.
--
-- Содержимое по виду запроса строят модули `dialogs/views/*` (`screen(ctx)` → заголовок,
-- пункты, подвал); решения собирает только `claudr.dialogs.decision`.
local input = require("claudr.input")
local model = require("claudr.tree.model")
local window = require("claudr.view.window")

local M = {}

M.FILETYPE = "claudr-dialog"
M.KEYS = { activate = "<CR>", confirm = "c", handoff = "T", next = "<Tab>" }

local views = {
  permission = require("claudr.dialogs.views.permission"),
  question = require("claudr.dialogs.views.question"),
  plan = require("claudr.dialogs.views.plan"),
}

-- Подписи состояний запроса.
M.STATE_TEXT = {
  waiting = "ждёт решения",
  sent = "решение отправлено, ждём Claude Code",
  accepted = "решение принято Claude Code",
  answered_elsewhere = "отвечено в панели или другим клиентом",
  closed_by_hook = "закрыт хуком, ответ в панели",
  answered_other = "ответ принят другим экземпляром Neovim",
  handed_off = "передан терминалу",
}

-- Состояния, после которых запрос в перечне больше не нужен.
local OPEN_STATES = { waiting = true, sent = true }

---@class claudr.DialogBuffer
---@field buf integer
---@field win integer|nil
---@field req table
---@field state table состояние вида (ответы, отметки)
---@field sent boolean решение уже отправлено из этого буфера
---@field items table<integer, table> строка → пункт
---@field screen table|nil
---@field unsubscribe function|nil
local D = nil

local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO)
end

local function pending()
  return require("claudr.dialogs.pending")
end

local function pane_node(req)
  return req.pane_id and model.get(req.pane_id) or nil
end

local function waiting_list(req)
  local node = pane_node(req)
  if not node then
    return {}
  end
  local ok, list = pcall(pending().for_node, node)
  return ok and list or {}
end

-- Строка с пунктом: номер и текст.
local function item_lines(i, item)
  local out = { ("  %d. %s"):format(i, item.text) }
  for _, l in ipairs(item.detail or {}) do
    out[#out + 1] = "       " .. l
  end
  return out
end

local function compose(d)
  local req = d.req
  local r = req.request
  local view = views[r.kind] or views.permission
  local lines = {}
  local function add(l)
    lines[#lines + 1] = l
  end
  add(view.TITLE .. (r.agent_id and " (субагент)" or ""))
  add(
    "Панель: "
      .. tostring(req.pane_id)
      .. (r.agent_id and ("  субагент: " .. r.agent_id) or "")
  )
  if r.cwd then
    add("Каталог: " .. r.cwd)
  end
  local others = #waiting_list(req)
  if others > 1 then
    add(
      ("Ждущих запросов у панели: %d (%s — следующий)"):format(
        others,
        M.KEYS.next
      )
    )
  end
  local status = M.STATE_TEXT[req.state] or tostring(req.state)
  if d.sent and req.state == "waiting" then
    status = M.STATE_TEXT.sent
  end
  add("Состояние: " .. status)
  add("")
  local screen = view.screen(d.ctx)
  d.screen = screen
  for _, l in ipairs(screen.header or {}) do
    add(l)
  end
  add("")
  local items = {}
  local first
  if req.state == "waiting" and not d.sent then
    for i, item in ipairs(screen.items or {}) do
      local block = item_lines(i, item)
      items[#lines + 1] = item
      first = first or (#lines + 1)
      for _, l in ipairs(block) do
        add(l)
      end
    end
    add("")
  end
  for _, l in ipairs(screen.footer or {}) do
    add(l)
  end
  add(
    ("%s — ответ, %s — подтвердить, %s — передать терминалу, %s — следующий запрос, q — закрыть"):format(
      M.KEYS.activate,
      M.KEYS.confirm,
      M.KEYS.handoff,
      M.KEYS.next
    )
  )
  return lines, items, first
end

local function render(d, reset_cursor)
  if not vim.api.nvim_buf_is_valid(d.buf) then
    return
  end
  local old_row
  if d.win and vim.api.nvim_win_is_valid(d.win) then
    old_row = vim.api.nvim_win_get_cursor(d.win)[1]
  end
  local lines, items, first = compose(d)
  d.items = items
  vim.bo[d.buf].modifiable = true
  vim.api.nvim_buf_set_lines(d.buf, 0, -1, false, lines)
  vim.bo[d.buf].modifiable = false
  vim.bo[d.buf].modified = false
  if d.win and vim.api.nvim_win_is_valid(d.win) then
    local row = (reset_cursor or not old_row) and (first or 1) or math.min(old_row, #lines)
    pcall(vim.api.nvim_win_set_cursor, d.win, { math.max(row, 1), 0 })
  end
end

-- Контекст вида: отправка решения, окно ввода, перерисовка.
local function make_ctx(d)
  local ctx = { state = d.state }
  ctx.req = d.req
  ctx.notify = notify
  ctx.refresh = function(reset)
    render(d, reset)
  end
  -- Решение уходит один раз: повторная отправка недоступна.
  ctx.decide = function(output)
    if d.sent or d.req.state ~= "waiting" then
      notify(
        "claudr: решение не отправлено: "
          .. (M.STATE_TEXT[d.req.state] or "запрос закрыт"),
        vim.log.levels.WARN
      )
      return false
    end
    local ok, sent, why = pcall(pending().decide, d.req, output)
    if not ok or sent ~= true then
      notify(
        "claudr: решение не отправлено: " .. tostring(ok and why or sent),
        vim.log.levels.ERROR
      )
      return false
    end
    d.sent = true
    notify("claudr: решение отправлено")
    render(d, true)
    return true
  end
  -- Окно ввода для свободного ответа и пояснения; `cb(text)` вернул `false` — окно остаётся.
  ctx.ask = function(title, key, cb)
    input.open({
      title = title,
      target = { kind = "dialog", key = tostring(d.req.id) .. "/" .. key },
      on_submit = function(text, close)
        if cb(text) ~= false then
          close()
        end
      end,
    })
  end
  return ctx
end

local function activate(d)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local item = d.items[row]
  if d.sent or d.req.state ~= "waiting" then
    notify(
      "claudr: решение уже отправлено или запрос закрыт: "
        .. (M.STATE_TEXT[d.req.state] or d.req.state),
      vim.log.levels.WARN
    )
    return
  end
  if not item then
    notify("claudr: на этой строке нет пункта", vim.log.levels.WARN)
    return
  end
  item.run()
end

--- Предложение подключения с вводом (диалог вне хука и передача терминалу).
---@param pane_id string
function M.offer_attach(pane_id)
  vim.ui.select({ "Подключиться с вводом", "Отмена" }, {
    prompt = "Диалог остаётся в панели:",
  }, function(choice)
    if choice == "Подключиться с вводом" then
      local node = model.get(pane_id)
      if node then
        require("claudr.view").attach(node)
      end
    end
  end)
end

local function handoff(d)
  local req = d.req
  local ok, done, why = pcall(pending().handoff, req)
  if not ok or done == false then
    notify(
      "claudr: передать терминалу не удалось: "
        .. tostring(ok and why or done),
      vim.log.levels.WARN
    )
    return
  end
  local pane_id = req.pane_id
  M.close()
  notify("claudr: диалог передан терминалу")
  M.offer_attach(pane_id)
end

local function goto_next(d)
  local list = waiting_list(d.req)
  if #list == 0 or (#list == 1 and list[1] == d.req) then
    notify("claudr: других ждущих запросов нет")
    return
  end
  local idx = 0
  for i, r in ipairs(list) do
    if r == d.req then
      idx = i
    end
  end
  M.open(list[idx % #list + 1])
end

local function on_pending_event(req, event)
  if not D or not vim.api.nvim_buf_is_valid(D.buf) then
    return
  end
  if event == "removed" and req == D.req then
    render(D, false)
    return
  end
  -- число ждущих запросов в строке заголовка меняется от любых запросов панели
  if req == D.req or req.pane_id == D.req.pane_id then
    render(D, false)
  end
end

local function dispose(d)
  if d.unsubscribe then
    d.unsubscribe()
    d.unsubscribe = nil
  end
  local req = d.req
  -- закрытый запрос больше не нужен перечню; ждущий остаётся
  if req and not OPEN_STATES[req.state] then
    pcall(pending().forget, req)
  end
  if D == d then
    D = nil
  end
end

local function create(req)
  local buf = window.scratch()
  vim.bo[buf].filetype = M.FILETYPE
  vim.bo[buf].modifiable = false
  local d = { buf = buf, req = req, state = {}, sent = false, items = {} }
  d.ctx = make_ctx(d)
  D = d
  d.unsubscribe = pending().subscribe(on_pending_event)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map(M.KEYS.activate, function()
    activate(d)
  end, "claudr: ответить")
  map(M.KEYS.confirm, function()
    if d.sent or d.req.state ~= "waiting" then
      notify(
        "claudr: решение уже отправлено или запрос закрыт",
        vim.log.levels.WARN
      )
    elseif d.screen and d.screen.confirm then
      d.screen.confirm()
    else
      notify("claudr: здесь нечего подтверждать", vim.log.levels.WARN)
    end
  end, "claudr: подтвердить")
  map(M.KEYS.handoff, function()
    handoff(d)
  end, "claudr: передать диалог терминалу")
  map(M.KEYS.next, function()
    goto_next(d)
  end, "claudr: следующий запрос")
  local ok, refs = pcall(require, "claudr.refs")
  if ok then
    refs.attach(buf, {
      cwd = function()
        return d.req.request.cwd
      end,
    })
  end
  return d
end

local function show(d)
  if d.win and vim.api.nvim_win_is_valid(d.win) then
    vim.api.nvim_set_current_win(d.win)
    return
  end
  local title = "диалог: " .. tostring(d.req.pane_id)
  d.win = window.open_float(d.buf, { title = title, width = 100, height = 30 })
  vim.wo[d.win].wrap = true
  vim.wo[d.win].cursorline = true
  window.register({
    kind = "dialog",
    node_id = d.req.pane_id,
    buf = d.buf,
    win = d.win,
    dispose = function()
      dispose(d)
    end,
  })
end

--- Открывает буфер диалога на запросе `req` (по команде пользователя). Курсор — на первом
--- пункте. Если буфер уже открыт, в нём показывается этот запрос.
---@param req table
---@return claudr.DialogBuffer
function M.open(req)
  local d = D
  if d and vim.api.nvim_buf_is_valid(d.buf) then
    if d.req ~= req then
      -- запрос, который больше не нужен перечню, забывается при смене
      local old = d.req
      if not OPEN_STATES[old.state] then
        pcall(pending().forget, old)
      end
      d.req = req
      d.ctx.req = req
      d.state = {}
      d.ctx.state = d.state
      d.sent = false
    end
  else
    d = create(req)
  end
  show(d)
  render(d, true)
  return d
end

--- Текущий буфер диалога или `nil`.
function M.current()
  return D and vim.api.nvim_buf_is_valid(D.buf) and D or nil
end

--- Закрывает буфер диалога (окно и буфер); перечень запросов не меняется.
function M.close()
  if D and vim.api.nvim_buf_is_valid(D.buf) then
    local d = D
    window.close({ buf = d.buf, win = d.win })
  end
end

return M
