-- Клиент herdr: путь сокета, кадры и ответы, идентификаторы, протокол, состав снимка.
local t = require("helpers.t")
local double = require("helpers.herdr_double")
local support = require("herdr.support")
local herdr = require("claudr.herdr")

local doubles = {}
local function track(d)
  table.insert(doubles, d)
  return d
end

after_each(function()
  herdr.stop()
  for _, d in ipairs(doubles) do
    d:close()
  end
  doubles = {}
end)

describe("Путь сокета", function()
  it("Neovim запущен внутри панели herdr", function()
    -- Сервер по умолчанию тоже есть: клиент должен выбрать путь из переменной.
    local default_dir = vim.env.XDG_CONFIG_HOME .. "/herdr"
    vim.fn.mkdir(default_dir, "p")
    local default = track(double.start({ dir = default_dir, snapshot = {}, env = false }))
    local d = track(double.start({ dir = support.dir(), snapshot = support.snapshot() }))
    t.eq(herdr.socket_path(), d.socket_path)
    herdr.start()
    support.wait_status(herdr, "connected")
    t.eq(d:count("ping"), 1)
    t.eq(default:count("ping"), 0)
  end)

  it("Neovim запущен вне herdr", function()
    t.eq(vim.env.HERDR_SOCKET_PATH, nil)
    local default_dir = vim.env.XDG_CONFIG_HOME .. "/herdr"
    vim.fn.mkdir(default_dir, "p")
    t.eq(herdr.socket_path(), default_dir .. "/herdr.sock")
    local d = track(double.start({ dir = default_dir, snapshot = support.snapshot(), env = false }))
    herdr.start()
    support.wait_status(herdr, "connected")
    t.eq(d:count("ping"), 1)
  end)

  it(
    "без XDG_CONFIG_HOME путь по умолчанию — ~/.config/herdr/herdr.sock",
    function()
      local saved = vim.env.XDG_CONFIG_HOME
      vim.uv.os_unsetenv("XDG_CONFIG_HOME")
      local ok, path = pcall(herdr.socket_path)
      vim.uv.os_setenv("XDG_CONFIG_HOME", saved)
      t.ok(ok, path)
      t.eq(path, vim.uv.os_homedir() .. "/.config/herdr/herdr.sock")
    end
  )
end)

describe("Кадры и соответствие ответов", function()
  it("Ответы приходят не по порядку", function()
    local d = track(support.connected(herdr))
    d:set_output("w2:p1", { lines = { "first" } })
    d:set_output("w2:p2", { lines = { "second" } })
    local rec = support.recorder(herdr)
    d:reply_order("reverse")
    local got = {}
    herdr.read_pane("w2:p1", {}, function(err, read)
      got.a = { err = err, text = read and read.text }
    end)
    herdr.read_pane("w2:p2", {}, function(err, read)
      got.b = { err = err, text = read and read.text }
    end)
    t.wait(function()
      return d:held_count("pane.read") == 2
    end, "оба запроса у сервера")
    local reads = {}
    for _, r in ipairs(d.requests) do
      if r.method == "pane.read" then
        table.insert(reads, r)
      end
    end
    -- Сервер обслуживает в соединении один запрос: у каждого запроса своё соединение.
    t.ok(reads[1].conn ~= reads[2].conn, "запросы на разных соединениях")
    d:release() -- сначала ответ на второй запрос
    d:reply_order("normal")
    t.wait(function()
      return got.a and got.b
    end, "оба ответа")
    t.eq(got.a, { text = "first" })
    t.eq(got.b, { text = "second" })
    vim.wait(0)
    t.eq(herdr.state().status, "connected")
    t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
    rec.unsubscribe()
  end)

  it(
    "несколько запросов подряд и одновременно — каждый своим соединением",
    function()
      local d = track(support.connected(herdr))
      local rec = support.recorder(herdr)
      -- Подряд: каждый следующий после ответа на предыдущий.
      for _ = 1, 3 do
        local err, result = support.call(herdr, "pane.send_keys", { pane_id = "w1:p1", keys = "x" })
        t.eq(err, nil)
        t.eq(result, { type = "ok" })
      end
      -- Одновременно: все в полёте до первого ответа.
      local results = {}
      for i = 1, 4 do
        herdr.read_pane("w2:p1", {}, function(err, read)
          results[i] = { err = err, read = read }
        end)
      end
      t.wait(function()
        return #results == 4 and results[1] and results[2] and results[3] and results[4]
      end, "ответы на одновременные запросы")
      for i = 1, 4 do
        t.eq(results[i].err, nil)
        t.eq(results[i].read.pane_id, "w2:p1")
      end
      local conns = {}
      for _, r in ipairs(d.requests) do
        if r.method == "pane.send_keys" or r.method == "pane.read" then
          t.ok(
            not conns[r.conn],
            "соединение запроса не используется повторно"
          )
          conns[r.conn] = true
        end
      end
      t.eq(vim.tbl_count(conns), 7)
      -- Закрытие соединения запроса после ответа — не потеря сервера.
      vim.wait(0)
      t.eq(herdr.state().status, "connected")
      t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
      t.eq(support.lifecycle_subscriptions(d), 1, "подписка не тронута")
      rec.unsubscribe()
    end
  )

  it(
    "обрыв соединения запроса до ответа — ошибка этого запроса, клиент остаётся подключённым",
    function()
      local d = track(support.connected(herdr))
      local rec = support.recorder(herdr)
      d:hold("pane.read")
      local got
      herdr.read_pane("w2:p1", {}, function(err)
        got = err
      end)
      t.wait(function()
        return d:held_count("pane.read") == 1
      end, "запрос у сервера")
      -- Сервер закрывает соединение запроса, не ответив.
      local conn_id = d:last("pane.read").conn
      d:_close_conn(d.connections[conn_id], false)
      t.wait(function()
        return got ~= nil
      end, "ошибка запросу")
      t.eq(got.code, "server_unavailable")
      d:release("pane.read")
      vim.wait(0)
      t.eq(herdr.state().status, "connected")
      t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
      local err = support.call(herdr, "pane.send_keys", { pane_id = "w1:p1", keys = "x" })
      t.eq(err, nil, "следующий запрос выполняется")
      rec.unsubscribe()
    end
  )

  it("Ошибка сервера", function()
    local d = track(support.connected(herdr))
    d:fail("pane.send_keys", "not_found", "pane not found")
    local err, result = support.call(herdr, "pane.send_keys", { pane_id = "w1:p1", keys = "x" })
    t.eq(err, { code = "not_found", message = "pane not found" })
    t.eq(result, nil)
  end)

  it(
    "запрос — строка JSON вида {id, method, params} с id-строкой",
    function()
      local d = track(support.connected(herdr))
      support.call(herdr, "pane.send_keys", { pane_id = "w1:p1", keys = "x" })
      local r = d:last("pane.send_keys")
      t.eq(type(r.id), "string")
      t.eq(r.params, { pane_id = "w1:p1", keys = "x" })
    end
  )
end)

describe("Идентификаторы — строки", function()
  it("Идентификатор с буквой", function()
    local snap = {
      workspaces = { double.workspace({ workspace_id = "w1a" }) },
      tabs = { double.tab({ tab_id = "w1a:t1b", workspace_id = "w1a" }) },
      panes = {
        double.pane({ pane_id = "w1a:p1c", workspace_id = "w1a", tab_id = "w1a:t1b" }),
        double.pane({ pane_id = "w1a:p10", workspace_id = "w1a", tab_id = "w1a:t1b" }),
      },
    }
    local d = track(support.connected(herdr, { snapshot = snap }))
    local panes = herdr.state().snapshot.panes
    t.eq(panes[1].pane_id, "w1a:p1c")
    t.eq(panes[2].pane_id, "w1a:p10")
    t.eq(herdr.state().snapshot.workspaces[1].workspace_id, "w1a")
    local err = support.call(herdr, "pane.send_keys", { pane_id = panes[1].pane_id, keys = "y" })
    t.eq(err, nil)
    t.eq(d:last("pane.send_keys").params.pane_id, "w1a:p1c")
    t.ok(
      support.pane_subscriptions(d)["w1a:p10"],
      "подписка по панели с буквой"
    )
  end)
end)

describe("Проверка версии протокола", function()
  it("Старый сервер", function()
    local d = track(double.start({ dir = support.dir(), snapshot = support.snapshot() }))
    d:set_protocol(21)
    local rec = support.recorder(herdr)
    herdr.start()
    support.wait_status(herdr, "incompatible")
    local msg = herdr.state().message
    t.match(msg, "22")
    t.match(msg, "21")
    t.eq(d:count("session.snapshot"), 0, "дерево не загружается")
    t.eq(d:count("events.subscribe"), 0)
    t.eq(herdr.state().snapshot.panes, {})
    local err = support.call(herdr, "pane.read", { pane_id = "w1:p1" })
    t.eq(err.code, "server_unavailable")
    t.wait(function()
      return rec:seen_status("incompatible")
    end, "подписчик узнал о несовместимости")
    rec.unsubscribe()
  end)

  it("Новый сервер", function()
    local snap = support.snapshot()
    snap.panes[2].future_pane_field = { nested = true }
    local d = track(double.start({ dir = support.dir(), snapshot = snap }))
    d:set_protocol(23, { future_field = "x", capabilities = { "a", "b" } })
    herdr.start()
    support.wait_status(herdr, "connected")
    t.eq(#herdr.state().snapshot.panes, 3)
    t.eq(herdr.state().message, nil)
  end)
end)

describe("Состав снимка", function()
  it("Сессия агента", function()
    track(support.connected(herdr))
    local snap = herdr.state().snapshot
    local p1 = snap.panes[1]
    t.eq(p1.agent, "claude")
    t.eq(p1.agent_session.kind, "id")
    t.eq(p1.agent_session.agent, "claude")
    t.eq(herdr.session_id(p1), "s-1")
    t.eq(herdr.session_id(snap.panes[2]), nil)
    -- Поля, которые использует клиент, есть в записях снимка.
    for _, key in ipairs({ "workspace_id", "label", "number", "agent_status", "active_tab_id" }) do
      t.ok(snap.workspaces[1][key] ~= nil, "workspace." .. key)
    end
    for _, key in ipairs({ "tab_id", "workspace_id", "label", "number" }) do
      t.ok(snap.tabs[1][key] ~= nil, "tab." .. key)
    end
    for _, key in ipairs({ "pane_id", "tab_id", "workspace_id", "foreground_process", "cwd" }) do
      t.ok(p1[key] ~= nil, "pane." .. key)
    end
    t.eq(p1.display_agent, "haiku")
    t.eq(p1.revision, 0)
  end)

  it("Неизвестное состояние", function()
    local snap = support.snapshot()
    snap.panes[1].agent_status = "pondering"
    snap.workspaces[1].agent_status = "pondering"
    local d = track(support.connected(herdr, { snapshot = snap }))
    t.eq(herdr.state().snapshot.panes[1].agent_status, "pondering")
    t.eq(herdr.state().snapshot.workspaces[1].agent_status, "pondering")
    local rec = support.recorder(herdr)
    d:set_agent_status("w1:p1", "contemplating")
    t.wait(function()
      return rec:has_event("pane.agent_status_changed", "w1:p1")
        and herdr.state().snapshot.panes[1].agent_status == "contemplating"
    end, "новое неизвестное состояние в снимке")
    t.eq(herdr.state().status, "connected")
    rec.unsubscribe()
  end)
end)
