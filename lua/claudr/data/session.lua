-- Слежение за сессией Claude Code: транскрипт владельца, каталог сессии, subagents/,
-- транскрипты и meta.json субагентов. Наблюдение — `vim.uv.new_fs_event`:
--   * транскрипта нет — ожидание его создания (наблюдение projects/ и каталогов проектов);
--   * каталог проекта — дописывание транскрипта владельца и появление каталога сессии;
--   * каталог сессии — пока нет subagents/; когда он создан, наблюдение переходит на него;
--   * subagents/ — meta.json и транскрипты субагентов (посторонние файлы и каталоги
--     пропускаются);
--   * каталог задач сессии (claudr.data.tasks_dir) — появление и удаление файлов вывода:
--     обычный файл, не принадлежащий фоновой команде, — работающий вызов Bash; пока
--     каталога нет, наблюдается ближайший существующий предок (claudr.data.fs.wait_path).
-- Транскрипты читаются асинхронно порциями (claudr.data.fs.read_lines_async) по одному
-- файлу за раз: главный поток Neovim не ждёт чтения больших файлов. Уведомление,
-- пришедшее во время чтения файла, вызывает ещё одно чтение этого файла после текущего.
-- Подписчик получает состояние, когда прочитаны все поставленные файлы; до этого
-- `state()` отдаёт последнее согласованное состояние, а не прочитанное наполовину.
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
    jobs = {}, -- очередь чтений: { key = путь, tail, owner, again }
    queued = {}, -- путь → чтение в очереди
    running = nil, -- идущее чтение
    loading = false, -- первое чтение транскриптов после присоединения не закончено
    task_files = {}, -- имя файла каталога задач → true, если обычный файл есть
    live = {}, -- id задачи → работающий вызов Bash {id, output_file, command}
    tries = {}, -- id задачи → число попыток найти команду работающего вызова
  }, Session)
  local path = data.find_transcript(session_id)
  if path then
    self:_attach(path)
  else
    -- недопустимый идентификатор locator не наблюдает
    self.locator = data._locate(session_id, function(found)
      self.locator = nil
      self:_attach(found)
      self:_emit()
    end)
  end
  self.last = self:_compute()
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
  self.loading = true
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
  self.tasks_dir = self.data.tasks_dir(path)
  self.tasks_wait = fs.wait_path(self.tasks_dir, function()
    self:_tasks_ready()
  end)
end

-- Каталог задач появился: наблюдение за ним и разбор уже лежащих файлов.
function Session:_tasks_ready()
  if self.closed or self.tasks_watch then
    return
  end
  self.tasks_watch = fs.watch(self.tasks_dir, function(filename)
    if filename == nil then
      self:_scan_tasks()
      self:_emit()
    elseif self:_task_file(filename) then
      self:_emit()
    end
  end)
  self:_scan_tasks()
  -- при создании сессии (каталог уже есть) состояние считает конструктор
  if self.last ~= nil then
    self:_emit()
  end
end

-- Попыток найти процесс работающего вызова: при появлении файла процесс может ещё не
-- открыть его, поэтому поиск повторяется по следующим уведомлениям о файле.
local COMMAND_TRIES = 3

-- Изменение файла `name` каталога задач; true — состояние изменилось. Уведомление о
-- дописывании известного файла состояния не меняет и обходится одной проверкой.
function Session:_task_file(name)
  local id = name:match("^(.+)%.output$")
  if not id then
    return false
  end
  local path = self.tasks_dir .. "/" .. name
  local st = vim.uv.fs_lstat(path)
  local regular = st ~= nil and st.type == "file"
  if not regular then
    local known = self.task_files[name] ~= nil
    self.task_files[name] = nil
    self.live[id] = nil
    self.tries[id] = nil
    return known
  end
  local changed = not self.task_files[name]
  self.task_files[name] = true
  local call = self.live[id]
  if not call then
    call = { id = id, output_file = path }
    self.live[id] = call
  end
  -- команда работающего вызова ещё не найдена: перестроение состояния ищет её снова
  return changed or self:_wants_command(id)
end

function Session:_wants_command(id)
  local call = self.live[id]
  return call ~= nil
    and not call.command
    and not self.ledger.commands[id]
    and (self.tries[id] or 0) < COMMAND_TRIES
end

function Session:_scan_tasks()
  local seen = {}
  for _, e in ipairs(fs.list_dir(self.tasks_dir)) do
    seen[e.name] = true
    self:_task_file(e.name)
  end
  for name in pairs(self.task_files) do
    if not seen[name] then
      self:_task_file(name)
    end
  end
end

-- Поставить чтение файла `key` (читатель `tail`, владелец `owner`) в очередь. Файл уже
-- в очереди — ничего; файл читается сейчас — после текущего чтения он читается ещё раз.
function Session:_queue(key, tail, owner)
  if self.closed or self.queued[key] then
    return
  end
  if self.running and self.running.key == key then
    self.running.again = true
    return
  end
  local job = { key = key, tail = tail, owner = owner }
  self.queued[key] = job
  self.jobs[#self.jobs + 1] = job
  self:_pump()
end

-- Начать следующее чтение очереди; очередь пуста — первое чтение закончено, подписчик
-- получает состояние.
function Session:_pump()
  if self.closed or self.running then
    return
  end
  local job = table.remove(self.jobs, 1)
  if not job then
    self.loading = false
    self:_emit()
    return
  end
  self.queued[job.key] = nil
  self.running = job
  fs.read_lines_async(job.tail, function(text)
    parse.scan(self.ledger, text, job.owner)
  end, function(found)
    self.running = nil
    if found and job.owner then
      self.paired[job.owner] = true
    end
    if job.again then
      job.again = false
      self.queued[job.key] = job
      self.jobs[#self.jobs + 1] = job
    end
    self:_pump()
  end, function()
    return self.closed
  end)
end

function Session:_busy()
  return self.running ~= nil or #self.jobs > 0
end

function Session:_read_owner()
  self:_queue(self.transcript, self.owner_tail, nil)
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
  self:_queue(path, tail, id)
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
  if self.closed or self:_busy() then
    return
  end
  local s = self:_compute()
  if not vim.deep_equal(s, self.last) then
    self.last = s
    self.on_change(s)
  end
end

function Session:_compute()
  local s = parse.build(self.ledger, self.metas, self.paired, self.owner_alive)
  s.transcript = self.transcript
  for _, task in pairs(s.tasks) do
    -- вывод есть, пока лежит файл (временный каталог могли очистить)
    task.output_available = task.output_file ~= nil and fs.is_file(task.output_file)
  end
  for id, call in pairs(self.live) do
    -- файл фоновой команды до записи о ней в транскрипте — тоже обычный файл задачи
    if self:_wants_command(id) then
      self.tries[id] = (self.tries[id] or 0) + 1
      local ok, cmd = pcall(self.data.process_command, call.output_file)
      call.command = ok and cmd or nil
    end
    if not self.ledger.commands[id] then
      s.calls[id] = {
        id = id,
        output_file = call.output_file,
        command = call.command,
        status = self.owner_alive and "running" or "orphaned",
      }
    end
  end
  return s
end

--- Вывод завершённого вызова Bash `id`: `{ text, persisted }` или nil.
function Session:call_output(id)
  local c = self.ledger.calls[id]
  if not c then
    return nil
  end
  return { text = self.ledger.outputs[id] or "", persisted = c.persisted }
end

--- Состояние сессии: `{ transcript = путь|nil, subagents = {[id] = …}, tasks = {[id] = …},
--- calls = {[id] = …} }` (форма записей — claudr.data.parse.build; у фоновой команды ещё
--- `output_available`; работающий вызов Bash — `{id, output_file, command, status}` по
--- идентификатору задачи, завершённый — по идентификатору вызова). Пока идёт чтение транскриптов — последнее
--- согласованное состояние (до конца первого чтения — без субагентов и команд).
function Session:state()
  if self:_busy() then
    return self.last
  end
  return self:_compute()
end

--- Закончено ли первое чтение транскриптов сессии (транскрипта нет — закончено).
function Session:loaded()
  return not self.loading
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
  for _, k in ipairs({
    "locator",
    "project_watch",
    "session_watch",
    "sub_watch",
    "tasks_wait",
    "tasks_watch",
  }) do
    if self[k] then
      self[k].close()
      self[k] = nil
    end
  end
end

return M
