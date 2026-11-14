-- Состояния буфера диалога (agent-dialogs): решение отправлено, принято, закрытие запроса,
-- передача терминалу, диалог без запроса.
local t = require("helpers.t")
local ds = require("dialogs.support")
local s = ds.ms.tree
local buffer = require("claudr.dialogs.buffer")
local dialogs = require("claudr.dialogs")

local pending, rec, req

before_each(function()
  pending, rec = ds.setup()
  req = ds.add(pending, "permission-bash")
  buffer.open(req)
end)

after_each(function()
  ds.reset()
  s.reset()
  package.loaded["claudr.view"] = nil
end)

describe("Состояние после решения", function()
  it(
    "Решение отправлено, повторная отправка недоступна",
    function()
      ds.choose("1%. разрешить один раз")
      t.eq(#pending.decided, 1)
      t.match(ds.text(), "Состояние: решение отправлено")
      t.eq(ds.line_of("^  %d+%. "), nil, "пунктов больше нет")
      ds.press("<CR>")
      ds.press("c")
      t.eq(#pending.decided, 1, "второго решения нет")
      t.ok(ds.ms.noted(rec, "уже отправлено"))
    end
  )

  it("Решение принято", function()
    ds.choose("1%. разрешить один раз")
    pending.set_state(req, "accepted")
    t.match(ds.text(), "решение принято Claude Code")
    ds.press("<CR>")
    t.eq(#pending.decided, 1)
  end)

  it("Отказ перечня: запрос уже не ждёт", function()
    pending.set_state(req, "answered_elsewhere")
    ds.press("<CR>")
    t.eq(#pending.decided, 0)
  end)
end)

describe("Закрытие запроса", function()
  it("Ответ в панели или другим клиентом", function()
    pending.set_state(req, "answered_elsewhere")
    t.match(ds.text(), "отвечено в панели или другим клиентом")
    t.eq(ds.line_of("^  %d+%. "), nil)
  end)

  it("Закрыт хуком, ответ в панели", function()
    pending.set_state(req, "closed_by_hook")
    t.match(ds.text(), "закрыт хуком, ответ в панели")
    ds.press("<CR>")
    t.eq(
      #pending.decided,
      0,
      "решение по такому запросу не отправляется"
    )
  end)

  it("Ответ принят другим экземпляром", function()
    pending.set_state(req, "answered_other")
    t.match(ds.text(), "ответ принят другим экземпляром")
  end)

  it("Решение отклонено перечнем", function()
    local saved = pending.decide
    pending.decide = function()
      return false, "запрос закрыт"
    end
    ds.choose("1%. разрешить один раз")
    t.ok(ds.ms.noted(rec, "решение не отправлено: запрос закрыт"))
    t.match(ds.text(), "1%. разрешить один раз", "пункты остаются")
    pending.decide = saved
    ds.choose("1%. разрешить один раз")
    t.eq(#pending.decided, 1)
  end)
end)

describe("Передача диалога терминалу", function()
  it(
    "Передача: соединение закрыто, буфер закрыт, предложено подключение",
    function()
      local sample = "subagent-command"
      s.env(s.snapshot({ s.claude_pane("w1:p1", sample) }), sample)
      s.wait_node("w1:p1")
      local attached
      package.loaded["claudr.view"] = {
        attach = function(node)
          attached = node
        end,
      }
      rec = ds.ms.stub({ select = { 1 } })
      ds.press("T")
      t.eq(pending.handoffs, { req })
      t.eq(buffer.current(), nil, "буфер закрыт")
      t.eq(#rec.selects, 1)
      t.eq(rec.selects[1].items[1], "Подключиться с вводом")
      t.ok(
        attached and attached.id == "w1:p1",
        "подключение с вводом к панели"
      )
      t.eq(#pending.decided, 0, "решения нет")
      t.eq(#pending.forgotten, 1)
    end
  )

  it("Отказ от подключения ничего не открывает", function()
    local sample = "subagent-command"
    s.env(s.snapshot({ s.claude_pane("w1:p1", sample) }), sample)
    s.wait_node("w1:p1")
    local attached = false
    package.loaded["claudr.view"] = {
      attach = function()
        attached = true
      end,
    }
    rec = ds.ms.stub({ select = { 2 } })
    ds.press("T")
    t.eq(attached, false)
  end)
end)

describe("Диалог без запроса или нераспознанный", function()
  it(
    "Сессия без хука: сообщение и подключение с вводом, pane.read не вызывается",
    function()
      buffer.close()
      pending.reqs = {}
      local sample = "subagent-command"
      local d =
        s.env(s.snapshot({ s.claude_pane("w1:p1", sample, { agent_status = "blocked" }) }), sample)
      s.wait_node("w1:p1")
      t.eq(dialogs.has_pending("w1:p1"), false)
      local attached
      package.loaded["claudr.view"] = {
        attach = function(node)
          attached = node
        end,
      }
      rec = ds.ms.stub({ select = { 1 } })
      require("claudr.messaging").send_message({ node = require("claudr.tree.model").get("w1:p1") })
      local buf = ds.ms.wait_input()
      ds.ms.set_text(buf, "ответ")
      ds.ms.write(buf)
      t.wait(function()
        return ds.ms.noted(rec, "ждёт ответа на диалог")
      end, "сообщение об ожидании")
      t.wait(function()
        return attached ~= nil
      end, "подключение с вводом")
      t.eq(d:count("pane.read"), 0)
      t.eq(d:count("pane.send_keys"), 0)
      t.eq(d:count("pane.send_text"), 0)
    end
  )
end)

describe("Сообщение заблокированному агенту", function()
  it(
    "Запрос есть: открывается буфер диалога, текст остаётся черновиком",
    function()
      buffer.close()
      pending.reqs = {}
      local sample = "subagent-command"
      s.env(s.snapshot({ s.claude_pane("w1:p1", sample, { agent_status = "blocked" }) }), sample)
      s.wait_node("w1:p1")
      ds.add(pending, "permission-bash")
      require("claudr.messaging").send_message({ node = require("claudr.tree.model").get("w1:p1") })
      local buf = ds.ms.wait_input()
      ds.ms.set_text(buf, "текст")
      ds.ms.write(buf)
      t.wait(function()
        return buffer.current() ~= nil
      end, "буфер диалога")
      t.match(ds.text(), "Инструмент: Bash")
      local key =
        require("claudr.herdr").session_id(require("claudr.herdr").state().snapshot.panes[1])
      t.eq(require("claudr.input").draft({ kind = "message", key = key }), "текст")
    end
  )
end)
