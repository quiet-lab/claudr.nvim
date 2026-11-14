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

--- Каталог проекта сессии (каталог, где лежит её транскрипт) или nil.
function M.project_dir(session_id)
  local path = M.find_transcript(session_id)
  return path and fs.dirname(path) or nil
end

--- Реплики диалога транскрипта по порядку записи: `{ {role = "user"|"assistant", text}, … }`;
--- файла нет — `nil, "unavailable"`.
function M.read_dialogue(path)
  local t = fs.tail(path)
  local lines = fs.read_lines(t)
  if not lines then
    return nil, "unavailable"
  end
  return parse.replies(lines)
end

-- Текст первой реплики пользователя транскрипта (чтение до неё) или nil.
local function first_user_text(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text
  for line in f:lines() do
    local rec = parse.decode(line)
    local r = rec and parse.reply(rec)
    if r and r.role == "user" then
      text = r.text
      break
    end
  end
  f:close()
  return text
end

--- Сессии каталога проекта — существующие файлы `<id>.jsonl`:
--- `{ {id, path, mtime (секунды), first_user_text|nil}, … }`, новые первыми.
function M.list_sessions(project_dir)
  local out = {}
  for _, e in ipairs(fs.list_dir(project_dir)) do
    local id = e.type == "file" and e.name:match("^(.+)%.jsonl$")
    if id then
      local path = project_dir .. "/" .. e.name
      local st = uv.fs_stat(path)
      if st then
        out[#out + 1] = {
          id = id,
          path = path,
          mtime = st.mtime.sec,
          first_user_text = first_user_text(path),
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return a.id < b.id
  end)
  return out
end

--- Ожидание создания транскрипта: наблюдает `projects/` (или ближайший существующий предок)
--- и каждый каталог проекта; `cb(path)` — один раз, когда `<id>.jsonl` найден. Возвращает
--- объект с `close()`.
function M._locate(session_id, cb)
  local L = { closed = false, dirs = {} }
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
    local function pump()
      if h.closed then
        return
      end
      local lines = fs.read_lines(tail)
      if lines and #lines > 0 then
        local replies = parse.replies(lines)
        if #replies > 0 then
          on_replies(replies)
        end
      end
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
      vim.schedule(pump)
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

--- Следит за сессией: транскрипт владельца, субагенты, фоновые команды. Состояние доступно
--- сразу (`handle:state()`), `on_change(state)` вызывается при каждом изменении состояния по
--- уведомлениям файловой системы и по `set_owner_alive`. Подробности — claudr.data.session.
function M.watch_session(session_id, on_change)
  return require("claudr.data.session").new(M, session_id, on_change)
end

--- Следит за файлом вывода фоновой команды: `on_text(chunk)` получает сначала уже записанное,
--- затем дописанные куски с запомненного смещения. Файла нет — `nil, "unavailable"`
--- (каталог временный; статус и код выхода по-прежнему даёт watch_session).
function M.watch_output(path, on_text)
  if type(path) ~= "string" or not fs.is_file(path) then
    return nil, "unavailable"
  end
  local h = { closed = false }
  local tail = fs.tail(path)
  local function pump()
    if h.closed then
      return
    end
    local chunk = fs.read_chunk(tail)
    if chunk and chunk ~= "" then
      on_text(chunk)
    end
  end
  -- наблюдается сам файл: вывод фонового субагента — символьная ссылка на его транскрипт,
  -- уведомления приходят по файлу, на который она указывает
  h.watch = fs.watch(path, function()
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
