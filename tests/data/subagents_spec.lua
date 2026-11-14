-- Модуль данных Claude Code: субагенты сессии, вложенность, отметка завершения, остановленный
-- и фоновый субагент (спецификация claude-code-data).
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")

local function session_state(samples, main)
  u.fresh(samples)
  local h = data.watch_session(fixtures.session_id(main or samples), function() end)
  local s = h:state()
  return s, h
end

local function ids(map)
  local out = vim.tbl_keys(map)
  table.sort(out)
  return out
end

describe("Субагенты сессии", function()
  it("Пара файлов", function()
    local s, h = session_state("subagent-command")
    t.eq(ids(s.subagents), { "a0000000000000004" })
    local a = s.subagents.a0000000000000004
    t.eq(a.id, "a0000000000000004")
    t.eq(a.agent_type, "general-purpose")
    t.eq(a.description, "Проверка фонового Bash с кодом выхода")
    t.eq(a.tool_use_id, "toolu_01Fixture000000000000011")
    t.eq(a.spawn_depth, 1)
    t.eq(a.parent_id, nil)
    t.eq(a.model, "haiku")
    t.eq(a.finished, true)
    h:close()
  end)

  it("meta.json без транскрипта субагента не даёт", function()
    local dir = u.fresh("subagent-command")
    local sub = fixtures.session_dir("subagent-command", dir) .. "/subagents"
    local f = assert(io.open(sub .. "/agent-a0000000000000077.meta.json", "w"))
    f:write('{"agentType":"general-purpose","spawnDepth":1}')
    f:close()
    local h = data.watch_session(fixtures.session_id("subagent-command"), function() end)
    t.eq(ids(h:state().subagents), { "a0000000000000004" })
    h:close()
  end)

  it("Посторонний файл", function()
    local s, h = session_state({ "subagent-command", "subagent-extra-files" }, "subagent-command")
    local sub = fixtures.session_dir("subagent-command") .. "/subagents"
    t.ok(vim.uv.fs_stat(sub .. "/agent-a0000000000000004.forked-skill.json"))
    t.ok(vim.uv.fs_stat(sub .. "/agent-a0000000000000004.forked-skill.marker.json"))
    t.eq(ids(s.subagents), { "a0000000000000004" })
    h:close()
    -- посторонние файлы без пары субагента не дают
    local dir = u.fresh("command-completed")
    local alone = fixtures.session_dir("command-completed", dir) .. "/subagents"
    vim.fn.mkdir(alone, "p")
    for _, name in ipairs({ "agent-a1.forked-skill.json", "agent-a1.forked-skill.marker.json" }) do
      local f = assert(io.open(alone .. "/" .. name, "w"))
      f:write('{"skillName":"x"}')
      f:close()
    end
    local h2 = data.watch_session(fixtures.session_id("command-completed"), function() end)
    t.eq(h2:state().subagents, {})
    h2:close()
  end)

  it("Каталог workflow", function()
    local s, h = session_state({ "subagent-command", "subagent-extra-files" }, "subagent-command")
    local wf = fixtures.session_dir("subagent-command") .. "/subagents/workflows/wf_fixture01"
    t.ok(
      vim.uv.fs_stat(wf .. "/agent-a0000000000000099.meta.json"),
      "похожая пара в workflows/"
    )
    t.eq(s.subagents.a0000000000000099, nil)
    t.eq(ids(s.subagents), { "a0000000000000004" })
    h:close()
  end)
end)

describe("Вложенность субагентов", function()
  it("Вложенный субагент", function()
    local s, h = session_state("subagent-nested")
    t.eq(ids(s.subagents), { "a0000000000000001", "a0000000000000002" })
    local outer, inner = s.subagents.a0000000000000002, s.subagents.a0000000000000001
    t.eq(outer.parent_id, nil)
    t.eq(outer.spawn_depth, 1)
    t.eq(inner.parent_id, "a0000000000000002")
    t.eq(inner.spawn_depth, 2)
    h:close()
  end)
end)

describe("Отметка завершения субагента", function()
  it("Работающий субагент", function()
    local s, h = session_state("owner-killed")
    local a = s.subagents.a0000000000000005
    t.eq(a.finished, false)
    t.eq(a.stop, nil)
    t.eq(a.status, "running")
    h:close()
  end)

  it("Завершённый субагент", function()
    local s, h = session_state("subagent-nested")
    t.eq(s.subagents.a0000000000000001.finished, true)
    t.eq(s.subagents.a0000000000000001.status, "finished")
    h:close()
  end)

  it("Остановленный субагент без поля", function()
    u.fresh("subagent-stopped")
    local sub = fixtures.session_dir("subagent-stopped")
      .. "/subagents/agent-a0000000000000006.jsonl"
    local recs = fixtures.records(sub)
    t.eq(recs[#recs].message.content[1].text, "[Request interrupted by user]")
    local h = data.watch_session(fixtures.session_id("subagent-stopped"), function() end)
    local a = h:state().subagents.a0000000000000006
    t.eq(a.finished, false, "отметки завершения в meta.json нет")
    h:close()
  end)
end)

describe("Остановленный и фоновый субагент", function()
  it("Остановка субагента", function()
    local s, h = session_state("subagent-stopped")
    local a = s.subagents.a0000000000000006
    t.eq(a.stop, "killed")
    t.eq(a.status, "finished")
    t.eq(
      s.tasks,
      {},
      "уведомление субагента не даёт фоновой команды"
    )
    h:close()
  end)

  it(
    "фоновый субагент завершён по уведомлению completed",
    function()
      local s, h = session_state("subagent-background")
      local a = s.subagents.a0000000000000003
      t.eq(a.stop, "completed")
      t.eq(a.status, "finished")
      t.eq(s.tasks.a0000000000000003, nil)
      h:close()
    end
  )

  it(
    "субагент на переднем плане завершён по результату вызова Agent",
    function()
      local s, h = session_state("subagent-command")
      t.eq(s.subagents.a0000000000000004.stop, "completed")
      h:close()
    end
  )

  it("Субагент убит вместе с родителем", function()
    u.fresh("owner-killed")
    local changed
    local h = data.watch_session(fixtures.session_id("owner-killed"), function(st)
      changed = st
    end)
    t.eq(h:state().subagents.a0000000000000005.status, "running")
    h:set_owner_alive(false)
    t.ok(changed, "подписчик получил изменение")
    local a = h:state().subagents.a0000000000000005
    t.eq(a.status, "orphaned")
    t.eq(a.stop, nil, "остановленным не считается")
    t.eq(a.finished, false)
    h:close()
  end)
end)
