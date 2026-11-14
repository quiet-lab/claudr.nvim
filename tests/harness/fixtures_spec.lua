-- Собственные тесты образцов данных Claude Code и помощника tests/helpers/fixtures.lua.
-- Не зависят от кода плагина.
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")

local function fresh()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local d = f:read("*a")
  f:close()
  return d
end

local function files_under(dir)
  local out = {}
  for name, kind in vim.fs.dir(dir, { depth = math.huge }) do
    if kind == "file" or kind == "link" then
      out[#out + 1] = dir .. "/" .. name
    end
  end
  table.sort(out)
  return out
end

local function records_of(path)
  return fixtures.records(path)
end

local function subagent_dir(sample, dest)
  return fixtures.session_dir(sample, dest) .. "/subagents"
end

local function metas(sample, dest)
  local out = {}
  for name, kind in vim.fs.dir(subagent_dir(sample, dest)) do
    local id = kind == "file" and name:match("^agent%-(.+)%.meta%.json$")
    if id then
      out[id] = vim.json.decode(read(subagent_dir(sample, dest) .. "/" .. name))
    end
  end
  return out
end

local function names()
  local out = {}
  for name in pairs(fixtures.catalog) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

local function raw_has(path, needle)
  return read(path):find(needle, 1, true) ~= nil
end

describe("образцы: состав и установка", function()
  it(
    "каждый образец из перечня существует как каталог",
    function()
      for _, name in ipairs(names()) do
        t.ok(vim.fn.isdirectory(fixtures.source .. "/" .. name) == 1, name)
      end
    end
  )

  it("образец без записи в перечне не существует", function()
    for name, kind in vim.fs.dir(fixtures.source) do
      t.ok(kind == "directory" and fixtures.catalog[name], "лишний образец " .. name)
    end
  end)

  it("install подставляет метки путей", function()
    local dest = fresh()
    fixtures.install(names(), dest)
    for _, path in ipairs(files_under(dest)) do
      local stat = vim.uv.fs_lstat(path)
      if stat.type == "file" then
        local data = read(path)
        t.ok(not data:find("@CLAUDE@", 1, true), "метка @CLAUDE@ в " .. path)
        t.ok(not data:find("@TMP@", 1, true), "метка @TMP@ в " .. path)
      end
    end
    local notice = read(fixtures.transcript("command-failed", dest))
    t.ok(
      notice:find(dest .. "/tmp/" .. fixtures.project, 1, true),
      "путь временного каталога"
    )
  end)

  it(
    "install принимает список и по умолчанию ставит в CLAUDE_CONFIG_DIR",
    function()
      fixtures.install({ "owner-dialogue", "command-failed" })
      local dest = vim.uv.os_getenv("CLAUDE_CONFIG_DIR")
      t.ok(vim.uv.fs_stat(fixtures.transcript("owner-dialogue", dest)))
      t.ok(vim.uv.fs_stat(fixtures.transcript("command-failed", dest)))
    end
  )

  it("install отклоняет неизвестное имя образца", function()
    local ok = pcall(fixtures.install, "no-such-sample", fresh())
    t.ok(not ok)
  end)

  it(
    "каждая строка каждого транскрипта разбирается как JSON, кроме намеренно повреждённой",
    function()
      local dest = fresh()
      fixtures.install(names(), dest)
      local bad_total = 0
      for _, path in ipairs(files_under(dest)) do
        if path:match("%.jsonl$") and not path:match("/workflows/") then
          for line in read(path):gmatch("[^\n]+") do
            local ok, rec = pcall(vim.json.decode, line)
            if not ok or type(rec) ~= "table" then
              bad_total = bad_total + 1
              t.eq(
                path,
                fixtures.transcript("unknown-records", dest),
                "повреждённая строка вне unknown-records"
              )
            end
          end
        end
      end
      t.eq(bad_total, 1)
    end
  )

  it("meta.json всех субагентов разбираются как JSON", function()
    local dest = fresh()
    fixtures.install(names(), dest)
    for _, path in ipairs(files_under(dest)) do
      if path:match("%.json$") then
        t.ok(pcall(vim.json.decode, read(path)), path)
      end
    end
  end)

  it(
    "время изменения транскрипта равно времени его последней записи",
    function()
      local dest = fresh()
      fixtures.install("history-project", dest)
      local path = fixtures.source -- только чтобы убедиться, что источник есть
      t.ok(path)
      local prev = 0
      for _, id in ipairs(fixtures.history.alpha) do
        local p = string.format("%s/projects/%s/%s.jsonl", dest, fixtures.project, id)
        local recs = records_of(p)
        local last = recs[#recs].timestamp
        local y, mo, d, h, mi, s = last:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
        local expected = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
        -- os.time трактует поля как местное время; сверяем с поправкой на смещение пояса
        local offset = os.time(os.date("*t", expected)) - os.time(os.date("!*t", expected))
        local mtime = vim.uv.fs_stat(p).mtime.sec
        t.eq(mtime, expected + offset, "mtime " .. id)
        t.ok(mtime > prev, "времена возрастают")
        prev = mtime
      end
    end
  )
end)

describe("образцы: обезличенность", function()
  it(
    "в образцах нет настоящих путей, только метки и вымышленные",
    function()
      local dest = fresh()
      fixtures.install(names(), dest)
      local root = fixtures.source
      for _, path in ipairs(files_under(root)) do
        if vim.uv.fs_lstat(path).type == "file" then
          local data = read(path)
          t.ok(not data:find("/home/", 1, true), "домашний каталог в " .. path)
          t.ok(not data:find("/tmp/", 1, true), "временный каталог в " .. path)
          t.ok(
            not data:find("/run/user", 1, true),
            "каталог выполнения в " .. path
          )
        end
      end
    end
  )

  it("все идентификаторы вымышленные", function()
    for _, path in ipairs(files_under(fixtures.source)) do
      if vim.uv.fs_lstat(path).type == "file" then
        local data = read(path)
        for u in
          data:gmatch("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x")
        do
          t.ok(
            u:find("^00000000%-0000%-4000%-"),
            "идентификатор " .. u .. " в " .. path
          )
        end
        for id in data:gmatch("toolu_(%w+)") do
          t.ok(id:find("^01Fixture"), "toolu_" .. id)
        end
        for id in data:gmatch("msg_(%w+)") do
          t.ok(id:find("^01Fixture"), "msg_" .. id)
        end
        for id in data:gmatch("req_(%w+)") do
          t.ok(id:find("^01Fixture"), "req_" .. id)
        end
      end
    end
  end)
end)

describe("образцы: перечень задачи 1.2", function()
  it(
    "транскрипт владельца содержит реплики пользователя и агента и служебные записи",
    function()
      local dest = fresh()
      fixtures.install("owner-dialogue", dest)
      local kinds = {}
      for _, r in ipairs(records_of(fixtures.transcript("owner-dialogue", dest))) do
        kinds[r.type] = (kinds[r.type] or 0) + 1
      end
      t.ok(kinds.user and kinds.assistant, "реплики")
      t.ok(
        kinds["queue-operation"] and kinds.attachment and kinds["last-prompt"],
        "служебные записи"
      )
    end
  )

  it(
    "фоновая команда: запуск с run_in_background, результат с backgroundTaskId и путём вывода",
    function()
      local dest = fresh()
      fixtures.install("command-completed", dest)
      local started, result
      for _, r in ipairs(records_of(fixtures.transcript("command-completed", dest))) do
        for _, block in
          ipairs(
            type(r.message) == "table" and type(r.message.content) == "table" and r.message.content
              or {}
          )
        do
          if
            block.type == "tool_use"
            and block.name == "Bash"
            and block.input.run_in_background
          then
            started = block
          end
        end
        if type(r.toolUseResult) == "table" and r.toolUseResult.backgroundTaskId then
          result = r
        end
      end
      t.ok(started and started.input.command, "вызов Bash")
      t.ok(result, "результат с backgroundTaskId")
      local text = result.message.content[1].content
      t.match(text, "Output is being written to: " .. vim.pesc(dest .. "/tmp/" .. fixtures.project))
    end
  )

  it("завершение completed: enqueue и user с блоком, код 0", function()
    local dest = fresh()
    fixtures.install("command-completed", dest)
    local enqueue, user
    for _, r in ipairs(records_of(fixtures.transcript("command-completed", dest))) do
      if
        r.type == "queue-operation"
        and r.operation == "enqueue"
        and (r.content or ""):find("<task%-notification>")
      then
        enqueue = r
      end
      if r.type == "user" and r.origin and r.origin.kind == "task-notification" then
        user = r
      end
    end
    t.ok(enqueue and user)
    t.match(enqueue.content, "<status>completed</status>")
    t.match(enqueue.content, "completed %(exit code 0%)")
    t.match(user.message.content, "<status>completed</status>")
  end)

  it(
    "статус failed с кодом 3: attachment queued_command и remove absorbed_mid_turn",
    function()
      local dest = fresh()
      fixtures.install("command-failed", dest)
      local att, remove, enqueue, user
      for _, r in ipairs(records_of(fixtures.transcript("command-failed", dest))) do
        if r.type == "attachment" and r.attachment.type == "queued_command" then
          att = r
        elseif r.type == "queue-operation" and r.operation == "remove" then
          remove = r
        elseif
          r.type == "queue-operation"
          and r.operation == "enqueue"
          and (r.content or ""):find("task%-notification")
        then
          enqueue = r
        elseif r.type == "user" and r.origin and r.origin.kind == "task-notification" then
          user = r
        end
      end
      t.ok(att and remove and enqueue)
      t.ok(
        not user,
        "записи user нет: уведомление пришло посреди хода"
      )
      t.eq(att.attachment.commandMode, "task-notification")
      t.eq(att.attachment.origin.kind, "task-notification")
      t.match(att.attachment.prompt, "<status>failed</status>")
      t.match(att.attachment.prompt, "failed with exit code 3")
      t.eq(remove.reason, "absorbed_mid_turn")
    end
  )

  it(
    "файл вывода: есть у одних образцов, отсутствует у других, пуст у оборванной команды",
    function()
      local dest = fresh()
      fixtures.install({ "command-failed", "command-completed", "command-orphaned" }, dest)
      local failed = files_under(fixtures.tasks_dir("command-failed", dest))
      t.eq(#failed, 1)
      t.match(read(failed[1]), "failing")
      t.ok(
        vim.fn.isdirectory(fixtures.tasks_dir("command-completed", dest)) == 0,
        "файла вывода нет"
      )
      local orphan = files_under(fixtures.tasks_dir("command-orphaned", dest))
      t.eq(#orphan, 1)
      t.eq(#read(orphan[1]), 0)
    end
  )

  it(
    "команда без отметок: после запуска записей о задаче нет",
    function()
      local dest = fresh()
      fixtures.install("command-orphaned", dest)
      local path = fixtures.transcript("command-orphaned", dest)
      t.ok(not raw_has(path, "<task-notification>"))
      t.ok(raw_has(path, "backgroundTaskId"))
    end
  )

  it("команда пережила ход: enqueue и user, status completed", function()
    local dest = fresh()
    fixtures.install("command-survived", dest)
    local path = fixtures.transcript("command-survived", dest)
    local user
    for _, r in ipairs(records_of(path)) do
      if r.type == "user" and r.origin and r.origin.kind == "task-notification" then
        user = r
      end
    end
    t.ok(user)
    t.match(user.message.content, "<status>completed</status>")
    t.eq(#files_under(fixtures.tasks_dir("command-survived", dest)), 1)
  end)

  it(
    "остановка TaskStop: результат с task_id, уведомления нет",
    function()
      local dest = fresh()
      fixtures.install("command-taskstop", dest)
      local path = fixtures.transcript("command-taskstop", dest)
      local stop
      for _, r in ipairs(records_of(path)) do
        if type(r.toolUseResult) == "table" and r.toolUseResult.task_id then
          stop = r.toolUseResult
        end
      end
      t.ok(stop and stop.task_type == "local_bash" and stop.command)
      t.ok(not raw_has(path, "<task-notification>"))
      t.ok(raw_has(path, '"name":"TaskStop"'))
    end
  )

  it(
    "задача Monitor: промежуточные уведомления без status и tool-use-id, итоговое со status",
    function()
      local dest = fresh()
      fixtures.install("monitor", dest)
      local inter, final = 0, 0
      for _, r in ipairs(records_of(fixtures.transcript("monitor", dest))) do
        if
          r.type == "queue-operation"
          and r.operation == "enqueue"
          and (r.content or ""):find("<task%-notification>")
        then
          local c = r.content
          if c:find("<status>", 1, true) then
            final = final + 1
            t.match(c, "<tool%-use%-id>")
          else
            inter = inter + 1
            t.ok(c:find("<event>", 1, true), "событие")
            t.ok(not c:find("<tool%-use%-id>"), "tool-use-id у промежуточного")
          end
        end
      end
      t.eq(inter, 3)
      t.eq(final, 1)
    end
  )

  it(
    "субагент: пара файлов, meta завершённого с finished, поля meta",
    function()
      local dest = fresh()
      fixtures.install("subagent-command", dest)
      local m = metas("subagent-command", dest)
      local id, meta = next(m)
      t.ok(id and meta)
      t.eq(meta.finished, true)
      for _, key in ipairs({ "agentType", "description", "toolUseId", "spawnDepth", "model" }) do
        t.ok(meta[key] ~= nil, key)
      end
      t.ok(vim.uv.fs_stat(subagent_dir("subagent-command", dest) .. "/agent-" .. id .. ".jsonl"))
    end
  )

  it(
    "команда субагента: вызов у субагента, уведомление у родителя и вложением у субагента",
    function()
      local dest = fresh()
      fixtures.install("subagent-command", dest)
      local id = next(metas("subagent-command", dest))
      local sub = records_of(subagent_dir("subagent-command", dest) .. "/agent-" .. id .. ".jsonl")
      local started, attachment = false, false
      for _, r in ipairs(sub) do
        t.eq(r.isSidechain, true)
        t.eq(r.agentId, id)
        for _, block in
          ipairs(
            type(r.message) == "table" and type(r.message.content) == "table" and r.message.content
              or {}
          )
        do
          if
            block.type == "tool_use"
            and block.name == "Bash"
            and block.input.run_in_background
          then
            started = true
          end
        end
        if r.type == "attachment" and r.attachment.type == "queued_command" then
          attachment = true
        end
      end
      t.ok(started, "вызов в транскрипте субагента")
      t.ok(attachment, "вложение queued_command у субагента")
      local parent_notice
      for _, r in ipairs(records_of(fixtures.transcript("subagent-command", dest))) do
        if
          r.type == "queue-operation"
          and r.operation == "enqueue"
          and (r.content or ""):find("<status>failed</status>")
        then
          parent_notice = r
        end
      end
      t.ok(parent_notice, "уведомление у родителя")
      t.match(parent_notice.content, "exit code 2")
    end
  )

  it(
    "фоновый субагент: requestShape background, ссылка вывода на транскрипт субагента",
    function()
      local dest = fresh()
      fixtures.install("subagent-background", dest)
      local id, meta = next(metas("subagent-background", dest))
      t.eq(meta.requestShape, "background")
      local link = fixtures.tasks_dir("subagent-background", dest) .. "/" .. id .. ".output"
      t.eq(vim.uv.fs_lstat(link).type, "link")
      t.eq(
        vim.uv.fs_readlink(link),
        subagent_dir("subagent-background", dest) .. "/agent-" .. id .. ".jsonl"
      )
      t.ok(
        vim.uv.fs_stat(link),
        "ссылка указывает на существующий файл"
      )
      local notice
      for _, r in ipairs(records_of(fixtures.transcript("subagent-background", dest))) do
        if r.type == "queue-operation" and (r.content or ""):find("<task%-id>" .. id) then
          notice = r.content
        end
      end
      t.ok(
        notice,
        "уведомление с task-id равным идентификатору агента"
      )
      t.match(notice, "<status>completed</status>")
    end
  )

  it(
    "остановленный субагент: нет finished, последняя запись — прерывание, у родителя killed",
    function()
      local dest = fresh()
      fixtures.install("subagent-stopped", dest)
      local id, meta = next(metas("subagent-stopped", dest))
      t.eq(meta.finished, nil)
      local sub = records_of(subagent_dir("subagent-stopped", dest) .. "/agent-" .. id .. ".jsonl")
      local last = sub[#sub]
      t.eq(last.type, "user")
      t.eq(last.message.content[1].text, "[Request interrupted by user]")
      local killed = false
      for _, r in ipairs(records_of(fixtures.transcript("subagent-stopped", dest))) do
        if
          r.type == "queue-operation"
          and (r.content or ""):find("<task%-id>" .. id .. "</task%-id>")
          and r.content:find("<status>killed</status>")
        then
          killed = true
        end
      end
      t.ok(killed)
    end
  )

  it(
    "вложенные субагенты: parentAgentId и spawnDepth 2 у внутреннего",
    function()
      local dest = fresh()
      fixtures.install("subagent-nested", dest)
      local m = metas("subagent-nested", dest)
      local outer, inner
      for id, meta in pairs(m) do
        if meta.parentAgentId then
          inner = { id = id, meta = meta }
        else
          outer = { id = id, meta = meta }
        end
      end
      t.ok(outer and inner)
      t.eq(inner.meta.parentAgentId, outer.id)
      t.eq(inner.meta.spawnDepth, 2)
      t.eq(outer.meta.spawnDepth, 1)
      t.eq(outer.meta.finished, true)
      t.eq(inner.meta.finished, true)
    end
  )

  it(
    "оборванный владелец: субагент без finished, уведомлений нет",
    function()
      local dest = fresh()
      fixtures.install("owner-killed", dest)
      local _, meta = next(metas("owner-killed", dest))
      t.eq(meta.finished, nil)
      t.ok(not raw_has(fixtures.transcript("owner-killed", dest), "<task-notification>"))
    end
  )

  it(
    "посторонние файлы и каталог workflows/ лежат в subagents/ сессии subagent-command",
    function()
      local dest = fresh()
      fixtures.install({ "subagent-command", "subagent-extra-files" }, dest)
      local dir = subagent_dir("subagent-command", dest)
      local id = next(metas("subagent-command", dest))
      t.ok(vim.uv.fs_stat(dir .. "/agent-" .. id .. ".forked-skill.json"))
      t.ok(vim.uv.fs_stat(dir .. "/agent-" .. id .. ".forked-skill.marker.json"))
      local journal = read(dir .. "/workflows/wf_fixture01/journal.jsonl")
      t.match(journal, '"type":"launched"')
      t.match(journal, '"type":"started"')
      t.ok(
        vim.uv.fs_stat(dir .. "/workflows/wf_fixture01/steps/journal.jsonl"),
        "вложенный каталог"
      )
      t.ok(
        vim.uv.fs_stat(dir .. "/workflows/wf_fixture01/agent-a0000000000000099.meta.json"),
        "похожая на субагента пара внутри workflows/"
      )
      t.eq(
        vim.tbl_count(metas("subagent-command", dest)),
        1,
        "пара внутри workflows/ не видна на уровне subagents/"
      )
    end
  )

  it(
    "транскрипта нет: сессия известна, файла ни в одном проекте нет",
    function()
      local dest = fresh()
      fixtures.install("no-transcript", dest)
      local found = vim.fn.glob(dest .. "/projects/*/" .. fixtures.missing_session_id .. ".jsonl")
      t.eq(found, "")
      t.ok(
        vim.fn.isdirectory(dest .. "/projects/" .. fixtures.project) == 1,
        "каталог проекта есть"
      )
    end
  )

  it(
    "неизвестные записи, поля и значения; одна повреждённая строка",
    function()
      local dest = fresh()
      fixtures.install("unknown-records", dest)
      local path = fixtures.transcript("unknown-records", dest)
      local unknown_type, unknown_field, unknown_value, unknown_att = false, false, false, false
      for _, r in ipairs(records_of(path)) do
        unknown_type = unknown_type or r.type == "future-kind"
        unknown_field = unknown_field or r.futureField ~= nil
        unknown_value = unknown_value or r.permissionMode == "quantum"
        unknown_att = unknown_att or (r.attachment and r.attachment.type == "future_attachment")
      end
      t.ok(unknown_type and unknown_field and unknown_value and unknown_att)
      local bad = 0
      for line in read(path):gmatch("[^\n]+") do
        if not pcall(vim.json.decode, line) then
          bad = bad + 1
        end
      end
      t.eq(bad, 1)
      local _, meta = next(metas("unknown-records", dest))
      t.eq(meta.futureField, "value")
    end
  )

  it(
    "сессия сменила каталог: cwd записей не совпадает с каталогом проекта",
    function()
      local dest = fresh()
      fixtures.install("session-moved", dest)
      local seen = false
      for _, r in ipairs(records_of(fixtures.transcript("session-moved", dest))) do
        if r.cwd then
          t.eq(r.cwd, fixtures.cwd .. "/subdir")
          seen = true
        end
      end
      t.ok(seen)
    end
  )

  it(
    "проект с несколькими сессиями: разные времена и первые реплики пользователя",
    function()
      local dest = fresh()
      fixtures.install("history-project", dest)
      local firsts = {}
      for _, id in ipairs(fixtures.history.alpha) do
        local recs =
          records_of(string.format("%s/projects/%s/%s.jsonl", dest, fixtures.project, id))
        firsts[#firsts + 1] = recs[1].message.content
      end
      t.eq(#firsts, 3)
      t.ok(firsts[1] ~= firsts[2] and firsts[2] ~= firsts[3])
      t.ok(#firsts[2] > 100, "одна реплика длинная")
      t.ok(
        vim.uv.fs_stat(
          string.format("%s/projects/-srv-demo-beta/%s.jsonl", dest, fixtures.history.beta)
        )
      )
    end
  )
end)

describe("fixtures.append и append_partial", function()
  it("append дописывает записи строками", function()
    local dest = fresh()
    fixtures.install("owner-dialogue", dest)
    local path = fixtures.transcript("owner-dialogue", dest)
    local sid = fixtures.session_id("owner-dialogue")
    local before = #records_of(path)
    fixtures.append(
      path,
      { fixtures.user_record(sid, "Вопрос"), fixtures.assistant_record(sid, "Ответ") }
    )
    local recs = records_of(path)
    t.eq(#recs, before + 2)
    t.eq(recs[#recs].message.content[1].text, "Ответ")
    t.eq(read(path):sub(-1), "\n")
  end)

  it(
    "append_partial оставляет недописанную строку, которая не разбирается",
    function()
      local dest = fresh()
      fixtures.install("owner-dialogue", dest)
      local path = fixtures.transcript("owner-dialogue", dest)
      local before = #records_of(path)
      fixtures.append_partial(path, '{"type":"user","message":{"role":"us')
      t.eq(#records_of(path), before)
      t.ok(read(path):sub(-1) ~= "\n")
      fixtures.append_partial(path, 'er","content":"x"}}\n')
      t.eq(#records_of(path), before + 1)
    end
  )

  it("notification_block собирает блок из полей", function()
    local block = fixtures.notification_block({
      task_id = "t1",
      tool_use_id = "u1",
      output_file = "/x/t1.output",
      status = "failed",
      summary = "failed with exit code 3",
    })
    t.match(block, "^<task%-notification>\n<task%-id>t1</task%-id>")
    t.match(block, "<status>failed</status>")
    t.match(block, "</task%-notification>$")
    t.ok(not fixtures.notification_block({ task_id = "t1" }):find("<status>", 1, true))
  end)
end)
