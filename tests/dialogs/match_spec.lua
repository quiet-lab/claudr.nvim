-- Идентификатор вызова по транскрипту и закрытие запроса по результату вызова (спецификация
-- agent-dialogs: «Идентификатор вызова», «Закрытие по результату вызова», «Состояние после
-- решения» в части перечня).
local t = require("helpers.t")
local s = require("dialogs.pending_support")
local pending = require("claudr.dialogs.pending")
local match = require("claudr.dialogs.match")
local model = require("claudr.tree.model")

local ids = s.samples.tool_use_ids

after_each(function()
  s.reset()
end)

local ALLOW = {
  hookSpecificOutput = { hookEventName = "PermissionRequest", decision = { behavior = "allow" } },
}

describe("Идентификатор вызова", function()
  it("Запись уже есть", function()
    s.env({ records = s.records("bash-pending") })
    local _, req = s.request(s.input("permission-bash"))
    t.eq(req.tool_use_id, ids.bash)
  end)

  it("Запись позже запроса", function()
    s.env({ records = s.records("bash-pending", 1, 1) })
    local _, req = s.request(s.input("permission-bash"))
    local events = {}
    pending.subscribe(function(r, ev)
      events[#events + 1] = ev
    end)
    s.settle()
    t.eq(req.tool_use_id, nil)
    s.append(s.transcript(), s.records("bash-pending", 2, 2))
    t.eq(s.wait_id(req), ids.bash)
    t.eq(events, { "tool_use_id" })
  end)

  it("транскрипт сессии появляется после запроса", function()
    s.env({ records = {} })
    vim.uv.fs_unlink(s.transcript())
    local _, req = s.request(s.input("permission-bash"))
    s.append(s.transcript(), s.records("bash-pending"))
    t.eq(s.wait_id(req), ids.bash)
  end)

  it("транскрипт субагента: идентификатор из него", function()
    s.env({ subagent = true, sub_records = s.records("subagent", 1, 1) })
    -- тот же вызов в транскрипте сессии не учитывается
    s.append(s.transcript(), {
      s.uses_record({
        { id = "toolu_main", name = "Bash", input = s.input("subagent").tool_input },
      }),
    })
    local _, req = s.request(s.input("subagent"))
    s.settle()
    t.eq(req.tool_use_id, nil)
    s.append(s.sub_transcript(), s.records("subagent", 2, 2))
    t.eq(s.wait_id(req), ids.sub)
  end)

  it(
    "параллельные вызовы получают свои идентификаторы",
    function()
      s.env({ records = s.records("parallel-reads", 1, 2) })
      -- запрос второго вызова пришёл первым: порядок хуков ключом не служит
      local _, b = s.request(s.input("permission-read", { file_path = "/etc/hosts" }))
      local _, a = s.request(s.input("permission-read"))
      t.eq(a.tool_use_id, ids.read1)
      t.eq(b.tool_use_id, ids.read2)
    end
  )

  it(
    "неразличимые вызовы сопоставляются по порядку записей",
    function()
      local input = s.input("permission-bash").tool_input
      s.env({
        records = {
          s.uses_record({
            { id = "toolu_same1", name = "Bash", input = input },
            { id = "toolu_same2", name = "Bash", input = input },
          }),
        },
      })
      local _, a = s.request(s.input("permission-bash"))
      local _, b = s.request(s.input("permission-bash"))
      t.eq(a.tool_use_id, "toolu_same1")
      t.eq(b.tool_use_id, "toolu_same2")
    end
  )

  it(
    "вызов с результатом до запроса и другой инструмент не подходят",
    function()
      local input = s.input("permission-bash").tool_input
      s.env({
        records = {
          s.uses_record({ { id = "toolu_old", name = "Bash", input = input } }),
          s.result_record("toolu_old", false),
          s.uses_record({ { id = "toolu_other", name = "Write", input = input } }),
        },
      })
      local _, req = s.request(s.input("permission-bash"))
      s.settle()
      t.eq(req.tool_use_id, nil)
      s.append(
        s.transcript(),
        { s.uses_record({ { id = "toolu_new", name = "Bash", input = input } }) }
      )
      t.eq(s.wait_id(req), "toolu_new")
    end
  )
end)

describe("Закрытие по результату вызова", function()
  it("Ответ в панели", function()
    s.env({ records = s.records("bash-answered-panel", 1, 2) })
    local h, req = s.request(s.input("permission-bash"))
    t.eq(req.tool_use_id, ids.bash)
    s.append(s.transcript(), s.records("bash-answered-panel", 3, 3))
    s.wait_state(req, "answered_elsewhere")
    h:wait_closed()
    t.eq(h.frames, {})
    t.eq(pending.count(model.get(s.PANE)), 0)
    t.eq(pending.decide(req, ALLOW), false)
  end)

  it(
    "отказ в панели: результат с ошибкой закрывает запрос",
    function()
      s.env({ records = s.records("bash-rejected-panel", 1, 2) })
      local h, req = s.request(s.input("permission-bash"))
      s.append(s.transcript(), s.records("bash-rejected-panel", 3, 4))
      s.wait_state(req, "answered_elsewhere")
      h:wait_closed()
    end
  )

  it(
    "вызов и результат дописаны вместе после запроса",
    function()
      s.env({ records = s.records("bash-answered-panel", 1, 1) })
      local h, req = s.request(s.input("permission-bash"))
      s.append(s.transcript(), s.records("bash-answered-panel", 2, 3))
      s.wait_state(req, "answered_elsewhere")
      t.eq(req.tool_use_id, ids.bash)
      h:wait_closed()
    end
  )

  it("решение принято: вложение hook_permission_decision", function()
    s.env({ records = s.records("bash-allowed", 1, 2) })
    local h, req = s.request(s.input("permission-bash"))
    pending.decide(req, ALLOW)
    h:wait_frame()
    s.append(s.transcript(), s.records("bash-allowed", 3, 3))
    s.wait_state(req, "accepted")
    t.eq(pending.decide(req, ALLOW), false)
    t.eq(pending.count(model.get(s.PANE)), 0)
    t.eq(match._watcher_count(), 0)
  end)

  it(
    "результат после нашего решения (в том числе с ошибкой) — решение принято",
    function()
      s.env({ records = s.records("bash-denied", 1, 2) })
      local h, req = s.request(s.input("permission-bash"))
      pending.decide(req, ALLOW)
      h:wait_frame()
      s.append(s.transcript(), s.records("bash-denied", 4, 4))
      s.wait_state(req, "accepted")
    end
  )

  it(
    "вложение чужого решения при ожидании запрос не закрывает",
    function()
      s.env({ records = s.records("bash-allowed", 1, 2) })
      local _, req = s.request(s.input("permission-bash"))
      s.append(s.transcript(), s.records("bash-allowed", 3, 3))
      s.settle()
      t.eq(req.state, "waiting")
      s.append(s.transcript(), s.records("bash-allowed", 4, 4))
      s.wait_state(req, "answered_elsewhere")
    end
  )

  it(
    "результат вызова субагента закрывает его запрос",
    function()
      s.env({ subagent = true, sub_records = s.records("subagent", 1, 2) })
      local h, req = s.request(s.input("subagent"))
      t.eq(req.tool_use_id, ids.sub)
      s.append(s.sub_transcript(), s.records("subagent", 4, 4))
      s.wait_state(req, "answered_elsewhere")
      h:wait_closed()
    end
  )

  it(
    "наблюдатели транскрипта снимаются без запросов",
    function()
      s.env({ records = s.records("parallel-reads", 1, 2) })
      local before = s.fs_event_count()
      local _, a = s.request(s.input("permission-read"))
      local _, b = s.request(s.input("permission-read", { file_path = "/etc/hosts" }))
      t.eq(match._watcher_count(), 1)
      t.ok(s.fs_event_count() > before)
      pending.handoff(a)
      t.eq(match._watcher_count(), 1)
      pending.handoff(b)
      t.eq(match._watcher_count(), 0)
      t.eq(s.fs_event_count(), before)
    end
  )
end)

describe("События транскрипта в claude-code-data", function()
  it(
    "вызовы, результаты и решения по порядку, посторонние записи пропущены",
    function()
      local hook = require("claudr.data.hook")
      local lines =
        vim.split(s.samples.text("transcripts", "parallel-reads"), "\n", { trimempty = true })
      table.insert(lines, 1, "не json")
      local evs = hook.events(lines)
      t.eq(evs, {
        { type = "call", id = ids.read1, name = "Read", input = { file_path = "/etc/hostname" } },
        { type = "call", id = ids.read2, name = "Read", input = { file_path = "/etc/hosts" } },
        { type = "decision", id = ids.read1, decision = "allow" },
        { type = "decision", id = ids.read2, decision = "deny" },
        { type = "result", id = ids.read1, is_error = false },
        { type = "result", id = ids.read2, is_error = true },
      })
    end
  )
end)

describe("План правится в том же сообщении", function()
  it("План правится в том же сообщении", function()
    s.env({ records = {} })
    local input = s.input("plan")
    local _, req = s.request(input)
    local edited = vim.deepcopy(input.tool_input)
    edited.plan = "# Plan: other text written by the model\n"
    s.append(
      s.transcript(),
      { s.uses_record({ { id = ids.plan, name = "ExitPlanMode", input = edited } }) }
    )
    t.eq(s.wait_id(req), ids.plan)
    -- результат вызова закрывает запрос
    s.append(s.transcript(), { s.result_record(ids.plan, false) })
    s.wait_state(req, "answered_elsewhere")
  end)

  it("другой planFilePath вызов не назначает", function()
    s.env({ records = {} })
    local input = s.input("plan")
    local _, req = s.request(input)
    local other = vim.deepcopy(input.tool_input)
    other.planFilePath = other.planFilePath .. ".other"
    s.append(
      s.transcript(),
      { s.uses_record({ { id = ids.plan, name = "ExitPlanMode", input = other } }) }
    )
    s.settle()
    t.eq(req.tool_use_id, nil)
  end)
end)
