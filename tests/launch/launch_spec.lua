-- Запуск дополнительной сессии Claude Code (спецификация session-launch): вкладка и деление,
-- `agent.start` без ожидания, готовность по состоянию панели, ошибки, диалог доверия,
-- идентификатор сессии, узел в дереве.
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local ms = require("messaging.support")
local s = ms.tree
local model = require("claudr.tree.model")
local launch = require("claudr.launch")
local messaging = require("claudr.messaging")
local herdr = require("claudr.herdr")

after_each(function()
  ms.reset()
end)

local function env(extra_panes)
  local panes = { s.claude_pane("w1:p1", "owner-dialogue") }
  for _, p in ipairs(extra_panes or {}) do
    panes[#panes + 1] = p
  end
  local d = s.env(s.snapshot(panes), "owner-dialogue")
  s.wait_node("w1:p1")
  return d
end

-- Запуск и ожидание завершения; возвращает ошибку и результат `on_done`.
local function run(opts)
  local finished, err, result = false, nil, nil
  opts.on_done = function(e, r)
    finished, err, result = true, e, r
  end
  launch.launch(opts)
  t.wait(function()
    return finished
  end, "завершение запуска")
  return err, result
end

describe("Выбор workspace и вкладки", function()
  it("Выбор из перечня", function()
    local d = s.env({
      workspaces = {
        s.double.workspace({ workspace_id = "w1", label = "первый" }),
        s.double.workspace({ workspace_id = "w2", label = "второй" }),
      },
      tabs = { s.double.tab({ tab_id = "w1:t1" }), s.double.tab({ tab_id = "w2:t1" }) },
      panes = { s.double.pane({ pane_id = "w1:p1" }), s.double.pane({ pane_id = "w2:p1" }) },
    })
    local rec = ms.stub({
      select = {
        function(items)
          return items[2]
        end,
      },
    })
    local err = run({})
    t.eq(err, nil)
    t.eq(#rec.selects, 1)
    t.eq(#rec.selects[1].items, 2, "перечень workspace через vim.ui.select")
    t.eq(rec.selects[1].items[1].workspace_id, "w1")
    t.eq(d:last("tab.create").params.workspace_id, "w2")
  end)

  it("узел дерева задаёт цель без вопросов", function()
    local d = env()
    local rec = ms.stub({})
    local err = run({ node = model.get("w1") })
    t.eq(err, nil)
    t.eq(#rec.selects, 0)
    t.eq(d:last("tab.create").params.workspace_id, "w1")
  end)

  it("вкладка и панель как цель новой вкладки", function()
    local d = env()
    ms.stub({})
    run({ node = model.get("w1:t1"), mode = "tab" })
    run({ node = model.get("w1:p1"), mode = "tab" })
    t.eq(d:count("tab.create"), 2)
    for _, r in ipairs(d.requests) do
      if r.method == "tab.create" then
        t.eq(r.params.workspace_id, "w1")
      end
    end
  end)
end)

describe("Новая сессия в новой вкладке", function()
  it("Запуск в workspace", function()
    local d = env()
    ms.stub({})
    local before = #d.requests
    local err, result = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err, nil)
    t.eq(ms.methods_after(d, before), { "tab.create", "agent.start" })
    local created = d:last("tab.create")
    t.eq(created.params.workspace_id, "w1")
    local start = d:last("agent.start")
    t.eq(start.params.kind, "claude")
    t.eq(start.params.pane_id, result.pane_id)
    -- панель для agent.start — корневая панель созданной вкладки
    local snap = herdr.state().snapshot
    local found
    for _, p in ipairs(snap.panes) do
      if p.pane_id == result.pane_id then
        found = p
      end
    end
    t.ok(
      found,
      "корневая панель созданной вкладки есть в снимке"
    )
    t.ok(start.params.name and start.params.name ~= "", "имя агента задано")
  end)
end)

describe("Новая сессия делением панели", function()
  it("Запуск делением", function()
    local d = env()
    local rec = ms.stub({
      select = {
        function(items)
          return items[1]
        end,
      },
    })
    local before = #d.requests
    local err, result = run({ node = model.get("w1:p1"), mode = "split" })
    t.eq(err, nil)
    t.eq(#rec.selects, 1)
    t.eq(rec.selects[1].opts.prompt, "Направление деления:")
    t.eq(ms.methods_after(d, before), { "pane.split", "agent.start" })
    local split = d:last("pane.split")
    t.eq(split.params.target_pane_id, "w1:p1")
    t.eq(split.params.direction, "right")
    local start = d:last("agent.start")
    t.eq(start.params.kind, "claude")
    t.eq(start.params.pane_id, result.pane_id)
    t.ok(result.pane_id ~= "w1:p1", "агент запущен в созданной панели")
  end)

  it(
    "панель выбирается из перечня панелей вкладки",
    function()
      local d = env({ s.double.pane({ pane_id = "w1:p2", tab_id = "w1:t1" }) })
      local rec = ms.stub({
        select = {
          function(items)
            return items[2]
          end,
          2,
        },
      })
      local err = run({ node = model.get("w1:t1"), mode = "split" })
      t.eq(err, nil)
      t.eq(#rec.selects, 2)
      t.eq(#rec.selects[1].items, 2, "перечень панелей вкладки")
      t.eq(d:last("pane.split").params.target_pane_id, "w1:p2")
      t.eq(d:last("pane.split").params.direction, "down")
    end
  )

  it(
    "узел панели без режима: выбор способа запуска",
    function()
      local d = env()
      local rec = ms.stub({
        select = {
          function(items)
            return items[2]
          end,
          1,
        },
      })
      run({ node = model.get("w1:p1") })
      t.eq(#rec.selects, 2)
      t.eq(rec.selects[1].opts.prompt, "Запуск сессии:")
      t.eq(d:count("pane.split"), 1)
    end
  )
end)

describe("Рабочий каталог", function()
  it("Запуск без каталога", function()
    local d = env()
    ms.stub({ select = { 1 } })
    run({ node = model.get("w1"), mode = "tab" })
    t.eq(d:last("tab.create").params.cwd, nil)
    t.eq(vim.tbl_contains(vim.tbl_keys(d:last("tab.create").params), "cwd"), false)
    run({ node = model.get("w1:p1"), mode = "split" })
    t.eq(d:last("pane.split").params.cwd, nil)
    t.eq(d:last("agent.start").params.cwd, nil)
  end)
end)

describe("Запуск без блокировки Neovim", function()
  it("Агент запускается", function()
    local d = env()
    local rec = ms.stub({})
    d:set_start_status("unknown")
    d:hold("agent.start")
    local finished = false
    local result
    launch.launch({
      node = model.get("w1"),
      mode = "tab",
      on_done = function(_, r)
        finished, result = true, r
      end,
    })
    -- вызов вернулся сразу; Neovim отзывчив, пока сервер не ответил
    t.wait(function()
      return d:held_count("agent.start") == 1
    end, "agent.start удержан")
    t.eq(finished, false)
    t.eq(vim.api.nvim_eval("1 + 1"), 2)
    d:release("agent.start")
    t.wait(function()
      return finished
    end, "ответ agent.start")
    t.eq(d:last("agent.start").params.timeout_ms, nil, "без timeout_ms")
    t.ok(
      ms.noted(rec, "запускается"),
      "сообщение «агент запускается»"
    )
    -- агент виден в дереве в состоянии unknown, о готовности не сообщается
    s.wait_node(result.pane_id, function(n)
      return n.pane_kind == "agent"
    end, "панель с агентом")
    t.eq(ms.noted(rec, "готов$"), false)
    t.eq(vim.api.nvim_eval("1 + 1"), 2)
  end)

  it("Агент готов", function()
    local d = env()
    local rec = ms.stub({})
    d:set_start_status("unknown")
    local err, result = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err, nil)
    t.ok(ms.noted(rec, "запускается"))
    s.wait_node(result.pane_id, function(n)
      return n.pane_kind == "agent"
    end, "панель с агентом")
    t.eq(ms.noted(rec, "готов$"), false)
    d:set_agent_status(result.pane_id, "idle")
    t.wait(function()
      return ms.noted(rec, "агент в панели " .. result.pane_id .. " готов")
    end, "сообщение о готовности")
    -- дальнейшие смены состояния новых сообщений о запуске не дают
    local n = #rec.notes
    d:set_agent_status(result.pane_id, "working")
    d:set_agent_status(result.pane_id, "idle")
    s.wait_node(result.pane_id, function(node)
      return node.state == "idle"
    end, "узел снова idle")
    d:set_agent_status(result.pane_id, "blocked")
    s.wait_node(result.pane_id, function(node)
      return node.state == "blocked"
    end, "узел blocked")
    t.eq(#rec.notes, n, "новых сообщений нет")
  end)

  it(
    "Агент готов: состояние idle пришло до ответа agent.start",
    function()
      env()
      local rec = ms.stub({})
      local _, result = run({ node = model.get("w1"), mode = "tab" })
      t.wait(function()
        return ms.noted(rec, "агент в панели " .. result.pane_id .. " готов")
      end, "сообщение о готовности")
      t.ok(ms.noted(rec, "запускается"))
    end
  )

  it("Панель закрыта до готовности", function()
    local d = env()
    local rec = ms.stub({})
    d:set_start_status("unknown")
    local _, result = run({ node = model.get("w1"), mode = "tab" })
    s.wait_node(result.pane_id, function(n)
      return n.pane_kind == "agent"
    end, "панель с агентом")
    d:pane_exited(result.pane_id, { vanish = true })
    t.wait(function()
      return ms.noted(rec, "закрыта", vim.log.levels.WARN)
    end, "сообщение о закрытой панели")
    t.eq(ms.noted(rec, "готов$"), false)
    t.eq(d:count("agent.start"), 1)
  end)
end)

describe("Ошибки запуска", function()
  it("Агент не запустился", function()
    local d = env()
    local rec = ms.stub({})
    d:fail("agent.start", "agent_failed", "не удалось запустить")
    local err, result = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err.code, "agent_failed")
    t.ok(ms.noted(rec, "agent_failed", vim.log.levels.ERROR))
    t.ok(ms.noted(rec, "не удалось запустить"))
    -- вкладка осталась открытой, ничего не закрывалось
    local tab =
      s.wait_node(model.get("w1").children[#model.get("w1").children], nil, "вкладка")
    t.eq(tab.kind, "tab")
    t.ok(model.get(result.pane_id), "панель осталась")
    t.eq(d:count("agent.start"), 1)
  end)

  it("ошибка tab.create и pane.split", function()
    local d = env()
    local rec = ms.stub({})
    d:fail("tab.create", "workspace_not_found", "нет такого workspace")
    local err = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err.code, "workspace_not_found")
    t.ok(ms.noted(rec, "workspace_not_found"))
    t.ok(ms.noted(rec, "нет такого workspace"))
    t.eq(d:count("agent.start"), 0)
    d:fail("pane.split", "pane_not_found", "нет панели")
    err = run({ node = model.get("w1:p1"), mode = "split", direction = "down" })
    t.eq(err.code, "pane_not_found")
    t.ok(ms.noted(rec, "pane.split: pane_not_found"))
    t.eq(d:count("agent.start"), 0)
  end)
end)

describe("Агент не готов", function()
  it("Каталог без доверия", function()
    local d = env()
    local rec = ms.stub({})
    d:set_start_status("blocked")
    local err, result = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err, nil)
    t.ok(ms.noted(rec, "запускается"))
    t.wait(function()
      return ms.noted(rec, "не готов", vim.log.levels.WARN)
    end, "сообщение «не готов»")
    t.ok(ms.noted(rec, "диалог доверия"))
    t.ok(ms.noted(rec, ":Claudr attach"))
    t.ok(ms.noted(rec, ":Claudr keys"))
    t.eq(ms.noted(rec, "агент в панели " .. result.pane_id .. " готов"), false)
    t.eq(d:count("agent.start"), 1, "повторного agent.start нет")
    local pane = s.wait_node(result.pane_id, function(n)
      return n.pane_kind == "agent" and n.state == "blocked"
    end, "панель остаётся, агент blocked")
    t.eq(pane.kind, "pane")
  end)

  it("Ответ на диалог", function()
    local d = env()
    local rec = ms.stub({ input = { "down enter" } })
    d:set_start_status("blocked")
    local _, result = run({ node = model.get("w1"), mode = "tab" })
    s.wait_node(result.pane_id, function(n)
      return n.state == "blocked"
    end)
    t.wait(function()
      return ms.noted(rec, "не готов")
    end, "сообщение «не готов»")
    -- ответ на диалог клавишами (:Claudr keys)
    messaging.send_keys({ pane_id = result.pane_id })
    t.wait(function()
      return d:count("pane.send_keys") == 1
    end, "pane.send_keys")
    t.eq(d:last("pane.send_keys").params.keys, { "down", "enter" })
    t.eq(ms.noted(rec, "агент в панели " .. result.pane_id .. " готов"), false)
    d:set_agent_status(result.pane_id, "idle")
    s.wait_node(result.pane_id, function(n)
      return n.state == "idle"
    end, "узел панели показывает idle по событию")
    t.wait(function()
      return ms.noted(rec, "агент в панели " .. result.pane_id .. " готов")
    end, "сообщение «готов» после ответа на диалог")
    t.eq(d:count("agent.start"), 1)
    -- после «готов» слежение снято: новые смены состояния сообщений не дают
    local n = #rec.notes
    d:set_agent_status(result.pane_id, "blocked")
    s.wait_node(result.pane_id, function(node)
      return node.state == "blocked"
    end, "узел blocked")
    t.eq(#rec.notes, n, "новых сообщений нет")
  end)

  it(
    "Панель закрыта до готовности: после сообщения «не готов»",
    function()
      local d = env()
      local rec = ms.stub({})
      d:set_start_status("blocked")
      local _, result = run({ node = model.get("w1"), mode = "tab" })
      t.wait(function()
        return ms.noted(rec, "не готов")
      end, "сообщение «не готов»")
      d:pane_exited(result.pane_id, { vanish = true })
      t.wait(function()
        return ms.noted(rec, "закрыта", vim.log.levels.WARN)
      end, "сообщение о закрытой панели")
      t.eq(ms.noted(rec, "агент в панели " .. result.pane_id .. " готов"), false)
    end
  )

  it("Сервер ответил agent_not_ready", function()
    local d = env()
    local rec = ms.stub({})
    d:fail("agent.start", "agent_not_ready")
    local err, result = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err.code, "agent_not_ready")
    t.ok(ms.noted(rec, "agent.start: agent_not_ready", vim.log.levels.ERROR))
    t.ok(ms.noted(rec, "is blocked during startup"), "текст ошибки сервера")
    t.eq(ms.noted(rec, "запускается"), false)
    t.eq(d:count("agent.start"), 1, "повторного agent.start нет")
    s.wait_node(result.pane_id, function(n)
      return n.pane_kind == "agent"
    end, "панель остаётся")
  end)
end)

describe("Идентификатор сессии нового агента", function()
  it("Сессия без сообщений", function()
    env()
    local rec = ms.stub({})
    local err, result = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err, nil)
    t.match(result.session_id, "^%S+$")
    local node = s.wait_node(result.pane_id, function(n)
      return n.pane_kind == "agent" and model._sessions()[n.id] ~= nil
    end, "узел панели связан с сессией")
    t.eq(herdr.session_id(node.data), result.session_id)
    t.eq(model._sessions()[node.id].sid, result.session_id)
    t.eq(
      model._sessions()[node.id].handle:state().transcript,
      nil,
      "транскрипта ещё нет"
    )
    for _, n in ipairs(rec.notes) do
      t.ok(n.level ~= vim.log.levels.ERROR, "ошибок нет: " .. n.msg)
    end
  end)

  it("Первое сообщение", function()
    env()
    ms.stub({})
    local _, result = run({ node = model.get("w1"), mode = "tab" })
    local sid = result.session_id
    s.wait_node(result.pane_id, function(n)
      return model._sessions()[n.id] ~= nil
    end, "сессия отслеживается")
    local entry = model._sessions()[result.pane_id]
    t.eq(entry.handle:state().transcript, nil)
    -- первое сообщение: Claude Code создаёт транскрипт `<сессия>.jsonl` и файлы субагентов
    local sample = "subagent-command"
    fixtures.install(sample, vim.uv.os_getenv("CLAUDE_CONFIG_DIR"))
    local sample_sid = fixtures.session_id(sample)
    local root = vim.uv.os_getenv("CLAUDE_CONFIG_DIR") .. "/projects/" .. fixtures.project
    t.ok(vim.uv.fs_rename(root .. "/" .. sample_sid, root .. "/" .. sid))
    t.ok(vim.uv.fs_rename(root .. "/" .. sample_sid .. ".jsonl", root .. "/" .. sid .. ".jsonl"))
    t.wait(function()
      local st = entry.handle:state()
      return st.transcript ~= nil and next(st.subagents) ~= nil
    end, "транскрипт и субагенты сессии прочитаны")
    t.eq(entry.handle:state().transcript, root .. "/" .. sid .. ".jsonl")
    s.wait_node(result.pane_id .. "/a0000000000000004", nil, "субагент в дереве")
  end)
end)

describe("Новая сессия в дереве", function()
  it("Появление узла", function()
    local d = env()
    ms.stub({})
    local _, result = run({ node = model.get("w1"), mode = "tab" })
    local pane = s.wait_node(result.pane_id, function(n)
      return n.pane_kind == "agent"
    end, "узел новой панели с агентом")
    t.eq(model.get(pane.parent).kind, "tab")
    t.eq(model.get(pane.parent).parent, "w1")
    t.ok(d:count("agent.start") == 1)
    -- деление
    local _, r2 = run({ node = model.get("w1:p1"), mode = "split", direction = "right" })
    local pane2 = s.wait_node(r2.pane_id, function(n)
      return n.pane_kind == "agent"
    end, "узел панели после деления")
    t.eq(pane2.parent, "w1:t1")
  end)
end)

describe("Сервер недоступен", function()
  it("Запуск без сервера", function()
    local rec = ms.stub({})
    local err = run({ workspace_id = "w1", mode = "tab" })
    t.eq(err.code, "server_unavailable")
    t.ok(ms.noted(rec, "недоступен", vim.log.levels.ERROR))
    t.ok(ms.noted(rec, "ничего не создано"))
    t.eq(#rec.selects, 0)
  end)

  it("сервер пропал после подключения", function()
    local d = env()
    d:stop()
    t.wait(function()
      return herdr.state().status ~= "connected"
    end, "потеря сервера")
    local rec = ms.stub({})
    local err = run({ node = model.get("w1"), mode = "tab" })
    t.eq(err.code, "server_unavailable")
    t.ok(ms.noted(rec, "недоступен"))
    t.eq(d:count("tab.create"), 0)
  end)
end)

describe("Подкоманды и клавиши дерева", function()
  it("регистрируются в setup", function()
    local commands = require("claudr.commands")
    launch.setup()
    t.ok(commands.get("launch"))
    t.eq(require("claudr.tree.view").action("launch").key, "L")
  end)
end)
