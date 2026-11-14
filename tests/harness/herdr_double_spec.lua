-- Собственные тесты двойника сервера herdr и поддельного `herdr`: оснастка проверяется на
-- себе, без кода плагина. Кадры сверяются с наблюдавшимися у herdr 0.9.5 дословно.
local t = require("helpers.t")
local double = require("helpers.herdr_double")

local uv = vim.uv

-- Простой клиент сокета для проверок: кадры строками и разобранными.
local function connect(path)
  local c = { lines = {}, frames = {}, closed = false, seq = 0 }
  c.pipe = uv.new_pipe(false)
  local connected = false
  c.pipe:connect(path, function(err)
    assert(not err, err)
    connected = true
    local buf = ""
    c.pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then
        c.closed = true
        c.pipe:close()
        return
      end
      buf = buf .. chunk
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        table.insert(c.lines, line)
        table.insert(c.frames, vim.json.decode(line))
      end
    end)
  end)
  t.wait(function()
    return connected
  end, "подключение к двойнику")
  function c:send(method, params)
    self.seq = self.seq + 1
    local id = tostring(self.seq)
    self.pipe:write(vim.json.encode({ id = id, method = method, params = params or {} }) .. "\n")
    return id
  end
  function c:response(id)
    for i, f in ipairs(self.frames) do
      if f.id == id then
        return f, self.lines[i]
      end
    end
  end
  function c:wait_response(id)
    t.wait(function()
      return self:response(id) ~= nil
    end, "ответ " .. id)
    return self:response(id)
  end
  function c:call(method, params)
    return self:wait_response(self:send(method, params))
  end
  function c:close()
    if not self.closed and not self.pipe:is_closing() then
      self.pipe:close()
    end
  end
  return c
end

local function basic_snapshot()
  return {
    workspaces = { double.workspace({ workspace_id = "w1", label = "ws1" }) },
    tabs = { double.tab({ tab_id = "w1:t1" }) },
    panes = {
      double.pane({ pane_id = "w1:p1", agent = "claude", agent_status = "idle", session = "s-1" }),
      double.pane({ pane_id = "w1:p2" }),
    },
  }
end

local d
local clients
local function client()
  local c = connect(d.socket_path)
  table.insert(clients, c)
  return c
end

local test_no = 0
before_each(function()
  clients = {}
  -- Свой каталог на каждый тест: журналы поддельного herdr не смешиваются.
  test_no = test_no + 1
  local dir = t.tmpdir() .. "/d" .. test_no
  vim.fn.mkdir(dir, "p")
  d = double.start({ dir = dir, snapshot = basic_snapshot() })
end)

after_each(function()
  for _, c in ipairs(clients) do
    c:close()
  end
  d:close()
end)

describe("сокет и ping", function()
  it(
    "двойник слушает свой сокет в каталоге теста и задаёт HERDR_SOCKET_PATH",
    function()
      t.eq(d.socket_path, d.dir .. "/herdr.sock")
      t.eq(uv.fs_stat(d.socket_path).type, "socket")
      t.eq(vim.env.HERDR_SOCKET_PATH, d.socket_path)
    end
  )

  it("ping отвечает протоколом 22 кадром как у herdr", function()
    local _, line = client():call("ping")
    t.eq(line, '{"id":"1","result":{"protocol":22,"type":"pong","version":"0.9.5"}}')
  end)

  it("протокол и лишние поля ping задаёт тест", function()
    d:set_protocol(21)
    t.eq(client():call("ping").result.protocol, 21)
    d:set_protocol(23, { future_field = "x" })
    local f = client():call("ping")
    t.eq(f.result.protocol, 23)
    t.eq(f.result.future_field, "x")
  end)

  it("неизвестный метод отвечает ошибкой", function()
    local f = client():call("no.such")
    t.eq(f.error.code, "invalid_request")
  end)

  it(
    "соединение запросов закрывается после ответа",
    function()
      local c = client()
      t.eq(c:call("ping").result.type, "pong")
      t.wait(function()
        return c.closed
      end, "закрытие соединения сервером")
      t.eq(#c.lines, 1)
    end
  )

  it(
    "второй запрос в том же соединении — закрытие без ответа",
    function()
      d:hold("ping")
      local c = client()
      local a = c:send("ping")
      t.wait(function()
        return d:held_count("ping") == 1
      end, "первый запрос у сервера")
      c:send("session.snapshot")
      t.wait(function()
        return c.closed
      end, "сброс соединения")
      d:release("ping")
      t.eq(#c.lines, 0, "ответа нет ни на один запрос")
      t.eq(c:response(a), nil)
      t.eq(d:count("session.snapshot"), 0, "второй запрос не обработан")
    end
  )
end)

describe("session.snapshot", function()
  it(
    "снимок содержит записи и вычисленные поля в формате herdr",
    function()
      local f = client():call("session.snapshot")
      t.eq(f.result.type, "session_snapshot")
      local s = f.result.snapshot
      t.eq(s.protocol, 22)
      t.eq(s.version, "0.9.5")
      t.eq(#s.workspaces, 1)
      t.eq(s.workspaces[1].pane_count, 2)
      t.eq(s.workspaces[1].tab_count, 1)
      t.eq(s.tabs[1].pane_count, 2)
      t.eq(#s.panes, 2)
      t.eq(s.panes[1].agent_session, {
        agent = "claude",
        kind = "id",
        source = "herdr:claude",
        value = "s-1",
      })
      t.match(s.panes[2].terminal_id, "^term_%x+$")
      t.eq(#s.agents, 1)
      t.eq(#s.layouts, 1)
      t.eq(s.focused_pane_id, "w1:p1")
    end
  )

  it(
    "ключи кадра идут по алфавиту, id ответа первым",
    function()
      local _, line = client():call("session.snapshot")
      t.match(line, '^{"id":"1","result":{"snapshot":{"agents":')
      t.match(line, '"type":"session_snapshot"}}$')
    end
  )

  it(
    "идентификаторы с буквами и неизвестные поля передаются как есть",
    function()
      d:set_snapshot({
        workspaces = { double.workspace({ workspace_id = "w3T", future = 1 }) },
        tabs = { double.tab({ tab_id = "w3T:t1" }) },
        panes = { double.pane({ pane_id = "w3T:p1", agent_status = "thinking" }) },
      })
      local s = client():call("session.snapshot").result.snapshot
      t.eq(s.workspaces[1].workspace_id, "w3T")
      t.eq(s.workspaces[1].future, 1)
      t.eq(s.panes[1].tab_id, "w3T:t1")
      t.eq(s.panes[1].agent_status, "thinking")
    end
  )
end)

describe("events.subscribe", function()
  local function subscribe(c, subs)
    return c:call("events.subscribe", { subscriptions = subs })
  end

  it("подписка отвечает subscription_started", function()
    local _, line = subscribe(client(), { { type = "pane.created" } })
    t.eq(line, '{"id":"1","result":{"type":"subscription_started"}}')
    t.eq(#d.subscriptions, 1)
  end)

  it(
    "общее событие приходит через подчёркивание с type в data",
    function()
      local c = client()
      subscribe(c, { { type = "pane.closed" }, { type = "pane.created" } })
      t.eq(d:emit("pane_closed", { pane_id = "w1:p2", workspace_id = "w1" }), 1)
      t.wait(function()
        return #c.lines == 2
      end)
      t.eq(
        c.lines[2],
        '{"data":{"pane_id":"w1:p2","type":"pane_closed","workspace_id":"w1"},"event":"pane_closed"}'
      )
    end
  )

  it(
    "по-панельное событие приходит через точку без type и только своей панели",
    function()
      local c = client()
      subscribe(c, { { type = "pane.agent_status_changed", pane_id = "w1:p1" } })
      t.eq(d:emit("pane.agent_status_changed", { agent_status = "working", pane_id = "w1:p2" }), 0)
      d:emit("pane.agent_status_changed", {
        agent = "claude",
        agent_status = "working",
        pane_id = "w1:p1",
        workspace_id = "w1",
      })
      t.wait(function()
        return #c.lines == 2
      end)
      t.eq(
        c.lines[2],
        '{"data":{"agent":"claude","agent_status":"working","pane_id":"w1:p1","workspace_id":"w1"},'
          .. '"event":"pane.agent_status_changed"}'
      )
    end
  )

  it("событие без подписки на него не приходит", function()
    local c = client()
    subscribe(c, { { type = "tab.created" } })
    t.eq(d:emit("pane_created", { pane = double.pane({ pane_id = "w1:p9" }) }), 0)
    d:emit_raw('{"marker":true}')
    t.wait(function()
      return #c.lines == 2
    end)
    t.eq(c.lines[2], '{"marker":true}')
  end)

  it(
    "неверная запись подписки отклоняет весь запрос",
    function()
      local c = client()
      local f = subscribe(c, {
        { type = "pane.created" },
        { type = "pane.output_changed", pane_id = "w1:p404" },
      })
      t.eq(f.error.code, "pane_not_found")
      t.eq(#d.subscriptions, 0)
      t.eq(d:emit("pane_created", {}), 0)
      t.wait(function()
        return c.closed
      end, "закрытие соединения после отказа")
    end
  )

  it(
    "events_lost — ошибка и закрытие соединения подписки",
    function()
      local c = client()
      subscribe(c, { { type = "pane.created" } })
      d:events_lost()
      t.wait(function()
        return c.closed
      end, "закрытие соединения")
      t.eq(c.frames[2].id, "1")
      t.eq(c.frames[2].error.code, "events_lost")
      t.eq(#d.subscriptions, 0)
    end
  )

  -- Подписка по панелям и общая подписка, как их держит клиент.
  local function pane_and_lifecycle()
    local panes = client()
    subscribe(panes, {
      { type = "pane.output_changed", pane_id = "w1:p1" },
      { type = "pane.output_changed", pane_id = "w1:p2" },
    })
    local general = client()
    subscribe(general, { { type = "pane.closed" }, { type = "pane.exited" } })
    return panes, general
  end

  local function check_pane_not_found(panes, general, pane_id)
    t.wait(function()
      return panes.closed
    end, "конец потока подписки по панелям")
    t.eq(#panes.lines, 2)
    t.eq(
      panes.lines[2],
      '{"id":"1","error":{"code":"pane_not_found","message":"pane ' .. pane_id .. ' not found"}}'
    )
    t.eq(#d.subscriptions, 1, "общая подписка осталась")
    t.ok(not general.closed)
  end

  it(
    "закрытие подписанной панели — кадр pane_not_found и конец потока подписки по панелям",
    function()
      local panes, general = pane_and_lifecycle()
      table.remove(d.state.panes, 2)
      t.eq(d:emit("pane_closed", { pane_id = "w1:p2", workspace_id = "w1" }), 1)
      check_pane_not_found(panes, general, "w1:p2")
      t.wait(function()
        return #general.lines == 2
      end, "pane_closed общей подписке")
      t.eq(general.frames[2].event, "pane_closed")
    end
  )

  it(
    "исчезновение подписанной панели при выходе процесса — кадр pane_not_found",
    function()
      local panes, general = pane_and_lifecycle()
      d:pane_exited("w1:p2", { vanish = true })
      check_pane_not_found(panes, general, "w1:p2")
    end
  )

  it(
    "выход процесса без исчезновения панели подписку по панелям не завершает",
    function()
      local panes, general = pane_and_lifecycle()
      d:pane_exited("w1:p2")
      t.wait(function()
        return #general.lines == 2
      end, "pane_exited общей подписке")
      t.ok(not panes.closed)
      t.eq(#d.subscriptions, 2)
    end
  )

  it("server_unavailable подписке — ошибка и закрытие", function()
    local c = client()
    d:fail("events.subscribe", "server_unavailable")
    local id = c:send("events.subscribe", { subscriptions = { { type = "pane.created" } } })
    t.wait(function()
      return c.closed
    end, "закрытие соединения")
    local _, line = c:response(id)
    t.eq(
      line,
      '{"id":"1","error":{"code":"server_unavailable",'
        .. '"message":"request handling failed: app response channel closed"}}'
    )
  end)
end)

describe("остановка и перезапуск", function()
  it(
    "stop закрывает соединения без кадра и удаляет файл сокета",
    function()
      local c = client()
      c:call("events.subscribe", { subscriptions = { { type = "pane.created" } } })
      d:stop()
      t.wait(function()
        return c.closed
      end, "конец потока подписки")
      t.eq(#c.lines, 1)
      t.eq(uv.fs_stat(d.socket_path), nil)
    end
  )

  it(
    "restart создаёт файл сокета заново: событие файловой системы и прежний снимок",
    function()
      d:stop()
      local created = false
      local w = uv.new_fs_event()
      w:start(d.dir, {}, function(_, fname)
        if fname == "herdr.sock" and uv.fs_stat(d.socket_path) then
          created = true
        end
      end)
      d:restart()
      t.wait(function()
        return created
      end, "создание файла сокета")
      w:stop()
      w:close()
      local s = client():call("session.snapshot").result.snapshot
      t.eq(#s.panes, 2)
    end
  )
end)

describe("pane.read", function()
  local lines = {}
  for i = 1, 3000 do
    lines[i] = tostring(i)
  end
  table.insert(lines, "@sh-5.3$ ")

  before_each(function()
    d:set_output("w1:p2", { lines = lines, revision = 7 })
  end)

  local function read(params)
    params.pane_id = params.pane_id or "w1:p2"
    return client():call("pane.read", params)
  end

  it("recent без числа строк отдаёт 80 строк и truncated", function()
    local r = read({ source = "recent" }).result.read
    t.eq(#vim.split(r.text, "\n", { trimempty = true }), 80)
    t.match(r.text, "^2922\n")
    t.match(r.text, "\n@sh%-5%.3%$\n$")
    t.eq(r.truncated, true)
    t.eq(r.revision, 7)
    t.eq(r.source, "recent")
    t.eq(r.format, "text")
    t.eq(r.tab_id, "w1:t1")
  end)

  it("recent с 5000 строк отдаёт не более 1000 и truncated", function()
    local r = read({ source = "recent", lines = 5000 }).result.read
    t.eq(#vim.split(r.text, "\n", { trimempty = true }), 1000)
    t.eq(r.truncated, true)
  end)

  it("visible отдаёт экран высотой 40 строк без truncated", function()
    local r = read({ source = "visible", lines = 5 }).result.read
    t.eq(#vim.split(r.text, "\n", { trimempty = true }), 40)
    t.eq(r.truncated, false)
  end)

  it(
    "recent_unwrapped склеивает перенесённую строку, recent сохраняет перенос",
    function()
      d:set_output("w1:p2", { lines = { "a", string.rep("x", 130), "b" } })
      local wrapped = read({ source = "recent", lines = 3 }).result.read.text
      local unwrapped = read({ source = "recent_unwrapped", lines = 3 }).result.read.text
      t.eq(wrapped, string.rep("x", 120) .. "\n" .. string.rep("x", 10) .. "\nb\n")
      t.eq(unwrapped, "a\n" .. string.rep("x", 130) .. "\nb")
    end
  )

  it(
    "формат ansi — последовательности оформления и \\r\\n, text — чистый текст",
    function()
      d:set_output("w1:p2", {
        lines = {
          "\27[0m\27[38;5;1mRED\27[0m \27[0m\27[1m\27[38;5;2mgreen\27[0m",
          "@sh-5.3$ ",
        },
      })
      t.eq(
        read({ source = "recent", format = "ansi" }).result.read.text,
        "\27[0m\27[38;5;1mRED\27[0m \27[0m\27[1m\27[38;5;2mgreen\27[0m\r\n@sh-5.3$ "
      )
      t.eq(read({ source = "recent", format = "text" }).result.read.text, "RED green\n@sh-5.3$\n")
    end
  )

  it(
    "полноэкранная программа — один экран для всех источников",
    function()
      local screen = {}
      for i = 1, 41 do
        screen[i] = "row " .. i
      end
      d:set_output("w1:p1", { lines = screen, height = 41, fullscreen = true })
      local texts = {}
      for _, src in ipairs({ "visible", "recent", "recent_unwrapped" }) do
        local r = read({ pane_id = "w1:p1", source = src, lines = 1000 }).result.read
        t.eq(r.truncated, false)
        texts[src] = vim.trim(r.text)
      end
      t.eq(texts.recent, texts.visible)
      t.eq(texts.recent_unwrapped, texts.visible)
      t.eq(#vim.split(texts.visible, "\n"), 41)
    end
  )

  it("чтение панели, которой нет, — ошибка not found", function()
    t.eq(read({ pane_id = "w1:p404", source = "visible" }).error.code, "pane_not_found")
  end)
end)

describe("pane.send_keys и agent.*", function()
  it(
    "pane.send_keys принимает клавиши и учитывает запрос",
    function()
      local f = client():call("pane.send_keys", { pane_id = "w1:p1", keys = { "down", "enter" } })
      t.eq(f.result, { type = "ok" })
      t.eq(d:last("pane.send_keys").params.keys, { "down", "enter" })
    end
  )

  it("agent.prompt агенту в idle отвечает agent_prompted", function()
    local f = client():call("agent.prompt", { target = "w1:p1", text = "привет" })
    t.eq(f.result.type, "agent_prompted")
    t.eq(f.result.agent.pane_id, "w1:p1")
    t.eq(d:last("agent.prompt").params.text, "привет")
  end)

  it("agent.prompt агенту в blocked — ошибка agent_blocked", function()
    d:set_agent_status("w1:p1", "blocked")
    local f = client():call("agent.prompt", { target = "w1:p1", text = "x" })
    t.eq(f.error, {
      code = "agent_blocked",
      message = "agent w1:p1 is blocked and requires interactive input",
    })
  end)

  it("agent.prompt без агента — agent_not_found", function()
    local f = client():call("agent.prompt", { target = "w1:p2", text = "x" })
    t.eq(f.error.code, "agent_not_found")
    t.eq(f.error.message, "agent target w1:p2 not found")
  end)

  it(
    "agent.start отвечает agent_info с agent_session и даёт события",
    function()
      local sub = client()
      sub:call("events.subscribe", {
        subscriptions = {
          { type = "pane.agent_detected" },
          { type = "pane.agent_status_changed", pane_id = "w1:p2" },
        },
      })
      local f = client():call("agent.start", { name = "c1", kind = "claude", pane_id = "w1:p2" })
      t.eq(f.result.type, "agent_info")
      local a = f.result.agent
      t.eq(a.name, "c1")
      t.eq(a.agent_status, "idle")
      t.eq(a.interactive_ready, true)
      t.eq(a.agent_session.source, "herdr:claude")
      t.ok(a.agent_session.value ~= "")
      t.wait(function()
        return #sub.frames == 4
      end, "события запуска агента")
      t.eq(sub.frames[2].event, "pane.agent_status_changed")
      t.eq(sub.frames[2].data.agent, nil)
      t.eq(sub.frames[2].data.agent_status, "unknown")
      t.eq(sub.frames[3].event, "pane_agent_detected")
      t.eq(sub.frames[4].data.agent_status, "idle")
      local s = client():call("session.snapshot").result.snapshot
      t.eq(s.panes[2].agent_session.value, a.agent_session.value)
      t.eq(client():call("agent.prompt", { target = "c1", text = "x" }).result.agent.name, "c1")
    end
  )

  it(
    "agent_not_ready оставляет агента в панели в состоянии blocked",
    function()
      d:fail("agent.start", "agent_not_ready")
      local f = client():call("agent.start", { name = "c1", kind = "claude", pane_id = "w1:p2" })
      t.eq(f.error, {
        code = "agent_not_ready",
        message = "agent c1 is blocked during startup and is not ready for prompts",
      })
      local s = client():call("session.snapshot").result.snapshot
      t.eq(s.panes[2].agent_status, "blocked")
    end
  )

  it(
    "fail отвечает ошибкой с заданным кодом и текстом только на следующий вызов",
    function()
      d:fail("pane.send_keys", "not_found", "pane not found")
      t.eq(client():call("pane.send_keys", { pane_id = "w1:p1", keys = { "x" } }).error, {
        code = "not_found",
        message = "pane not found",
      })
      t.eq(client():call("pane.send_keys", { pane_id = "w1:p1", keys = { "x" } }).result.type, "ok")
    end
  )
end)

describe("tab.create и pane.split", function()
  it(
    "tab.create отвечает tab и root_pane, вкладка попадает в снимок с событиями",
    function()
      local sub = client()
      sub:call(
        "events.subscribe",
        { subscriptions = { { type = "tab.created" }, { type = "pane.created" } } }
      )
      local f = client():call("tab.create", { workspace_id = "w1" })
      t.eq(f.result.type, "tab_created")
      t.eq(f.result.tab.tab_id, "w1:t2")
      t.eq(f.result.root_pane.pane_id, "w1:p3")
      t.eq(f.result.root_pane.tab_id, "w1:t2")
      t.eq(d:last("tab.create").params.cwd, nil)
      t.wait(function()
        return #sub.frames == 3
      end)
      t.eq(sub.frames[2].event, "tab_created")
      t.eq(sub.frames[3].event, "pane_created")
      t.eq(sub.frames[3].data.type, "pane_created")
      local s = client():call("session.snapshot").result.snapshot
      t.eq(#s.tabs, 2)
      t.eq(#s.panes, 3)
    end
  )

  it("pane.split отвечает записью pane", function()
    local f = client():call("pane.split", { target_pane_id = "w1:p2", direction = "right" })
    t.eq(f.result.type, "pane_info")
    t.eq(f.result.pane.pane_id, "w1:p3")
    t.eq(f.result.pane.tab_id, "w1:t1")
  end)
end)

describe("выход процесса панели", function()
  it(
    "pane_exited без кода; панель и workspace исчезают без pane_closed и workspace_closed",
    function()
      d:set_snapshot({
        workspaces = {
          double.workspace({ workspace_id = "w1" }),
          double.workspace({ workspace_id = "w2" }),
        },
        tabs = { double.tab({ tab_id = "w1:t1" }), double.tab({ tab_id = "w2:t1" }) },
        panes = { double.pane({ pane_id = "w1:p1" }), double.pane({ pane_id = "w2:p1" }) },
      })
      local sub = client()
      sub:call("events.subscribe", {
        subscriptions = {
          { type = "pane.updated" },
          { type = "pane.exited" },
          { type = "pane.closed" },
          { type = "workspace.closed" },
        },
      })
      d:pane_exited("w2:p1", { vanish = true })
      t.wait(function()
        return #sub.frames == 3
      end)
      t.eq(sub.frames[2].event, "pane_updated")
      t.eq(
        sub.lines[3],
        '{"data":{"pane_id":"w2:p1","type":"pane_exited","workspace_id":"w2"},"event":"pane_exited"}'
      )
      local s = client():call("session.snapshot").result.snapshot
      t.eq(#s.workspaces, 1)
      t.eq(#s.tabs, 1)
      t.eq(#s.panes, 1)
      t.eq(s.panes[1].pane_id, "w1:p1")
    end
  )
end)

describe("удержание ответов", function()
  it(
    "удержанный снимок вычислен в момент запроса; событие во время снимка",
    function()
      local sub = client()
      sub:call("events.subscribe", { subscriptions = { { type = "pane.created" } } })
      d:hold("session.snapshot")
      local c = client()
      local id = c:send("session.snapshot")
      t.wait(function()
        return d:held_count("session.snapshot") == 1
      end)
      table.insert(d.state.panes, double.pane({ pane_id = "w1:p3" }))
      d:emit("pane_created", { pane = double.pane({ pane_id = "w1:p3" }) })
      t.wait(function()
        return #sub.frames == 2
      end)
      t.eq(c:response(id), nil)
      d:release("session.snapshot")
      t.eq(#c:wait_response(id).result.snapshot.panes, 2)
      t.eq(#client():call("session.snapshot").result.snapshot.panes, 3)
    end
  )

  it(
    "ответы не по порядку: второй запрос получает ответ первым",
    function()
      local ca, cb = client(), client()
      d:reply_order("reverse")
      ca:send("ping")
      t.wait(function()
        return d:held_count() == 1
      end)
      cb:send("session.snapshot")
      t.wait(function()
        return d:held_count() == 2
      end)
      -- Порядок записи ответов двойником: по соединениям, в которые они ушли.
      local written = {}
      local write = d._write
      d._write = function(self, c, line)
        table.insert(written, c.id)
        return write(self, c, line)
      end
      d:release()
      d._write = nil
      t.eq(written, { 2, 1 }, "сначала ответ второму соединению")
      t.wait(function()
        return #ca.frames == 1 and #cb.frames == 1
      end)
      t.eq(ca.frames[1].result.type, "pong")
      t.eq(cb.frames[1].result.type, "session_snapshot")
      d:reply_order("normal")
      t.eq(client():call("ping").result.type, "pong")
    end
  )
end)

-- Поддельный herdr ----------------------------------------------------------------------

describe("поддельный herdr: terminal session observe", function()
  it(
    "печатает кадры terminal.frame: первый полный, далее приращения; сам не завершается",
    function()
      local stdout, exited = "", nil
      local proc = vim.system({ "herdr", "terminal", "session", "observe", "w1:p1" }, {
        stdout = function(_, data)
          if data then
            stdout = stdout .. data
          end
        end,
      }, function(r)
        exited = r
      end)
      d:frame("w1:p1", "\27[2J\27[1;1Hscreen", { full = true })
      t.wait(function()
        return select(2, stdout:gsub("\n", "")) == 1
      end, "полный кадр")
      d:frame("w1:p1", "\27[5;1Hmore")
      t.wait(function()
        return select(2, stdout:gsub("\n", "")) == 2
      end, "приращение")
      local lines = vim.split(stdout, "\n", { trimempty = true })
      t.eq(
        lines[1],
        '{"bytes":"'
          .. vim.base64.encode("\27[2J\27[1;1Hscreen")
          .. '","encoding":"ansi","full":true,"height":40,"seq":1,"type":"terminal.frame","width":120}'
      )
      local second = vim.json.decode(lines[2])
      t.eq(second.full, false)
      t.eq(second.seq, 2)
      t.eq(vim.base64.decode(second.bytes), "\27[5;1Hmore")
      t.eq(exited, nil)
      proc:kill("sigterm")
      t.wait(function()
        return exited ~= nil
      end, "выход по сигналу")
      t.eq(exited.code, 143)
      t.eq(d:calls()[1].argv, { "terminal", "session", "observe", "w1:p1" })
    end
  )

  -- Запуск наблюдения с учётом вывода и выхода; `cmd` по умолчанию — поддельный `herdr`.
  local function start_observe(cmd)
    local p = { stdout = "", stderr = "" }
    p.proc = vim.system(cmd or { "herdr", "terminal", "session", "observe", "w1:p1" }, {
      stdout = function(_, data)
        if data then
          p.stdout = p.stdout .. data
        end
      end,
      stderr = function(_, data)
        if data then
          p.stderr = p.stderr .. data
        end
      end,
    }, function(r)
      p.exited = r
    end)
    return p
  end

  local function wait_gone(p, msg)
    t.wait(function()
      return p.exited ~= nil
    end, msg)
    t.ok(uv.kill(p.proc.pid, 0) ~= 0, "процесс " .. p.proc.pid .. " жив")
  end

  it(
    "SIGTERM сразу после запуска, до первого кадра, завершает наблюдение",
    function()
      -- Несколько процессов: сигнал приходит в разные моменты запуска Neovim и сценария.
      -- Код выхода зависит от момента (сигнал во время запуска Neovim завершает его самого),
      -- проверяется только выход.
      local ps = {}
      for i = 1, 8 do
        ps[i] = start_observe()
        ps[i].proc:kill("sigterm")
      end
      for i, p in ipairs(ps) do
        wait_gone(p, "выход процесса " .. i)
      end
    end
  )

  it(
    "SIGTERM сразу после первого кадра завершает наблюдение кодом 143",
    function()
      d:frame("w1:p1", "screen", { full = true })
      local p = start_observe()
      t.wait(function()
        return p.stdout:find("\n", 1, true) ~= nil
      end, "первый кадр")
      p.proc:kill("sigterm")
      wait_gone(p, "выход по сигналу")
      t.eq(p.exited.code, 143)
    end
  )

  it(
    "SIGTERM, пришедший до установки обработчиков сигналов, завершает наблюдение кодом 143",
    function()
      -- Сигнал себе в начале сценария `nvim -l`, до кода поддельного `herdr`: Neovim ставит
      -- его в свою очередь событий, обработчики `vim.uv` его уже не получат.
      local main = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        .. "/helpers/fake_herdr/main.lua"
      local pre = vim.fn.tempname() .. ".lua"
      vim.fn.writefile({
        'vim.uv.kill(vim.uv.os_getpid(), "sigterm")',
        "arg[0] = " .. vim.inspect(main),
        "dofile(arg[0])",
      }, pre)
      local p = start_observe({
        "nvim",
        "--clean",
        "--headless",
        "-l",
        pre,
        "terminal",
        "session",
        "observe",
        "w1:p1",
      })
      wait_gone(p, "выход по сигналу")
      os.remove(pre)
      t.eq(p.exited.code, 143)
    end
  )
end)

describe("поддельный herdr: terminal attach", function()
  -- Запуск в псевдотерминале; вывод копится, выход ловится по событию.
  local function attach(args)
    local p = { out = "", code = nil }
    local cmd = { "herdr", "terminal", "attach" }
    vim.list_extend(cmd, args)
    p.job = vim.fn.jobstart(cmd, {
      pty = true,
      width = 100,
      height = 30,
      on_stdout = function(_, data)
        p.out = p.out .. table.concat(data, "\n")
      end,
      on_exit = function(_, code)
        p.code = code
      end,
    })
    t.ok(p.job > 0, "процесс запущен")
    return p
  end

  local function wait_out(p, pattern, msg)
    t.wait(function()
      return p.out:find(pattern, 1, true) ~= nil or p.code ~= nil
    end, msg)
    t.ok(
      p.out:find(pattern, 1, true),
      "нет «" .. pattern .. "» в выводе: " .. vim.inspect(p.out)
    )
  end

  local function wait_exit(p)
    t.wait(function()
      return p.code ~= nil
    end, "выход процесса")
    return p.code
  end

  it(
    "рисует экран, пишет ввод в журнал, Ctrl+b q отключает с кодом 0",
    function()
      d:set_attach_screen("term_a", "SCREEN-LINE\nsecond")
      local p = attach({ "term_a" })
      wait_out(p, "SCREEN-LINE\r\nsecond", "экран")
      t.eq(d:attached("term_a"), tostring(vim.fn.jobpid(p.job)))
      vim.fn.chansend(p.job, "echo HELLO\r\2\2")
      vim.fn.chansend(p.job, "\2q")
      t.eq(wait_exit(p), 0)
      t.eq(d:attach_input("term_a"), "echo HELLO\r\2")
      t.eq(d:attached("term_a"), nil)
      t.eq(d:calls()[1].argv, { "terminal", "attach", "term_a" })
    end
  )

  it(
    "второму клиенту без --takeover — отказ текстом и кодом как у herdr",
    function()
      d:mark_attached("term_b")
      local p = attach({ "term_b" })
      t.eq(wait_exit(p), 1)
      t.ok(
        p.out:find(
          "herdr: server shut down: terminal attach failed: terminal term_b "
            .. "already has an attached client; retry with --takeover\r\n",
          1,
          true
        ),
        vim.inspect(p.out)
      )
      t.eq(d:attached("term_b"), "external")
    end
  )

  it(
    "--takeover вытесняет прежнего клиента: тот завершается с сообщением",
    function()
      local first = attach({ "term_c" })
      wait_out(first, "fake herdr: terminal term_c", "экран первого клиента")
      local second = attach({ "--takeover", "term_c" })
      wait_out(second, "fake herdr: terminal term_c", "экран второго клиента")
      t.eq(wait_exit(first), 1)
      t.ok(first.out:find("herdr: server shut down: terminal attach taken over\r\n", 1, true))
      t.eq(d:attached("term_c"), tostring(vim.fn.jobpid(second.job)))
      t.eq(second.code, nil)
      vim.fn.chansend(second.job, "\2q")
      t.eq(wait_exit(second), 0)
      t.eq(d:attached("term_c"), nil)
    end
  )

  it("без терминала — ошибка ZeroSizedGridError и код 1", function()
    local r
    vim.system({ "herdr", "terminal", "attach", "term_d" }, {}, function(res)
      r = res
    end)
    t.wait(function()
      return r ~= nil
    end, "выход процесса")
    t.eq(r.code, 1)
    t.match(r.stderr, "ZeroSizedGridError")
  end)
end)
