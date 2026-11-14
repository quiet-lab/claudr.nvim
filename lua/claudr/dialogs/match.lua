-- Сопоставление запроса хука с вызовом инструмента в транскрипте (спецификация agent-dialogs,
-- решения D15, D27, D34).
--
-- Во входе `PermissionRequest` нет идентификатора вызова: его даёт запись `tool_use` того же
-- инструмента с равным `tool_input` в транскрипте сессии (`session_id` входа), у субагента —
-- в его транскрипте. Кандидат — вызов без результата на момент приёма запроса и не занятый
-- другим запросом; неразличимые вызовы достаются запросам по порядку записей. Записи нет —
-- запрос ждёт её по уведомлению файловой системы о дописывании транскрипта.
--
-- Наблюдатель — один на транскрипт, общий для запросов этого транскрипта; снимается, когда
-- запросов не остаётся. Записи разбирает только `claudr.data.hook`. Таймеров и опроса нет.
local data = require("claudr.data")
local fs = require("claudr.data.fs")
local hook = require("claudr.data.hook")

local M = {}

-- ключ транскрипта (`<сессия>` или `<сессия>/<субагент>`) → наблюдатель
local watchers = {}
-- запрос → { w = наблюдатель, cb = обработчик, since = число событий при приёме,
-- use = назначенный вызов, joining = запрос ещё входит в наблюдатель }
local tracked = {}

local function key_of(req)
  if req.agent_id then
    return req.session_id .. "/" .. req.agent_id
  end
  return req.session_id
end

-- Наблюдатель ---------------------------------------------------------------------------

local W = {}
W.__index = W

local function new_watcher(key, session_id, agent_id)
  return setmetatable({
    key = key,
    session_id = session_id,
    agent_id = agent_id,
    closed = false,
    n = 0, -- число учтённых событий транскрипта
    -- вызовы по порядку записей: { id, name, input, idx, result_idx?, result_ev?,
    -- decision_ev?, owner? }
    uses = {},
    by_id = {}, -- идентификатор вызова → вызов
    reqs = {}, -- запросы наблюдателя по порядку приёма
  }, W)
end

function W:close()
  if self.closed then
    return
  end
  self.closed = true
  for _, k in ipairs({ "locator", "wait", "watch" }) do
    if self[k] then
      self[k].close()
      self[k] = nil
    end
  end
  watchers[self.key] = nil
end

-- Обработчик запроса: `cb(req, event, value)`.
local function emit(req, event, value)
  local t = tracked[req]
  if t then
    t.cb(req, event, value)
  end
end

-- Событие транскрипта для вызова, занятого запросом.
local function deliver(use, ev)
  local req = use.owner
  if not req or not tracked[req] then
    return
  end
  if ev.type == "result" then
    emit(req, "result", ev.is_error)
  elseif ev.type == "decision" then
    emit(req, "decision", ev.decision)
  end
end

-- Назначение вызовов ждущим запросам: по порядку приёма запросов, вызов — первый подходящий
-- по порядку записей. Если результат вызова уже записан (после приёма запроса), он сразу
-- передаётся запросу.
function W:assign()
  for _, req in ipairs(vim.list_slice(self.reqs)) do
    local t = tracked[req]
    if t and not t.use and not t.joining and not self.closed then
      for _, use in ipairs(self.uses) do
        if
          not use.owner
          and use.name == req.tool_name
          and (not use.result_idx or use.result_idx > t.since)
          and hook.same_call(req.tool_name, use.input, req.tool_input)
        then
          use.owner = req
          t.use = use
          emit(req, "tool_use_id", use.id)
          if use.decision_ev then
            deliver(use, use.decision_ev)
          end
          if use.result_ev then
            deliver(use, use.result_ev)
          end
          break
        end
      end
    end
  end
end

function W:ingest(events)
  for _, ev in ipairs(events) do
    self.n = self.n + 1
    if ev.type == "call" then
      if not self.by_id[ev.id] then
        local use = { id = ev.id, name = ev.name, input = ev.input, idx = self.n }
        self.uses[#self.uses + 1] = use
        self.by_id[ev.id] = use
      end
    else
      local use = self.by_id[ev.id]
      if use then
        if ev.type == "result" and not use.result_idx then
          use.result_idx = self.n
          use.result_ev = ev
          deliver(use, ev)
        elseif ev.type == "decision" and not use.decision_ev then
          use.decision_ev = ev
          deliver(use, ev)
        end
      end
    end
  end
end

function W:pump()
  if self.closed or not self.tail then
    return
  end
  local lines = fs.read_lines(self.tail)
  if lines and #lines > 0 then
    self:ingest(hook.events(lines))
    self:assign()
  end
end

-- Наблюдение за файлом транскрипта: каталог файла (уведомления по имени файла).
function W:attach(path)
  if self.closed or self.tail then
    return
  end
  self.path = path
  self.tail = fs.tail(path)
  local dir, name = fs.dirname(path), fs.basename(path)
  self.wait = fs.wait_path(dir, function()
    if self.closed then
      return
    end
    self.watch = fs.watch(dir, function(filename)
      if filename == nil or filename == name then
        self:pump()
      end
    end)
    -- файл мог дописаться, пока ставилось наблюдение
    self:pump()
  end)
end

-- Транскрипт субагента: путь известен, когда найден транскрипт сессии.
function W:attach_subagent(session_path)
  if self.closed then
    return
  end
  local path = session_path:sub(1, -7) .. "/subagents/agent-" .. self.agent_id .. ".jsonl"
  self:attach(path)
end

function W:locate()
  local session_path = data.find_transcript(self.session_id)
  if session_path then
    if self.agent_id then
      self:attach_subagent(session_path)
    else
      self:attach(session_path)
    end
    return
  end
  self.locator = data._locate(self.session_id, function(found)
    self.locator = nil
    if self.agent_id then
      self:attach_subagent(found)
    else
      self:attach(found)
    end
  end)
end

-- Публичный API -------------------------------------------------------------------------

--- Начинает сопоставление запроса (`req.session_id`, `req.agent_id?`, `req.tool_name`,
--- `req.tool_input`). `cb(req, event, value)`: `"tool_use_id"` (идентификатор вызова),
--- `"result"` (результат вызова, `value` — `is_error`), `"decision"` (вложение
--- `hook_permission_decision`, `value` — `allow` или `deny`). Запрос без `session_id` не
--- сопоставляется. Обработчик может вызвать `untrack`.
function M.track(req, cb)
  if tracked[req] or type(req.session_id) ~= "string" then
    return
  end
  local key = key_of(req)
  local w = watchers[key]
  local fresh = false
  if not w then
    w = new_watcher(key, req.session_id, req.agent_id)
    watchers[key] = w
    fresh = true
  end
  -- запрос входит в наблюдатель до чтения: обработчики других запросов, вызванные чтением,
  -- не снимут наблюдатель
  local t = { w = w, cb = cb, joining = true }
  tracked[req] = t
  w.reqs[#w.reqs + 1] = req
  if fresh then
    w:locate()
  end
  -- уже записанное учитывается до отметки приёма: результаты прежних вызовов не подходят
  w:pump()
  t.since = w.n
  t.joining = nil
  w:assign()
end

--- Прекращает сопоставление запроса; наблюдатель без запросов снимается.
function M.untrack(req)
  local t = tracked[req]
  if not t then
    return
  end
  tracked[req] = nil
  local w = t.w
  for i, r in ipairs(w.reqs) do
    if r == req then
      table.remove(w.reqs, i)
      break
    end
  end
  if #w.reqs == 0 then
    w:close()
  end
end

-- Только для тестов: число наблюдателей транскриптов.
function M._watcher_count()
  local n = 0
  for _ in pairs(watchers) do
    n = n + 1
  end
  return n
end

return M
