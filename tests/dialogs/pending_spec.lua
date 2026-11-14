-- Перечень ждущих запросов и их закрытие хуком, передачей и ответом другого экземпляра
-- (спецификация agent-dialogs: «Перечень ждущих запросов», «Первое решение побеждает»,
-- «Закрытие запроса хуком», «Передача диалога терминалу», «Диалог в панели не затрагивается»,
-- «Отсутствие таймеров и опроса»).
local t = require("helpers.t")
local s = require("dialogs.pending_support")
local pending = require("claudr.dialogs.pending")
local match = require("claudr.dialogs.match")
local model = require("claudr.tree.model")

after_each(function()
  s.reset()
end)

local ALLOW = {
  hookSpecificOutput = { hookEventName = "PermissionRequest", decision = { behavior = "allow" } },
}

describe("Перечень ждущих запросов", function()
  it("Два параллельных вызова", function()
    s.env({ records = s.records("parallel-reads", 1, 1) })
    local _, a = s.request(s.input("permission-read"))
    local _, b = s.request(s.input("permission-read", { file_path = "/etc/hosts" }))
    local pane = model.get(s.PANE)
    t.eq(pending.count(pane), 2)
    t.eq(pending.for_node(pane), { a, b })
    t.ok(a.id ~= b.id)
    t.eq(a.tool_name, "Read")
    t.eq(a.session_id, s.samples.session_id)
    t.eq(a.tool_input, { file_path = "/etc/hostname" })
    t.eq(b.tool_input, { file_path = "/etc/hosts" })
    t.eq(a.request.kind, "permission")
    t.eq(pending.get(a.id), a)
    t.eq(pending.list(), { a, b })
  end)

  it("Субагент и главная сессия", function()
    s.env({ subagent = true })
    local _, sub = s.request(s.input("subagent"))
    local _, main = s.request(s.input("permission-bash"))
    t.eq(pending.count(model.get(s.SUB_NODE)), 1)
    t.eq(pending.for_node(model.get(s.SUB_NODE)), { sub })
    t.eq(pending.count(model.get(s.PANE)), 2)
    t.eq(pending.for_node(model.get(s.PANE)), { sub, main })
    t.eq(pending.for_pane(s.PANE), { sub, main })
  end)

  it("у прочих узлов запросов нет", function()
    s.env()
    s.request(s.input("permission-bash"))
    t.eq(pending.count(model.get("w1")), 0)
    t.eq(pending.count(nil), 0)
  end)

  it(
    "решение уходит хуку кадром decision, повторное отклоняется",
    function()
      s.env()
      local h, req = s.request(s.input("permission-bash"))
      local events = {}
      local off = pending.subscribe(function(r, ev)
        events[#events + 1] = { r.id, ev, r.state }
      end)
      t.eq(pending.decide(req, ALLOW), true)
      t.eq(req.state, "sent")
      local f = h:wait_frame()
      t.eq(f, { type = "decision", output = ALLOW })
      local ok, why = pending.decide(req, ALLOW)
      t.eq(ok, false)
      t.ok(type(why) == "string")
      t.eq(events, { { req.id, "state", "sent" } })
      off()
      -- запрос с отправленным решением остаётся открытым до подтверждения в транскрипте
      t.eq(pending.count(model.get(s.PANE)), 1)
    end
  )

  it("неразборчивый вход хука не принимается", function()
    s.env()
    local hd = require("helpers.hook_double")
    local h = hd.spawn({
      socket = require("claudr.dialogs.socket").path(),
      input = { session_id = s.samples.session_id },
      env = s.hook_env(),
    })
    h:wait_closed()
    t.eq(pending.list(), {})
  end)

  it("forget убирает закрытый запрос из перечня", function()
    s.env()
    local h, req = s.request(s.input("permission-bash"))
    local removed
    pending.subscribe(function(r, ev)
      if ev == "removed" then
        removed = r
      end
    end)
    pending.handoff(req)
    t.eq(pending.list(), { req })
    pending.forget(req)
    t.eq(pending.list(), {})
    t.eq(removed, req)
    h:wait_closed()
  end)
end)

describe("Первое решение побеждает", function()
  it(
    "получив «отвечено», плагин закрывает запрос: принят другим экземпляром",
    function()
      s.env()
      local h, req = s.request(s.input("permission-bash"))
      local states = {}
      pending.subscribe(function(r, ev)
        if ev == "state" then
          states[#states + 1] = r.state
        end
      end)
      h:answered()
      s.wait_state(req, "answered_other")
      t.eq(states, { "answered_other" })
      t.eq(pending.count(model.get(s.PANE)), 0)
      t.eq(pending.list(), { req })
      t.eq(pending.decide(req, ALLOW), false)
      t.eq(h.frames, {})
    end
  )
end)

describe("Закрытие запроса хуком", function()
  it("Срок хука истёк", function()
    local d = s.env()
    local h, req = s.request(s.input("permission-bash"))
    -- хук, завершённый Claude Code по сроку, закрывает соединение (SIGTERM)
    h:term()
    s.wait_state(req, "closed_by_hook")
    t.eq(h:wait_exit(), 0)
    t.eq(pending.count(model.get(s.PANE)), 0)
    local ok, why = pending.decide(req, ALLOW)
    t.eq(ok, false)
    t.ok(why)
    t.eq(d:count("pane.send_keys"), 0)
    t.eq(d:count("pane.send_text"), 0)
    t.eq(d:count("pane.read"), 0)
  end)

  it("закрытие соединения без сигнала до решения", function()
    s.env()
    local h, req = s.request(s.input("permission-bash"))
    h:close()
    s.wait_state(req, "closed_by_hook")
    t.eq(match._watcher_count(), 0)
  end)

  it(
    "закрытие хуком после отправленного решения не закрывает запрос",
    function()
      s.env()
      local h, req = s.request(s.input("permission-bash"))
      pending.decide(req, ALLOW)
      h:wait_frame()
      h:close()
      s.settle()
      t.wait(function()
        return require("claudr.dialogs.socket")._conn_count() == 0
      end, "соединение закрыто")
      t.eq(req.state, "sent")
    end
  )
end)

describe("Передача диалога терминалу", function()
  it("Передача", function()
    s.env()
    local h, req = s.request(s.input("permission-bash"))
    t.eq(pending.handoff(req), true)
    t.eq(req.state, "handed_off")
    h:wait_closed()
    t.eq(h.frames, {})
    t.eq(pending.count(model.get(s.PANE)), 0)
    t.eq(pending.decide(req, ALLOW), false)
    t.eq(pending.handoff(req), false)
    t.eq(match._watcher_count(), 0)
  end)
end)

describe("Диалог в панели не затрагивается", function()
  it("Запрос ждёт", function()
    local d = s.env({ records = s.records("bash-pending") })
    local h, req = s.request(s.input("permission-bash"))
    s.wait_id(req)
    pending.decide(req, ALLOW)
    h:wait_frame()
    s.append(s.transcript(), s.records("bash-allowed", 3, 4))
    s.wait_state(req, "accepted")
    t.eq(d:count("pane.send_keys"), 0)
    t.eq(d:count("pane.send_text"), 0)
    t.eq(d:count("pane.read"), 0)
  end)
end)

describe("Отсутствие таймеров и опроса", function()
  it("Тишина", function()
    s.env({ records = s.records("bash-pending", 1, 1) })
    local _, req = s.request(s.input("permission-bash"))
    s.settle()
    local reads = s.count_reads()
    s.settle()
    s.settle()
    reads.restore()
    t.eq(reads.open, 0, "файлы не читаются: " .. vim.inspect(reads.paths))
    t.eq(reads.read, 0)
    t.eq(s.timer_count(), 0, "таймеров нет")
    t.eq(req.state, "waiting")
    t.eq(req.tool_use_id, nil)
  end)

  it("в исходниках dialogs/ нет таймеров", function()
    local dir = t.root .. "/lua/claudr/dialogs"
    for name in vim.fs.dir(dir) do
      if name:match("%.lua$") then
        local f = assert(io.open(dir .. "/" .. name))
        local text = f:read("*a")
        f:close()
        for _, word in ipairs({ "defer_fn", "new_timer", "timer_start" }) do
          t.eq(text:find(word, 1, true), nil, name .. ": " .. word)
        end
      end
    end
  end)
end)
