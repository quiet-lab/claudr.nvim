-- Сообщения и клавиши агентам (спецификация messaging): `agent.prompt`, `agent_blocked`,
-- `pane.send_keys`, отказ для субагентов и фоновых команд, сервер недоступен.
local t = require("helpers.t")
local ms = require("messaging.support")
local s = ms.tree
local model = require("claudr.tree.model")
local messaging = require("claudr.messaging")
local input = require("claudr.input")
local herdr = require("claudr.herdr")

-- Ключ черновика сообщения панели: сессия панели.
local function draft_key(pane_id)
  for _, p in ipairs(herdr.state().snapshot.panes) do
    if p.pane_id == pane_id then
      return herdr.session_id(p) or pane_id
    end
  end
end

-- Открыть окно ввода сообщения панели w1:p1, набрать текст `text`.
local function compose(text)
  messaging.send_message({ node = model.get("w1:p1") })
  local buf = ms.wait_input()
  ms.set_text(buf, text)
  return buf
end

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
    local rec = ms.stub()
    messaging.send_message({ node = model.get("w1:p1") })
    local buf = ms.wait_input()
    ms.set_text(buf, "привет, агент")
    ms.write(buf)
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    local req = d:last("agent.prompt")
    t.eq(req.params.target, "w1:p1")
    t.eq(req.params.text, "привет, агент")
    t.eq(#rec.inputs, 0, "vim.ui.input не используется")
    ms.wait_note(rec, "сообщение отправлено")
  end)

  it("строка вкладки — агент вкладки", function()
    local d = env("idle")
    messaging.send_message({ node = model.get("w1:t1"), text = "вкладке" })
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.target, "w1:p1")
  end)

  it("Сообщение второму агенту", function()
    local sample = "subagent-command"
    local d = s.env(
      s.snapshot({
        s.claude_pane("w1:p1", sample, { focused = true }),
        s.claude_pane("w1:p3", sample, { display_agent = "opus" }),
      }),
      sample
    )
    s.wait_node("w1:p3")
    messaging.send_message({ node = model.get("w1:p3"), text = "второму" })
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.target, "w1:p3")
  end)

  it("Вкладка без агента", function()
    local d = s.env(s.snapshot({ s.double.pane({ pane_id = "w1:p4" }) }))
    s.wait_node("w1:p4")
    local rec = ms.stub()
    messaging.send_message({ node = model.get("w1:t1"), text = "никому" })
    ms.wait_note(rec, "нет агента")
    t.eq(d:count("agent.prompt"), 0)
  end)

  it("панель выбирается из перечня, когда узла нет", function()
    local d = env("idle")
    local rec = ms.stub({ select = { 1 } })
    messaging.send_message({})
    local buf = ms.wait_input()
    ms.set_text(buf, "текст")
    ms.write(buf)
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(#rec.selects, 1)
    t.eq(rec.selects[1].items[1].pane_id, "w1:p1")
    t.eq(d:last("agent.prompt").params.target, "w1:p1")
  end)

  it("пустой текст ничего не отправляет", function()
    local d = env("idle")
    ms.stub()
    messaging.send_message({ node = model.get("w1:p1") })
    local buf = ms.wait_input()
    ms.set_text(buf, "   ")
    ms.write(buf)
    t.eq(d:count("agent.prompt"), 0)
    t.ok(vim.api.nvim_buf_is_valid(buf), "окно остаётся")
  end)

  it("готовый текст отправляется без окна", function()
    local d = env("idle")
    ms.stub()
    messaging.send_message({ node = model.get("w1:p1"), text = "сразу" })
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.text, "сразу")
    t.eq(ms.input_buf(), nil)
  end)
end)

describe("Агент в состоянии без приёма сообщений", function()
  local function blocked_env()
    local d = env("idle")
    d:set_agent_status("w1:p1", "blocked")
    s.wait_node("w1:p1", function(n)
      return n.state == "blocked"
    end)
    return d
  end

  local function send_blocked(rec_opts)
    local rec = ms.stub(rec_opts)
    local result
    messaging.send_message({
      node = model.get("w1:p1"),
      on_done = function(err)
        result = err
      end,
    })
    local buf = ms.wait_input()
    ms.set_text(buf, "вопрос")
    ms.write(buf)
    t.wait(function()
      return result ~= nil
    end, "ответ agent_blocked")
    t.eq(result.code, "agent_blocked")
    return rec
  end

  it("Агент в состоянии blocked", function()
    local d = blocked_env()
    local before = #d.requests
    local rec = send_blocked({ select = { 2 } })
    t.ok(
      ms.noted(rec, "ждёт ответа", vim.log.levels.WARN),
      "сообщение, что агент ждёт ответа"
    )
    t.eq(#rec.selects, 1)
    t.eq(rec.selects[1].items[1], "Подключиться с вводом")
    -- текст не ушёл иным способом: единственный запрос — отклонённый agent.prompt
    t.eq(ms.methods_after(d, before), { "agent.prompt" })
  end)

  it("Запроса нет", function()
    local d = blocked_env()
    local rec = send_blocked({ select = { 2 } })
    t.ok(ms.noted(rec, "черновик"), "текст остался черновиком")
    t.eq(rec.selects[1].items[1], "Подключиться с вводом")
    t.eq(d:count("pane.send_keys"), 0)
    t.eq(input.draft({ kind = "message", key = draft_key("w1:p1") }), "вопрос")
  end)

  it(
    "предложение подключения с вводом открывает вид подключения",
    function()
      local d = blocked_env()
      local attached
      local view = require("claudr.view")
      local saved = view.attach
      view.attach = function(node)
        attached = node.id
      end
      send_blocked({ select = { 1 } })
      view.attach = saved
      t.eq(attached, "w1:p1")
      t.eq(d:count("pane.send_keys"), 0)
    end
  )

  it("Запрос есть", function()
    blocked_env()
    local opened = {}
    package.loaded["claudr.dialogs"] = {
      has_pending = function(pane_id)
        return pane_id == "w1:p1"
      end,
      open_for_pane = function(pane_id)
        opened[#opened + 1] = pane_id
        return true
      end,
    }
    local rec = send_blocked()
    t.eq(opened, { "w1:p1" })
    t.eq(
      #rec.selects,
      0,
      "предложения терминала нет: открыт буфер диалога"
    )
    -- набранный текст сохранён как черновик, окно ввода закрыто
    t.eq(input.draft({ kind = "message", key = draft_key("w1:p1") }), "вопрос")
    t.eq(ms.input_buf(), nil)
  end)
end)

describe("Многострочный текст", function()
  it("Несколько строк", function()
    local d = env("idle")
    ms.stub()
    local text =
      '  первая "строка" \\ кавычки\n\n\tотступ и кириллица: ёжик\''
    local buf = compose(text)
    ms.write(buf)
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.text, text)
    t.eq(d:count("agent.prompt"), 1, "текст не разбит на части")
  end)
end)

describe("Ошибка отправки", function()
  it("Сервер недоступен", function()
    local d = env("idle")
    d:fail("agent.prompt", "server_unavailable")
    local rec = ms.stub()
    local buf = compose("не дойдёт")
    ms.write(buf)
    ms.wait_note(rec, "недоступен")
    t.ok(vim.api.nvim_buf_is_valid(buf), "окно остаётся")
    t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "не дойдёт" })
    t.eq(d:count("agent.prompt"), 1, "ничего не отложено")
  end)
end)

describe("Работающий агент — очередь", function()
  it("Сообщение работающему агенту", function()
    local d = env("working")
    local rec = ms.stub()
    local buf = compose("допиши тесты")
    ms.write(buf)
    ms.wait_note(rec, "очередь")
    t.eq(d:last("agent.prompt").params.text, "допиши тесты")
    t.wait(function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, "окно закрыто")
  end)
end)

describe("Начало с «/» или «!»", function()
  it("По умолчанию", function()
    local d = env("idle")
    local rec = ms.stub()
    local buf = compose("/clear")
    ms.write(buf)
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.text, "/clear")
    t.ok(ms.noted(rec, "поймёт его как команду"), "предупреждение")
  end)

  it("режим оболочки при «!»", function()
    local d = env("idle")
    local rec = ms.stub()
    local buf = compose("!ls")
    ms.write(buf)
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.text, "!ls")
    t.ok(ms.noted(rec, "режим оболочки"))
  end)

  it("Защита включена", function()
    local d = env("idle")
    require("claudr.config").setup({ message_input = { guard_commands = true } })
    ms.stub()
    local buf = compose("/clear")
    ms.write(buf)
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.text, " /clear")
  end)

  it(
    "обычный текст не меняется и без предупреждения",
    function()
      local d = env("idle")
      local rec = ms.stub()
      local buf = compose("привет /clear")
      ms.write(buf)
      t.wait(function()
        return d:count("agent.prompt") == 1
      end, "agent.prompt")
      t.eq(d:last("agent.prompt").params.text, "привет /clear")
      t.ok(not ms.noted(rec, "поймёт"))
    end
  )
end)

describe("Окно ввода сообщения", function()
  it("Вызов из вида панели", function()
    local d = env("idle")
    local view = require("claudr.view")
    ms.stub()
    local v = view.open(model.get("w1:p1"))
    t.ok(v, "вид открыт")
    vim.api.nvim_set_current_win(v.win)
    local map = vim.fn.maparg("m", "n", false, true)
    t.ok(
      map.buffer == 1 and map.callback,
      "клавиша ввода назначена в виде панели"
    )
    map.callback()
    local buf = ms.wait_input()
    t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "" })
    t.eq(vim.api.nvim_win_get_config(0).relative, "editor")
    t.ok(vim.bo[buf].buftype == "acwrite", "обычный редактируемый буфер")
    t.ok(vim.bo[buf].modifiable)
    ms.set_text(buf, "из вида")
    ms.write(buf)
    t.wait(function()
      return d:count("agent.prompt") == 1
    end, "agent.prompt")
    t.eq(d:last("agent.prompt").params.target, "w1:p1")
    view.close_all()
  end)

  it("Вызов на узле субагента", function()
    local d = env("idle")
    s.wait_node("w1:p1/a0000000000000004", nil, "субагент в дереве")
    local rec = ms.stub()
    local before = #d.requests
    messaging.send_message({ node = model.get("w1:p1/a0000000000000004") })
    t.ok(ms.noted(rec, "субагенту писать нельзя"))
    t.eq(ms.input_buf(), nil, "окно не открыто")
    t.eq(#d.requests, before)
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
    local rec = ms.stub()
    local err
    messaging.send_message({
      node = model.get("w1:p1"),
      on_done = function(e)
        err = e
      end,
    })
    local buf = ms.wait_input()
    ms.set_text(buf, "текст")
    ms.write(buf)
    t.wait(function()
      return err ~= nil
    end, "ответ об ошибке")
    t.ok(ms.noted(rec, "недоступен"))
    t.eq(d:count("agent.prompt"), 1, "повторной отправки нет")
    t.ok(vim.api.nvim_buf_is_valid(buf), "окно на месте")
    t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "текст" })
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
