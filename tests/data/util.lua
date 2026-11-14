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
