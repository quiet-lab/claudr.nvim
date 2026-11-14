-- Слежение за сессией Claude Code: транскрипт владельца, каталог сессии, subagents/,
-- транскрипты и meta.json субагентов. Наблюдение — `vim.uv.new_fs_event`:
--   * транскрипта нет — ожидание его создания (наблюдение projects/ и каталогов проектов);
--   * каталог проекта — дописывание транскрипта владельца и появление каталога сессии;
--   * каталог сессии — пока нет subagents/; когда он создан, наблюдение переходит на него;
--   * subagents/ — meta.json и транскрипты субагентов (посторонние файлы и каталоги
--     пропускаются).
-- Таймеров и опроса нет; каждое чтение вызвано уведомлением или созданием наблюдения.
local fs = require("claudr.data.fs")
local parse = require("claudr.data.parse")

local Session = {}
Session.__index = Session

local M = {}

function M.new(data, session_id, on_change)
  local self = setmetatable({
    data = data,
    id = session_id,
    on_change = on_change or function() end,
    owner_alive = true,
    closed = false,
    ledger = parse.ledger(),
    metas = {}, -- id субагента → разобранный meta.json
    paired = {}, -- id субагента → true, если есть его транскрипт
    sub_tails = {}, -- id субагента → читатель транскрипта
  }, Session)
  local path = data.find_transcript(session_id)
  if path then
    self:_attach(path)
  elseif type(session_id) == "string" and session_id ~= "" then
    self.locator = data._locate(session_id, function(found)
      self.locator = nil
      self:_attach(found)
      self:_emit()
    end)
  end
  self.last = self:state()
  return self
end

function Session:_attach(path)
  if self.closed then
    return
  end
  self.transcript = path
  self.session_dir = path:sub(1, -7)
  self.subagents_dir = self.session_dir .. "/subagents"
  self.owner_tail = fs.tail(path)
  local name = fs.basename(path)
  local session_name = fs.basename(self.session_dir)
  self.project_watch = fs.watch(fs.dirname(path), function(filename)
    if filename == nil or filename == name then
      self:_read_owner()
    end
    if filename == nil or filename == session_name then
      self:_session_dir_changed()
    end
    self:_emit()
  end)
  self:_read_owner()
  self:_session_dir_changed()
end

local function feed_lines(ledger, lines, owner)
  for _, line in ipairs(lines or {}) do
    local rec = parse.decode(line)
    if rec then
      parse.feed(ledger, rec, owner)
    end
  end
end

function Session:_read_owner()
  feed_lines(self.ledger, fs.read_lines(self.owner_tail), nil)
end

-- Каталог сессии: пока subagents/ нет, наблюдается каталог сессии; когда subagents/ создан,
-- наблюдение переходит на него.
function Session:_session_dir_changed()
  if self.closed or self.sub_watch then
    return
  end
  if fs.is_dir(self.subagents_dir) then
    if self.session_watch then
      self.session_watch.close()
      self.session_watch = nil
    end
    self.sub_watch = fs.watch(self.subagents_dir, function(filename)
      self:_subagent_event(filename)
      self:_emit()
    end)
    self:_scan_subagents()
    return
  end
  if not self.session_watch and fs.is_dir(self.session_dir) then
    self.session_watch = fs.watch(self.session_dir, function(filename)
      if filename == nil or filename == "subagents" then
        self:_session_dir_changed()
        self:_emit()
      end
    end)
    -- subagents/ мог появиться, пока ставилось наблюдение
    self:_session_dir_changed()
  end
end

function Session:_read_meta(id)
  local text = fs.read_file(self.subagents_dir .. "/agent-" .. id .. ".meta.json")
  local meta = text and parse.decode(text)
  if meta then
    self.metas[id] = meta
  end
end

function Session:_read_subagent_transcript(id)
  local path = self.subagents_dir .. "/agent-" .. id .. ".jsonl"
  local tail = self.sub_tails[id]
  if not tail then
    if not fs.is_file(path) then
      return
    end
    tail = fs.tail(path)
    self.sub_tails[id] = tail
  end
  local lines = fs.read_lines(tail)
  if lines then
    self.paired[id] = true
    feed_lines(self.ledger, lines, id)
  end
end

function Session:_subagent_file(name)
  local kind, id = parse.subagent_file(name)
  if kind == "meta" then
    self:_read_meta(id)
  elseif kind == "transcript" then
    self:_read_subagent_transcript(id)
  end
end

function Session:_subagent_event(filename)
  if filename == nil then
    self:_scan_subagents()
  else
    self:_subagent_file(filename)
  end
end

function Session:_scan_subagents()
  for _, e in ipairs(fs.list_dir(self.subagents_dir)) do
    if e.type == "file" then
      self:_subagent_file(e.name)
    end
  end
end

function Session:_emit()
  if self.closed then
    return
  end
  local s = self:state()
  if not vim.deep_equal(s, self.last) then
    self.last = s
    self.on_change(s)
  end
end

--- Состояние сессии: `{ transcript = путь|nil, subagents = {[id] = …}, tasks = {[id] = …} }`
--- (форма записей — claudr.data.parse.build).
function Session:state()
  local s = parse.build(self.ledger, self.metas, self.paired, self.owner_alive)
  s.transcript = self.transcript
  return s
end

--- Сообщение о панели владельца: false — процесс панели завершён или панель закрыта;
--- субагенты и фоновые команды без отметки завершения получают состояние «оборван».
function Session:set_owner_alive(alive)
  self.owner_alive = alive ~= false
  self:_emit()
end

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  for _, k in ipairs({ "locator", "project_watch", "session_watch", "sub_watch" }) do
    if self[k] then
      self[k].close()
      self[k] = nil
    end
  end
end

return M
