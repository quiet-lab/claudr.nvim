-- Значки, подписи и цвета узлов, значки состояний, режим без значков (спецификация agent-tree,
-- решения D36, D37, D41–D43). Значки herdr — синтетическая заглушка `claudr.herdr.icons`.
local t = require("helpers.t")
local s = require("tree.support")
local icons = s.stub_icons()
local model = require("claudr.tree.model")
local view = require("claudr.tree.view")
local config = require("claudr.config")
local double = s.double

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
  view._set_timer_factory()
  s.reset()
end)

local function line(id)
  return view.lines()[view.line_of(id)]
end

local function wait_line(id, pattern)
  t.wait(function()
    local row = view.line_of(id)
    return row ~= nil and (pattern == nil or view.lines()[row]:find(pattern) ~= nil)
  end, "строка узла " .. id)
end

-- Группа подсветки строки `id`, начинающаяся в столбце `col` (метки подсветки дерева).
local function hl_at(id, col)
  local ns = vim.api.nvim_get_namespaces()["claudr.tree"]
  local row = view.line_of(id) - 1
  for _, m in
    ipairs(
      vim.api.nvim_buf_get_extmarks(view.buf(), ns, { row, 0 }, { row, -1 }, { details = true })
    )
  do
    if m[3] == col then
      return m[4].hl_group
    end
  end
end

-- Окрашена ли строка `id` цветом workspace (группы `ClaudrTreeColor…`).
local function colored(id)
  local ns = vim.api.nvim_get_namespaces()["claudr.tree"]
  local row = view.line_of(id) - 1
  for _, m in
    ipairs(
      vim.api.nvim_buf_get_extmarks(view.buf(), ns, { row, 0 }, { row, -1 }, { details = true })
    )
  do
    if vim.startswith(m[4].hl_group or "", "ClaudrTreeColor") then
      return true
    end
  end
  return false
end

local function hl_fg(name)
  local h = vim.api.nvim_get_hl(0, { name = name })
  return h.fg and string.format("#%06x", h.fg) or nil
end

local function ws(o)
  local w = double.workspace(o)
  if o.tokens == false then
    w.tokens = nil
  end
  return w
end

describe("Значки узлов", function()
  it("Панель с агентом", function()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed", { agent_status = "idle" }) }))
    view.open()
    wait_line("w1:p1")
    local ic = view._icon("w1:p1")
    t.eq(ic.text, "i")
    t.eq(ic.hl, "DiagnosticOk")
    t.eq(ic.pos, "inline")
    -- панель без детей: отступ, место знака свёртки и пробел
    t.eq(ic.col, #"      ", "значок в начале строки узла")
    t.eq(line("w1:p1"), "      opus задача w1:p1")
    t.eq(
      line("w1:p1"):find(" A ", 1, true),
      nil,
      "буквенного обозначения нет"
    )
  end)

  it("Субагент и команда", function()
    config.setup({ show_finished = true })
    -- работающий субагент и завершённая команда — из двух образцов
    s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "owner-killed"),
        s.claude_pane("w1:p2", "command-completed"),
      }),
      { "owner-killed", "command-completed" }
    )
    view.open()
    local a = s.wait_node("w1:p1/a0000000000000005")
    local c = s.wait_node("w1:p2/bfixt0005")
    t.eq(a.state, "running")
    t.eq(c.state, "finished")
    wait_line(a.id)
    wait_line(c.id)
    t.match(view._icon(a.id).text, "^w%d$", "значок working")
    t.match(line(a.id), "🤖 ")
    t.eq(view._icon(c.id).text, "d")
    t.match(line(c.id), "🔧 ")
    for _, id in ipairs({ a.id, c.id }) do
      t.eq(line(id):find("\239\184\143", 1, true), nil, "без U+FE0F")
      local sign = line(id):find("🤖", 1, true) or line(id):find("🔧", 1, true)
      t.eq(
        view._icon(id).col,
        sign - 1,
        "знак вида сразу после значка состояния"
      )
    end
  end)

  it(
    "панель с командой — знак $ без значка состояния",
    function()
      s.env(s.snapshot({
        double.pane({ pane_id = "w1:p1", foreground_process = "cargo", cwd = "/src" }),
      }))
      view.open()
      wait_line("w1:p1")
      t.eq(view._icon("w1:p1"), nil)
      t.eq(line("w1:p1"), "      $ cargo /src")
    end
  )

  it("Состояния нет", function()
    local tab = double.tab({ tab_id = "w1:t1", label = "main" })
    tab.agent_status = nil
    s.env({
      workspaces = { ws({ workspace_id = "w1", label = "ws1" }) },
      tabs = { tab },
      panes = { double.pane({ pane_id = "w1:p1" }) },
    })
    view.open()
    wait_line("w1:t1")
    t.eq(view._icon("w1:t1"), nil)
    t.match(line("w1:t1"), "^  ▾ main$")
  end)

  it("состояние вкладки — из снимка", function()
    s.env({
      workspaces = { ws({ workspace_id = "w1" }) },
      tabs = { double.tab({ tab_id = "w1:t1", agent_status = "blocked" }) },
      panes = { double.pane({ pane_id = "w1:p1" }) },
    })
    t.eq(s.wait_node("w1:t1").state, "blocked")
    t.eq(model.get("w1:t1").icon, "blocked")
    view.open()
    wait_line("w1:t1")
    t.eq(view._icon("w1:t1").text, "b")
  end)
end)

describe("Подписи workspace и вкладок", function()
  it("Символ и цвет", function()
    s.env({
      workspaces = {
        ws({ workspace_id = "w1", label = "demo", tokens = { symbol = "S1", color = "#336699" } }),
      },
      tabs = { double.tab({ tab_id = "w1:t1", label = "main" }) },
      panes = {
        s.claude_pane("w1:p1", "owner-killed"),
        double.pane({ pane_id = "w1:p2", foreground_process = "cargo" }),
      },
    }, "owner-killed")
    local w = s.wait_node("w1")
    t.eq(w.label, "S1 demo")
    t.eq(w.color, "#336699")
    t.eq(model.get("w1:t1").color, "#336699")
    t.eq(model.get("w1:p1").color, "#336699")
    t.eq(
      model.get("w1:p2").color,
      nil,
      "панель с командой не окрашивается"
    )
    view.open()
    wait_line("w1:p2")
    t.match(line("w1"), "^▾ S1 demo$")
    for _, id in ipairs({ "w1", "w1:t1", "w1:p1" }) do
      local col = #line(id):match("^[%s▾▸]* ")
      local group = hl_at(id, col)
      t.ok(group, "подпись окрашена: " .. id)
      t.eq(hl_fg(group), "#336699")
    end
  end)

  it("символ уже в начале label не повторяется", function()
    s.env({
      workspaces = { ws({ workspace_id = "w1", label = "S1 demo", tokens = { symbol = "S1" } }) },
      tabs = { double.tab({ tab_id = "w1:t1" }) },
      panes = { double.pane({ pane_id = "w1:p1" }) },
    })
    t.eq(s.wait_node("w1").label, "S1 demo")
  end)

  it("цвет #RGB приводится к #RRGGBB", function()
    t.eq(model.color("#ABC"), "#aabbcc")
    t.eq(model.color("#336699"), "#336699")
    t.eq(model.color("#33669"), nil)
    t.eq(model.color(""), nil)
    t.eq(model.color(vim.NIL), nil)
  end)

  it("Токенов нет", function()
    s.env({
      workspaces = { ws({ workspace_id = "w1", label = "demo", tokens = false }) },
      tabs = { double.tab({ tab_id = "w1:t1" }) },
      panes = { s.claude_pane("w1:p1", "owner-killed") },
    }, "owner-killed")
    local w = s.wait_node("w1")
    t.eq(w.label, "demo")
    t.eq(w.color, nil)
    view.open()
    wait_line("w1")
    t.match(line("w1"), "^▾ demo$")
    t.eq(colored("w1"), false, "цвет подписи обычный")
  end)

  it("Не цвет", function()
    s.env({
      workspaces = {
        ws({ workspace_id = "w1", label = "demo", tokens = { symbol = "S1", color = "red" } }),
      },
      tabs = { double.tab({ tab_id = "w1:t1" }) },
      panes = { s.claude_pane("w1:p1", "owner-killed") },
    }, "owner-killed")
    t.eq(s.wait_node("w1").color, nil)
    t.eq(model.get("w1:p1").color, nil)
    view.open()
    wait_line("w1:p1")
    t.eq(colored("w1"), false)
    t.eq(colored("w1:p1"), false)
  end)
end)

describe("Значки состояний", function()
  it("Значки по таблице", function()
    icons.set({
      idle = { frames = { "i" }, period = 400 },
      working = { frames = { "a", "b" }, period = 100 },
      blocked = { frames = { "x" }, period = 400 },
      done = { frames = { "d" }, period = 400 },
      unknown = { frames = { "u" }, period = 400 },
    })
    s.env(s.snapshot({
      double.pane({ pane_id = "w1:p1", agent = "codex", agent_status = "working" }),
      double.pane({ pane_id = "w1:p2", agent = "codex", agent_status = "blocked" }),
    }))
    view.open()
    wait_line("w1:p2")
    local w = view._icon("w1:p1").text
    t.ok(w == "a" or w == "b", "кадр working: " .. w)
    t.eq(view._icon("w1:p1").hl, "DiagnosticInfo")
    t.eq(view._icon("w1:p2").text, "x")
    t.eq(view._icon("w1:p2").hl, "DiagnosticError")
  end)

  it("Состояние done", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    view.open()
    wait_line("w1:p1")
    d:set_agent_status("w1:p1", "done")
    t.wait(function()
      local ic = view._icon("w1:p1")
      return ic and ic.text == "d"
    end, "значок done")
    t.eq(view._icon("w1:p1").hl, "DiagnosticHint")
    t.eq(
      line("w1:p1"):find("[done]", 1, true),
      nil,
      "известное значение не в подписи"
    )
  end)

  it("Состояние субагента", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    view.open()
    s.wait_node("w1:p1/a0000000000000005")
    d:pane_exited("w1:p1")
    s.wait_node("w1:p1/a0000000000000005", function(n)
      return n.state == "orphaned"
    end, "субагент оборван")
    t.wait(function()
      local ic = view._icon("w1:p1/a0000000000000005")
      return ic and ic.text == "u"
    end, "значок unknown")
    t.eq(view._icon("w1:p1/a0000000000000005").hl, "Comment")
  end)

  it("Неизвестное значение", function()
    local d = s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    view.open()
    wait_line("w1:p1")
    d:set_agent_status("w1:p1", "paused")
    wait_line("w1:p1", "paused")
    t.eq(view._icon("w1:p1").text, "u")
    t.match(line("w1:p1"), "opus задача w1:p1 %[paused%]$")
  end)

  it(
    "смена значков в конфигурации herdr перерисовывает дерево",
    function()
      s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
      view.open()
      wait_line("w1:p1")
      t.eq(view._icon("w1:p1").text, "i")
      local new = vim.deepcopy(s.ICONS)
      new.idle.frames = { "I" }
      icons.set(new)
      t.eq(view._icon("w1:p1").text, "I")
    end
  )
end)

describe("Режим без значков", function()
  it("Текстовый режим", function()
    config.setup({ icons = "text" })
    s.env({
      workspaces = {
        ws({ workspace_id = "w1", label = "demo", tokens = { symbol = "S1", color = "#336699" } }),
      },
      tabs = { double.tab({ tab_id = "w1:t1", label = "main" }) },
      panes = { double.pane({ pane_id = "w1:p1", agent = "codex", agent_status = "working" }) },
    })
    view.open()
    wait_line("w1:p1")
    t.eq(line("w1:p1"), "      A haiku [working]")
    t.eq(line("w1"), "▾ W demo")
    t.eq(line("w1:t1"), "  ▾ T main")
    t.eq(view._icon("w1:p1"), nil, "значка нет")
    t.eq(colored("w1"), false, "цвета workspace нет")
    t.eq(colored("w1:p1"), false)
    t.eq(rec.active(), nil, "таймер не заведён")
    t.eq(#rec.timers, 0)
    t.eq(icons.subscribed, 0, "значки herdr не нужны")
  end)

  it("Режим по умолчанию", function()
    t.eq(config.get().icons, "herdr")
    s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), "owner-killed")
    view.open()
    wait_line("w1:p1")
    t.eq(view._icon("w1:p1").text, "i")
    t.eq(icons.subscribed, 1)
  end)
end)
