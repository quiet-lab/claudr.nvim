-- Модель дерева: состав, виды панелей, состояния, субагенты и фоновые команды, завершённые
-- узлы, обновление по событиям (спецификация agent-tree).
local t = require("helpers.t")
local s = require("tree.support")
local model = require("claudr.tree.model")
local double = s.double
local fixtures = s.fixtures

after_each(function()
  s.reset()
end)

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

describe("Состав дерева", function()
  it("Вложенный workspace", function()
    s.env({
      workspaces = {
        double.workspace({ workspace_id = "w1" }),
        double.workspace({ workspace_id = "w2", parent_workspace_id = "w1" }),
      },
      tabs = { double.tab({ tab_id = "w1:t1" }), double.tab({ tab_id = "w2:t1" }) },
      panes = { double.pane({ pane_id = "w1:p1" }), double.pane({ pane_id = "w2:p1" }) },
    })
    local w2 = s.wait_node("w2")
    t.eq(w2.parent, "w1")
    t.eq(s.children("w1"), { "w1:t1", "w2" })
    t.eq(#model.roots(), 1)
    t.eq(model.roots()[1].id, "w1")
    t.eq(model.get("w2:t1").parent, "w2")
    t.eq(model.get("w2:p1").parent, "w2:t1")
  end)

  it("Агент открыл новую вкладку", function()
    local d = s.env(s.snapshot({ double.pane({ pane_id = "w1:p1" }) }))
    s.wait_node("w1:p1")
    -- агент в панели обращается к серверу своим клиентом: вкладка, затем агент в ней
    local created = d.handlers["tab.create"](d, { workspace_id = "w1" })
    local pane_id = created.root_pane.pane_id
    d.handlers["agent.start"](d, { pane_id = pane_id, kind = "claude" })
    local pane = s.wait_node(pane_id, function(n)
      return n.pane_kind == "agent"
    end, "панель с агентом в новой вкладке")
    t.eq(pane.parent, created.tab.tab_id)
    t.eq(model.get(created.tab.tab_id).parent, "w1")
    t.eq(model.get(created.tab.tab_id).kind, "tab")
  end)

  it("вкладки и панели идут в порядке number", function()
    s.env({
      workspaces = { double.workspace({ workspace_id = "w1" }) },
      tabs = {
        double.tab({ tab_id = "w1:t2", number = 2 }),
        double.tab({ tab_id = "w1:t1", number = 1 }),
      },
      panes = {
        double.pane({ pane_id = "w1:p3", tab_id = "w1:t1", number = 2 }),
        double.pane({ pane_id = "w1:p2", tab_id = "w1:t1", number = 1 }),
        double.pane({ pane_id = "w1:p1", tab_id = "w1:t2" }),
      },
    })
    s.wait_node("w1:p3")
    t.eq(s.children("w1"), { "w1:t1", "w1:t2" })
    t.eq(s.children("w1:t1"), { "w1:p2", "w1:p3" })
  end)
end)

describe("Виды панелей", function()
  it("Панель с командой", function()
    s.env(s.snapshot({
      double.pane({ pane_id = "w1:p1", foreground_process = "cargo", cwd = "/src" }),
    }))
    local n = s.wait_node("w1:p1")
    t.eq(n.kind, "pane")
    t.eq(n.pane_kind, "command")
    t.match(n.label, "cargo")
    t.match(n.label, "/src")
    t.eq(n.state, nil)
  end)

  it("Панель с агентом", function()
    s.env(s.snapshot({
      double.pane({
        pane_id = "w1:p1",
        agent = "claude",
        display_agent = "opus",
        terminal_title = "✳ разбор журнала",
        terminal_title_stripped = "разбор журнала",
      }),
    }))
    local n = s.wait_node("w1:p1")
    t.eq(n.pane_kind, "agent")
    t.match(n.label, "opus")
    t.match(n.label, "разбор журнала")
  end)

  it("без display_agent подпись содержит agent", function()
    local p = double.pane({ pane_id = "w1:p1", agent = "codex", terminal_title = "сеанс" })
    p.display_agent = nil
    s.env(s.snapshot({ p }))
    local n = s.wait_node("w1:p1")
    t.match(n.label, "codex")
    t.match(n.label, "сеанс")
  end)
end)

describe("Агенты других видов", function()
  it("Агент не Claude Code", function()
    -- сессия задана, а образец с субагентами для неё есть: модель её всё равно не читает
    s.env(
      s.snapshot({
        double.pane({
          pane_id = "w1:p1",
          agent = "codex",
          agent_status = "working",
          session = fixtures.session_id("subagent-nested"),
        }),
      }),
      "subagent-nested"
    )
    local n = s.wait_node("w1:p1")
    t.eq(n.pane_kind, "agent")
    t.eq(n.children, {})
    t.eq(model._sessions()["w1:p1"], nil, "сессия не наблюдается")
  end)
end)

describe("Состояние вкладки", function()
  it("Агент ждёт ответа", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    s.wait_node("w1:t1")
    d:set_tab_status("w1:t1", "blocked")
    d:set_agent_status("w1:p1", "blocked")
    s.wait_node("w1:t1", function(n)
      return n.state == "blocked"
    end, "состояние blocked")
  end)

  it("неизвестное значение показывается как есть", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    s.wait_node("w1:t1")
    d:set_tab_status("w1:t1", "weird")
    d:set_agent_status("w1:p1", "working")
    s.wait_node("w1:t1", function(n)
      return n.state == "weird" and n.icon == "weird"
    end, "состояние как есть")
  end)

  it("Агент вышел", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    s.wait_node("w1:p1/a0000000000000005")
    local handle = model._sessions()["w1:p1"].handle
    local p = d:_pane("w1:p1")
    p.agent, p.agent_session, p.display_agent = nil, nil, nil
    p.agent_status = "unknown"
    p.foreground_process = "bash"
    d:emit("pane_updated", { pane = vim.deepcopy(p) })
    local n = s.wait_node("w1:p1", function(x)
      return x.pane_kind == "command"
    end, "панель с командой")
    t.eq(n.children, {})
    t.eq(model.get("w1:p1/a0000000000000005"), nil)
    t.eq(model._sessions()["w1:p1"], nil)
    t.ok(handle.closed, "наблюдение сессии закрыто")
  end)
end)

describe("Субагенты агента вкладки", function()
  it("Вложенные субагенты", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-nested") }), "subagent-nested")
    local a = s.wait_node("w1:p1/a0000000000000002")
    local b = model.get("w1:p1/a0000000000000001")
    t.eq(a.kind, "subagent")
    t.eq(a.parent, "w1:t1")
    t.eq(b.parent, a.id)
    t.eq(
      s.children("w1:t1"),
      { a.id },
      "строки панели агента вкладки нет"
    )
    t.eq(a.children, { b.id })
    t.match(a.label, "outer")
    t.match(a.label, "general%-purpose")
    t.eq(a.owner_pane, "w1:p1")
  end)
end)

describe("Агент без известной сессии", function()
  it("Сессия ещё не известна", function()
    local p = s.claude_pane("w1:p1", "owner-killed", { agent_session = vim.NIL })
    local d = s.env(s.snapshot({ p }), "owner-killed")
    local n = s.wait_node("w1:p1")
    t.eq(n.pane_kind, "agent")
    t.eq(n.children, {})
    local rec = d:_pane("w1:p1")
    rec.agent_session = {
      agent = "claude",
      kind = "id",
      source = "herdr:claude",
      value = fixtures.session_id("owner-killed"),
    }
    d:emit("pane_updated", { pane = vim.deepcopy(rec) })
    s.wait_node("w1:p1/a0000000000000005", nil, "субагент сессии")
  end)

  it("транскрипт не найден — панель без детей", function()
    s.env(s.snapshot({
      double.pane({ pane_id = "w1:p1", agent = "claude", session = fixtures.missing_session_id }),
    }))
    local n = s.wait_node("w1:p1")
    t.eq(n.children, {})
    t.ok(model._sessions()["w1:p1"], "создание транскрипта ожидается")
  end)
end)

describe("Фоновые команды", function()
  it("Команда агента", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "command-completed") }), "command-completed")
    local c = s.wait_node("w1:p1/bfixt0005")
    t.eq(c.kind, "task")
    t.eq(c.parent, "w1:t1")
    t.match(c.label, "Print lines 1%-8 with one%-second pauses")
    t.eq(c.owner_pane, "w1:p1")
  end)

  it("Команда субагента", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-command") }), "subagent-command")
    local c = s.wait_node("w1:p1/bfixt0003")
    t.eq(c.parent, "w1:p1/a0000000000000004")
    t.ok(vim.tbl_contains(model.get("w1:p1/a0000000000000004").children, c.id))
    t.ok(not vim.tbl_contains(s.children("w1:t1"), c.id))
  end)

  it("без description подпись — command", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "command-completed") }), "command-completed")
    s.wait_node("w1:p1/bfixt0005")
    local path = fixtures.transcript("command-completed", s.claude_dir)
    local sid = fixtures.session_id("command-completed")
    local out = s.claude_dir .. "/tmp/bnodesc01.output"
    write(out, "")
    local recs = require("data.util").bash_launch(
      sid,
      "toolu_01FixtureNoDesc0000000001",
      "bnodesc01",
      "make check",
      out
    )
    recs[1].message.content[1].input.description = nil
    fixtures.append(path, recs)
    local c = s.wait_node("w1:p1/bnodesc01")
    t.match(c.label, "make check")
  end)
end)

describe("Состояния субагентов и команд", function()
  it("Работающий субагент", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    local a = s.wait_node("w1:p1/a0000000000000005")
    t.eq(a.state, "running")
  end)

  it("Завершение фоновой команды", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "command-completed") }), "command-completed")
    local c = s.wait_node("w1:p1/bfixt0005")
    t.eq(c.state, "finished")
    t.match(c.label, "код выхода 0")
  end)

  it("Остановленная команда", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "command-taskstop") }), "command-taskstop")
    local c = s.wait_node("w1:p1/bfixt0004")
    t.eq(c.state, "finished")
    t.match(c.label, "остановлена")
  end)

  it(
    "остановленный субагент — завершён с пометкой остановки",
    function()
      s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-stopped") }), "subagent-stopped")
      local a = s.wait_node("w1:p1/a0000000000000006")
      t.eq(a.state, "finished")
      t.match(a.label, "остановлен")
    end
  )

  it("Упавший владелец", function()
    local d = s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "owner-killed"),
        s.claude_pane("w1:p2", "command-orphaned"),
      }),
      { "owner-killed", "command-orphaned" }
    )
    t.eq(s.wait_node("w1:p1/a0000000000000005").state, "running")
    t.eq(s.wait_node("w1:p2/bfixt0005").state, "running")
    d:pane_exited("w1:p1")
    d:pane_exited("w1:p2")
    s.wait_node("w1:p1/a0000000000000005", function(n)
      return n.state == "orphaned"
    end, "субагент оборван")
    s.wait_node("w1:p2/bfixt0005", function(n)
      return n.state == "orphaned"
    end, "команда оборвана")
    t.eq(model._sessions()["w1:p1"].alive, false)
  end)

  it(
    "завершённые узлы владельца после pane_exited остаются завершёнными",
    function()
      local d =
        s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-command") }), "subagent-command")
      s.wait_node("w1:p1/bfixt0003")
      d:pane_exited("w1:p1")
      t.wait(function()
        local x = model._sessions()["w1:p1"]
        return x and x.alive == false
      end, "владелец отмечен завершённым")
      t.eq(model.get("w1:p1/a0000000000000004").state, "finished")
      t.eq(model.get("w1:p1/bfixt0003").state, "finished")
    end
  )
end)

describe("Отметка завершения владельца", function()
  it(
    "pane_exited без сессии не обрывает сессию, начатую позже",
    function()
      local d = s.env(s.snapshot({ double.pane({ pane_id = "w1:p1" }) }))
      s.wait_node("w1:p1")
      d:pane_exited("w1:p1")
      t.wait(function()
        return model._exited()["w1:p1"] ~= nil
      end, "модель получила pane_exited")
      d.handlers["agent.start"](d, { pane_id = "w1:p1", kind = "claude" })
      s.wait_node("w1:p1", function(n)
        return n.pane_kind == "agent" and model._sessions()["w1:p1"] ~= nil
      end, "сессия нового агента")
      t.eq(model._sessions()["w1:p1"].alive, true)
    end
  )
end)

describe("Завершённые узлы", function()
  it("Завершённый узел остаётся", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-nested") }), "subagent-nested")
    local a = s.wait_node("w1:p1/a0000000000000002")
    t.eq(a.state, "finished")
    -- другие события herdr узел не убирают
    d:set_agent_status("w1:p1", "working")
    s.wait_node("w1:p1", function(n)
      return n.state == "working"
    end)
    t.eq(model.get("w1:p1/a0000000000000002").state, "finished")
    t.eq(
      model.visible(model.get("w1:p1/a0000000000000002")),
      false,
      "в окне дерева не показан, в модели остаётся"
    )
  end)

  it("Скрытие завершённых", function()
    require("claudr").setup({ show_finished = true })
    local d = s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "subagent-nested"),
        s.claude_pane("w1:p2", "owner-killed"),
        s.claude_pane("w1:p3", "command-orphaned"),
      }),
      { "subagent-nested", "owner-killed", "command-orphaned" }
    )
    d:pane_exited("w1:p3")
    s.wait_node("w1:p3/bfixt0005", function(n)
      return n.state == "orphaned"
    end)
    t.eq(model.show_finished(), true, "показ включён")
    local notified = 0
    local unsub = model.subscribe(function()
      notified = notified + 1
    end)
    vim.cmd("Claudr toggle-finished")
    unsub()
    t.ok(notified > 0, "подписчики уведомлены")
    t.eq(model.show_finished(), false)
    t.eq(model.visible(model.get("w1:p1/a0000000000000002")), false)
    t.eq(model.visible(model.get("w1:p1/a0000000000000001")), false)
    t.eq(model.visible(model.get("w1:p2/a0000000000000005")), true, "работающий")
    t.eq(model.visible(model.get("w1:p3/bfixt0005")), true, "оборванный")
    vim.cmd("Claudr toggle-finished")
    t.eq(model.visible(model.get("w1:p1/a0000000000000002")), true)
  end)

  it("Скрыты по умолчанию", function()
    require("claudr").setup()
    t.eq(model.show_finished(), false)
    s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "subagent-nested"),
        s.claude_pane("w1:p2", "command-completed"),
      }),
      { "subagent-nested", "command-completed" }
    )
    t.eq(model.visible(s.wait_node("w1:p1/a0000000000000002")), false, "субагент")
    t.eq(model.visible(s.wait_node("w1:p2/bfixt0005")), false, "команда")
  end)

  it("Показ по команде", function()
    require("claudr").setup()
    s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "subagent-nested"),
        s.claude_pane("w1:p2", "command-completed"),
      }),
      { "subagent-nested", "command-completed" }
    )
    s.wait_node("w1:p2/bfixt0005")
    vim.cmd("Claudr toggle-finished")
    t.eq(model.show_finished(), true)
    t.eq(model.visible(model.get("w1:p1/a0000000000000002")), true, "субагент")
    t.eq(model.visible(model.get("w1:p2/bfixt0005")), true, "команда")
  end)

  it("Закрытие панели владельца", function()
    local d = s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "subagent-command"),
        double.pane({ pane_id = "w1:p2" }),
      }),
      "subagent-command"
    )
    s.wait_node("w1:p1/bfixt0003")
    local handle = model._sessions()["w1:p1"].handle
    local _, idx = d:_pane("w1:p1")
    table.remove(d.state.panes, idx)
    d:emit("pane_closed", { pane_id = "w1:p1", workspace_id = "w1" })
    s.wait_gone("w1:p1")
    t.eq(model.get("w1:p1/a0000000000000004"), nil)
    t.eq(model.get("w1:p1/bfixt0003"), nil)
    t.eq(model._sessions()["w1:p1"], nil)
    t.ok(handle.closed, "наблюдение сессии закрыто")
    t.eq(s.children("w1:t1"), { "w1:p2" })
  end)

  it(
    "панель исчезла из снимка после pane_exited — узлы исчезают",
    function()
      local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
      s.wait_node("w1:p1/a0000000000000005")
      local handle = model._sessions()["w1:p1"].handle
      d:pane_exited("w1:p1", { vanish = true })
      s.wait_gone("w1:p1")
      t.eq(model.get("w1:p1/a0000000000000005"), nil)
      t.eq(model.get("w1"), nil)
      t.ok(handle.closed)
    end
  )
end)

describe("Обновление по событиям", function()
  it("Новый субагент", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "command-completed") }), "command-completed")
    s.wait_node("w1:p1/bfixt0005")
    local sid = fixtures.session_id("command-completed")
    local sub = fixtures.session_dir("command-completed", s.claude_dir) .. "/subagents"
    vim.fn.mkdir(sub, "p")
    write(
      sub .. "/agent-a0000000000000031.meta.json",
      '{"agentType":"Explore","description":"поиск по коду","toolUseId":"toolu_01FixtureNew0000000000001",'
        .. '"spawnDepth":1,"model":"haiku"}'
    )
    fixtures.append(sub .. "/agent-a0000000000000031.jsonl", {
      fixtures.user_record(sid, "задание субагенту"),
    })
    local a = s.wait_node("w1:p1/a0000000000000031", nil, "новый субагент")
    t.eq(a.parent, "w1:t1")
    t.eq(a.state, "running")
    t.match(a.label, "поиск по коду")
    t.match(a.label, "Explore")
  end)

  it("Ничего не происходит", function()
    local d = s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "subagent-command"),
        s.claude_pane("w1:p2", "owner-killed"),
        double.pane({ pane_id = "w1:p3" }),
      }),
      { "subagent-command", "owner-killed" }
    )
    s.wait_node("w1:p2/a0000000000000005")
    s.settle()
    local timers = s.timer_count()
    local requests = #d.requests
    local notified = 0
    local unsub = model.subscribe(function()
      notified = notified + 1
    end)
    local reads = s.count_reads()
    local ok, err = pcall(function()
      s.settle()
      s.settle()
    end)
    reads.restore()
    unsub()
    t.ok(ok, err)
    t.eq(reads.open, 0, "файлы не читаются: " .. table.concat(reads.paths, ", "))
    t.eq(reads.read, 0)
    t.eq(#d.requests, requests, "запросов к сокету нет")
    t.eq(notified, 0, "модель не перестраивается")
    t.eq(s.timer_count(), timers, "таймеры не запущены")
  end)

  it(
    "в коде дерева нет таймеров и отложенных вызовов, кроме таймера кадров",
    function()
      -- таймер кадров — единственный, в view.lua, под меткой WARNING (решение D38)
      local vf = assert(io.open(t.root .. "/lua/claudr/tree/view.lua", "r"))
      local vtext = vf:read("*a")
      vf:close()
      local _, timers = vtext:gsub("new_timer", "")
      t.eq(timers, 1, "один таймер кадров")
      t.ok(
        vtext:find("WARNING: таймер", 1, true),
        "метка WARNING над таймером кадров"
      )
      for _, pattern in ipairs({ "defer_fn", "timer_start", "new_idle", "new_check" }) do
        t.ok(not vtext:find(pattern, 1, true), "view.lua: " .. pattern)
      end
      for _, name in ipairs({ "init.lua", "model.lua" }) do
        local path = t.root .. "/lua/claudr/tree/" .. name
        local f = assert(io.open(path, "r"))
        local text = f:read("*a")
        f:close()
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

  it(
    "смена сессии панели закрывает прежнее наблюдение",
    function()
      local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), {
        "owner-killed",
        "subagent-nested",
      })
      s.wait_node("w1:p1/a0000000000000005")
      local old = model._sessions()["w1:p1"].handle
      local rec = d:_pane("w1:p1")
      rec.agent_session = {
        agent = "claude",
        kind = "id",
        source = "herdr:claude",
        value = fixtures.session_id("subagent-nested"),
      }
      d:emit("pane_updated", { pane = vim.deepcopy(rec) })
      s.wait_node("w1:p1/a0000000000000002", nil, "субагенты новой сессии")
      t.eq(model.get("w1:p1/a0000000000000005"), nil)
      t.ok(old.closed, "прежнее наблюдение закрыто")
    end
  )

  it(
    "Сервер недоступен: модель сообщает состояние «нет сервера»",
    function()
      model.start()
      t.wait(function()
        return model.status().status == "no_server"
      end, "нет сервера")
      t.eq(model.roots(), {})
    end
  )
end)

describe("Агент вкладки", function()
  it(
    "панель с агентом в фокусе, иначе первая по номеру",
    function()
      s.env(
        s.snapshot({
          double.pane({ pane_id = "w1:p1", number = 1 }),
          s.claude_pane("w1:p2", "owner-killed", { number = 2 }),
          s.claude_pane("w1:p3", "subagent-nested", { number = 3 }),
        }),
        { "owner-killed", "subagent-nested" }
      )
      local tab = s.wait_node("w1:t1")
      t.eq(tab.agent_pane, "w1:p2", "первая по номеру")
      t.eq(tab.phase_key, "w1:p2")
      t.eq(model.get("w1:p2").hidden, true)
      t.eq(model.agent_node(tab).id, "w1:p2")
      t.eq(model.pane_node(tab).id, "w1:p2")
      t.eq(model.row_of_pane("w1:p2").id, "w1:t1")
      t.eq(
        model.agent_node(model.get("w1")).id,
        "w1:p2",
        "workspace с одной вкладкой"
      )
    end
  )

  it("вид workspace — агент активной вкладки", function()
    s.env({
      workspaces = { double.workspace({ workspace_id = "w1", active_tab_id = "w1:t2" }) },
      tabs = {
        double.tab({ tab_id = "w1:t1", number = 1 }),
        double.tab({ tab_id = "w1:t2", number = 2 }),
      },
      panes = {
        double.pane({ pane_id = "w1:p1", tab_id = "w1:t1", agent = "codex" }),
        double.pane({ pane_id = "w1:p2", tab_id = "w1:t2", number = 1 }),
        double.pane({ pane_id = "w1:p3", tab_id = "w1:t2", number = 2, agent = "codex" }),
      },
    })
    local w = s.wait_node("w1")
    t.eq(model.pane_node(w).id, "w1:p3")
    t.eq(
      model.agent_node(w),
      nil,
      "у workspace с несколькими вкладками агента нет"
    )
  end)

  it("фокус выбирает агента", function()
    s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "owner-killed", { number = 1 }),
        s.claude_pane("w1:p3", "subagent-nested", { number = 2, focused = true }),
      }),
      { "owner-killed", "subagent-nested" }
    )
    s.wait_node("w1:p3/a0000000000000002")
    t.eq(model.get("w1:t1").agent_pane, "w1:p3")
    t.eq(model.get("w1:p3/a0000000000000002").parent, "w1:t1")
    t.eq(model.get("w1:p1/a0000000000000005").parent, "w1:p1")
  end)
end)

describe("Прочие агенты вкладки", function()
  it("Второй агент вкладки", function()
    s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "owner-killed", { number = 1, focused = true }),
        double.pane({ pane_id = "w1:p2", number = 2, foreground_process = "nvim" }),
        s.claude_pane("w1:p3", "subagent-nested", { number = 3, display_agent = "opus" }),
      }),
      { "owner-killed", "subagent-nested" }
    )
    local a = s.wait_node("w1:p3/a0000000000000002")
    local kids = s.children("w1:t1")
    t.eq(
      kids[1],
      "w1:p3",
      "строка прочего агента первой, затем субагенты агента вкладки"
    )
    t.ok(not vim.tbl_contains(kids, "w1:p1"), "строки агента вкладки нет")
    t.ok(not vim.tbl_contains(kids, "w1:p2"), "строки Neovim нет")
    t.ok(vim.tbl_contains(kids, "w1:p1/a0000000000000005"))
    local p3 = model.get("w1:p3")
    t.eq(p3.pane_kind, "agent")
    t.match(p3.label, "^opus")
    t.eq(a.parent, "w1:p3")
    t.eq(model.agent_node(p3).id, "w1:p3")
    t.eq(model.get("w1:p2").hidden, true)
  end)
end)

describe("Вкладка без агента", function()
  it("вид — панель в фокусе, без неё первая", function()
    s.env(s.snapshot({
      double.pane({ pane_id = "w1:p1", number = 1 }),
      double.pane({ pane_id = "w1:p4", number = 2, focused = true }),
    }))
    local tab = s.wait_node("w1:t1")
    t.eq(tab.agent_pane, nil)
    t.eq(model.agent_node(tab), nil)
    t.eq(model.pane_node(tab).id, "w1:p4")
    t.eq(s.children("w1:t1"), { "w1:p1", "w1:p4" })
  end)
end)

describe("Узел команды с выводом", function()
  it("команда без файла вывода не показывается", function()
    s.env(
      s.snapshot({ s.claude_pane("w1:p1", "command-completed") }),
      "command-completed",
      nil,
      { outputs = false }
    )
    s.wait_node("w1:t1")
    s.settle()
    t.eq(model.get("w1:p1/bfixt0005"), nil)
  end)
end)

describe("Вызовы Bash", function()
  it(
    "Работающий вызов под вкладкой, завершённый — под владельцем",
    function()
      s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-nested") }), "subagent-nested")
      s.wait_node("w1:p1/a0000000000000002")
      local tasks = fixtures.tasks_dir("subagent-nested", s.claude_dir)
      vim.fn.mkdir(tasks, "p")
      write(tasks .. "/bcall0009.output", "x")
      local n = s.wait_node("w1:p1/bcall0009", nil, "работающий вызов")
      t.eq(n.kind, "bash")
      t.eq(n.parent, "w1:t1")
      t.eq(n.state, "running")
      t.eq(n.label, "Bash", "команду определить нельзя")
      os.remove(tasks .. "/bcall0009.output")
      s.wait_gone("w1:p1/bcall0009", "вызов завершился")
      local sid = fixtures.session_id("subagent-nested")
      local sub = fixtures.session_dir("subagent-nested", s.claude_dir)
        .. "/subagents/agent-a0000000000000002.jsonl"
      fixtures.append(
        sub,
        require("data.util").bash_call(sid, "toolu_01FixtureCall00000000009", "make", {
          description = "Сборка",
          stdout = "ok",
        })
      )
      local c = s.wait_node(
        "w1:p1/toolu_01FixtureCall00000000009",
        nil,
        "завершённый вызов"
      )
      t.eq(c.parent, "w1:p1/a0000000000000002")
      t.eq(c.label, "Сборка")
      t.eq(c.state, "finished")
      t.eq(model.visible(c), false, "скрыт по умолчанию")
      t.eq(model.call_output(c).text, "ok")
    end
  )
end)

describe("Подпись субагента", function()
  it(
    "описание, первая строка задания, тип агента, идентификатор",
    function()
      local f = model._subagent_label
      t.eq(
        f({ id = "a1", description = "поиск", agent_type = "Explore" }),
        "поиск (Explore)"
      )
      t.eq(
        f({ id = "a1", prompt = "Проверить ветку", agent_type = "general-purpose" }),
        "Проверить ветку (general-purpose)"
      )
      t.eq(f({ id = "a1", agent_type = "general-purpose" }), "general-purpose")
      t.eq(f({ id = "a1" }), "a1")
      t.eq(
        f({ id = "a1", description = "поиск" }),
        "поиск",
        "без типа — без скобок"
      )
      local long = f({ id = "a1", prompt = string.rep("я", 100) })
      t.eq(vim.fn.strchars(long), model.PROMPT_LABEL_MAX)
      t.match(long, "…$")
    end
  )
end)
