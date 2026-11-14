-- Модуль данных Claude Code: фоновые команды, их завершение и остановка, команды субагентов,
-- задачи наблюдения, файлы вывода (спецификация claude-code-data).
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")

local function watch(sample, extra)
  local dir = u.fresh(extra or sample)
  local changes = { n = 0 }
  local h = data.watch_session(fixtures.session_id(sample), function(s)
    changes.n = changes.n + 1
    changes.last = s
  end)
  return h, changes, dir
end

local function output_path(sample, task_id, dir)
  return fixtures.tasks_dir(sample, dir) .. "/" .. task_id .. ".output"
end

describe("Запуск фоновой команды", function()
  it("Команда субагента", function()
    local h = watch("subagent-command")
    local task = h:state().tasks.bfixt0007
    t.eq(task.owner, "a0000000000000004")
    t.eq(task.command, "sleep 4; echo from-sub ; exit 2")
    t.eq(task.description, "Run background sleep and exit with code 2")
    t.eq(task.monitor, false)
    h:close()
  end)

  it("Результат вызова", function()
    local h, _, dir = watch("command-failed")
    local task = h:state().tasks.bfixt0002
    t.eq(task.id, "bfixt0002")
    t.eq(task.owner, nil, "команда сессии")
    t.eq(task.command, "sleep 3; echo failing; exit 3")
    t.eq(task.output_file, output_path("command-failed", "bfixt0002", dir))
    t.eq(task.tool_use_id, "toolu_01Fixture000000000000002")
    h:close()
  end)

  it("вызов без run_in_background командой не считается", function()
    local h = watch("command-failed")
    -- в образце есть обычный вызов Bash (cat файла вывода) — он не фоновая команда
    t.eq(vim.tbl_keys(h:state().tasks), { "bfixt0002" })
    h:close()
  end)
end)

describe("Завершение фоновой команды", function()
  it("Команда завершилась", function()
    local h = watch("command-completed")
    local task = h:state().tasks.bfixt0005
    t.eq(task.status, "finished")
    t.eq(task.result, "completed")
    t.eq(task.exit_code, 0)
    h:close()
  end)

  it("Ненулевой код выхода", function()
    local h = watch("command-failed")
    local task = h:state().tasks.bfixt0002
    t.eq(task.status, "finished")
    t.eq(task.result, "failed")
    t.eq(task.exit_code, 3)
    h:close()
  end)

  it("Одно завершение в нескольких записях", function()
    local h, changes, dir = watch("command-orphaned")
    local sid = fixtures.session_id("command-orphaned")
    t.eq(h:state().tasks.bfixt0005.status, "running")
    local block = fixtures.notification_block({
      task_id = "bfixt0005",
      tool_use_id = "toolu_01Fixture000000000000001",
      output_file = output_path("command-orphaned", "bfixt0005", dir),
      status = "completed",
      summary = 'Background command "x" completed (exit code 0)',
    })
    local path = fixtures.transcript("command-orphaned")
    -- queue-operation и user
    fixtures.append(path, {
      fixtures.queue_record(sid, "enqueue", block),
      u.notification_user_record(sid, block),
    })
    u.wait(function()
      return changes.n > 0
    end, "отметка завершения")
    local first = vim.deepcopy(h:state())
    t.eq(first.tasks.bfixt0005.result, "completed")
    t.eq(vim.tbl_count(first.tasks), 1)
    -- attachment и queue-operation remove с тем же блоком
    local n = changes.n
    fixtures.append(path, {
      u.attachment_record(sid, block),
      fixtures.queue_record(sid, "remove", block),
    })
    u.settle()
    t.eq(
      changes.n,
      n,
      "повторная запись завершения не меняет состояние"
    )
    t.eq(h:state(), first)
    -- в образцах: enqueue + user и attachment + remove
    for _, sample in ipairs({ "command-completed", "command-failed" }) do
      local hs = watch(sample)
      local tasks = hs:state().tasks
      t.eq(vim.tbl_count(tasks), 1, sample)
      t.eq(select(2, next(tasks)).status, "finished", sample)
      hs:close()
    end
    h:close()
  end)

  it("Уведомление посреди хода", function()
    local h, changes, dir = watch("command-orphaned")
    local sid = fixtures.session_id("command-orphaned")
    local block = fixtures.notification_block({
      task_id = "bfixt0005",
      tool_use_id = "toolu_01Fixture000000000000001",
      output_file = output_path("command-orphaned", "bfixt0005", dir),
      status = "failed",
      summary = 'Background command "x" failed with exit code 5',
    })
    fixtures.append(fixtures.transcript("command-orphaned"), { u.attachment_record(sid, block) })
    u.wait(function()
      return changes.n > 0
    end, "отметка из вложения")
    local task = h:state().tasks.bfixt0005
    t.eq(task.result, "failed")
    t.eq(task.exit_code, 5)
    h:close()
  end)

  it("Чужое уведомление", function()
    local h, changes = watch("command-completed")
    local sid = fixtures.session_id("command-completed")
    local before = vim.deepcopy(h:state())
    local block = fixtures.notification_block({
      task_id = "bunknown1",
      tool_use_id = "toolu_01FixtureUnknown0000000",
      status = "completed",
      summary = 'Background command "y" completed (exit code 0)',
    })
    fixtures.append(fixtures.transcript("command-completed"), {
      fixtures.queue_record(sid, "enqueue", block),
      u.notification_user_record(sid, block),
    })
    u.settle()
    t.eq(changes.n, 0)
    t.eq(h:state(), before)
    h:close()
  end)
end)

describe("Остановка фоновой команды", function()
  it("Команда остановлена", function()
    local h = watch("command-taskstop")
    local task = h:state().tasks.bfixt0004
    t.eq(task.command, "sleep 600")
    t.eq(task.status, "finished")
    t.eq(task.result, "killed")
    t.eq(task.exit_code, nil)
    h:close()
  end)
end)

describe("Команда, запущенная субагентом", function()
  it("Завершение команды субагента", function()
    local h, _, dir = watch("subagent-command")
    local task = h:state().tasks.bfixt0007
    t.eq(task.owner, "a0000000000000004")
    t.eq(task.result, "failed")
    t.eq(task.exit_code, 2)
    t.eq(task.output_file, output_path("subagent-command", "bfixt0007", dir))
    h:close()
  end)

  it("завершение только из транскрипта родителя", function()
    local dir = u.fresh("subagent-command")
    -- у субагента остаётся только запуск: вложение с уведомлением убрано
    local sub = fixtures.session_dir("subagent-command", dir)
      .. "/subagents/agent-a0000000000000004.jsonl"
    u.split_transcript(sub, "<task-notification>")
    local h = data.watch_session(fixtures.session_id("subagent-command"), function() end)
    local task = h:state().tasks.bfixt0007
    t.eq(task.owner, "a0000000000000004")
    t.eq(task.result, "failed")
    h:close()
  end)
end)

describe("Задача наблюдения", function()
  it("Промежуточное уведомление", function()
    u.fresh("monitor")
    local path = fixtures.transcript("monitor")
    local rest = u.split_transcript(path, "<status>")
    local changes = 0
    local h = data.watch_session(fixtures.session_id("monitor"), function()
      changes = changes + 1
    end)
    local task = h:state().tasks.bfixt0001
    t.eq(task.monitor, true)
    t.eq(task.command, "for i in 1 2 3; do echo tick $i; sleep 1; done")
    t.eq(
      task.status,
      "running",
      "после промежуточных уведомлений задача работает"
    )
    t.eq(task.result, nil)
    local sid = fixtures.session_id("monitor")
    local block = fixtures.notification_block({
      task_id = "bfixt0001",
      summary = 'Monitor event: "ticks"',
      event = "tick 4",
    })
    fixtures.append(path, {
      fixtures.queue_record(sid, "enqueue", block),
      u.notification_user_record(sid, block),
    })
    u.settle()
    t.eq(changes, 0)
    t.eq(h:state().tasks.bfixt0001.status, "running")
    -- остаток образца содержит итоговое уведомление
    fixtures.append(path, rest)
    u.wait(function()
      return changes > 0
    end, "итоговое уведомление")
    t.eq(h:state().tasks.bfixt0001.status, "finished")
    h:close()
  end)

  it("Итоговое уведомление", function()
    local h, _, dir = watch("monitor")
    local task = h:state().tasks.bfixt0001
    t.eq(task.status, "finished")
    t.eq(task.result, "completed")
    t.eq(task.output_file, output_path("monitor", "bfixt0001", dir))
    h:close()
  end)
end)

describe("Файл вывода фоновой команды", function()
  it("Дописывание вывода", function()
    local h, _, dir = watch("command-survived")
    local path = h:state().tasks.bfixt0008.output_file
    t.eq(path, output_path("command-survived", "bfixt0008", dir))
    local f = assert(io.open(path, "rb"))
    local initial = f:read("*a")
    f:close()
    local got = {}
    local out = assert(data.watch_output(path, function(chunk)
      got[#got + 1] = chunk
    end))
    u.wait(function()
      return #got == 1
    end, "уже записанный вывод")
    t.eq(got[1], initial)
    f = assert(io.open(path, "a"))
    f:write("line 9\n")
    f:close()
    u.wait(function()
      return #got == 2
    end, "дописанная строка")
    t.eq(got[2], "line 9\n")
    out:close()
    h:close()
  end)

  it(
    "вывод фонового субагента — символьная ссылка на его транскрипт",
    function()
      local dir = u.fresh("subagent-background")
      local link = output_path("subagent-background", "a0000000000000003", dir)
      t.eq(vim.uv.fs_lstat(link).type, "link")
      local got = {}
      local out = assert(data.watch_output(link, function(chunk)
        got[#got + 1] = chunk
      end))
      u.wait(function()
        return #got == 1
      end, "уже записанный вывод")
      local sub = fixtures.session_dir("subagent-background", dir)
        .. "/subagents/agent-a0000000000000003.jsonl"
      fixtures.append(sub, { "{}" })
      u.wait(function()
        return #got == 2
      end, "дописанный транскрипт субагента")
      t.eq(got[2], "{}\n")
      out:close()
    end
  )

  it("Файла нет", function()
    local h = watch("command-completed")
    local task = h:state().tasks.bfixt0005
    t.eq(task.result, "completed")
    t.eq(task.exit_code, 0)
    t.ok(task.output_file)
    t.ok(not vim.uv.fs_stat(task.output_file), "файла вывода в образце нет")
    local out, err = data.watch_output(task.output_file, function() end)
    t.eq(out, nil)
    t.eq(err, "unavailable")
    h:close()
  end)
end)
