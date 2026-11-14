-- Клиент herdr: снимок и подписка, события, выход процесса, подписки по панелям,
-- потеря событий.
local t = require("helpers.t")
local double = require("helpers.herdr_double")
local support = require("herdr.support")
local herdr = require("claudr.herdr")

local d, rec

-- Ждать, пока клиент не перестанет читать снимок.
local function wait_idle()
  t.wait(function()
    local reading = herdr._reading()
    return not reading
  end, "чтение снимка завершено")
end

before_each(function()
  d = support.connected(herdr)
  wait_idle()
  rec = support.recorder(herdr)
end)

after_each(function()
  rec.unsubscribe()
  herdr.stop()
  d:close()
end)

describe("Снимок и подписка", function()
  it(
    "подписка открыта до снимка и на отдельном соединении",
    function()
      local sub_index, snap_index, sub_conn, snap_conn
      for i, r in ipairs(d.requests) do
        if r.method == "events.subscribe" and not sub_index then
          sub_index, sub_conn = i, r.conn
        elseif r.method == "session.snapshot" and not snap_index then
          snap_index, snap_conn = i, r.conn
        end
      end
      t.ok(sub_index < snap_index, "подписка раньше снимка")
      t.ok(sub_conn ~= snap_conn, "снимок другим соединением")
    end
  )

  it("Событие во время чтения снимка", function()
    d:hold("session.snapshot")
    d:emit("pane_updated", { pane = d.state.panes[2] })
    t.wait(function()
      return d:held_count("session.snapshot") == 1
    end, "чтение снимка начато")
    local before = d:count("session.snapshot")
    table.insert(d.state.panes, double.pane({ pane_id = "w2:p3" }))
    d:emit("pane_created", { pane = d.state.panes[#d.state.panes] })
    t.wait(function()
      local _, dirty = herdr._reading()
      return dirty
    end, "событие пришло во время чтения")
    d:release("session.snapshot")
    t.wait(function()
      return support.has_pane(herdr.state().snapshot, "w2:p3")
    end, "итоговое состояние содержит новую панель")
    t.ok(d:count("session.snapshot") > before, "снимок запрошен ещё раз")
  end)

  it("Занятое соединение подписки", function()
    local err = support.call(herdr, "pane.send_keys", { pane_id = "w1:p1", keys = "z" })
    t.eq(err, nil)
    local req = d:last("pane.send_keys")
    for _, s in ipairs(d.subscriptions) do
      t.ok(s.conn ~= req.conn, "запрос не идёт соединением подписки")
    end
    -- Соединения подписки продолжают получать события.
    t.ok(d:set_agent_status("w1:p1", "working") >= 1)
    t.wait(function()
      return rec:has_event("pane.agent_status_changed", "w1:p1")
    end, "событие по соединению подписки")
  end)

  it(
    "событие не накладывается на снимок как данные",
    function()
      -- Событие говорит о панели, которой нет в снимке сервера: в кэш она не попадает.
      local before = d:count("session.snapshot")
      d:emit("pane_created", { pane = double.pane({ pane_id = "w9:p9" }) })
      t.wait(function()
        return rec:has_event("pane_created") and d:count("session.snapshot") > before
      end, "событие и перечитывание")
      wait_idle()
      t.wait(function()
        return not herdr.state().stale
      end, "кэш обновлён")
      t.ok(not support.has_pane(herdr.state().snapshot, "w9:p9"))
    end
  )
end)

describe("События жизненного цикла", function()
  it("Событие через подчёркивание", function()
    local before = d:count("session.snapshot")
    d:emit_raw(
      '{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w1:p2","workspace_id":"w1"}}\n'
    )
    t.wait(function()
      return rec:has_event("pane_closed", "w1:p2") and d:count("session.snapshot") > before
    end, "кэш устарел и перечитан")
  end)

  it("Событие подписки на панель", function()
    local before = d:count("session.snapshot")
    d:emit_raw(
      '{"event":"pane.agent_status_changed","data":{"agent_status":"working","pane_id":"w1:p1","workspace_id":"w1"}}\n'
    )
    t.wait(function()
      return rec:has_event("pane.agent_status_changed", "w1:p1")
        and d:count("session.snapshot") > before
    end, "обработано по значению event")
  end)

  it("Первое событие состояния без агента", function()
    local before = d:count("session.snapshot")
    local delivered = d:emit("pane.agent_status_changed", {
      agent_status = "unknown",
      display_agent = "haiku",
      pane_id = "w2:p1",
      workspace_id = "w2",
    })
    t.ok(delivered >= 1)
    t.wait(function()
      return rec:has_event("pane.agent_status_changed", "w2:p1")
        and d:count("session.snapshot") > before
    end, "событие принято")
    local ev
    for _, e in ipairs(rec.events) do
      if e.event == "pane.agent_status_changed" then
        ev = e
      end
    end
    t.eq(ev.data.agent, nil)
    t.eq(herdr.state().status, "connected")
  end)

  it(
    "подписка без параметров на события жизненного цикла",
    function()
      local general
      for _, s in ipairs(d.subscriptions) do
        if not s.subscriptions[1].pane_id then
          general = s.subscriptions
        end
      end
      local types = {}
      for _, r in ipairs(general) do
        t.eq(r.pane_id, nil)
        types[r.type] = true
      end
      for _, name in ipairs({
        "workspace.created",
        "workspace.closed",
        "tab.created",
        "tab.closed",
        "pane.created",
        "pane.updated",
        "pane.closed",
        "pane.exited",
        "pane.agent_detected",
        "layout.updated",
      }) do
        t.ok(types[name], name)
      end
    end
  )
end)

describe("Выход процесса панели", function()
  it("Выход в единственной панели", function()
    local before = d:count("session.snapshot")
    d:pane_exited("w1:p1", { vanish = true })
    t.wait(function()
      local snap = herdr.state().snapshot
      return d:count("session.snapshot") > before
        and not support.has_pane(snap, "w1:p1")
        and not support.has_workspace(snap, "w1")
        and rec:has_event("pane_exited", "w1:p1")
    end, "панель и workspace сняты по снимку")
    t.ok(not rec:has_event("pane_closed"))
    t.ok(not rec:has_event("workspace_closed"))
    local exited
    for _, e in ipairs(rec.events) do
      if e.event == "pane_exited" then
        exited = e
      end
    end
    t.eq(exited.data.pane_id, "w1:p1")
    t.eq(exited.data.exit_code, nil)
    -- Подписки по панелям пересобраны по новому снимку.
    support.wait_pane_subscriptions(d, { "w2:p1", "w2:p2" })
    t.eq(herdr.state().status, "connected")
    t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
  end)

  it("Выход при остальных панелях", function()
    d:pane_exited("w2:p2", { vanish = true })
    t.wait(function()
      local snap = herdr.state().snapshot
      return rec:has_event("pane_exited", "w2:p2") and not support.has_pane(snap, "w2:p2")
    end, "снимок перечитан")
    wait_idle()
    local ids = {}
    for _, p in ipairs(herdr.state().snapshot.panes) do
      table.insert(ids, p.pane_id)
    end
    t.eq(ids, { "w1:p1", "w2:p1" })
    t.ok(support.has_workspace(herdr.state().snapshot, "w2"))
  end)
end)

describe("Подписки по панелям", function()
  it(
    "подписки создаются только для панелей последнего снимка",
    function()
      local set = support.pane_subscriptions(d)
      t.eq(set, { ["w1:p1"] = true, ["w2:p1"] = true, ["w2:p2"] = true })
      for _, s in ipairs(d.subscriptions) do
        for _, r in ipairs(s.subscriptions) do
          if r.pane_id then
            t.ok(r.type == "pane.output_changed" or r.type == "pane.agent_status_changed", r.type)
          end
        end
      end
    end
  )

  it("Закрытие панели", function()
    local subscribes = d:count("events.subscribe")
    table.remove(d.state.panes, 3) -- w2:p2
    d:emit("pane_closed", { pane_id = "w2:p2", workspace_id = "w2" })
    support.wait_pane_subscriptions(d, { "w1:p1", "w2:p1" })
    t.eq(
      d:count("events.subscribe"),
      subscribes + 1,
      "открыта одна новая подписка"
    )
    t.eq(support.lifecycle_subscriptions(d), 1, "общая подписка не тронута")
    -- Остальные подписки продолжают действовать.
    t.eq(d:set_agent_status("w2:p1", "working"), 1)
    t.wait(function()
      return rec:has_event("pane.agent_status_changed", "w2:p1")
    end, "событие по оставшейся панели")
    -- Кадр pane_not_found и конец потока подписки по панелям — не потеря сервера.
    t.eq(herdr.state().status, "connected")
    t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
  end)

  it(
    "кадр pane_not_found и конец подписки по панелям без события — подписка пересобрана",
    function()
      local subscribes = d:count("events.subscribe")
      local snapshots = d:count("session.snapshot")
      -- Панель исчезла, событие жизненного цикла не пришло: сигналом служит только
      -- завершение подписки по панелям.
      table.remove(d.state.panes, 3) -- w2:p2
      d:_end_pane_subscriptions("w2:p2")
      support.wait_pane_subscriptions(d, { "w1:p1", "w2:p1" })
      wait_idle()
      t.ok(d:count("session.snapshot") > snapshots, "снимок перечитан")
      t.eq(d:count("events.subscribe"), subscribes + 1)
      t.eq(support.lifecycle_subscriptions(d), 1, "общая подписка не тронута")
      t.ok(not support.has_pane(herdr.state().snapshot, "w2:p2"))
      t.eq(herdr.state().status, "connected")
      t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
    end
  )

  it("Новая панель", function()
    table.insert(d.state.panes, double.pane({ pane_id = "w2:p3" }))
    d:emit("pane_created", { pane = d.state.panes[#d.state.panes] })
    support.wait_pane_subscriptions(d, { "w1:p1", "w2:p1", "w2:p2", "w2:p3" })
    t.ok(support.has_pane(herdr.state().snapshot, "w2:p3"))
    t.eq(d:set_agent_status("w2:p3", "idle"), 1)
  end)

  it(
    "отклонённая подписка по панелям — новый снимок и подписка по нему",
    function()
      -- Панель исчезает между снимком и подпиской: сервер отклоняет весь запрос.
      table.insert(d.state.panes, double.pane({ pane_id = "w2:p3" }))
      d:hold("session.snapshot")
      d:emit("pane_created", { pane = d.state.panes[#d.state.panes] })
      t.wait(function()
        return d:held_count("session.snapshot") == 1
      end, "снимок с новой панелью вычислен")
      table.remove(d.state.panes) -- w2:p3 закрыта, событие ещё не дошло
      local subscribes = d:count("events.subscribe")
      d:release("session.snapshot")
      t.wait(function()
        return d:count("events.subscribe") > subscribes
      end, "подписка с исчезнувшей панелью подана")
      d:emit("pane_closed", { pane_id = "w2:p3", workspace_id = "w2" })
      -- Прежняя подписка по панелям совпадает с итоговым составом, поэтому ждать нужно
      -- снимка без исчезнувшей панели, а не смены подписки.
      t.wait(function()
        return not support.has_pane(herdr.state().snapshot, "w2:p3")
      end, "снимок без исчезнувшей панели")
      support.wait_pane_subscriptions(d, { "w1:p1", "w2:p1", "w2:p2" })
      wait_idle()
      t.eq(herdr.state().status, "connected")
      t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
    end
  )
end)

describe("Потеря событий", function()
  it(
    "events_lost во время пересборки подписки по панелям",
    function()
      d:hold("events.subscribe")
      table.insert(d.state.panes, double.pane({ pane_id = "w2:p5" }))
      local subscribes = d:count("events.subscribe")
      d:emit("pane_created", { pane = d.state.panes[#d.state.panes] })
      t.wait(function()
        return d:count("events.subscribe") > subscribes
      end, "пересборка подписки по панелям начата")
      d:events_lost()
      t.wait(function()
        return d:count("events.subscribe") > subscribes + 1
      end, "общая подписка подана заново")
      d:release("events.subscribe")
      support.wait_pane_subscriptions(d, { "w1:p1", "w2:p1", "w2:p2", "w2:p5" })
      t.eq(herdr.state().status, "connected")
      t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
    end
  )

  it("Отставший читатель", function()
    local subscribes = d:count("events.subscribe")
    local snapshots = d:count("session.snapshot")
    table.insert(d.state.panes, double.pane({ pane_id = "w2:p4" }))
    local mark = #d.requests
    d:events_lost()
    t.wait(function()
      return support.has_pane(herdr.state().snapshot, "w2:p4")
    end, "дерево по новому снимку")
    t.ok(d:count("events.subscribe") > subscribes, "подписка заново")
    t.ok(d:count("session.snapshot") > snapshots, "новый снимок")
    support.wait_pane_subscriptions(d, { "w1:p1", "w2:p1", "w2:p2", "w2:p4" })
    t.eq(support.lifecycle_subscriptions(d), 1)
    t.eq(herdr.state().status, "connected")
    t.ok(not rec:seen_status("no_server"), "без перехода в «нет сервера»")
    -- Новая общая подписка начата раньше нового снимка.
    local sub_i, snap_i
    for i = mark + 1, #d.requests do
      local r = d.requests[i]
      if not sub_i and r.method == "events.subscribe" and not r.params.subscriptions[1].pane_id then
        sub_i = i
      elseif sub_i and not snap_i and r.method == "session.snapshot" then
        snap_i = i
      end
    end
    t.ok(sub_i and snap_i, "подписка, затем снимок")
  end)
end)

describe("Поток событий вывода панели", function()
  it(
    "события вывода во время чтения снимка сливаются в одно следующее чтение",
    function()
      local before = d:count("session.snapshot")
      local seen = herdr._events()
      d:hold("session.snapshot")
      d:emit("pane.output_changed", { pane_id = "w1:p1", revision = 1 })
      t.wait(function()
        return d:held_count("session.snapshot") == 1
      end, "чтение снимка начато")
      for i = 2, 30 do
        t.eq(d:emit("pane.output_changed", { pane_id = "w1:p1", revision = i }), 1)
      end
      t.wait(function()
        return herdr._events() == seen + 30
      end, "события получены")
      t.eq(
        d:count("session.snapshot"),
        before + 1,
        "второй запрос не послан, пока идёт первый"
      )
      d:release("session.snapshot")
      wait_idle()
      print(
        string.format(
          "  замер: запросов снимка на 30 событий вывода — %d",
          d:count("session.snapshot") - before
        )
      )
      t.eq(
        d:count("session.snapshot"),
        before + 2,
        "одно чтение и одно следующее"
      )
    end
  )
end)
