-- Требования «Запрос хука к Neovim» (два экземпляра), «Первое решение побеждает»,
-- «Хук не мешает диалогу» (соединения закрыты, неверный кадр).
local t = require("helpers.t")
local support = require("hook.support")
local listener_double = require("helpers.listener_double")

local ENV = {
  HERDR_PANE_ID = "w1:p1",
  HERDR_SOCKET_PATH = "/run/herdr/test.sock",
}

local listeners
local h

local function start(names, mode)
  for _, name in ipairs(names) do
    table.insert(
      listeners,
      listener_double.start({ dir = support.socket_dir(), name = name, mode = mode })
    )
  end
end

local function wait_requests()
  t.wait(function()
    for _, l in ipairs(listeners) do
      if #l.requests == 0 then
        return false
      end
    end
    return true
  end, "запросы у всех слушателей")
end

local function decision()
  return {
    hookSpecificOutput = {
      hookEventName = "PermissionRequest",
      decision = {
        behavior = "allow",
        updatedInput = { command = "ls", nested = vim.empty_dict(), list = {} },
      },
    },
  }
end

before_each(function()
  listeners = {}
  h = nil
end)

after_each(function()
  if h and not h.exited then
    h:term()
    h:wait_exit()
  end
  for _, l in ipairs(listeners) do
    l:stop()
  end
end)

describe("Запрос хука к Neovim", function()
  it("Два экземпляра", function()
    start({ "101.sock", "102.sock" })
    h = support.spawn({ env = ENV })
    wait_requests()
    local input = support.sample_input()
    for _, l in ipairs(listeners) do
      t.eq(#l.requests, 1)
      local req = l.requests[1]
      t.eq(req.type, "request")
      t.eq(req.version, 1)
      t.eq(req.input, vim.json.decode(vim.json.encode(input)), "вход хука целиком")
      t.eq(req.env, ENV, "переменные herdr")
    end
    t.ok(not h.exited, "хук ждёт решения")
    t.ok(
      listeners[1]:connected() and listeners[2]:connected(),
      "соединения открыты"
    )
  end)

  it(
    "Два экземпляра: без переменных herdr ключей env нет",
    function()
      start({ "103.sock" })
      h = support.spawn({ env = { HERDR_PANE_ID = false, HERDR_SOCKET_PATH = false } })
      wait_requests()
      t.eq(listeners[1].requests[1].env, vim.empty_dict())
    end
  )
end)

describe("Первое решение побеждает", function()
  it("Ответ из первого экземпляра", function()
    start({ "201.sock", "202.sock" })
    local before
    h = support.spawn({ env = ENV })
    wait_requests()
    before = support.snapshot()
    listeners[1]:reply(decision())
    h:wait_exit()
    t.eq(h.code, 0, "код выхода")
    t.eq(h.stderr, "", "stderr")
    local lines = vim.split(h.stdout, "\n", { plain = true })
    t.eq(#lines, 2, "одна строка JSON")
    t.eq(lines[2], "")
    t.eq(vim.json.decode(lines[1]), decision(), "stdout — решение")
    t.match(lines[1], '"nested":{}', "пустой объект сохранён")
    t.match(lines[1], '"list":%[%]', "пустой массив сохранён")
    t.wait(function()
      return listeners[2].got_answered and listeners[2].closed_by_peer
    end, "второй экземпляр получил «отвечено» и закрытие")
    t.ok(
      not listeners[1].got_answered,
      "победителю «отвечено» не шлётся"
    )
    t.eq(support.snapshot(), before, "хук не создал файлов")
  end)

  it(
    "Ответ из первого экземпляра: неверный кадр другого соединения не мешает",
    function()
      start({ "203.sock", "204.sock" })
      h = support.spawn({ env = ENV })
      wait_requests()
      listeners[1]:send_raw("не JSON\n")
      t.wait(function()
        return listeners[1].closed_by_peer
      end, "соединение с неверным кадром закрыто")
      t.ok(not h.exited, "хук ждёт остальных")
      listeners[2]:reply(decision())
      h:wait_exit()
      t.eq(h.code, 0)
      t.eq(vim.json.decode(h.stdout), decision())
      t.ok(
        not listeners[1].got_answered,
        "закрытому соединению «отвечено» не шлётся"
      )
    end
  )
end)

describe("Хук не мешает диалогу", function()
  it("Соединения закрыты", function()
    start({ "301.sock", "302.sock" })
    h = support.spawn({ env = ENV })
    wait_requests()
    local before = support.snapshot()
    listeners[1]:close_conn()
    t.ok(
      not h.exited or h.stdout == "",
      "после первого закрытия решения нет"
    )
    listeners[2]:close_conn()
    h:wait_exit()
    support.assert_silent_exit(h)
    t.eq(support.snapshot(), before, "хук не создал файлов")
  end)

  it(
    "Соединения закрыты: экземпляры не приняли запрос",
    function()
      start({ "303.sock", "304.sock" }, "close")
      local before = support.snapshot()
      h = support.spawn({ env = ENV })
      h:wait_exit()
      support.assert_silent_exit(h)
      for _, l in ipairs(listeners) do
        t.eq(#l.requests, 1, "запрос получен")
      end
      t.eq(support.snapshot(), before, "хук не создал файлов")
    end
  )

  it("Неверный кадр: строка не JSON", function()
    start({ "401.sock" })
    h = support.spawn({ env = ENV })
    wait_requests()
    local before = support.snapshot()
    listeners[1]:send_raw("{oops\n")
    h:wait_exit()
    support.assert_silent_exit(h)
    t.eq(support.snapshot(), before, "хук не создал файлов")
  end)

  it(
    "Неверный кадр: решение без вывода и кадр другого вида",
    function()
      start({ "402.sock", "403.sock" })
      h = support.spawn({ env = ENV })
      wait_requests()
      listeners[1]:send_raw('{"type":"decision"}\n')
      listeners[2]:send_raw('{"type":"other","output":{}}\n')
      h:wait_exit()
      support.assert_silent_exit(h)
    end
  )

  it(
    "Неверный кадр: мёртвый сокет рядом с живым не мешает",
    function()
      listener_double.dead({ dir = support.socket_dir(), name = "404.sock" })
      start({ "405.sock" })
      h = support.spawn({ env = ENV })
      wait_requests()
      listeners[1]:reply(decision())
      h:wait_exit()
      t.eq(h.code, 0)
      t.eq(vim.json.decode(h.stdout), decision())
    end
  )
end)
