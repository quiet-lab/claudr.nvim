-- Заглушка перечня ждущих запросов `claudr.dialogs.pending` с тем же интерфейсом (для тестов
-- буфера диалога, сообщения об ожидании и дерева без сокета). Подменяет модуль в
-- `package.loaded`; `M.uninstall()` возвращает прежнее.
local hook = require("claudr.data.hook")

local M = {}

local saved
local next_id

--- Ставит заглушку и возвращает её.
function M.install()
  saved = package.loaded["claudr.dialogs.pending"]
  next_id = 0
  local stub = { reqs = {}, subs = {}, decided = {}, handoffs = {}, forgotten = {} }

  local function emit(req, event)
    for _, cb in ipairs({ unpack(stub.subs) }) do
      cb(req, event)
    end
  end

  --- Добавляет запрос по входу хука (таблица) для панели `pane_id`.
  function stub.add(input, pane_id)
    local request = assert(hook.parse_input(input))
    next_id = next_id + 1
    local req = {
      id = next_id,
      pane_id = pane_id,
      agent_id = request.agent_id,
      session_id = request.session_id,
      tool_name = request.tool_name,
      tool_input = request.tool_input,
      request = request,
      state = "waiting",
    }
    stub.reqs[#stub.reqs + 1] = req
    emit(req, "added")
    return req
  end

  function stub.set_state(req, state)
    req.state = state
    emit(req, "state")
  end

  local function open(req)
    return req.state == "waiting" or req.state == "sent"
  end

  function stub.list()
    return vim.list_slice(stub.reqs)
  end

  function stub.for_node(node)
    local out = {}
    for _, r in ipairs(stub.reqs) do
      if open(r) then
        if node.kind == "pane" and r.pane_id == node.id then
          out[#out + 1] = r
        elseif node.kind == "subagent" and node.id == r.pane_id .. "/" .. tostring(r.agent_id) then
          out[#out + 1] = r
        end
      end
    end
    return out
  end

  function stub.count(node)
    return #stub.for_node(node)
  end

  function stub.get(id)
    for _, r in ipairs(stub.reqs) do
      if r.id == id then
        return r
      end
    end
  end

  function stub.decide(req, output)
    if req.state ~= "waiting" then
      return false, "запрос не ждёт решения"
    end
    stub.decided[#stub.decided + 1] = { req = req, output = output }
    stub.set_state(req, "sent")
    return true
  end

  function stub.handoff(req)
    stub.handoffs[#stub.handoffs + 1] = req
    stub.set_state(req, "handed_off")
    return true
  end

  function stub.subscribe(cb)
    stub.subs[#stub.subs + 1] = cb
    return function()
      for i, f in ipairs(stub.subs) do
        if f == cb then
          table.remove(stub.subs, i)
          break
        end
      end
    end
  end

  function stub.forget(req)
    stub.forgotten[#stub.forgotten + 1] = req
    for i, r in ipairs(stub.reqs) do
      if r == req then
        table.remove(stub.reqs, i)
        break
      end
    end
    emit(req, "removed")
  end

  function stub.start() end
  function stub.stop() end

  package.loaded["claudr.dialogs.pending"] = stub
  return stub
end

function M.uninstall()
  package.loaded["claudr.dialogs.pending"] = saved
  saved = nil
end

return M
