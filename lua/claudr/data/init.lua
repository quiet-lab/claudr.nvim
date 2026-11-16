-- Модуль данных Claude Code (спецификация claude-code-data): единственный разборщик
-- транскриптов, meta.json субагентов, записей фоновых команд и файлов вывода. Остальной код
-- получает от него записи видов «субагент», «фоновая команда» и «реплика диалога».
--
-- Слежение — только уведомлениями файловой системы (`vim.uv.new_fs_event`), дописываемые
-- файлы читаются с запомненного смещения; таймеров и опроса нет. Обратные вызовы подписчиков
-- идут в обычном контексте Neovim.
local fs = require("claudr.data.fs")
local parse = require("claudr.data.parse")

local uv = vim.uv

local M = {}

--- Каталог данных Claude Code: `$CLAUDE_CONFIG_DIR`, без неё — `~/.claude`.
function M.root()
  local dir = uv.os_getenv("CLAUDE_CONFIG_DIR")
  if not dir or dir == "" then
    dir = (uv.os_homedir() or "") .. "/.claude"
  end
  return (dir:gsub("(.)/+$", "%1"))
end

local function projects_dir()
  return M.root() .. "/projects"
end

local function valid_id(id)
  return type(id) == "string"
    and id ~= ""
    and not id:find("/", 1, true)
    and id ~= "."
    and id ~= ".."
end

--- Путь транскрипта сессии `<id>.jsonl` среди всех каталогов проектов или nil (не найден:
--- ещё не создан; это не ошибка). Каталог проекта не выводится из рабочего каталога.
function M.find_transcript(session_id)
  if not valid_id(session_id) then
    return nil
  end
  local projects = projects_dir()
  local name = session_id .. ".jsonl"
  for _, e in ipairs(fs.list_dir(projects)) do
    if e.type == "directory" then
      local path = projects .. "/" .. e.name .. "/" .. name
      if fs.is_file(path) then
        return path
      end
    end
  end
  return nil
end

--- Временный каталог Claude Code: `$CLAUDR_CLAUDE_TMP`, без неё — `claude-<uid>` во
--- временном каталоге системы.
function M.tmp_root()
  local dir = uv.os_getenv("CLAUDR_CLAUDE_TMP")
  if not dir or dir == "" then
    dir = (uv.os_tmpdir() or "/tmp") .. "/claude-" .. tostring(uv.getuid())
  end
  return (dir:gsub("(.)/+$", "%1"))
end

--- Каталог задач сессии по пути её транскрипта: `<временный каталог>/<имя каталога
--- проекта>/<сессия>/tasks`. В нём лежат файлы вывода вызовов Bash сессии и её субагентов.
function M.tasks_dir(transcript)
  local project = fs.basename(fs.dirname(transcript))
  local session = fs.basename(transcript):gsub("%.jsonl$", "")
  return M.tmp_root() .. "/" .. project .. "/" .. session .. "/tasks"
end

-- Слово оболочки, начинающееся с позиции `i` строки `s`: склеенные части в одинарных и
-- двойных кавычках и без кавычек до пробела. Возвращает текст слова без кавычек.
local function shell_word(s, i)
  local out = {}
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "'" then
      local j = s:find("'", i + 1, true)
      if not j then
        out[#out + 1] = s:sub(i + 1)
        break
      end
      out[#out + 1] = s:sub(i + 1, j - 1)
      i = j + 1
    elseif c == '"' then
      local j = i + 1
      local part = {}
      while j <= n do
        local d = s:sub(j, j)
        if d == "\\" and j < n then
          part[#part + 1] = s:sub(j + 1, j + 1)
          j = j + 2
        elseif d == '"' then
          break
        else
          part[#part + 1] = d
          j = j + 1
        end
      end
      out[#out + 1] = table.concat(part)
      i = j + 1
    elseif c:match("%s") then
      break
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Команда вызова Bash из командной строки оболочки Claude Code (`… && eval '<команда>'
--- && …`) или nil.
function M.eval_command(cmdline)
  if type(cmdline) ~= "string" then
    return nil
  end
  local i = cmdline:find("eval '", 1, true)
  if not i then
    return nil
  end
  local cmd = shell_word(cmdline, i + 5)
  return cmd ~= "" and cmd or nil
end

-- Каталог процессов: подменяется в тестах.
M.proc_dir = "/proc"

-- Файл каталога процессов целиком: размер у таких файлов — 0, читается до конца порциями.
local function read_proc(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local parts, offset = {}, 0
  while true do
    local chunk = uv.fs_read(fd, 65536, offset)
    if not chunk or chunk == "" then
      break
    end
    parts[#parts + 1] = chunk
    offset = offset + #chunk
  end
  uv.fs_close(fd)
  return table.concat(parts)
end

--- Команда вызова Bash, пишущего в файл `path`: командная строка процесса оболочки, у
--- которого поток вывода направлен в этот файл (Linux, `/proc`). nil — процесс не найден.
function M.process_command(path)
  local fd = uv.fs_scandir(M.proc_dir)
  if not fd then
    return nil
  end
  while true do
    local name = uv.fs_scandir_next(fd)
    if not name then
      return nil
    end
    if name:match("^%d+$") then
      local base = M.proc_dir .. "/" .. name
      -- поток вывода наследуют и дочерние процессы команды: нужен процесс оболочки с `eval`
      if uv.fs_readlink(base .. "/fd/1") == path then
        local raw = read_proc(base .. "/cmdline")
        local cmd = raw and M.eval_command((raw:gsub("%z", " ")))
        if cmd then
          return cmd
        end
      end
    end
  end
end

--- Каталог проекта сессии (каталог, где лежит её транскрипт) или nil.
function M.project_dir(session_id)
  local path = M.find_transcript(session_id)
  return path and fs.dirname(path) or nil
end

-- Строки порции текста (каждая оканчивается переводом строки), без пустых.
local function split_lines(text)
  local lines = {}
  for line in text:gmatch("([^\n]*)\n") do
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

-- Читает строки файла асинхронно порциями, пока `on_lines(lines)` не вернёт true (тогда
-- чтение прекращается) или файл не кончится. `on_done(found)` — один раз после этого, если
-- чтение не отменено (`cancelled()`); `found = false` — файла нет. Дескриптор закрывается
-- при любом исходе.
local function scan_lines(path, on_lines, on_done, cancelled)
  local stop = false
  fs.read_lines_async(fs.tail(path), function(text)
    if stop then
      return
    end
    if on_lines(split_lines(text)) then
      stop = true
      if not (cancelled and cancelled()) then
        on_done(true)
      end
    end
  end, function(found)
    if not stop then
      on_done(found)
    end
  end, function()
    return stop or (cancelled ~= nil and cancelled())
  end)
end

--- Рабочий каталог сессии по первой записи транскрипта с полем `cwd`: `cb(cwd|nil)` после
--- асинхронного чтения (чтение останавливается на найденной записи; отмена — без вызова).
function M.session_cwd(path, cb, cancelled)
  local cwd
  scan_lines(path, function(lines)
    cwd = parse.cwd(lines)
    return cwd ~= nil
  end, function()
    cb(cwd)
  end, cancelled)
end

--- Реплики диалога транскрипта по порядку записи, асинхронно порциями: `on_replies(replies)`
--- получает реплики каждой порции (пустые порции пропускаются), `on_done(found)` — после
--- конца файла; `found = false` — файла нет (`unavailable`). Отмена — `cancelled()`: чтение
--- прекращается без дальнейших вызовов.
function M.read_dialogue(path, on_replies, on_done, cancelled)
  fs.read_lines_async(fs.tail(path), function(text)
    local replies = parse.replies(split_lines(text))
    if #replies > 0 then
      on_replies(replies)
    end
  end, on_done, cancelled)
end

-- Текст первой реплики пользователя транскрипта (чтение до неё): `cb(text|nil)`.
local function first_user_text(path, cb, cancelled)
  local text
  scan_lines(path, function(lines)
    text = parse.first_user_text(lines)
    return text ~= nil
  end, function()
    cb(text)
  end, cancelled)
end

--- Сессии каталога проекта — существующие файлы `<id>.jsonl`, асинхронно: `on_done(list)`,
--- `list = { {id, path, mtime (секунды), first_user_text|nil}, … }`, новые первыми.
--- Начала первых реплик читаются по одному файлу за раз. Отмена — `cancelled()`: без вызова.
function M.list_sessions(project_dir, on_done, cancelled)
  local out = {}
  for _, e in ipairs(fs.list_dir(project_dir)) do
    local id = e.type == "file" and e.name:match("^(.+)%.jsonl$")
    if id then
      local path = project_dir .. "/" .. e.name
      local st = uv.fs_stat(path)
      if st then
        out[#out + 1] = { id = id, path = path, mtime = st.mtime.sec }
      end
    end
  end
  local i = 0
  local function sorted()
    table.sort(out, function(a, b)
      if a.mtime ~= b.mtime then
        return a.mtime > b.mtime
      end
      return a.id < b.id
    end)
    on_done(out)
  end
  local function nextfile()
    i = i + 1
    local s = out[i]
    if not s then
      sorted()
      return
    end
    first_user_text(s.path, function(text)
      s.first_user_text = text
      nextfile()
    end, cancelled)
  end
  -- первое чтение — отдельным шагом цикла: вызов возвращается до чтения
  vim.schedule(function()
    if not (cancelled and cancelled()) then
      nextfile()
    end
  end)
end

--- Ожидание создания транскрипта: наблюдает `projects/` (или ближайший существующий предок)
--- и каждый каталог проекта; `cb(path)` — один раз, когда `<id>.jsonl` найден. Возвращает
--- объект с `close()`.
function M._locate(session_id, cb)
  local L = { closed = false, dirs = {} }
  if not valid_id(session_id) then
    L.closed = true
    L.close = function() end
    return L
  end
  local name = session_id .. ".jsonl"
  local projects = projects_dir()

  function L.close()
    if L.closed then
      return
    end
    L.closed = true
    for _, w in pairs(L.dirs) do
      if w then
        w.close()
      end
    end
    if L.projects_watch then
      L.projects_watch.close()
    end
    if L.wait then
      L.wait.close()
    end
  end

  local function check(dir)
    if L.closed then
      return
    end
    local path = dir .. "/" .. name
    if fs.is_file(path) then
      L.close()
      cb(path)
    end
  end

  local function watch_project(dir)
    if L.closed or L.dirs[dir] ~= nil then
      return
    end
    L.dirs[dir] = fs.watch(dir, function(filename)
      if filename == nil or filename == name then
        check(dir)
      end
    end) or false
    check(dir)
  end

  local function scan()
    for _, e in ipairs(fs.list_dir(projects)) do
      if L.closed then
        return
      end
      if e.type == "directory" then
        watch_project(projects .. "/" .. e.name)
      end
    end
  end

  L.wait = fs.wait_path(projects, function()
    if L.closed then
      return
    end
    L.projects_watch = fs.watch(projects, function(filename)
      if filename == nil then
        scan()
      elseif fs.is_dir(projects .. "/" .. filename) then
        watch_project(projects .. "/" .. filename)
      end
    end)
    scan()
  end)
  return L
end

--- Путь транскрипта субагента `agent_id` сессии `session_id` или nil, если транскрипт
--- сессии не найден. Файл субагента может ещё не существовать.
function M.subagent_transcript(session_id, agent_id)
  if not valid_id(agent_id) then
    return nil
  end
  local path = M.find_transcript(session_id)
  if not path then
    return nil
  end
  return path:sub(1, -7) .. "/subagents/agent-" .. agent_id .. ".jsonl"
end

--- Следит за диалогом транскрипта: аргумент — идентификатор сессии (транскрипт ищется,
--- при отсутствии — ожидается его создание) или путь файла. `on_replies(replies)` получает
--- сначала уже записанные реплики, затем новые по мере записи. Возвращает handle с `close()`.
function M.watch_dialogue(session_id_or_path, on_replies)
  local h = { closed = false }

  local function attach(path)
    if h.closed then
      return
    end
    h.path = path
    local tail = fs.tail(path)
    local name = fs.basename(path)
    local dir = fs.dirname(path)
    -- Чтение асинхронное, порциями, по одному за раз (`h.reading`); уведомление во время
    -- чтения вызывает ещё одно чтение после текущего.
    local again = false
    local function pump()
      if h.closed then
        return
      end
      if h.reading then
        again = true
        return
      end
      h.reading, again = true, false
      fs.read_lines_async(tail, function(text)
        local lines = {}
        for line in text:gmatch("([^\n]*)\n") do
          if line ~= "" then
            lines[#lines + 1] = line
          end
        end
        local replies = parse.replies(lines)
        if #replies > 0 then
          on_replies(replies)
        end
      end, function()
        h.reading = false
        if again then
          pump()
        end
      end, function()
        return h.closed
      end)
    end
    h.wait = fs.wait_path(dir, function()
      if h.closed then
        return
      end
      h.watch = fs.watch(dir, function(filename)
        if filename == nil or filename == name then
          pump()
        end
      end)
      -- уже записанное отдаётся отдельным шагом цикла, после возврата handle
      h.reading = true
      vim.schedule(function()
        h.reading = false
        pump()
      end)
    end)
  end

  function h:close()
    if h.closed then
      return
    end
    h.closed = true
    for _, k in ipairs({ "locator", "wait", "watch" }) do
      if h[k] then
        h[k].close()
        h[k] = nil
      end
    end
  end

  local arg = session_id_or_path
  if type(arg) == "string" and arg:find("/", 1, true) then
    attach(arg)
  else
    local path = M.find_transcript(arg)
    if path then
      attach(path)
    elseif valid_id(arg) then
      h.locator = M._locate(arg, attach)
    end
  end
  return h
end

--- Следит за сессией: транскрипт владельца, субагенты, фоновые команды. Транскрипты
--- читаются асинхронно: `handle:state()` до конца первого чтения (`handle:loaded()`) отдаёт
--- состояние без субагентов и команд; `on_change(state)` вызывается при каждом изменении
--- состояния — после первого чтения, по уведомлениям файловой системы и по
--- `set_owner_alive`. Подробности — claudr.data.session.
function M.watch_session(session_id, on_change)
  return require("claudr.data.session").new(M, session_id, on_change)
end

--- Следит за файлом вывода фоновой команды или вызова Bash: `on_text(chunk)` получает сначала
--- уже записанное (асинхронно, порциями), затем дописанные куски с запомненного смещения;
--- `on_gone()` — один раз, когда файл удалён. Файла нет — `nil, "unavailable"` (каталог
--- временный; статус и код выхода по-прежнему даёт watch_session).
function M.watch_output(path, on_text, on_gone)
  if type(path) ~= "string" or not fs.is_file(path) then
    return nil, "unavailable"
  end
  local h = { closed = false }
  local tail = fs.tail(path)
  -- Чтение по одному за раз; уведомление во время чтения вызывает ещё одно после него.
  local again = false
  local function pump()
    if h.closed then
      return
    end
    if h.reading then
      again = true
      return
    end
    h.reading, again = true, false
    fs.read_chunks_async(tail, on_text, function()
      h.reading = false
      if again then
        pump()
      end
    end, function()
      return h.closed
    end)
  end
  -- наблюдается сам файл: вывод фонового субагента — символьная ссылка на его транскрипт,
  -- уведомления приходят по файлу, на который она указывает
  h.watch = fs.watch(path, function()
    if on_gone and not h.gone and not uv.fs_stat(path) then
      -- файл удалён: вызов Bash не в фоне завершился, временный каталог очищен
      h.gone = true
      on_gone()
      return
    end
    pump()
  end)
  function h:close()
    if not h.closed then
      h.closed = true
      if h.watch then
        h.watch.close()
      end
    end
  end
  vim.schedule(pump)
  return h
end

return M
