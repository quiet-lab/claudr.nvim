-- Двойник слушателя: приём запроса, ответ, «отвечено», закрытие, режимы, мёртвый сокет.
local t = require("helpers.t")
local listener_double = require("helpers.listener_double")

local uv = vim.uv

local function dir()
  return t.tmpdir() .. "/run/claudr"
end

-- Клиент на месте хука: соединяется, копит принятое, отмечает закрытие и ошибку соединения.
local function client(path)
  local c = { data = "", closed = false, connected = false, err = nil }
  c.pipe = uv.new_pipe(false)
  c.pipe:connect(path, function(err)
    if err then
      c.err = err
      c.pipe:close()
      return
    end
    c.connected = true
    c.pipe:read_start(function(rerr, data)
      if rerr or not data then
        c.closed = true
        if not c.pipe:is_closing() then
          c.pipe:close()
        end
        return
      end
      c.data = c.data .. data
    end)
  end)
  function c:send(text)
    self.pipe:write(text)
  end
  function c:close()
    if not self.pipe:is_closing() then
      self.pipe:close()
    end
  end
  return c
end

local function wait_connected(c)
  t.wait(function()
    return c.connected or c.err ~= nil
  end, "соединение")
end

local REQUEST = '{"type":"request","version":1,"input":{"tool_name":"Bash"},"env":{}}\n'

before_each(function()
  vim.fn.mkdir(t.tmpdir() .. "/run", "p", tonumber("700", 8))
end)

describe("Двойник слушателя", function()
  it(
    "создаёт каталог 0700 и сокет с именем по pid по умолчанию",
    function()
      local l = listener_double.start({ dir = dir() })
      t.eq(l.path, dir() .. "/" .. uv.os_getpid() .. ".sock")
      t.eq(uv.fs_stat(l.path).type, "socket")
      t.eq(bit.band(uv.fs_stat(dir()).mode, tonumber("777", 8)), tonumber("700", 8))
      l:stop()
      t.ok(not uv.fs_stat(l.path), "сокет удалён при остановке")
    end
  )

  it(
    "принимает запрос, отвечает решением и видит «отвечено»",
    function()
      local l = listener_double.start({ dir = dir(), name = "1.sock" })
      local c = client(l.path)
      wait_connected(c)
      c:send(REQUEST)
      t.wait(function()
        return #l.requests == 1
      end, "запрос")
      t.eq(l.requests[1].input, { tool_name = "Bash" })
      l:reply({ hookSpecificOutput = { decision = { behavior = "allow" } } })
      t.wait(function()
        return c.data:find("\n", 1, true) ~= nil
      end, "решение")
      t.eq(vim.json.decode(c.data), {
        type = "decision",
        output = { hookSpecificOutput = { decision = { behavior = "allow" } } },
      })
      c:send('{"type":"answered"}\n')
      c:close()
      t.wait(function()
        return l.got_answered and l.closed_by_peer
      end, "«отвечено» и закрытие хуком")
      l:stop()
    end
  )

  it("закрывает соединение без ответа по команде", function()
    local l = listener_double.start({ dir = dir(), name = "2.sock" })
    local c = client(l.path)
    wait_connected(c)
    c:send(REQUEST)
    t.wait(function()
      return #l.requests == 1
    end, "запрос")
    l:close_conn()
    t.wait(function()
      return c.closed
    end, "закрытие у клиента")
    t.eq(c.data, "")
    t.ok(not l.closed_by_peer, "закрыл двойник, а не клиент")
    l:stop()
  end)

  it(
    "режим close: закрывает соединение сразу после запроса",
    function()
      local l = listener_double.start({ dir = dir(), name = "3.sock", mode = "close" })
      local c = client(l.path)
      wait_connected(c)
      c:send(REQUEST)
      t.wait(function()
        return c.closed
      end, "закрытие у клиента")
      t.eq(#l.requests, 1)
      t.eq(c.data, "")
      l:stop()
    end
  )

  it(
    "отправляет строку как есть и копит неверные строки",
    function()
      local l = listener_double.start({ dir = dir(), name = "4.sock" })
      local c = client(l.path)
      wait_connected(c)
      c:send("не JSON\n" .. REQUEST)
      t.wait(function()
        return #l.requests == 1
      end, "запрос")
      t.eq(l.bad_lines, { "не JSON" })
      l:send_raw("{oops\n")
      t.wait(function()
        return c.data == "{oops\n"
      end, "строка у клиента")
      c:close()
      l:stop()
    end
  )

  it(
    "мёртвый сокет: файл сокета есть, подключение отказано",
    function()
      local path = listener_double.dead({ dir = dir(), name = "5.sock" })
      t.eq(uv.fs_stat(path).type, "socket")
      t.ok(not uv.fs_stat(path .. ".bind"), "временного файла нет")
      local c = client(path)
      wait_connected(c)
      t.ok(c.err ~= nil, "подключение отказано")
      t.ok(uv.fs_stat(path), "файл остался")
    end
  )
end)
