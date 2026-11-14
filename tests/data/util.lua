-- Общие помощники тестов модуля данных Claude Code.
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")

local M = {}

--- Свежий каталог данных Claude Code для теста: задаёт CLAUDE_CONFIG_DIR и ставит образцы.
function M.fresh(samples)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.uv.os_setenv("CLAUDE_CONFIG_DIR", dir)
  if samples then
    fixtures.install(samples, dir)
  end
  return dir
end

--- Ожидание события цикла Neovim до выполнения условия (без срока).
function M.wait(cond, msg)
  t.wait(cond, msg)
end

--- Даёт циклу обработать уже пришедшие уведомления: собственное наблюдение теста за
--- отдельным каталогом получает событие о записанном файле, затем выполняется отложенный
--- шаг `vim.schedule`. Срока нет: ожидание идёт до этих событий.
function M.settle()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local handle = vim.uv.new_fs_event()
  local fired = false
  handle:start(dir, {}, function()
    fired = true
  end)
  local f = assert(io.open(dir .. "/mark", "w"))
  f:write("x")
  f:close()
  t.wait(function()
    return fired
  end, "событие собственного наблюдения")
  handle:stop()
  handle:close()
  local done = false
  vim.schedule(function()
    done = true
  end)
  t.wait(function()
    return done
  end, "отложенный шаг цикла")
end

--- Слежение за сессией (`claudr.data.watch_session`) с ожиданием конца первого чтения
--- транскриптов: чтение асинхронное, состояние полно после `loaded()`. `on_change`
--- получает только изменения после первого чтения.
function M.watch_session(session_id, on_change)
  local ready = false
  local h = require("claudr.data").watch_session(session_id, function(s)
    if ready and on_change then
      on_change(s)
    end
  end)
  t.wait(function()
    return h:loaded()
  end, "первое чтение транскриптов сессии")
  ready = true
  return h
end

--- Считает вызовы `vim.uv.fs_open` и `vim.uv.fs_read` (чтения файлов) до `restore()`.
function M.count_reads()
  local counter = { open = 0, read = 0, paths = {} }
  local orig_open, orig_read = vim.uv.fs_open, vim.uv.fs_read
  vim.uv.fs_open = function(path, ...)
    counter.open = counter.open + 1
    counter.paths[#counter.paths + 1] = path
    return orig_open(path, ...)
  end
  vim.uv.fs_read = function(...)
    counter.read = counter.read + 1
    return orig_read(...)
  end
  function counter.restore()
    vim.uv.fs_open, vim.uv.fs_read = orig_open, orig_read
  end
  return counter
end

--- Записи запуска фоновой команды Bash: вызов `tool_use` и результат с идентификатором задачи
--- и путём файла вывода (как в транскрипте субагента — без `toolUseResult`).
function M.bash_launch(session_id, tool_id, task_id, command, output_file)
  local call = fixtures.assistant_record(session_id, "")
  call.message.content = {
    {
      type = "tool_use",
      id = tool_id,
      name = "Bash",
      input = { command = command, description = "test command", run_in_background = true },
    },
  }
  local result = fixtures.user_record(session_id, "")
  result.message.content = {
    {
      tool_use_id = tool_id,
      type = "tool_result",
      content = "Command running in background with ID: "
        .. task_id
        .. ". Output is being written to: "
        .. output_file
        .. ". You will be notified when it completes.",
    },
  }
  return { call, result }
end

--- Запись `attachment` `queued_command` с блоком уведомления (доставка посреди хода).
function M.attachment_record(session_id, block)
  return {
    type = "attachment",
    isSidechain = false,
    sessionId = session_id,
    timestamp = "2026-11-14T06:00:11.000Z",
    attachment = {
      type = "queued_command",
      prompt = block,
      commandMode = "task-notification",
      origin = { kind = "task-notification", producer = "session-task" },
    },
  }
end

--- Запись `user` с блоком уведомления (доставка на простое сессии).
function M.notification_user_record(session_id, block)
  local r = fixtures.user_record(session_id, block)
  r.origin = { kind = "task-notification" }
  return r
end

--- Сохраняет первые строки образца (до первой строки, содержащей `stop_at`) в новый файл
--- транскрипта и возвращает остальные строки.
function M.split_transcript(path, stop_at)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  local head, rest = {}, {}
  for line in text:gmatch("[^\n]+") do
    if #rest == 0 and not line:find(stop_at, 1, true) then
      head[#head + 1] = line
    else
      rest[#rest + 1] = line
    end
  end
  f = assert(io.open(path, "wb"))
  f:write(table.concat(head, "\n") .. "\n")
  f:close()
  return rest
end

--- Записи вызова инструмента `name`, который учёт не разбирает, и его результата с
--- содержимым `size` байт: строки, которые отбор строк учёта пропускает.
function M.filler_records(session_id, n, name, size)
  local call = fixtures.assistant_record(session_id, "")
  local id = string.format("toolu_01FixtureFiller%08d", n)
  call.message.content = {
    { type = "tool_use", id = id, name = name, input = { file_path = "/srv/demo/alpha/f" .. n } },
  }
  local result = fixtures.user_record(session_id, "")
  result.message.content = {
    { tool_use_id = id, type = "tool_result", content = string.rep("x", size) },
  }
  return { call, result }
end

--- Синтетический транскрипт для проверок асинхронного чтения: в начале запуск фоновой
--- команды `bbig0001`, затем `count` пар заполнителей по `size` байт, в конце уведомление
--- о завершении команды с кодом выхода 0. Пишется в `path` (файл заменяется).
function M.big_transcript(path, session_id, count, size)
  local f = assert(io.open(path, "w"))
  local function put(records)
    for _, r in ipairs(records) do
      f:write(vim.json.encode(r), "\n")
    end
  end
  put(
    M.bash_launch(session_id, "toolu_01FixtureBig000000000001", "bbig0001", "sleep 1", "/x.output")
  )
  for i = 1, count do
    put(M.filler_records(session_id, i, i % 2 == 0 and "Read" or "Bash", size))
  end
  put({
    M.notification_user_record(
      session_id,
      fixtures.notification_block({
        task_id = "bbig0001",
        tool_use_id = "toolu_01FixtureBig000000000001",
        status = "completed",
        summary = 'Background command "sleep 1" completed (exit code 0)',
      })
    ),
  })
  f:close()
end

--- Число запущенных таймеров цикла libuv.
function M.timer_count()
  local n = 0
  vim.uv.walk(function(h)
    if vim.uv.handle_get_type(h) == "timer" and h:is_active() then
      n = n + 1
    end
  end)
  return n
end

--- Число открытых наблюдений fs_event.
function M.fs_event_count()
  local n = 0
  vim.uv.walk(function(h)
    if vim.uv.handle_get_type(h) == "fs_event" and not h:is_closing() then
      n = n + 1
    end
  end)
  return n
end

return M
