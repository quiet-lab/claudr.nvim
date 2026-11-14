-- Модуль данных Claude Code: единый модуль разбора, устойчивость к неизвестному, отсутствие
-- таймеров и опроса (спецификация claude-code-data).
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")

local function lua_files(dir)
  local out = {}
  for name, kind in vim.fs.dir(dir, { depth = math.huge }) do
    if kind == "file" and name:match("%.lua$") then
      out[#out + 1] = dir .. "/" .. name
    end
  end
  table.sort(out)
  return out
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("Единый модуль чтения данных Claude Code", function()
  it("Изменение формата", function()
    -- приметы форматов Claude Code встречаются только в lua/claudr/data/
    local markers = {
      "task%-notification",
      "queue%-operation",
      "toolUseResult",
      "meta%.json",
      "parentAgentId",
      "run_in_background",
      "backgroundTaskId",
      "queued_command",
      "tool_result",
    }
    local plugin = t.root .. "/lua/claudr"
    local data_files = 0
    for _, path in ipairs(lua_files(plugin)) do
      local inside = path:find(plugin .. "/data/", 1, true) == 1
      if inside then
        data_files = data_files + 1
      else
        local text = read(path)
        for _, m in ipairs(markers) do
          t.ok(not text:find(m), path .. " разбирает формат Claude Code: " .. m)
        end
      end
    end
    t.ok(data_files > 0)
  end)
end)

describe("Устойчивость к неизвестному", function()
  it("Новое поле", function()
    u.fresh("unknown-records")
    local h = data.watch_session(fixtures.session_id("unknown-records"), function() end)
    local s = h:state()
    t.eq(vim.tbl_keys(s.subagents), { "a0000000000000010" })
    local a = s.subagents.a0000000000000010
    t.eq(a.finished, true)
    t.eq(a.description, "inner")
    t.eq(a.futureField, nil)
    h:close()
    local replies = data.read_dialogue(fixtures.transcript("unknown-records"))
    t.eq(replies[1], { role = "user", text = "Remember the code word MANGO. Reply with just: ok" })
  end)

  it("Неизвестная запись", function()
    u.fresh({ "unknown-records", "owner-dialogue" })
    local path = fixtures.transcript("unknown-records")
    local text = read(path)
    t.ok(
      text:find('"type":"future-kind"', 1, true),
      "запись неизвестного вида"
    )
    t.ok(
      text:find('"future_attachment"', 1, true),
      "вложение неизвестного вида"
    )
    local replies = data.read_dialogue(path)
    -- повреждённая строка и неизвестные записи пропущены, остальные реплики прочитаны
    t.eq(replies, data.read_dialogue(fixtures.transcript("owner-dialogue")))
  end)

  it(
    "непонятные значения известных полей пропускаются",
    function()
      local dir = u.fresh("command-orphaned")
      local sid = fixtures.session_id("command-orphaned")
      local path = fixtures.transcript("command-orphaned")
      local odd_meta =
        '{"agentType":5,"description":["x"],"spawnDepth":"deep","finished":"yes","parentAgentId":{}}'
      local sub = fixtures.session_dir("command-orphaned", dir) .. "/subagents"
      vim.fn.mkdir(sub, "p")
      local f = assert(io.open(sub .. "/agent-a0000000000000031.meta.json", "w"))
      f:write(odd_meta)
      f:close()
      f = assert(io.open(sub .. "/agent-a0000000000000032.meta.json", "w"))
      f:write("[1, 2]")
      f:close()
      f = assert(io.open(sub .. "/agent-a0000000000000033.meta.json", "w"))
      f:write("{not json")
      f:close()
      for _, id in ipairs({ "31", "32", "33" }) do
        fixtures.append(sub .. "/agent-a00000000000000" .. id .. ".jsonl", { "{}" })
      end
      fixtures.append(path, {
        { type = "assistant", message = { content = 5 } },
        {
          type = "assistant",
          message = { content = { { type = "tool_use", id = 7, name = {}, input = "x" } } },
        },
        {
          type = "user",
          message = { content = { { type = "tool_result", tool_use_id = {}, content = 3 } } },
        },
        { type = "user", message = "text", toolUseResult = "x" },
        { type = "queue-operation", operation = "enqueue", content = { 1 } },
        { type = "attachment", attachment = { type = "queued_command", prompt = 9 } },
        fixtures.queue_record(
          sid,
          "enqueue",
          fixtures.notification_block({ task_id = "bfixt0005", status = "exploded", summary = "?" })
        ),
        "[1,2,3]",
        "null",
      })
      local h = data.watch_session(sid, function() end)
      local s = h:state()
      t.eq(vim.tbl_keys(s.subagents), { "a0000000000000031" })
      local a = s.subagents.a0000000000000031
      t.eq(a.agent_type, nil)
      t.eq(a.description, nil)
      t.eq(a.spawn_depth, nil)
      t.eq(a.parent_id, nil)
      t.eq(a.finished, false)
      t.eq(
        s.tasks.bfixt0005.status,
        "running",
        "неизвестный статус уведомления пропущен"
      )
      t.eq(#data.read_dialogue(path), 1)
      h:close()
    end
  )

  it(
    "посторонние файлы и подкаталоги каталога субагентов пропускаются",
    function()
      local dir = u.fresh("unknown-records")
      local sub = fixtures.session_dir("unknown-records", dir) .. "/subagents"
      t.ok(vim.uv.fs_stat(sub .. "/agent-a0000000000000010.note.txt"))
      t.ok(vim.uv.fs_stat(sub .. "/unknown-dir/x.json"))
      local h = data.watch_session(fixtures.session_id("unknown-records"), function() end)
      t.eq(vim.tbl_keys(h:state().subagents), { "a0000000000000010" })
      -- новые посторонние файлы и каталоги по уведомлениям тоже пропускаются
      vim.fn.mkdir(sub .. "/workflows/wf_x", "p")
      local f = assert(io.open(sub .. "/agent-a0000000000000010.forked-skill.json", "w"))
      f:write("{}")
      f:close()
      u.settle()
      t.eq(vim.tbl_keys(h:state().subagents), { "a0000000000000010" })
      h:close()
    end
  )
end)

describe("Отсутствие таймеров и опроса", function()
  it("Файлы не меняются", function()
    local dir = u.fresh({ "subagent-command", "command-survived" })
    local timers = u.timer_count()
    local handles = {
      data.watch_session(fixtures.session_id("subagent-command"), function() end),
      data.watch_session(fixtures.missing_session_id, function() end),
      data.watch_dialogue(fixtures.session_id("subagent-command"), function() end),
      data.watch_dialogue(fixtures.missing_session_id, function() end),
      assert(
        data.watch_output(
          fixtures.tasks_dir("command-survived", dir) .. "/bfixt0008.output",
          function() end
        )
      ),
    }
    -- уже записанное отдаётся по запросу подписчика; дальше уведомлений нет — чтений нет
    u.settle()
    local reads = u.count_reads()
    local ok, err = pcall(function()
      u.settle()
      u.settle()
    end)
    reads.restore()
    t.ok(ok, err)
    t.eq(reads.open, 0, "файлы не читаются: " .. table.concat(reads.paths, ", "))
    t.eq(reads.read, 0)
    t.eq(u.timer_count(), timers, "таймеры не запущены")
    for _, h in ipairs(handles) do
      h:close()
    end
  end)

  it(
    "в коде модуля нет таймеров и отложенных вызовов",
    function()
      for _, path in ipairs(lua_files(t.root .. "/lua/claudr/data")) do
        local text = read(path)
        for _, pattern in ipairs({
          "new_timer",
          "defer_fn",
          "timer_start",
          "new_idle",
          "new_check",
          "new_prepare",
        }) do
          t.ok(not text:find(pattern, 1, true), path .. ": " .. pattern)
        end
      end
    end
  )
end)
