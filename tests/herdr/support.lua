-- Общие помощники тестов клиента herdr: двойник в своём каталоге, запуск клиента,
-- запись вызовов подписчика.
local t = require("helpers.t")
local double = require("helpers.herdr_double")

local M = {}

local dir_no = 0

--- Новый пустой каталог внутри каталога теста.
function M.dir(name)
  dir_no = dir_no + 1
  local dir = t.tmpdir() .. "/" .. (name or "h") .. dir_no
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.snapshot()
  return {
    workspaces = {
      double.workspace({ workspace_id = "w1", label = "ws1" }),
      double.workspace({ workspace_id = "w2", label = "ws2" }),
    },
    tabs = { double.tab({ tab_id = "w1:t1" }), double.tab({ tab_id = "w2:t1" }) },
    panes = {
      double.pane({ pane_id = "w1:p1", agent = "claude", agent_status = "idle", session = "s-1" }),
      double.pane({ pane_id = "w2:p1" }),
      double.pane({ pane_id = "w2:p2" }),
    },
  }
end

--- Подписчик клиента, который запоминает вызовы.
function M.recorder(herdr)
  local r = { calls = {}, events = {}, statuses = {} }
  r.unsubscribe = herdr.subscribe(function(state, events)
    table.insert(r.calls, { state = state, events = events })
    table.insert(r.statuses, state.status)
    vim.list_extend(r.events, events)
  end)
  function r:seen_status(status)
    return vim.tbl_contains(self.statuses, status)
  end
  function r:has_event(name, pane_id)
    for _, e in ipairs(self.events) do
      if e.event == name and (pane_id == nil or (e.data and e.data.pane_id == pane_id)) then
        return true
      end
    end
    return false
  end
  return r
end

function M.has_pane(snap, pane_id)
  for _, p in ipairs(snap.panes or {}) do
    if p.pane_id == pane_id then
      return true
    end
  end
  return false
end

function M.has_workspace(snap, ws_id)
  for _, w in ipairs(snap.workspaces or {}) do
    if w.workspace_id == ws_id then
      return true
    end
  end
  return false
end

function M.wait_status(herdr, status)
  t.wait(function()
    return herdr.state().status == status
  end, "состояние " .. status)
end

--- Подписки двойника по панелям: множество `pane_id`.
function M.pane_subscriptions(d)
  local set = {}
  for _, s in ipairs(d.subscriptions) do
    for _, rec in ipairs(s.subscriptions) do
      if rec.pane_id then
        set[rec.pane_id] = true
      end
    end
  end
  return set
end

--- Число соединений двойника с общей подпиской (без панелей).
function M.lifecycle_subscriptions(d)
  local n = 0
  for _, s in ipairs(d.subscriptions) do
    if s.subscriptions[1] and not s.subscriptions[1].pane_id then
      n = n + 1
    end
  end
  return n
end

--- Ждать, пока подписка двойника по панелям не совпадёт с `ids`.
function M.wait_pane_subscriptions(d, ids)
  local want = {}
  for _, id in ipairs(ids) do
    want[id] = true
  end
  t.wait(function()
    return vim.deep_equal(M.pane_subscriptions(d), want) and #d.subscriptions == 2
  end, "подписки по панелям " .. table.concat(ids, ","))
end

--- Синхронный вызов `herdr.request` до ответа.
function M.call(herdr, method, params)
  local done, err, result = false, nil, nil
  herdr.request(method, params, function(e, r)
    done, err, result = true, e, r
  end)
  t.wait(function()
    return done
  end, "ответ " .. method)
  return err, result
end

--- Двойник со снимком и подключённый клиент. Возвращает двойник.
function M.connected(herdr, opts)
  opts = opts or {}
  local d = double.start({ dir = M.dir(), snapshot = opts.snapshot or M.snapshot() })
  herdr.start()
  M.wait_status(herdr, "connected")
  if opts.wait_panes ~= false then
    local ids = {}
    for _, p in ipairs(herdr.state().snapshot.panes) do
      table.insert(ids, p.pane_id)
    end
    M.wait_pane_subscriptions(d, ids)
    if #ids > 0 then
      -- Начатая подписка по панелям вызывает ещё одно чтение снимка: дождаться его конца,
      -- чтобы запросы теста не смешались с запросами подключения.
      t.wait(function()
        return d:count("session.snapshot") >= 2 and not herdr._reading()
      end, "чтение снимка после подписки по панелям")
    end
  end
  return d
end

return M
