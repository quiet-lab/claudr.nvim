-- Сокет плагина и приём запросов хука (спецификация agent-dialogs: «Сокет плагина Neovim»,
-- «Приём запроса и привязка к узлу»).
local t = require("helpers.t")
local s = require("dialogs.pending_support")
local socket = require("claudr.dialogs.socket")
local pending = require("claudr.dialogs.pending")

local uv = vim.uv

local extra = {} -- посторонние слушатели и процессы теста

after_each(function()
  s.reset()
  socket.stop()
  for _, x in ipairs(extra) do
    x()
  end
  extra = {}
end)

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

-- Слушатель другого «живого экземпляра» в каталоге сокетов.
local function live_listener(path)
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  server:listen(4, function()
    local c = uv.new_pipe(false)
    server:accept(c)
    c:close()
  end)
  table.insert(extra, function()
    server:close()
    uv.fs_unlink(path)
  end)
end

-- Сокет умершего экземпляра: файл сокета без слушателя. libuv удаляет файл сокета при
-- закрытии, поэтому остаётся жёсткая ссылка на него, сделанная до закрытия.
local function dead_socket(path)
  local server = uv.new_pipe(false)
  assert(server:bind(path .. ".tmp"))
  assert(uv.fs_link(path .. ".tmp", path))
  server:close()
  uv.fs_unlink(path .. ".tmp")
  t.ok(exists(path), "файл сокета без слушателя остался")
end

describe("Сокет плагина Neovim", function()
  it("Запуск и выход", function()
    local dir = socket.dir()
    local addr = t.tmpdir() .. "/child.nvim"
    local exited = false
    local proc = vim.system({
      vim.v.progpath,
      "--headless",
      "--clean",
      "-u",
      "NONE",
      "--listen",
      addr,
      "--cmd",
      "set rtp^=" .. t.root,
      "-c",
      "lua assert(require('claudr.dialogs.socket').start())",
    }, {}, function()
      exited = true
    end)
    table.insert(extra, function()
      if not exited then
        proc:kill(9)
      end
    end)
    local path = dir .. "/" .. proc.pid .. ".sock"
    t.wait(function()
      return exists(path)
    end, "сокет экземпляра появился")
    local st = uv.fs_stat(dir)
    t.eq(
      st.mode % 512,
      448,
      "каталог сокетов доступен только владельцу"
    )
    local ch
    t.wait(function()
      ch = ch or (exists(addr) and vim.fn.sockconnect("pipe", addr, { rpc = true }) or nil)
      return ch ~= nil and ch > 0
    end, "соединение с экземпляром")
    vim.rpcnotify(ch, "nvim_command", "qa!")
    t.wait(function()
      return exited
    end, "выход экземпляра")
    t.eq(exists(path), false, "сокет удалён при выходе")
  end)

  it(
    "сокет текущего экземпляра: путь по pid, удаление при stop()",
    function()
      assert(socket.start())
      local path = socket.dir() .. "/" .. uv.os_getpid() .. ".sock"
      t.eq(socket.path(), path)
      t.ok(exists(path))
      socket.stop()
      t.eq(exists(path), false)
      t.eq(socket.path(), nil)
    end
  )

  it(
    "каталог без XDG_RUNTIME_DIR — во временном каталоге с uid",
    function()
      local prev = uv.os_getenv("XDG_RUNTIME_DIR")
      uv.os_unsetenv("XDG_RUNTIME_DIR")
      local dir = socket.dir()
      uv.os_setenv("XDG_RUNTIME_DIR", prev)
      t.eq(dir, uv.os_tmpdir() .. "/claudr-" .. uv.getuid())
    end
  )

  it("Сокет умершего экземпляра", function()
    local dir = socket.dir()
    vim.fn.mkdir(dir, "p", "0700")
    local dead = dir .. "/999999991.sock"
    local live = dir .. "/999999992.sock"
    dead_socket(dead)
    live_listener(live)
    assert(socket.start())
    t.wait(function()
      return not exists(dead)
    end, "сокет умершего экземпляра удалён")
    t.ok(exists(live), "сокет живого экземпляра остался")
    t.ok(exists(socket.path()), "свой сокет на месте")
  end)
end)

describe("Приём запроса и привязка к узлу", function()
  it("Чужой сервер", function()
    s.env()
    local h = require("helpers.hook_double").spawn({
      socket = socket.path(),
      input = s.input("permission-bash"),
      env = s.hook_env({ HERDR_SOCKET_PATH = t.tmpdir() .. "/other/herdr.sock" }),
    })
    h:wait_closed()
    t.eq(h.frames, {})
    t.eq(pending.list(), {})
  end)

  it(
    "неизвестная панель: соединение закрыто без ответа",
    function()
      s.env()
      local h = require("helpers.hook_double").spawn({
        socket = socket.path(),
        input = s.input("permission-bash"),
        env = s.hook_env({ HERDR_PANE_ID = "w9:p9" }),
      })
      h:wait_closed()
      t.eq(h.frames, {})
      t.eq(pending.list(), {})
    end
  )

  it("запрос без окружения herdr закрыт без ответа", function()
    s.env()
    local h = require("helpers.hook_double").spawn({
      socket = socket.path(),
      input = s.input("permission-bash"),
      env = {},
    })
    h:wait_closed()
    t.eq(pending.list(), {})
  end)

  it(
    "неверная первая строка закрывает соединение",
    function()
      s.env()
      local c = uv.new_pipe(false)
      local closed = false
      c:connect(socket.path(), function(err)
        assert(not err, err)
        c:read_start(function(_, chunk)
          if not chunk then
            closed = true
            c:close()
          end
        end)
        c:write("не json\n")
      end)
      t.wait(function()
        return closed
      end, "закрытие плагином")
      t.eq(pending.list(), {})
    end
  )

  it("Запрос субагента", function()
    s.env({ subagent = true })
    local _, req = s.request(s.input("subagent"))
    t.eq(req.agent_id, s.samples.agent_id)
    t.eq(pending.node_id(req), s.SUB_NODE)
    local model = require("claudr.tree.model")
    t.eq(pending.count(model.get(s.SUB_NODE)), 1)
    t.eq(pending.for_node(model.get(s.SUB_NODE))[1], req)
  end)

  it(
    "запрос субагента без узла в дереве привязан к панели",
    function()
      s.env()
      local _, req = s.request(s.input("subagent"))
      t.eq(pending.node_id(req), s.PANE)
      local model = require("claudr.tree.model")
      t.eq(pending.count(model.get(s.PANE)), 1)
    end
  )

  it("запрос без agent_id привязан к панели", function()
    s.env({ subagent = true })
    local _, req = s.request(s.input("permission-bash"))
    t.eq(req.pane_id, s.PANE)
    t.eq(pending.node_id(req), s.PANE)
    local model = require("claudr.tree.model")
    t.eq(pending.count(model.get(s.SUB_NODE)), 0)
    t.eq(pending.count(model.get(s.PANE)), 1)
  end)
end)
