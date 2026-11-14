-- Модуль данных Claude Code: состояние «оборван» по сообщению о завершении или закрытии панели
-- владельца (спецификация claude-code-data).
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")

local NESTED_META = '{"agentType":"general-purpose","description":"inner","toolUseId":"toolu_01FixtureNested00000000",'
  .. '"parentAgentId":"a0000000000000005","spawnDepth":2,"model":"haiku"}'

describe("Состояние «оборван»", function()
  it("Владелец упал", function()
    local dir = u.fresh("owner-killed")
    local sid = fixtures.session_id("owner-killed")
    local sub = fixtures.session_dir("owner-killed", dir) .. "/subagents"
    local tasks = fixtures.tasks_dir("owner-killed", dir)
    -- фоновая команда работающего субагента и вложенный субагент со своей командой
    fixtures.append(
      sub .. "/agent-a0000000000000005.jsonl",
      u.bash_launch(
        sid,
        "toolu_01FixtureOrphan000000001",
        "borph0001",
        "sleep 300",
        tasks .. "/borph0001.output"
      )
    )
    local f = assert(io.open(sub .. "/agent-a0000000000000007.meta.json", "w"))
    f:write(NESTED_META)
    f:close()
    fixtures.append(
      sub .. "/agent-a0000000000000007.jsonl",
      u.bash_launch(
        sid,
        "toolu_01FixtureOrphan000000002",
        "borph0002",
        "sleep 400",
        tasks .. "/borph0002.output"
      )
    )
    local changes = 0
    local h = data.watch_session(sid, function()
      changes = changes + 1
    end)
    local s = h:state()
    t.eq(s.subagents.a0000000000000007.parent_id, "a0000000000000005")
    t.eq(s.tasks.borph0001.owner, "a0000000000000005")
    t.eq(s.tasks.borph0002.owner, "a0000000000000007")
    for _, v in pairs(s.subagents) do
      t.eq(v.status, "running")
    end
    h:set_owner_alive(false)
    t.eq(changes, 1)
    s = h:state()
    t.eq(s.subagents.a0000000000000005.status, "orphaned")
    t.eq(s.subagents.a0000000000000007.status, "orphaned", "вложенный субагент")
    t.eq(s.tasks.borph0001.status, "orphaned")
    t.eq(
      s.tasks.borph0002.status,
      "orphaned",
      "команда вложенного субагента"
    )
    t.eq(s.tasks.borph0001.result, nil)
    h:close()
  end)

  it(
    "отметка завершения сильнее сообщения о владельце",
    function()
      u.fresh("subagent-command")
      local h = data.watch_session(fixtures.session_id("subagent-command"), function() end)
      h:set_owner_alive(false)
      local s = h:state()
      t.eq(s.subagents.a0000000000000004.status, "finished")
      t.eq(s.tasks.bfixt0007.status, "finished")
      h:close()
    end
  )

  it("Владелец убит принудительно", function()
    u.fresh("command-orphaned")
    local last
    local h = data.watch_session(fixtures.session_id("command-orphaned"), function(s)
      last = s
    end)
    t.eq(h:state().tasks.bfixt0005.status, "running")
    h:set_owner_alive(false)
    t.eq(last.tasks.bfixt0005.status, "orphaned")
    t.eq(last.tasks.bfixt0005.result, nil)
    h:close()
  end)

  it("Владелец жив", function()
    u.fresh({ "command-orphaned", "owner-killed" })
    local h1 = data.watch_session(fixtures.session_id("command-orphaned"), function() end)
    local h2 = data.watch_session(fixtures.session_id("owner-killed"), function() end)
    h1:set_owner_alive(true)
    h2:set_owner_alive(true)
    t.eq(h1:state().tasks.bfixt0005.status, "running")
    t.eq(h2:state().subagents.a0000000000000005.status, "running")
    -- сообщение «жив» после «закрыта» возвращает работающее состояние
    h1:set_owner_alive(false)
    h1:set_owner_alive(true)
    t.eq(h1:state().tasks.bfixt0005.status, "running")
    h1:close()
    h2:close()
  end)
end)
