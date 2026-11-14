-- Сообщения и клавиши агентам (спецификация messaging): `agent.prompt`, `agent_blocked`,
-- `pane.send_keys`, отказ для субагентов и фоновых команд, сервер недоступен.
local t = require("helpers.t")
local ms = require("messaging.support")
local s = ms.tree
local model = require("claudr.tree.model")
local messaging = require("claudr.messaging")

after_each(function()
  ms.reset()
end)

local function env(status)
  local sample = "subagent-command"
  local d = s.env(
    s.snapshot({ s.claude_pane("w1:p1", sample, { agent_status = status or "idle" }) }),
    sample
  )
  s.wait_node("w1:p1")
  return d
end

describe("Сообщение агенту", function()
  it("Сообщение агенту", function()
    local d = env("idle")
    local rec = ms.stub({ input = { "привет, агент" } })
    messaging.send_message({ node = model.get("w1:p1") })
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    local req = d:last("agent.prompt")
    t.eq(req.params.target, "w1:p1")
    t.eq(req.params.text, "привет, агент")
    t.eq(#rec.inputs, 1)
    ms.wait_note(rec, "сообщение отправлено")
  end)

  it("панель выбирается из перечня, когда узла нет", function()
    local d = env("idle")
    local rec = ms.stub({ input = { "текст" }, select = { 1 } })
    messaging.send_message({})
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(#rec.selects, 1)
    t.eq(rec.selects[1].items[1].pane_id, "w1:p1")
    t.eq(d:last("agent.prompt").params.target, "w1:p1")
  end)

  it("пустой ввод и отмена ничего не отправляют", function()
    local d = env("idle")
    ms.stub({ input = { "   " } })
    messaging.send_message({ node = model.get("w1:p1") })
    ms.stub({ input = { false } })
    messaging.send_message({ node = model.get("w1:p1") })
    t.eq(d:count("agent.prompt"), 0)
  end)
end)

describe("Агент в состоянии без приёма сообщений", function()
  it("Агент в состоянии blocked", function()
    local d = env("idle")
    d:set_agent_status("w1:p1", "blocked")
    s.wait_node("w1:p1", function(n)
      return n.state == "blocked"
    end)
    local rec = ms.stub({ input = { "вопрос" }, select = { 2 } })
    local before = #d.requests
    local result
    messaging.send_message({
      node = model.get("w1:p1"),
      on_done = function(err)
        result = err
      end,
    })
    t.wait(function()
      return result ~= nil
    end, "ответ agent_blocked")
    t.eq(result.code, "agent_blocked")
    t.ok(
      ms.noted(rec, "ждёт ответа", vim.log.levels.WARN),
      "сообщение, что агент ждёт ответа"
    )
    t.eq(#rec.selects, 1)
    t.eq(rec.selects[1].items[1], "Отправить клавиши")
    -- текст не ушёл иным способом: единственный запрос — отклонённый agent.prompt
    t.eq(ms.methods_after(d, before), { "agent.prompt" })
  end)

  it("предложение клавиш при blocked ведёт к pane.send_keys", function()
    local d = env("blocked")
    s.wait_node("w1:p1", function(n)
      return n.state == "blocked"
    end)
    ms.stub({ input = { "вопрос", "enter" }, select = { 1 } })
    messaging.send_message({ node = model.get("w1:p1") })
    t.wait(function()
      return d:count("pane.send_keys") == 1
    end, "pane.send_keys")
    t.eq(d:last("pane.send_keys").params.keys, { "enter" })
    t.eq(d:count("agent.prompt"), 1)
  end)
end)

describe("Клавиши агенту", function()
  it("Ответ на разрешение", function()
    local d = env("blocked")
    s.wait_node("w1:p1", function(n)
      return n.state == "blocked"
    end)
    ms.stub({ input = { "enter" } })
    messaging.send_keys({ node = model.get("w1:p1") })
    t.wait(function()
      return d:count("pane.send_keys") == 1
    end, "pane.send_keys")
    local req = d:last("pane.send_keys")
    t.eq(req.params.pane_id, "w1:p1")
    t.eq(req.params.keys, { "enter" })
  end)

  it("Несколько клавиш", function()
    local d = env("blocked")
    s.wait_node("w1:p1", function(n)
      return n.state == "blocked"
    end)
    ms.stub({ input = { "down down enter" } })
    messaging.send_keys({ node = model.get("w1:p1") })
    t.wait(function()
      return d:count("pane.send_keys") == 1
    end, "pane.send_keys")
    t.eq(d:last("pane.send_keys").params.keys, { "down", "down", "enter" })
    -- диалог закрыт: сервер сообщает состояние idle, узел показывает его по событию
    d:set_agent_status("w1:p1", "idle")
    s.wait_node("w1:p1", function(n)
      return n.state == "idle"
    end, "узел панели в состоянии idle")
  end)

  it(
    "клавиши через подкоманду по идентификатору панели",
    function()
      local d = env("blocked")
      ms.stub({ input = { "down, enter" } })
      messaging.send_keys({ pane_id = "w1:p1" })
      t.wait(function()
        return d:count("pane.send_keys") == 1
      end, "pane.send_keys")
      t.eq(d:last("pane.send_keys").params.keys, { "down", "enter" })
    end
  )
end)

describe(
  "Субагентам и фоновым командам писать нельзя",
  function()
    local function agent_node(kind)
      local nodes = model.find(function(n)
        return n.kind == kind
      end)
      t.ok(#nodes > 0, "в дереве есть узел " .. kind)
      return nodes[1]
    end

    it("Сообщение субагенту", function()
      local d = env("idle")
      s.wait_node("w1:p1/a0000000000000004", nil, "субагент в дереве")
      local rec = ms.stub({ input = { "текст" } })
      local before = #d.requests
      messaging.send_message({ node = agent_node("subagent") })
      t.ok(
        ms.noted(rec, "нет панели"),
        "сообщение «у узла нет панели»"
      )
      t.ok(ms.noted(rec, "субагенту писать нельзя"))
      t.eq(#rec.inputs, 0)
      t.eq(#d.requests, before, "запросов к серверу нет")
    end)

    it("сообщение и клавиши фоновой команде", function()
      local d = env("idle")
      t.wait(function()
        return #model.find(function(n)
          return n.kind == "task"
        end) > 0
      end, "фоновая команда в дереве")
      local rec = ms.stub({ input = { "текст", "enter" } })
      local before = #d.requests
      messaging.send_message({ node = agent_node("task") })
      messaging.send_keys({ node = agent_node("task") })
      t.ok(ms.noted(rec, "фоновой команде писать нельзя"))
      t.eq(#rec.inputs, 0)
      t.eq(#d.requests, before)
    end)

    it("клавиши субагенту", function()
      local d = env("idle")
      s.wait_node("w1:p1/a0000000000000004", nil, "субагент в дереве")
      local rec = ms.stub({ input = { "enter" } })
      local before = #d.requests
      messaging.send_keys({ node = agent_node("subagent") })
      t.ok(ms.noted(rec, "нет панели"))
      t.eq(#d.requests, before)
    end)
  end
)

describe("Сервер недоступен", function()
  it("Отправка без сервера", function()
    local rec = ms.stub({ input = { "текст" } })
    messaging.send_message({ pane_id = "w1:p1" })
    t.ok(
      ms.noted(rec, "недоступен", vim.log.levels.ERROR),
      "сообщение о недоступности сервера"
    )
    t.eq(
      #rec.inputs,
      0,
      "ввод не запрашивался: ничего не откладывается"
    )
    messaging.send_keys({ pane_id = "w1:p1" })
    t.eq(#rec.inputs, 0)
  end)

  it("сервер пропал после подключения", function()
    local d = env("idle")
    d:stop()
    t.wait(function()
      return require("claudr.herdr").state().status ~= "connected"
    end, "потеря сервера")
    local rec = ms.stub({ input = { "текст" } })
    messaging.send_message({ node = model.get("w1:p1") })
    t.ok(ms.noted(rec, "недоступен"))
    t.eq(#rec.inputs, 0)
  end)

  it("сервер пропал во время запроса", function()
    local d = env("idle")
    d:fail("agent.prompt", "server_unavailable")
    local rec = ms.stub({ input = { "текст" } })
    local err
    messaging.send_message({
      node = model.get("w1:p1"),
      on_done = function(e)
        err = e
      end,
    })
    t.wait(function()
      return err ~= nil
    end, "ответ об ошибке")
    t.ok(ms.noted(rec, "недоступен"))
    t.eq(d:count("agent.prompt"), 1, "повторной отправки нет")
  end)
end)

describe("Подкоманды и клавиши дерева", function()
  it("регистрируются в setup", function()
    local commands = require("claudr.commands")
    messaging.setup()
    t.ok(commands.get("message"))
    t.ok(commands.get("keys"))
    local view = require("claudr.tree.view")
    t.eq(view.action("message").key, "m")
    t.eq(view.action("keys").key, "K")
  end)
end)
