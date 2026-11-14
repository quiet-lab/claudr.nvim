-- Модуль данных Claude Code: слежение за каталогом сессии, subagents/, транскриптами и файлами
-- вывода уведомлениями файловой системы (спецификация claude-code-data).
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")

local META = '{"agentType":"general-purpose","description":"first","toolUseId":"toolu_01FixtureFirst000000001",'
  .. '"spawnDepth":1,"model":"haiku"}'

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

describe("Слежение за изменениями", function()
  it("Первый субагент", function()
    local dir = u.fresh("command-completed")
    local sid = fixtures.session_id("command-completed")
    local session_dir = fixtures.session_dir("command-completed", dir)
    local seen = {}
    local h = data.watch_session(sid, function(s)
      seen[#seen + 1] = s
    end)
    t.eq(h:state().subagents, {})
    t.ok(not h.session_watch and not h.sub_watch, "каталога сессии ещё нет")
    vim.fn.mkdir(session_dir, "p")
    u.wait(function()
      return h.session_watch ~= nil
    end, "наблюдение каталога сессии")
    vim.fn.mkdir(session_dir .. "/subagents", "p")
    u.wait(function()
      return h.sub_watch ~= nil
    end, "переход на subagents/")
    t.eq(
      h.session_watch,
      nil,
      "каталог сессии больше не наблюдается"
    )
    write(session_dir .. "/subagents/agent-a0000000000000021.meta.json", META)
    fixtures.append(session_dir .. "/subagents/agent-a0000000000000021.jsonl", {
      fixtures.user_record(sid, "task for subagent"),
    })
    u.wait(function()
      return #seen > 0 and seen[#seen].subagents.a0000000000000021 ~= nil
    end, "новый субагент")
    local a = h:state().subagents.a0000000000000021
    t.eq(a.description, "first")
    t.eq(a.status, "running")
    h:close()
  end)

  it("каталог сессии и subagents/ созданы разом", function()
    local dir = u.fresh("command-completed")
    local sid = fixtures.session_id("command-completed")
    local sub = fixtures.session_dir("command-completed", dir) .. "/subagents"
    local h = data.watch_session(sid, function() end)
    vim.fn.mkdir(sub, "p")
    write(sub .. "/agent-a0000000000000022.meta.json", META)
    write(sub .. "/agent-a0000000000000022.jsonl", "")
    u.wait(function()
      return h:state().subagents.a0000000000000022 ~= nil
    end, "субагент")
    h:close()
  end)

  it("изменения meta.json и транскрипта субагента", function()
    local dir = u.fresh("owner-killed")
    local sid = fixtures.session_id("owner-killed")
    local sub = fixtures.session_dir("owner-killed", dir) .. "/subagents"
    local h = u.watch_session(sid, function() end)
    t.eq(h:state().subagents.a0000000000000005.finished, false)
    fixtures.append(
      sub .. "/agent-a0000000000000005.jsonl",
      u.bash_launch(
        sid,
        "toolu_01FixtureWatch0000000001",
        "bwatch001",
        "sleep 9",
        dir .. "/x.output"
      )
    )
    u.wait(function()
      return h:state().tasks.bwatch001 ~= nil
    end, "команда из дописанного транскрипта субагента")
    local meta = vim.json.decode(
      table.concat(vim.fn.readfile(sub .. "/agent-a0000000000000005.meta.json"), "\n")
    )
    meta.finished = true
    write(sub .. "/agent-a0000000000000005.meta.json", vim.json.encode(meta))
    u.wait(function()
      return h:state().subagents.a0000000000000005.finished
    end, "отметка завершения в meta.json")
    h:close()
  end)

  it("дописывание транскрипта владельца", function()
    local dir = u.fresh("command-orphaned")
    local sid = fixtures.session_id("command-orphaned")
    local h = data.watch_session(sid, function() end)
    fixtures.append(
      fixtures.transcript("command-orphaned"),
      u.bash_launch(
        sid,
        "toolu_01FixtureWatch0000000002",
        "bwatch002",
        "sleep 8",
        dir .. "/y.output"
      )
    )
    u.wait(function()
      return h:state().tasks.bwatch002 ~= nil
    end, "новая команда владельца")
    t.eq(h:state().tasks.bwatch002.owner, nil)
    h:close()
  end)

  it(
    "close закрывает все наблюдения и прекращает уведомления",
    function()
      local base = u.fs_event_count()
      local dir = u.fresh({ "command-completed", "command-survived" })
      local calls = 0
      local hs_wait = data.watch_session(fixtures.missing_session_id, function()
        calls = calls + 1
      end)
      local hs = data.watch_session(fixtures.session_id("command-completed"), function()
        calls = calls + 1
      end)
      local hd = data.watch_dialogue(fixtures.session_id("command-completed"), function()
        calls = calls + 1
      end)
      local hd_wait = data.watch_dialogue(fixtures.missing_session_id, function()
        calls = calls + 1
      end)
      local out = assert(
        data.watch_output(
          fixtures.tasks_dir("command-survived", dir) .. "/bfixt0008.output",
          function()
            calls = calls + 1
          end
        )
      )
      vim.fn.mkdir(fixtures.session_dir("command-completed", dir), "p")
      u.settle()
      t.ok(u.fs_event_count() > base, "наблюдения открыты")
      for _, h in ipairs({ hs_wait, hs, hd, hd_wait, out }) do
        h:close()
      end
      u.settle()
      t.eq(u.fs_event_count(), base, "все наблюдения закрыты")
      calls = 0
      local sid = fixtures.session_id("command-completed")
      fixtures.append(
        fixtures.transcript("command-completed"),
        { fixtures.user_record(sid, "after close") }
      )
      fixtures.append(
        dir .. "/projects/" .. fixtures.project .. "/" .. fixtures.missing_session_id .. ".jsonl",
        {
          fixtures.user_record(fixtures.missing_session_id, "late"),
        }
      )
      u.settle()
      t.eq(calls, 0)
    end
  )
end)
