-- Перечень ждущих запросов хука (спецификация agent-dialogs, решения D26, D27, D34, D35).
--
-- Запрос — принятое сокетом соединение хука с разобранным входом. Состояния:
--   waiting            ждёт решения;
--   sent               решение отправлено хуку;
--   accepted           решение принято Claude Code: в транскрипте вложение
--                      `hook_permission_decision` или результат вызова после нашего решения;
--   answered_elsewhere результат вызова без нашего решения (ответ в панели или другим
--                      клиентом), соединение закрыто плагином;
--   closed_by_hook     хук закрыл соединение до решения (Escape, срок, выход сессии);
--   answered_other     хук прислал «отвечено»: победило решение другого экземпляра;
--   handed_off         диалог передан терминалу, соединение закрыто без решения.
-- Запросы во всех состояниях остаются в `list()` до `forget`; в `for_node` и `count` входят
-- только `waiting` и `sent`.
--
-- Привязка к узлу дерева: панель — `HERDR_PANE_ID` окружения хука, субагент — `agent_id` входа
-- (узел `<панель>/<agent_id>`, если он есть в дереве, иначе узел панели). Таймеров и опроса
-- нет: состояния меняют события сокета и дописывание транскрипта.
local hook = require("claudr.data.hook")
local match = require("claudr.dialogs.match")
local socket = require("claudr.dialogs.socket")

local M = {}

local ACTIVE = { waiting = true, sent = true }

local S = {
  seq = 0,
  reqs = {}, -- запросы по порядку приёма
  conns = {}, -- запрос → соединение (пока открыто)
}

local subscribers = {}

local function emit(req, event)
  for _, s in ipairs({ unpack(subscribers) }) do
    if s.active then
      local ok, err = pcall(s.cb, req, event)
      if not ok then
        vim.notify(
          "claudr: ошибка подписчика перечня запросов: "
            .. tostring(err),
          vim.log.levels.ERROR
        )
      end
    end
  end
end

local function close_conn(req)
  local c = S.conns[req]
  if c then
    S.conns[req] = nil
    c:close()
  end
end

-- Переход в итоговое состояние: соединение закрыто, сопоставление прекращено.
local function finish(req, state)
  req.state = state
  close_conn(req)
  match.untrack(req)
  emit(req, "state")
end

-- События транскрипта по вызову запроса.
local function on_match(req, event, value)
  if event == "tool_use_id" then
    req.tool_use_id = value
    emit(req, "tool_use_id")
  elseif event == "decision" then
    if req.state == "sent" then
      finish(req, "accepted")
    end
  elseif event == "result" then
    if req.state == "sent" then
      finish(req, "accepted")
    elseif req.state == "waiting" then
      -- ответ в панели или другим клиентом: хук завершится без решения
      finish(req, "answered_elsewhere")
    end
  end
end

local function on_frame(req, frame)
  if frame.type == "answered" and ACTIVE[req.state] then
    finish(req, "answered_other")
  end
end

local function on_close(req)
  S.conns[req] = nil
  if req.state == "waiting" then
    finish(req, "closed_by_hook")
  end
  -- после отправленного решения хук печатает его и завершается: запрос ждёт подтверждения
  -- в транскрипте
end

local function on_request(conn, frame)
  local parsed = hook.parse_input(frame.input)
  if not parsed then
    conn:close()
    return
  end
  S.seq = S.seq + 1
  local req = {
    id = S.seq,
    pane_id = frame.env.HERDR_PANE_ID,
    agent_id = parsed.agent_id,
    session_id = parsed.session_id,
    tool_name = parsed.tool_name,
    tool_input = parsed.tool_input,
    request = parsed,
    state = "waiting",
  }
  S.reqs[#S.reqs + 1] = req
  S.conns[req] = conn
  conn.on_frame = function(_, f)
    on_frame(req, f)
  end
  conn.on_close = function()
    on_close(req)
  end
  emit(req, "added")
  if req.state == "waiting" then
    match.track(req, on_match)
  end
end

-- Публичный API -------------------------------------------------------------------------

--- Запускает приём запросов: сокет плагина. Возвращает true или nil, причина.
function M.start()
  return socket.start({ on_request = on_request })
end

--- Останавливает приём: сокет закрыт, соединения закрыты без решения, перечень очищен
--- (подписчики получают `removed` по каждому запросу).
function M.stop()
  socket.stop()
  local reqs = S.reqs
  S.reqs = {}
  for _, req in ipairs(reqs) do
    close_conn(req)
    match.untrack(req)
    emit(req, "removed")
  end
  S.conns = {}
end

--- Все запросы по порядку приёма, включая закрытые.
function M.list()
  return { unpack(S.reqs) }
end

--- Запрос по номеру или nil.
function M.get(id)
  for _, req in ipairs(S.reqs) do
    if req.id == id then
      return req
    end
  end
  return nil
end

--- Открыт ли запрос (`waiting` или `sent`).
function M.active(req)
  return req ~= nil and ACTIVE[req.state] == true
end

--- Идентификатор узла дерева, к которому привязан запрос: узел субагента, если он есть в
--- дереве, иначе узел панели.
function M.node_id(req)
  if req.agent_id then
    local id = req.pane_id .. "/" .. req.agent_id
    local node = require("claudr.tree.model").get(id)
    if node and node.kind == "subagent" then
      return id
    end
  end
  return req.pane_id
end

--- Открытые запросы панели (с запросами её субагентов) по порядку приёма.
function M.for_pane(pane_id)
  local out = {}
  for _, req in ipairs(S.reqs) do
    if ACTIVE[req.state] and req.pane_id == pane_id then
      out[#out + 1] = req
    end
  end
  return out
end

--- Открытые запросы узла по порядку приёма: узел панели — вместе с запросами её субагентов,
--- узел субагента — только свои; у прочих узлов запросов нет.
function M.for_node(node)
  if type(node) ~= "table" then
    return {}
  end
  if node.kind == "pane" then
    return M.for_pane(node.id)
  end
  local out = {}
  if node.kind == "subagent" and node.owner_pane and node.data then
    for _, req in ipairs(S.reqs) do
      if
        ACTIVE[req.state]
        and req.pane_id == node.owner_pane
        and req.agent_id ~= nil
        and req.agent_id == node.data.id
      then
        out[#out + 1] = req
      end
    end
  end
  return out
end

--- Число открытых запросов узла (см. `for_node`).
function M.count(node)
  return #M.for_node(node)
end

--- Отправляет решение (`output` — объект вывода хука целиком). true или false, причина:
--- запрос не ждёт решения (решение уже отправлено или запрос закрыт) либо хук уже закрыл
--- соединение.
function M.decide(req, output)
  if not req or req.state ~= "waiting" then
    return false, "запрос не ждёт решения"
  end
  local c = S.conns[req]
  local sent = c
    and c:send({ type = "decision", output = output }, function(err)
      if err and req.state == "sent" then
        -- решение не дошло: хук закрыл соединение раньше
        finish(req, "closed_by_hook")
      end
    end)
  if not sent then
    finish(req, "closed_by_hook")
    return false, "хук закрыл соединение, ответ в панели"
  end
  req.state = "sent"
  emit(req, "state")
  return true
end

--- Передаёт диалог терминалу: соединение закрывается без решения, хук завершается без
--- вывода. true или false, причина (запрос не ждёт решения).
function M.handoff(req)
  if not req or req.state ~= "waiting" then
    return false, "запрос не ждёт решения"
  end
  finish(req, "handed_off")
  return true
end

--- Убирает запрос из перечня; открытое соединение закрывается без решения.
function M.forget(req)
  for i, r in ipairs(S.reqs) do
    if r == req then
      table.remove(S.reqs, i)
      close_conn(req)
      match.untrack(req)
      emit(req, "removed")
      return
    end
  end
end

--- Подписка на изменения: `cb(req, event)`, `event` — `added`, `state`, `tool_use_id`,
--- `removed`. Возвращает функцию отписки.
function M.subscribe(cb)
  local s = { cb = cb, active = true }
  table.insert(subscribers, s)
  return function()
    s.active = false
    for i, x in ipairs(subscribers) do
      if x == s then
        table.remove(subscribers, i)
        break
      end
    end
  end
end

return M
