-- Собственные тесты двойника хука: процесс-клиент сокета против простого слушателя в тесте.
local t = require("helpers.t")
local hook_double = require("helpers.hook_double")

local uv = vim.uv

local listener
local test_no = 0

-- Слушатель: принимает одно соединение, копит строки, умеет отвечать и закрывать.
local function listen()
  test_no = test_no + 1
  local dir = t.tmpdir() .. "/hl" .. test_no
  vim.fn.mkdir(dir, "p")
  local l = { path = dir .. "/p.sock", lines = {}, closed_by_client = false }
  l.server = uv.new_pipe(false)
  assert(l.server:bind(l.path))
  l.server:listen(8, function(err)
    assert(not err, err)
    local c = uv.new_pipe(false)
    l.server:accept(c)
    l.conn = c
    local buf = ""
    c:read_start(function(rerr, chunk)
      if rerr or not chunk then
        l.closed_by_client = true
        if not c:is_closing() then
          c:close()
        end
        return
      end
      buf = buf .. chunk
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        table.insert(l.lines, buf:sub(1, nl - 1))
        buf = buf:sub(nl + 1)
      end
    end)
  end)
  function l:send(line)
    self.conn:write(line .. "\n")
  end
  function l:close_conn()
    if self.conn and not self.conn:is_closing() then
      self.conn:close()
    end
  end
  function l:stop()
    self:close_conn()
    if not self.server:is_closing() then
      self.server:close()
    end
  end
  return l
end

before_each(function()
  listener = listen()
end)

after_each(function()
  hook_double.stop_all()
  listener:stop()
end)

local ENV = { HERDR_PANE_ID = "w1:p1", HERDR_SOCKET_PATH = "/x/herdr.sock" }

describe("двойник хука", function()
  it("кадр request доходит целиком: вход и окружение", function()
    local input = {
      tool_name = "Bash",
      tool_input = { command = 'ls\nпривет "кавычки"' },
      permission_suggestions = vim.NIL,
    }
    local h = hook_double.spawn({ socket = listener.path, input = input, env = ENV })
    t.wait(function()
      return #listener.lines == 1
    end, "кадр request")
    local frame = vim.json.decode(listener.lines[1])
    t.eq(frame.type, "request")
    t.eq(frame.version, 1)
    t.eq(frame.input.tool_name, "Bash")
    t.eq(frame.input.tool_input.command, 'ls\nпривет "кавычки"')
    t.eq(frame.input.permission_suggestions, vim.NIL)
    t.eq(frame.env, ENV)
    t.ok(h:wait_connected())
  end)

  it(
    "переменная окружения, которой нет, — ключа нет",
    function()
      hook_double.spawn({ socket = listener.path, input = {}, env = { HERDR_PANE_ID = "w1:p1" } })
      t.wait(function()
        return #listener.lines == 1
      end, "кадр request")
      t.eq(vim.json.decode(listener.lines[1]).env, { HERDR_PANE_ID = "w1:p1" })
    end
  )

  it(
    "решение плагина принято целиком, порядок кадров сохранён",
    function()
      local h = hook_double.spawn({ socket = listener.path, input = {}, env = ENV })
      t.wait(function()
        return listener.conn ~= nil and #listener.lines == 1
      end, "request")
      local out = { hookSpecificOutput = { hookEventName = "PermissionRequest" } }
      listener:send(vim.json.encode({ type = "decision", output = out }))
      listener:send(vim.json.encode({ type = "other" }))
      local f = h:wait_frame()
      t.eq(f, { type = "decision", output = out })
      h:wait_frame(2)
      t.eq(h.frames[2], { type = "other" })
      t.eq(h.closed_by_peer, false)
    end
  )

  it(
    "answered: кадр доходит до плагина, соединение закрыто",
    function()
      local h = hook_double.spawn({ socket = listener.path, input = {}, env = ENV })
      t.wait(function()
        return #listener.lines == 1
      end, "request")
      h:answered()
      t.wait(function()
        return listener.closed_by_client
      end, "закрытие клиентом")
      t.eq(listener.lines[2], '{"type":"answered"}')
      t.eq(h.closed_by_peer, false)
    end
  )

  it("close закрывает соединение без кадра", function()
    local h = hook_double.spawn({ socket = listener.path, input = {}, env = ENV })
    t.wait(function()
      return #listener.lines == 1
    end, "request")
    h:close()
    t.wait(function()
      return listener.closed_by_client
    end, "закрытие клиентом")
    t.eq(#listener.lines, 1)
  end)

  it("silent: соединение без кадра request", function()
    local h = hook_double.spawn({ socket = listener.path, silent = true })
    t.ok(h:wait_connected())
    t.wait(function()
      return listener.conn ~= nil
    end, "соединение принято")
    h:close()
    t.wait(function()
      return listener.closed_by_client
    end, "закрытие клиентом")
    t.eq(listener.lines, {})
  end)

  it(
    "закрытие соединения плагином видно: closed_by_peer, wait_frame возвращает nil",
    function()
      local h = hook_double.spawn({ socket = listener.path, input = {}, env = ENV })
      t.wait(function()
        return #listener.lines == 1
      end, "request")
      listener:close_conn()
      t.eq(h:wait_frame(), nil)
      t.eq(h.closed_by_peer, true)
      t.eq(h.frames, {})
    end
  )

  it(
    "неверная строка плагина не становится кадром",
    function()
      local h = hook_double.spawn({ socket = listener.path, input = {}, env = ENV })
      t.wait(function()
        return #listener.lines == 1
      end, "request")
      listener:send("не json")
      listener:send('{"type":"decision","output":{}}')
      h:wait_frame()
      t.eq(h.bad_lines, { "не json" })
      t.eq(h.frames[1].type, "decision")
    end
  )

  it("ошибка соединения: нет сокета", function()
    local h = hook_double.spawn({ socket = t.tmpdir() .. "/нет.sock", input = {}, env = ENV })
    t.eq(h:wait_connected(), false)
    t.ok(h.connect_error ~= nil)
  end)

  it(
    "SIGTERM завершает процесс кодом 0, соединение закрыто",
    function()
      local h = hook_double.spawn({ socket = listener.path, input = {}, env = ENV })
      t.wait(function()
        return #listener.lines == 1
      end, "request")
      h:term()
      t.eq(h:wait_exit(), 0)
      t.eq(h.signal, 0)
      t.wait(function()
        return listener.closed_by_client
      end, "закрытие клиентом")
    end
  )

  it("stop_all завершает оставшихся двойников", function()
    local h = hook_double.spawn({ socket = listener.path, input = {}, env = ENV })
    h:wait_connected()
    hook_double.stop_all()
    t.eq(h.exited, true)
    t.eq(h.code, 0)
  end)
end)
