-- Виды панели: наблюдение за терминалом, подключение с вводом, занятый терминал, история,
-- отсутствие опроса (спецификация node-view).
local t = require("helpers.t")
local s = require("view.support")
local view = require("claudr.view")
local model = require("claudr.tree.model")
local double = s.double

after_each(function()
  s.reset()
end)

local function env()
  s.big_editor()
  local d = s.env(
    s.snapshot({
      s.claude_pane("w1:p1", "owner-dialogue"),
      double.pane({ pane_id = "w1:p2", foreground_process = "bash" }),
    }),
    { "owner-dialogue" }
  )
  s.wait_node("w1:p1")
  s.wait_node("w1:p2")
  return d
end

local function requests_except_snapshot(d)
  local out = {}
  for _, r in ipairs(d.requests) do
    if r.method ~= "session.snapshot" and r.method ~= "events.subscribe" and r.method ~= "ping" then
      out[#out + 1] = r.method
    end
  end
  return out
end

-- Команда наблюдения: размер клиента — размер окна вида.
local function observe_cmd(v, pane)
  return ("terminal session observe %s --cols %d --rows %d"):format(
    pane,
    vim.api.nvim_win_get_width(v.win),
    vim.api.nvim_win_get_height(v.win)
  )
end

local function observe_calls(d)
  local out = {}
  for _, c in ipairs(d:calls()) do
    out[#out + 1] = table.concat(c.argv, " ")
  end
  return out
end

local function wait_frames(v, n)
  t.wait(function()
    return v.frames >= n
  end, "кадров " .. n)
end

describe("Подключение к любому узлу", function()
  it("Выбор узла", function()
    env()
    local tree_view = require("claudr.tree.view")
    view.setup()
    tree_view.open()
    t.ok(tree_view.focus("w1:p2"), "узел показан в дереве")
    tree_view.run_action("view")
    local v = s.track(view.views()[1])
    t.ok(v, "вид открыт")
    t.eq(v.kind, "observe")
    t.eq(v.node_id, "w1:p2")
    t.eq(vim.api.nvim_get_current_buf(), v.buf)
    t.eq(vim.bo[v.buf].buftype, "terminal")
  end)
end)

describe("Панель — наблюдение за терминалом", function()
  it("Наблюдение за панелью с агентом", function()
    local d = env()
    local v = s.track(view.open(model.get("w1:p1")))
    d:frame("w1:p1", "\27[2J\27[1;1HAGENT-SCREEN\r\n> prompt", { full = true })
    s.wait_text(v.buf, "AGENT-SCREEN", "полный кадр")
    d:frame("w1:p1", "\27[2;3Hdelta-text")
    s.wait_text(v.buf, "delta-text", "приращение")
    t.eq(v.frames, 2)
    t.eq(v.seq, 2)
    t.match(s.text(v.buf), "AGENT%-SCREEN")
    -- ввода в панель нет: процесс наблюдения, никаких send_keys и attach
    t.eq(observe_calls(d), { observe_cmd(v, "w1:p1") })
    t.eq(requests_except_snapshot(d), {})
    t.eq(vim.api.nvim_get_option_value("modifiable", { buf = v.buf }), false)
  end)

  it("Наблюдение за панелью с командой", function()
    local d = env()
    local v = s.track(view.open(model.get("w1:p2")))
    d:frame("w1:p2", "\27[2J\27[1;1H$ make", { full = true })
    s.wait_text(v.buf, "$ make", "полный кадр")
    d:frame("w1:p2", "\r\nbuild ok")
    s.wait_text(v.buf, "build ok", "новый вывод по кадру")
    t.eq(v.kind, "observe")
    t.eq(observe_calls(d), { observe_cmd(v, "w1:p2") })
    t.eq(requests_except_snapshot(d), {})
  end)

  it("размер окна вида кадром не меняется", function()
    local d = env()
    local v = s.track(view.open(model.get("w1:p2")))
    local width, height = vim.api.nvim_win_get_width(v.win), vim.api.nvim_win_get_height(v.win)
    d:frame("w1:p2", "x", { full = true, width = 100, height = 30 })
    wait_frames(v, 1)
    t.eq(vim.api.nvim_win_get_width(v.win), width)
    t.eq(vim.api.nvim_win_get_height(v.win), height)
  end)

  it("Закрытие вида", function()
    local d = env()
    local v = s.track(view.open(model.get("w1:p1")))
    d:frame("w1:p1", "screen", { full = true })
    wait_frames(v, 1)
    t.ok(s.alive(v.pid), "процесс наблюдения работает")
    s.close_win(v)
    s.wait_exit(v, "наблюдение завершено")
    t.ok(not s.alive(v.pid), "процесс наблюдения завершён")
    t.ok(not vim.api.nvim_buf_is_valid(v.buf), "буфер вида удалён")
    -- завершён сигналом SIGTERM: поддельный herdr выходит кодом 143
    t.eq(v.exited.code, 143)
    -- панель живёт: клиент ничего не просил у сервера, панель в снимке
    t.eq(requests_except_snapshot(d), {})
    t.ok(model.get("w1:p1"), "панель в дереве")
  end)

  it(
    "удаление буфера вида тоже завершает наблюдение",
    function()
      env()
      local v = s.track(view.open(model.get("w1:p2")))
      vim.api.nvim_buf_delete(v.buf, { force = true })
      s.wait_exit(v)
      t.ok(not s.alive(v.pid))
    end
  )
end)

describe("Панель — ввод отдельной командой", function()
  it("Ввод в панель с командой", function()
    local d = env()
    local pane = model.get("w1:p2")
    local tid = pane.data.terminal_id
    d:set_attach_screen(tid, "SHELL-PROMPT $")
    local v = s.track(view.attach(pane))
    t.eq(vim.bo[v.buf].buftype, "terminal")
    s.wait_text(v.buf, "SHELL-PROMPT", "экран панели")
    t.eq(d:calls()[1].argv, { "terminal", "attach", tid })
    vim.fn.chansend(vim.bo[v.buf].channel, "echo HELLO\r")
    t.wait(function()
      return d:attach_input(tid) == "echo HELLO\r"
    end, "ввод дошёл до панели")
    for _, c in ipairs(d:calls()) do
      t.ok(
        c.argv[1] ~= "agent",
        "команда подключения к агенту не используется"
      )
    end
  end)

  it("Отключение", function()
    local d = env()
    local pane = model.get("w1:p2")
    local tid = pane.data.terminal_id
    local v = s.track(view.attach(pane))
    s.wait_text(v.buf, "fake herdr: terminal", "экран")
    -- отключение клавишами herdr Ctrl+b q
    vim.fn.chansend(vim.bo[v.buf].channel, "\2q")
    s.wait_exit(v)
    t.eq(v.exited, 0)
    t.eq(d:attached(tid), nil)
    t.ok(not vim.api.nvim_buf_is_valid(v.buf), "вид закрыт")
    t.eq(requests_except_snapshot(d), {})
    t.ok(model.get("w1:p2"), "панель жива")
  end)

  it(
    "закрытие вида с вводом отключает клиента, панель живёт",
    function()
      local d = env()
      local pane = model.get("w1:p2")
      local tid = pane.data.terminal_id
      local v = s.track(view.attach(pane))
      s.wait_text(v.buf, "fake herdr: terminal", "экран")
      s.close_win(v)
      s.wait_exit(v)
      t.ok(not s.alive(v.pid))
      t.eq(requests_except_snapshot(d), {})
      t.ok(model.get("w1:p2"), "панель жива")
      t.ok(d:attached(tid) == nil, "терминал свободен")
    end
  )
end)

describe("Занятый терминал", function()
  it("Второй клиент с вводом", function()
    local d = env()
    local pane = model.get("w1:p2")
    local tid = pane.data.terminal_id
    d:mark_attached(tid)
    local notes = s.stub_notify()
    local sel = s.stub_select(function()
      return nil -- пользователь ничего не выбрал
    end)
    local v = s.track(view.attach(pane))
    s.wait_exit(v)
    t.wait(function()
      return #sel > 0
    end, "предложение вытеснения")
    sel.restore()
    notes.restore()
    t.ok(
      notes.has("already has an attached client; retry with --takeover"),
      "показан отказ сервера"
    )
    t.eq(sel[1].items[1], require("claudr.view.attach").CHOICE_TAKEOVER)
    -- без решения пользователя вытеснения нет
    local takeover = 0
    for _, c in ipairs(d:calls()) do
      if vim.tbl_contains(c.argv, "--takeover") then
        takeover = takeover + 1
      end
    end
    t.eq(takeover, 0)
    t.eq(#d:calls(), 1)
    t.eq(d:attached(tid), "external")
    t.ok(not vim.api.nvim_buf_is_valid(v.buf), "неудачный вид закрыт")
  end)

  it("Вытеснение по решению пользователя", function()
    local d = env()
    local pane = model.get("w1:p2")
    local tid = pane.data.terminal_id
    -- прежний клиент — другой процесс поддельного herdr с вводом
    local first = { out = "" }
    first.job = vim.fn.jobstart({ "herdr", "terminal", "attach", tid }, {
      pty = true,
      width = 80,
      height = 20,
      on_stdout = function(_, data)
        first.out = first.out .. table.concat(data, "\n")
      end,
      on_exit = function(_, code)
        first.code = code
      end,
    })
    first.pid = vim.fn.jobpid(first.job)
    t.wait(function()
      return d:attached(tid) == tostring(first.pid)
    end, "прежний клиент подключён")
    local notes = s.stub_notify()
    local sel = s.stub_select(function(items)
      return items[1]
    end)
    local refused = view.attach(pane)
    s.wait_exit(refused)
    t.wait(function()
      return #view.views() == 1 and view.views()[1] ~= refused
    end, "подключение с вытеснением")
    sel.restore()
    notes.restore()
    local v = s.track(view.views()[1])
    t.eq(v.takeover, true)
    t.wait(function()
      return #d:calls() == 3
    end, "вызов с вытеснением записан")
    t.eq(d:calls()[#d:calls()].argv, { "terminal", "attach", "--takeover", tid })
    t.wait(function()
      return first.code ~= nil
    end, "прежний клиент отключён сервером")
    t.eq(first.code, 1)
    t.ok(first.out:find("taken over", 1, true), first.out)
    t.wait(function()
      return d:attached(tid) == tostring(v.pid)
    end, "терминал у нового клиента")
  end)
end)

describe("Панель — прокрутка истории", function()
  local function lines_of(n)
    local out = {}
    for i = 1, n do
      out[i] = "line " .. i
    end
    return out
  end

  it("История оболочки", function()
    local d = env()
    d:set_output("w1:p2", { lines = lines_of(1500) })
    local v = view.scrollback(model.get("w1:p2"))
    s.wait_text(v.buf, "line 1500", "история")
    local lines = vim.api.nvim_buf_get_lines(v.buf, 0, -1, false)
    t.eq(#lines, 1000)
    t.eq(lines[1], "line 501")
    t.eq(v.no_history, false)
    t.eq(vim.bo[v.buf].modifiable, false)
    local read = d:last("pane.read")
    t.ok(read, "pane.read вызван")
    local recent
    for _, r in ipairs(d.requests) do
      if r.method == "pane.read" and r.params.source == "recent_unwrapped" then
        recent = r.params
      end
    end
    t.eq(recent.lines, 1000)
  end)

  it("Полноэкранная программа", function()
    local d = env()
    d:set_output("w1:p1", { lines = { "CLAUDE SCREEN", "> ask" }, fullscreen = true })
    local notes = s.stub_notify()
    local v = view.scrollback(model.get("w1:p1"))
    s.wait_text(v.buf, "CLAUDE SCREEN", "текущий экран")
    notes.restore()
    t.eq(v.no_history, true)
    t.ok(notes.has("истории нет"), "сообщение, что истории нет")
    t.match(s.text(v.buf), "истории нет")
    t.match(s.text(v.buf), "> ask")
  end)
end)

describe("Отсутствие таймеров и опроса в видах", function()
  it("Тишина в панели", function()
    local d = env()
    local v = s.track(view.open(model.get("w1:p2")))
    d:frame("w1:p2", "quiet", { full = true })
    wait_frames(v, 1)
    local reads = d:count("pane.read")
    -- события панели (вывод изменился) не вызывают чтения
    d:emit("pane.output_changed", { pane_id = "w1:p2", revision = 5 })
    s.settle()
    s.settle()
    t.eq(d:count("pane.read"), reads)
    t.eq(reads, 0)
    t.eq(v.frames, 1)
    t.eq(s.timer_count(), 0)
  end)
end)
