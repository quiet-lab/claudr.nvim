-- Общие помощники тестов дерева: двойник herdr, образцы Claude Code, запуск модели, заглушка
-- значков herdr и записывающая фабрика таймера кадров.
local t = require("helpers.t")
local double = require("helpers.herdr_double")
local fixtures = require("helpers.fixtures")
local hsupport = require("herdr.support")
local u = require("data.util")
local herdr = require("claudr.herdr")
local model = require("claudr.tree.model")
local config = require("claudr.config")

local M = {}

-- Синтетическая таблица значков: `working` — три кадра, остальные — по одному.
M.ICONS = {
  idle = { frames = { "i" }, period = 400 },
  working = { frames = { "w0", "w1", "w2" }, period = 100 },
  blocked = { frames = { "b" }, period = 400 },
  done = { frames = { "d" }, period = 400 },
  unknown = { frames = { "u" }, period = 400 },
}

--- Заглушка модуля `claudr.herdr.icons` с подсчётом подписок. `icons` — таблица значков (по
--- умолчанию `M.ICONS`). Возвращает заглушку: `subs` — действующие подписки, `subscribed` и
--- `unsubscribed` — счётчики, `set(icons)` — смена значков с вызовом подписчиков.
function M.stub_icons(icons)
  local stub =
    { table = vim.deepcopy(icons or M.ICONS), subs = {}, subscribed = 0, unsubscribed = 0 }
  function stub.get()
    return stub.table
  end
  function stub.watching()
    return false
  end
  function stub.subscribe(fn)
    stub.subscribed = stub.subscribed + 1
    local rec = { fn = fn }
    stub.subs[#stub.subs + 1] = rec
    return function()
      for i, x in ipairs(stub.subs) do
        if x == rec then
          table.remove(stub.subs, i)
          stub.unsubscribed = stub.unsubscribed + 1
          break
        end
      end
    end
  end
  function stub.set(new)
    stub.table = vim.deepcopy(new)
    for _, rec in ipairs({ unpack(stub.subs) }) do
      rec.fn()
    end
  end
  package.loaded["claudr.herdr.icons"] = stub
  return stub
end

-- Тесты дерева идут на синтетических значках: разбор конфигурации herdr проверяют
-- тесты `tests/herdr/icons_spec.lua`.
M.stub_icons()

--- Записывающая фабрика таймера кадров: `timers` — созданные таймеры с журналом `calls`
--- (`start`, `stop`, `close`). `active()` — есть ли заведённый и не закрытый таймер.
function M.timer_recorder()
  local rec = { timers = {}, calls = {} }
  function rec.factory()
    local tm = { started = false, closed = false }
    function tm:start(delay, rep, cb)
      assert(not self.closed, "start закрытого таймера")
      self.started, self.delay, self.rep, self.cb = true, delay, rep, cb
      rec.calls[#rec.calls + 1] = { "start", delay, rep }
    end
    function tm:stop()
      self.started = false
      rec.calls[#rec.calls + 1] = { "stop" }
    end
    function tm:close()
      self.closed = true
      self.started = false
      rec.calls[#rec.calls + 1] = { "close" }
    end
    rec.timers[#rec.timers + 1] = tm
    return tm
  end
  function rec.active()
    for _, tm in ipairs(rec.timers) do
      if tm.started and not tm.closed then
        return tm
      end
    end
    return nil
  end
  function rec.count(name)
    local n = 0
    for _, c in ipairs(rec.calls) do
      if c[1] == name then
        n = n + 1
      end
    end
    return n
  end
  return rec
end

M.double = double
M.fixtures = fixtures

local current

--- Окружение теста: каталог данных Claude Code с образцами `samples`, двойник herdr со
--- снимком `snapshot`, запущенная модель, подписки клиента по всем панелям, законченное
--- первое чтение транскриптов сессий панелей. `prepare(dir)` (необязательно) вызывается
--- после установки образцов до запуска модели; `opts.loaded = false` — не ждать чтения
--- транскриптов. Возвращает двойник.
function M.env(snapshot, samples, prepare, opts)
  M.claude_dir = u.fresh(samples)
  if prepare then
    prepare(M.claude_dir)
  end
  local d = double.start({ dir = hsupport.dir("tree"), snapshot = snapshot })
  current = d
  model.start()
  hsupport.wait_status(herdr, "connected")
  local ids = {}
  for _, p in ipairs(snapshot.panes or {}) do
    ids[#ids + 1] = p.pane_id
  end
  if #ids > 0 then
    hsupport.wait_pane_subscriptions(d, ids)
    -- после начала подписки по панелям клиент перечитывает снимок ещё раз
    t.wait(function()
      local reading = herdr._reading()
      return d:count("session.snapshot") >= 2 and not reading
    end, "снимок после подписки по панелям")
  end
  if not (opts and opts.loaded == false) then
    M.wait_loaded()
  end
  return d
end

--- Ждать конца первого чтения транскриптов всех сессий панелей модели.
function M.wait_loaded()
  t.wait(function()
    for _, rec in pairs(model._sessions()) do
      if not rec.handle:loaded() then
        return false
      end
    end
    return true
  end, "первое чтение транскриптов сессий")
end

--- Уборка после теста: модель, клиент, двойник, настройки.
function M.reset()
  model.stop()
  herdr.stop()
  if current then
    current:close()
    current = nil
  end
  config.setup({})
end

--- Ждать, пока узел `id` не будет удовлетворять `pred(node)` (без `pred` — пока не появится).
function M.wait_node(id, pred, msg)
  t.wait(function()
    local n = model.get(id)
    return n ~= nil and (pred == nil or pred(n))
  end, msg or ("узел " .. id))
  return model.get(id)
end

--- Ждать исчезновения узла `id`.
function M.wait_gone(id, msg)
  t.wait(function()
    return model.get(id) == nil
  end, msg or ("исчезновение узла " .. id))
end

--- Идентификаторы детей узла.
function M.children(id)
  local n = model.get(id)
  return n and vim.deepcopy(n.children) or nil
end

--- Панель снимка двойника с сессией образца `sample`.
function M.claude_pane(pane_id, sample, extra)
  local o = {
    pane_id = pane_id,
    agent = "claude",
    display_agent = "opus",
    agent_status = "idle",
    session = fixtures.session_id(sample),
    terminal_title = "✳ задача " .. pane_id,
    terminal_title_stripped = "задача " .. pane_id,
  }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return double.pane(o)
end

--- Снимок из одного workspace `w1` с вкладкой `w1:t1` и панелями `panes`.
function M.snapshot(panes)
  return {
    workspaces = { double.workspace({ workspace_id = "w1", label = "ws1" }) },
    tabs = { double.tab({ tab_id = "w1:t1", label = "main" }) },
    panes = panes,
  }
end

M.settle = u.settle
M.count_reads = u.count_reads
M.timer_count = u.timer_count
M.fs_event_count = u.fs_event_count

return M
