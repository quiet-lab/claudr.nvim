-- Клиент herdr: недоступный сервер, остановка и перезапуск, отсутствие таймеров и опроса.
local t = require("helpers.t")
local double = require("helpers.herdr_double")
local support = require("herdr.support")
local herdr = require("claudr.herdr")

local uv = vim.uv

local d, rec
local cleanups = {}

local function defer_cleanup(fn)
  table.insert(cleanups, fn)
end

-- Счётчик соединений, которые открывает клиент: обёртка над `vim.uv.new_pipe`.
local function count_pipes()
  local orig = uv.new_pipe
  local counter = { n = 0 }
  uv.new_pipe = function(...)
    counter.n = counter.n + 1
    return orig(...)
  end
  defer_cleanup(function()
    uv.new_pipe = orig
  end)
  return counter
end

-- Событие файловой системы в каталоге `dir`, увиденное наблюдателем теста: к этому
-- моменту наблюдатель клиента на том же каталоге своё событие тоже получил.
local function fs_touch(dir, name)
  local seen = false
  local ev = uv.new_fs_event()
  ev:start(dir, {}, function(_, filename)
    if filename == name then
      seen = true
    end
  end)
  local f = assert(io.open(dir .. "/" .. name, "w"))
  f:write("x")
  f:close()
  t.wait(function()
    return seen
  end, "событие файловой системы " .. name)
  ev:stop()
  ev:close()
  -- Дать циклу обработать всё, что пришло вместе с событием.
  vim.wait(0)
end

local function set_socket_env(path)
  uv.os_setenv("HERDR_SOCKET_PATH", path)
  defer_cleanup(function()
    uv.os_unsetenv("HERDR_SOCKET_PATH")
  end)
end

before_each(function()
  d = nil
  rec = support.recorder(herdr)
end)

after_each(function()
  rec.unsubscribe()
  herdr.stop()
  if d then
    d:close()
  end
  for i = #cleanups, 1, -1 do
    cleanups[i]()
  end
  cleanups = {}
end)

describe("Недоступный сервер", function()
  it("Запуск без сервера", function()
    local dir = support.dir()
    set_socket_env(dir .. "/herdr.sock")
    require("claudr").setup()
    herdr.start()
    support.wait_status(herdr, "no_server")
    t.wait(function()
      return rec:seen_status("no_server")
    end, "подписчик видит «нет сервера»")
    local answered
    herdr.request("agent.prompt", { target = "w1:p1", text = "hi" }, function(err)
      answered = err
    end)
    t.ok(answered, "ответ сразу, без ожидания")
    t.eq(answered.code, "server_unavailable")
    t.match(answered.message, "недоступен")
    local read_err
    herdr.read_pane("w1:p1", {}, function(err)
      read_err = err
    end)
    t.eq(read_err and read_err.code, "server_unavailable")
  end)
end)

describe("Остановка сервера", function()
  it("Остановка при открытой подписке", function()
    d = support.connected(herdr)
    d:stop()
    support.wait_status(herdr, "no_server")
    t.ok(herdr.state().stale, "кэш устарел")
    local err = support.call(herdr, "pane.read", { pane_id = "w1:p1" })
    t.eq(err.code, "server_unavailable")
    -- Клиент ждёт появления сокета.
    d:restart()
    support.wait_status(herdr, "connected")
  end)

  it("Подписка во время остановки", function()
    local notified = 0
    local orig = vim.notify
    vim.notify = function(...)
      notified = notified + 1
      return orig(...)
    end
    defer_cleanup(function()
      vim.notify = orig
    end)
    d = double.start({ dir = support.dir(), snapshot = support.snapshot() })
    d:fail("events.subscribe", "server_unavailable")
    herdr.start()
    support.wait_status(herdr, "no_server")
    t.wait(function()
      return rec:seen_status("no_server")
    end, "подписчик видит «нет сервера»")
    vim.wait(0)
    t.eq(notified, 0, "ошибка не показывается как сбой")
    t.eq(herdr.state().message, "сервер herdr недоступен")
    t.eq(d:count("session.snapshot"), 0)
  end)

  it(
    "ждущий запрос при остановке получает server_unavailable",
    function()
      d = support.connected(herdr)
      d:hold("pane.read")
      local got
      herdr.read_pane("w1:p1", {}, function(err)
        got = err
      end)
      t.wait(function()
        return d:held_count("pane.read") == 1
      end, "запрос у сервера")
      d:stop()
      t.wait(function()
        return got ~= nil
      end, "ответ ждущему")
      t.eq(got.code, "server_unavailable")
    end
  )
end)

describe("Перезапуск сервера", function()
  it("Подмена сервера", function()
    d = support.connected(herdr)
    local subscribes = d:count("events.subscribe")
    d:stop()
    support.wait_status(herdr, "no_server")
    d:set_snapshot({
      workspaces = { double.workspace({ workspace_id = "w3" }) },
      tabs = { double.tab({ tab_id = "w3:t1" }) },
      panes = { double.pane({ pane_id = "w3:p1" }) },
    })
    local snapshots = d:count("session.snapshot")
    d:restart()
    support.wait_status(herdr, "connected")
    local snap = herdr.state().snapshot
    t.ok(support.has_pane(snap, "w3:p1"))
    t.ok(not support.has_pane(snap, "w1:p1"), "прежнее дерево заменено")
    t.ok(d:count("session.snapshot") > snapshots)
    support.wait_pane_subscriptions(d, { "w3:p1" })
    t.ok(
      d:count("events.subscribe") >= subscribes + 2,
      "подписки поданы заново"
    )
    t.eq(d:count("ping"), 2, "протокол проверен заново")
  end)

  it("Сервер запущен после Neovim", function()
    local dir = support.dir()
    set_socket_env(dir .. "/herdr.sock")
    herdr.start()
    support.wait_status(herdr, "no_server")
    d = double.start({ dir = dir, snapshot = support.snapshot(), env = false })
    support.wait_status(herdr, "connected")
    t.eq(#herdr.state().snapshot.panes, 3)
    t.ok(rec:seen_status("no_server"))
  end)

  it(
    "каталога сокета ещё нет: наблюдение спускается по мере создания каталогов",
    function()
      local base = support.dir()
      local dir = base .. "/run/herdr"
      set_socket_env(dir .. "/herdr.sock")
      local pipes = count_pipes()
      herdr.start()
      support.wait_status(herdr, "no_server")
      t.eq(pipes.n, 1)
      vim.fn.mkdir(base .. "/run")
      fs_touch(base .. "/run", "marker")
      vim.fn.mkdir(dir)
      fs_touch(dir, "marker")
      t.eq(
        pipes.n,
        1,
        "без файла сокета попыток подключения нет"
      )
      d = double.start({ dir = dir, snapshot = support.snapshot(), env = false })
      support.wait_status(herdr, "connected")
      t.eq(#herdr.state().snapshot.panes, 3)
    end
  )

  it("Сервер восстановил состояние", function()
    d = support.connected(herdr)
    local before = vim.deepcopy(herdr.state().snapshot)
    d:stop()
    support.wait_status(herdr, "no_server")
    local mark = #d.requests
    d:restart()
    support.wait_status(herdr, "connected")
    support.wait_pane_subscriptions(d, { "w1:p1", "w2:p1", "w2:p2" })
    local after = herdr.state().snapshot
    t.eq(after.panes, before.panes)
    t.eq(after.workspaces, before.workspaces)
    for i = mark + 1, #d.requests do
      local m = d.requests[i].method
      t.ok(
        m == "ping" or m == "events.subscribe" or m == "session.snapshot",
        "лишний запрос " .. m
      )
    end
  end)
end)

describe("Отсутствие таймеров и опроса", function()
  it("Сервер недоступен длительное время", function()
    local dir = support.dir()
    set_socket_env(dir .. "/herdr.sock")
    local pipes = count_pipes()
    herdr.start()
    support.wait_status(herdr, "no_server")
    t.eq(pipes.n, 1, "одна попытка при запуске")
    -- Посторонние события в каталоге сокета и обработка цикла событий не вызывают
    -- попыток подключения.
    fs_touch(dir, "session.json")
    fs_touch(dir, "herdr-client.sock")
    for _ = 1, 100 do
      vim.wait(0)
    end
    t.eq(
      pipes.n,
      1,
      "попыток подключения без события о файле сокета нет"
    )
    -- Событие о файле сокета вызывает подключение.
    d = double.start({ dir = dir, snapshot = support.snapshot(), env = false })
    support.wait_status(herdr, "connected")
    t.ok(pipes.n > 1)
  end)

  it(
    "сокет есть, но сервер не принимает: попытка только по событию",
    function()
      local dir = support.dir()
      local path = dir .. "/herdr.sock"
      set_socket_env(path)
      -- Файл сокета без слушающего сервера: привязан, но `listen` не вызван.
      local srv = uv.new_pipe(false)
      assert(srv:bind(path))
      defer_cleanup(function()
        srv:close()
      end)
      t.ok(uv.fs_stat(path), "файл сокета есть")
      local pipes = count_pipes()
      herdr.start()
      support.wait_status(herdr, "no_server")
      t.eq(pipes.n, 1)
      local n = pipes.n
      fs_touch(dir, "other")
      for _ = 1, 100 do
        vim.wait(0)
      end
      t.eq(pipes.n, n, "повторов подключения нет")
    end
  )

  it("в модуле клиента нет таймеров", function()
    local files = vim.fn.globpath(t.root .. "/lua/claudr/herdr", "**/*.lua", false, true)
    t.ok(#files >= 3, "файлы модуля найдены")
    for _, file in ipairs(files) do
      local f = assert(io.open(file))
      local text = f:read("*a")
      f:close()
      for _, pattern in ipairs({ "new_timer", "defer_fn", "timer_start" }) do
        t.ok(not text:find(pattern, 1, true), file .. ": " .. pattern)
      end
    end
  end)
end)
