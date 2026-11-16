-- Анимация состояний и кадр анимации (спецификация agent-tree, решения D38, D39): таймер
-- кадров заводится и останавливается по условиям, кадр — функция переданного времени,
-- срабатывание меняет только метки значков. Таймер подменён записывающей фабрикой, время
-- передаётся явно; реального ожидания времени нет.
local t = require("helpers.t")
local s = require("tree.support")
local icons = s.stub_icons()
local model = require("claudr.tree.model")
local view = require("claudr.tree.view")
local double = s.double

-- В заглушке `working` — кадры w0, w1, w2 с периодом 100 мс.
local PERIOD = 100

local rec

before_each(function()
  icons = s.stub_icons()
  rec = s.timer_recorder()
  view._set_timer_factory(rec.factory)
end)

after_each(function()
  if view.buf() then
    vim.api.nvim_buf_delete(view.buf(), { force = true })
  end
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd("tabclose!")
  end
  view._set_timer_factory()
  s.reset()
end)

local function wait_line(id)
  t.wait(function()
    return view.line_of(id) ~= nil
  end, "строка узла " .. id)
end

-- Панель с агентом в состоянии `status` (без сессии Claude Code).
local function agent(id, status)
  return double.pane({ pane_id = id, agent = "codex", agent_status = status })
end

-- Снимок одной вкладки, где агент вкладки — `w1:p0` в фокусе (idle, без анимации), а панели
-- `panes` — строки прочих агентов: строку панели с агентом дерево показывает только у них.
local function snap(panes)
  table.insert(
    panes,
    1,
    double.pane({ pane_id = "w1:p0", agent = "codex", agent_status = "idle", focused = true })
  )
  return s.snapshot(panes)
end

-- Ждать состояния таймера: перепроверка после событий окон идёт после самого события.
local function wait_timer(active, msg)
  t.wait(function()
    return (rec.active() ~= nil) == active
  end, msg)
end

local function wait_status(id, status)
  s.wait_node(id, function(n)
    return n.state == status
  end, id .. " в " .. status)
end

describe("Функция кадра", function()
  it(
    "номер кадра по времени, периоду и числу кадров",
    function()
      t.eq(view.frame_index(3, 100, 0), 0)
      t.eq(view.frame_index(3, 100, 99), 0)
      t.eq(view.frame_index(3, 100, 100), 1)
      t.eq(view.frame_index(3, 100, 500), 2)
      t.eq(view.frame_index(3, 100, 600), 0)
      t.eq(view.frame_index(1, 100, 12345), 0)
    end
  )
end)

describe("Анимация состояний", function()
  it("Таймер заведён", function()
    s.env(snap({ agent("w1:p1", "working") }))
    view.open()
    wait_line("w1:p1")
    local tm = rec.active()
    t.ok(tm, "таймер заведён")
    t.eq(tm.rep, 0, "одиночное срабатывание")
    t.ok(
      tm.delay >= 1 and tm.delay <= PERIOD,
      "до ближайшей границы кадра: " .. tm.delay
    )
  end)

  it(
    "ближайшая граница кадра среди анимируемых значков",
    function()
      local tbl = vim.deepcopy(s.ICONS)
      tbl.blocked = { frames = { "b0", "b1" }, period = 1000 }
      icons.set(tbl)
      s.env(snap({ agent("w1:p1", "blocked"), agent("w1:p2", "working") }))
      view.open()
      wait_line("w1:p2")
      view._tick(1030)
      t.eq(rec.active().delay, 70, "граница working (1100), а не blocked (2000)")
    end
  )

  it("Нет анимируемых узлов", function()
    s.env(snap({ agent("w1:p1", "idle"), agent("w1:p2", "blocked") }))
    view.open()
    wait_line("w1:p2")
    t.eq(rec.active(), nil)
    t.eq(#rec.timers, 0, "таймер не создавался")
  end)

  it("Окно закрыто", function()
    s.env(snap({ agent("w1:p1", "working") }))
    view.open()
    wait_line("w1:p1")
    t.ok(rec.active())
    view.close()
    wait_timer(false, "окно закрыто — таймер остановлен")
    view.open()
    wait_timer(true, "показ дерева заводит снова")
  end)

  it("Окно закрыто: дерева нет в текущей вкладке", function()
    s.env(snap({ agent("w1:p1", "working") }))
    view.open()
    wait_line("w1:p1")
    t.ok(rec.active())
    vim.cmd("tabnew")
    wait_timer(false, "вкладка без дерева — таймер остановлен")
    vim.cmd("tabprevious")
    wait_timer(
      true,
      "возврат во вкладку с деревом заводит снова"
    )
  end)

  it(
    "буфер дерева сменился в окне — таймер остановлен",
    function()
      s.env(snap({ agent("w1:p1", "working") }))
      local win = view.open()
      wait_line("w1:p1")
      t.ok(rec.active())
      vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
      t.wait(function()
        return rec.active() == nil
      end, "остановка после смены буфера")
      vim.api.nvim_win_set_buf(win, view.buf())
      wait_timer(true, "буфер дерева снова показан")
    end
  )

  it("Анимируемый узел скрыт", function()
    s.env(snap({ agent("w1:p1", "working") }))
    view.open()
    wait_line("w1:p1")
    t.ok(rec.active())
    -- вкладка и workspace в двойнике — `unknown` (один кадр)
    t.ok(view.focus("w1:t1"))
    view.toggle_fold()
    t.eq(view.line_of("w1:p1"), nil, "узел свёрнут вместе с родителем")
    t.eq(rec.active(), nil, "таймер остановлен")
    view.toggle_fold()
    t.ok(rec.active(), "разворачивание заводит снова")
  end)

  it("скрытый завершённый узел не анимируется", function()
    local tbl = vim.deepcopy(s.ICONS)
    tbl.done = { frames = { "d0", "d1" }, period = 100 }
    icons.set(tbl)
    s.env(snap({ s.claude_pane("w1:p1", "subagent-nested") }), "subagent-nested")
    view.open()
    s.wait_node("w1:p1/a0000000000000002")
    wait_line("w1:p1")
    t.eq(rec.active(), nil, "завершённые скрыты — анимируемых нет")
    model.toggle_finished()
    t.ok(rec.active(), "показ завершённых заводит таймер")
    model.toggle_finished()
    t.eq(rec.active(), nil)
  end)

  it("Состояние изменилось", function()
    local d = s.env(snap({ agent("w1:p1", "working"), agent("w1:p2", "idle") }))
    view.open()
    wait_line("w1:p1")
    t.ok(rec.active())
    d:set_agent_status("w1:p1", "idle")
    wait_status("w1:p1", "idle")
    t.eq(rec.active(), nil, "последний working перешёл в idle")
    d:set_agent_status("w1:p2", "working")
    wait_status("w1:p2", "working")
    t.ok(rec.active(), "idle перешёл в working")
  end)

  it("модель остановлена — таймер остановлен", function()
    s.env(snap({ agent("w1:p1", "working") }))
    view.open()
    wait_line("w1:p1")
    t.ok(rec.active())
    model.stop()
    t.eq(rec.active(), nil)
  end)

  it("срабатывание перепроверяет условия", function()
    s.env(snap({ agent("w1:p1", "working") }))
    view.open()
    wait_line("w1:p1")
    view._tick(PERIOD)
    t.ok(rec.active())
    -- режим сменился без перерисовки: срабатывание само видит, что условия не выполнены
    require("claudr.config").get().icons = "text"
    view._tick(2 * PERIOD)
    t.eq(rec.active(), nil)
  end)

  it(
    "утечек нет: таймер закрыт и подписка на значки снята",
    function()
      s.env(snap({ agent("w1:p1", "working") }))
      view.open()
      wait_line("w1:p1")
      t.eq(#icons.subs, 1, "подписка на значки")
      view.close()
      wait_timer(false, "окно закрыто")
      for _, tm in ipairs(rec.timers) do
        t.ok(tm.closed, "таймер закрыт")
      end
      view.open()
      vim.api.nvim_buf_delete(view.buf(), { force = true })
      t.eq(#icons.subs, 0, "подписка на значки снята")
      t.eq(icons.unsubscribed, 1)
      for _, tm in ipairs(rec.timers) do
        t.ok(tm.closed and not tm.started, "таймер остановлен и закрыт")
      end
      t.eq(rec.count("start") > 0, true)
    end
  )
end)

describe("Кадр анимации", function()
  it("Смена кадра", function()
    s.env(snap({ agent("w1:p1", "working"), agent("w1:p2", "working") }))
    view.open()
    wait_line("w1:p2")
    local base = 999 * PERIOD -- кадр 0
    view._tick(base)
    t.eq(view._icon("w1:p1").text, "w0")
    t.eq(view._icon("w1:p2").text, "w0")
    view._tick(base + PERIOD)
    t.eq(view._icon("w1:p1").text, "w1")
    t.eq(view._icon("w1:p2").text, "w1")
    view._tick(base + 2 * PERIOD)
    t.eq(view._icon("w1:p1").text, "w2")
    view._tick(base + 3 * PERIOD)
    t.eq(view._icon("w1:p1").text, "w0", "по кругу после последнего")
  end)

  it("Кадр по часам", function()
    s.env(snap({ agent("w1:p1", "working") }))
    view.open()
    wait_line("w1:p1")
    view._tick(5 * PERIOD)
    t.eq(
      view._icon("w1:p1").text,
      "w2",
      "кадр 2 из трёх при пяти периодах"
    )
    t.eq(
      rec.active().delay,
      PERIOD,
      "следующая граница — через период"
    )
  end)

  it("Только значки", function()
    s.env(snap({ agent("w1:p1", "working"), agent("w1:p2", "idle") }))
    local win = view.open()
    wait_line("w1:p2")
    vim.api.nvim_win_set_cursor(win, { view.line_of("w1:p2"), 0 })
    view._tick(0)
    local ns = vim.api.nvim_get_namespaces()
    local lines = view.lines()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local nodes = {}
    for i = 1, #lines do
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      local n = view.node_at_cursor()
      nodes[i] = n and n.id or false
    end
    vim.api.nvim_win_set_cursor(win, cursor)
    local hl_marks = vim.api.nvim_buf_get_extmarks(view.buf(), ns["claudr.tree"], 0, -1, {})
    local icon_marks = vim.api.nvim_buf_get_extmarks(view.buf(), ns["claudr.tree.icons"], 0, -1, {})
    local tick = vim.api.nvim_buf_get_changedtick(view.buf())
    local idle = view._icon("w1:p2")
    view._tick(PERIOD)
    t.eq(view.lines(), lines, "строки буфера прежние")
    t.eq(vim.api.nvim_buf_get_changedtick(view.buf()), tick, "буфер не писался")
    t.eq(vim.api.nvim_win_get_cursor(win), cursor, "курсор прежний")
    for i = 1, #lines do
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      local n = view.node_at_cursor()
      t.eq(n and n.id or false, nodes[i], "список узлов прежний")
    end
    vim.api.nvim_win_set_cursor(win, cursor)
    t.eq(vim.api.nvim_buf_get_extmarks(view.buf(), ns["claudr.tree"], 0, -1, {}), hl_marks)
    t.eq(
      vim.api.nvim_buf_get_extmarks(view.buf(), ns["claudr.tree.icons"], 0, -1, {}),
      icon_marks,
      "метки значков на прежних местах"
    )
    t.eq(
      view._icon("w1:p1").text,
      "w1",
      "метка анимируемой строки сменилась"
    )
    t.eq(view._icon("w1:p2"), idle, "неанимируемая строка не тронута")
  end)
end)

describe("Кадры строк со сдвигом (per_row)", function()
  -- Образец herdr: 8 кадров, 83 мс, разброс 0.10.
  local MOON = { "m0", "m1", "m2", "m3", "m4", "m5", "m6", "m7" }
  local function per_row_icons(spread)
    local tbl = vim.deepcopy(s.ICONS)
    tbl.working = { frames = MOON, period = 83, per_row = true, spread = spread }
    return tbl
  end

  it("часы строки совпадают с row_phase herdr", function()
    local e = per_row_icons(100).working
    -- значения посчитаны по status_frames.rs (FNV-1a 64 и splitmix64, ключ машины пустой)
    local period, offset = view.row_clock(e, "w1:p1")
    t.eq(period, 86735)
    t.eq(offset, 510167)
    period, offset = view.row_clock(e, "w1:p2")
    t.eq(period, 90470)
    t.eq(offset, 331971)
  end)

  it("разброс и сдвиг в пределах", function()
    local e = per_row_icons(100).working
    for i = 1, 200 do
      local period, offset = view.row_clock(e, "w" .. i .. ":p1")
      t.ok(period >= 83 * 900 and period <= 83 * 1100, "период " .. period)
      t.ok(offset >= 0 and offset < period * #MOON, "сдвиг " .. offset)
    end
    local period = view.row_clock(per_row_icons(0).working, "w1:p1")
    t.eq(period, 83000, "без разброса — период состояния")
    t.eq(
      { view.row_clock(s.ICONS.working, "w1:p1") },
      { 100000, 0 },
      "synced — без сдвига"
    )
  end)

  it("разные строки показывают разные кадры", function()
    icons.set(per_row_icons(100))
    s.env(snap({ agent("w1:p1", "working"), agent("w1:p2", "working") }))
    view.open()
    wait_line("w1:p2")
    local base = 1000000
    view._tick(base)
    local a, b = view._icon("w1:p1").text, view._icon("w1:p2").text
    t.eq(a, MOON[view.row_frame_index(icons.table.working, "w1:p1", base) + 1])
    t.eq(b, MOON[view.row_frame_index(icons.table.working, "w1:p2", base) + 1])
    local differ = 0
    for i = 0, 40 do
      local now = base + i * 50
      view._tick(now)
      if view._icon("w1:p1").text ~= view._icon("w1:p2").text then
        differ = differ + 1
      end
    end
    t.ok(differ > 0, "кадры строк не совпадают всё время")
  end)

  it("ключ строки вкладки — панель её агента", function()
    icons.set(per_row_icons(100))
    s.env({
      workspaces = { double.workspace({ workspace_id = "w1", label = "ws1" }) },
      tabs = {
        double.tab({ tab_id = "w1:t1", number = 1, agent_status = "working" }),
        double.tab({ tab_id = "w1:t2", number = 2, agent_status = "working" }),
      },
      panes = {
        agent("w1:p1", "working"),
        double.pane({
          pane_id = "w1:p2",
          tab_id = "w1:t2",
          agent = "codex",
          agent_status = "working",
        }),
      },
    })
    view.open()
    wait_line("w1:t2")
    for i = 0, 20 do
      local now = 1000000 + i * 37
      view._tick(now)
      for tab, pane in pairs({ ["w1:t1"] = "w1:p1", ["w1:t2"] = "w1:p2" }) do
        t.eq(
          view._icon(tab).text,
          MOON[view.row_frame_index(icons.table.working, pane, now) + 1],
          tab
        )
      end
    end
  end)

  it("таймер — на ближайшую границу среди строк", function()
    icons.set(per_row_icons(100))
    s.env(snap({ agent("w1:p1", "working"), agent("w1:p2", "working") }))
    view.open()
    wait_line("w1:p2")
    local now = 1000000
    view._tick(now)
    local best
    for _, id in ipairs({ "w1:p1", "w1:p2" }) do
      local period, offset = view.row_clock(icons.table.working, id)
      local us = now * 1000
      local b = (math.floor((us + offset) / period) + 1) * period - offset
      best = (not best or b < best) and b or best
    end
    local delay = rec.active().delay
    t.ok(
      delay >= math.ceil((best - now * 1000) / 1000)
        and delay <= math.ceil((best + 2000 - now * 1000) / 1000),
      "задержка " .. delay
    )
  end)
end)

describe("Обновление по событиям", function()
  it("Таймер кадров не читает данные", function()
    local d = s.env(
      s.snapshot({ s.claude_pane("w1:p1", "owner-killed", { agent_status = "working" }) }),
      "owner-killed"
    )
    view.open()
    wait_line("w1:p1/a0000000000000005")
    s.settle()
    local requests = #d.requests
    local notified = 0
    local unsub = model.subscribe(function()
      notified = notified + 1
    end)
    local reads = s.count_reads()
    local ok, err = pcall(function()
      for i = 1, 5 do
        view._tick(i * PERIOD)
      end
    end)
    reads.restore()
    unsub()
    t.ok(ok, err)
    t.eq(reads.open, 0, "файлы не читаются: " .. table.concat(reads.paths, ", "))
    t.eq(reads.read, 0)
    t.eq(#d.requests, requests, "запросов к сокету нет")
    t.eq(notified, 0, "модель не перестраивается")
    t.ok(rec.active(), "таймер переставлен на следующую границу")
  end)

  it(
    "Ничего не происходит: без анимируемых узлов таймер не заведён",
    function()
      view._set_timer_factory()
      local timers = s.timer_count()
      s.env(snap({ agent("w1:p1", "idle") }))
      view.open()
      wait_line("w1:p1")
      s.settle()
      t.eq(view._timer_active(), false)
      t.eq(s.timer_count(), timers, "ни один таймер не заведён")
    end
  )
end)
