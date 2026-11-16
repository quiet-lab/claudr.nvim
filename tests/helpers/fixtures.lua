-- Образцы данных Claude Code для тестов: обезличенные копии записей, наблюдавшихся на
-- Claude Code 2.1.325 (spec-checks.md, раздел Б). Образец — каталог в tests/fixtures/claude/,
-- устроенный как каталог данных Claude Code плюс каталог временных файлов сессий:
--   projects/<проект>/<сессия>.jsonl            транскрипт владельца
--   projects/<проект>/<сессия>/subagents/…      субагенты: agent-<id>.jsonl + agent-<id>.meta.json
--   tmp/<проект>/<сессия>/tasks/<id>.output     файлы вывода фоновых команд
-- Пути внутри записей — метки: @CLAUDE@ (каталог данных, куда ставится образец) и @TMP@
-- (каталог временных файлов, `<каталог данных>/tmp`); `install` подставляет их.
-- Проект везде один — каталог `-srv-demo-alpha` (рабочий каталог /srv/demo/alpha).
--
-- Перечень образцов (имя — назначение):
--   owner-dialogue       транскрипт владельца: реплики пользователя и агента, служебные записи
--                        (queue-operation, attachment, last-prompt, cost-state, mode, …)
--   command-completed    фоновая команда, завершилась кодом 0: queue-operation enqueue + user
--                        с <task-notification>; файла вывода нет
--   command-failed       фоновая команда, status failed, код 3: уведомление посреди хода —
--                        attachment queued_command + queue-operation remove absorbed_mid_turn;
--                        файл вывода есть
--   command-survived     команда пережила ход (второй ход после уведомления): enqueue + user;
--                        файл вывода есть
--   command-taskstop     команда остановлена TaskStop: результат с task_id, уведомления нет
--   command-orphaned     запуск команды и ничего больше (владелец убит); файл вывода пуст
--   monitor              задача Monitor: промежуточные уведомления без status и tool-use-id,
--                        итоговое со status; файл вывода есть
--   subagent-command     завершённый субагент на переднем плане (finished) с фоновой командой:
--                        вызов в транскрипте субагента, уведомление failed (код 2) у родителя
--                        (enqueue + remove) и attachment у субагента; файлы вывода
--   subagent-background  фоновый субагент (requestShape background, finished), уведомление
--                        completed у родителя; файл вывода субагента — символьная ссылка на его
--                        транскрипт; плюс фоновая команда без отметок
--   subagent-stopped     остановленный фоновый субагент: meta без finished, последняя запись
--                        «[Request interrupted by user]», у родителя уведомление killed
--   subagent-nested      вложенные субагенты: внешний и внутренний (parentAgentId, spawnDepth 2),
--                        оба finished
--   owner-killed         владелец убит принудительно при работающем субагенте: meta без finished,
--                        уведомлений нет
--   subagent-extra-files НАЛОЖЕНИЕ на сессию subagent-command (ставится вместе с ней): посторонние
--                        *.forked-skill.json, *.forked-skill.marker.json, каталог workflows/wf_<id>/
--                        с журналами и вложенными каталогами (в том числе похожая на субагента пара)
--   unknown-records      неизвестные виды записей, поля и значения, повреждённая строка транскрипта;
--                        субагент с неизвестным полем meta и посторонними файлами и каталогом
--   session-moved        сессия сменила каталог: транскрипт в каталоге проекта alpha, cwd записей
--                        — другой
--   history-project      проект для истории: три сессии в alpha (разные времена, первая реплика
--                        пользователя, одна длинная) и одна сессия в другом проекте beta
--   no-transcript        проект есть, транскрипта сессии `fixtures.missing_session_id` нет
--
-- Дополнения к договорённости плана: `catalog`, `history`, `session_id`, `transcript`,
-- `session_dir`, `tasks_dir`, `records`, `user_record`, `assistant_record`,
-- `notification_block`, `queue_record`, `missing_session_id`, `project`, `cwd`.
local M = {}

M.project = "-srv-demo-alpha"
M.cwd = "/srv/demo/alpha"
M.missing_session_id = "00000000-0000-4000-8000-0000000000ff"

--- Имя образца → назначение (кратко); полное описание — в комментарии выше.
M.catalog = {
  ["owner-dialogue"] = "транскрипт владельца с репликами и служебными записями",
  ["command-completed"] = "фоновая команда, код 0, enqueue + user, файла вывода нет",
  ["command-failed"] = "фоновая команда, failed код 3, attachment + remove, файл вывода",
  ["command-survived"] = "команда пережила ход, enqueue + user, файл вывода",
  ["command-taskstop"] = "остановка TaskStop без уведомления",
  ["command-orphaned"] = "команда без отметок, владелец убит",
  ["monitor"] = "задача Monitor: промежуточные и итоговое уведомления",
  ["subagent-command"] = "завершённый субагент с фоновой командой",
  ["subagent-background"] = "фоновый субагент, ссылка вывода, команда без отметок",
  ["subagent-stopped"] = "остановленный фоновый субагент (killed)",
  ["subagent-nested"] = "вложенные субагенты (parentAgentId)",
  ["owner-killed"] = "владелец убит, субагент без finished",
  ["subagent-extra-files"] = "наложение: посторонние файлы и workflows/",
  ["unknown-records"] = "неизвестные записи и поля, повреждённая строка",
  ["session-moved"] = "cwd записей не совпадает с каталогом проекта",
  ["history-project"] = "несколько сессий в двух проектах",
  ["no-transcript"] = "проект без транскрипта известной сессии",
}

--- Постоянные идентификаторы сессий образца history-project (остальные — `session_id`).
M.history = {
  alpha = {
    "00000000-0000-4000-8000-000000000021",
    "00000000-0000-4000-8000-000000000022",
    "00000000-0000-4000-8000-000000000023",
  },
  beta = "00000000-0000-4000-8000-000000000024",
}

local source_root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/tests/helpers/[^/]*$")
M.source = source_root .. "/tests/fixtures/claude"

local function config_dir()
  local dir = vim.uv.os_getenv("CLAUDE_CONFIG_DIR")
  assert(dir and dir ~= "", "CLAUDE_CONFIG_DIR не задан")
  return dir
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

local function plain_replace(s, from, to)
  local out, pos = {}, 1
  while true do
    local a, b = s:find(from, pos, true)
    if not a then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    out[#out + 1] = to
    pos = b + 1
  end
  return table.concat(out)
end

local function substitute(s, dest)
  s = plain_replace(s, "@CLAUDE@", dest)
  return plain_replace(s, "@TMP@", dest .. "/tmp")
end

-- дни от 1970-01-01 по гражданской дате (без зависимости от часового пояса)
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function epoch(ts)
  local y, mo, d, h, mi, s = ts:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600
    + tonumber(mi) * 60
    + tonumber(s)
end

--- Время последней записи транскрипта (секунды эпохи) или nil.
local function last_timestamp(data)
  local last
  for ts in data:gmatch('"timestamp":"([^"]+)"') do
    last = ts
  end
  return last and epoch(last) or nil
end

local function copy_tree(src, dest)
  vim.fn.mkdir(dest, "p")
  local entries = {}
  for name, kind in vim.fs.dir(src, { depth = math.huge }) do
    entries[#entries + 1] = { name = name, kind = kind }
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  for _, e in ipairs(entries) do
    local from, to = src .. "/" .. e.name, dest .. "/" .. e.name
    if e.kind == "directory" then
      vim.fn.mkdir(to, "p")
    elseif e.kind == "link" then
      local target = assert(vim.uv.fs_readlink(from))
      vim.fn.mkdir(vim.fs.dirname(to), "p")
      vim.uv.fs_unlink(to)
      assert(vim.uv.fs_symlink(substitute(target, dest), to))
    else
      vim.fn.mkdir(vim.fs.dirname(to), "p")
      local data = substitute(read_file(from), dest)
      write_file(to, data)
      if to:match("%.jsonl$") then
        local mtime = last_timestamp(data)
        if mtime then
          vim.uv.fs_utime(to, mtime, mtime)
        end
      end
    end
  end
end

--- Устанавливает образец (или список образцов, по порядку: наложения идут после основных)
--- в `dest` (по умолчанию `$CLAUDE_CONFIG_DIR`); метки путей подставляются. Время изменения
--- `.jsonl` ставится равным времени последней записи. Возвращает `dest`.
function M.install(name_or_list, dest)
  dest = dest or config_dir()
  local list = type(name_or_list) == "table" and name_or_list or { name_or_list }
  for _, name in ipairs(list) do
    assert(M.catalog[name], "неизвестный образец: " .. tostring(name))
    copy_tree(M.source .. "/" .. name, dest)
  end
  -- временный каталог Claude Code образцов (каталоги задач сессий)
  vim.uv.os_setenv("CLAUDR_CLAUDE_TMP", dest .. "/tmp")
  return dest
end

local function first_session_file(sample)
  local dir = M.source .. "/" .. sample .. "/projects/" .. M.project
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.jsonl$") then
      return name
    end
  end
end

--- Идентификатор сессии владельца образца (по имени файла транскрипта).
function M.session_id(sample)
  local name = first_session_file(sample)
  return name and name:sub(1, -7) or nil
end

--- Путь транскрипта образца в `dest` (по умолчанию `$CLAUDE_CONFIG_DIR`).
function M.transcript(sample, dest)
  return string.format(
    "%s/projects/%s/%s.jsonl",
    dest or config_dir(),
    M.project,
    assert(M.session_id(sample))
  )
end

--- Каталог сессии образца (`subagents/` внутри него).
function M.session_dir(sample, dest)
  return string.format(
    "%s/projects/%s/%s",
    dest or config_dir(),
    M.project,
    assert(M.session_id(sample))
  )
end

--- Каталог файлов вывода образца (`tmp/<проект>/<сессия>/tasks`).
function M.tasks_dir(sample, dest)
  return string.format(
    "%s/tmp/%s/%s/tasks",
    dest or config_dir(),
    M.project,
    assert(M.session_id(sample))
  )
end

--- Разбор файла построчно; повреждённые строки пропускаются. Возвращает список записей.
function M.records(path)
  local out = {}
  for line in read_file(path):gmatch("[^\n]+") do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" then
      out[#out + 1] = rec
    end
  end
  return out
end

--- Дописывает записи (таблицы кодируются в JSON, строки пишутся как есть) строками.
function M.append(path, records)
  local f = assert(io.open(path, "a"))
  for _, r in ipairs(records) do
    f:write(type(r) == "string" and r or vim.json.encode(r), "\n")
  end
  f:close()
end

--- Дописывает недописанную строку: текст без перевода строки.
function M.append_partial(path, text)
  local f = assert(io.open(path, "a"))
  f:write(text)
  f:close()
end

local counter = 0
local function next_uuid()
  counter = counter + 1
  return string.format("00000000-0000-4000-9100-%012x", counter)
end

local function envelope(session_id)
  return {
    isSidechain = false,
    userType = "external",
    entrypoint = "sdk-cli",
    cwd = M.cwd,
    sessionId = session_id,
    version = "2.1.325",
    gitBranch = "HEAD",
  }
end

--- Запись `user` (реплика пользователя) в форме транскрипта; `opts.timestamp`, `opts.parent`.
function M.user_record(session_id, text, opts)
  opts = opts or {}
  local r = envelope(session_id)
  r.parentUuid = opts.parent or vim.NIL
  r.type = "user"
  r.message = { role = "user", content = text }
  r.uuid = next_uuid()
  r.timestamp = opts.timestamp or "2026-11-14T06:00:00.000Z"
  r.permissionMode = "default"
  return r
end

--- Запись `assistant` с текстовым ответом.
function M.assistant_record(session_id, text, opts)
  opts = opts or {}
  local r = envelope(session_id)
  r.parentUuid = opts.parent or vim.NIL
  r.type = "assistant"
  r.message = {
    model = "claude-haiku-5-5",
    id = "msg_01Fixture00000000000000000",
    type = "message",
    role = "assistant",
    content = { { type = "text", text = text } },
    stop_reason = "end_turn",
  }
  r.uuid = next_uuid()
  r.timestamp = opts.timestamp or "2026-11-14T06:00:05.000Z"
  return r
end

--- Запись `queue-operation` (`enqueue`, `dequeue`, `remove`); `content` — текст блока.
function M.queue_record(session_id, operation, content, timestamp)
  return {
    type = "queue-operation",
    operation = operation,
    timestamp = timestamp or "2026-11-14T06:00:10.000Z",
    sessionId = session_id,
    content = content,
  }
end

--- Блок `<task-notification>`: поля `task_id`, `tool_use_id`, `output_file`, `status`,
--- `summary`, `event`; пустые поля пропускаются (промежуточное уведомление Monitor).
function M.notification_block(f)
  local lines = { "<task-notification>" }
  local function add(tag, v)
    if v then
      lines[#lines + 1] = string.format("<%s>%s</%s>", tag, v, tag)
    end
  end
  add("task-id", f.task_id)
  add("tool-use-id", f.tool_use_id)
  add("output-file", f.output_file)
  add("status", f.status)
  add("summary", f.summary)
  add("event", f.event)
  lines[#lines + 1] = "</task-notification>"
  return table.concat(lines, "\n")
end

return M
