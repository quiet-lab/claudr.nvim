-- История сессий (спецификация session-history): перечень сессий проекта панели, исключение
-- тем вопросов по коду, срок хранения транскриптов, просмотр диалога, источник — файлы
-- Claude Code.
local t = require("helpers.t")
local s = require("tree.support")
local u = require("data.util")
local fixtures = require("helpers.fixtures")
local hsupport = require("herdr.support")
local herdr = require("claudr.herdr")
local history = require("claudr.history")
local registry = require("claudr.questions.registry")

local alpha = fixtures.history.alpha
local selects, notes, orig_select, orig_notify

-- Подмена vim.ui.select: запоминает перечень и выбирает `pick(list)` (без выбора — отмена).
local function stub_select(pick)
  vim.ui.select = function(list, opts, cb)
    selects[#selects + 1] =
      { list = list, opts = opts, lines = vim.tbl_map(opts.format_item, list) }
    cb(pick and pick(list) or nil)
  end
end

before_each(function()
  selects, notes = {}, {}
  orig_select, orig_notify = vim.ui.select, vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  vim.cmd("silent! only")
  vim.cmd("enew")
  vim.fn.delete(registry.path())
  require("claudr").setup()
end)

after_each(function()
  vim.ui.select, vim.notify = orig_select, orig_notify
  require("claudr.tree.view").close()
  s.reset()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("^claudr://history/") then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end)

local function note_text()
  return table.concat(
    vim.tbl_map(function(n)
      return n.msg
    end, notes),
    "\n"
  )
end

describe("Перечень сессий проекта инстанса", function()
  it("Проект с несколькими сессиями", function()
    u.fresh("history-project")
    stub_select()
    history.show_for_session(alpha[1])
    t.eq(#selects, 1)
    local lines = selects[1].lines
    t.eq(
      #lines,
      3,
      "три сессии проекта, сессия другого проекта не входит"
    )
    local joined = table.concat(lines, "\n")
    for _, id in ipairs(alpha) do
      t.ok(joined:find(id, 1, true), "в перечне " .. id)
    end
    -- у каждой строки: идентификатор, время последней записи, начало первой реплики
    for _, e in ipairs(selects[1].list) do
      local line = history.format_entry(e)
      t.ok(line:find(e.id, 1, true), "идентификатор в строке")
      t.ok(line:find(os.date("%Y-%m-%d %H:%M", e.mtime), 1, true), "время в строке")
    end
    t.match(joined, "How is the retry logic organised%?")
    t.match(joined, "Rename the helper and update callers")
    -- длинная первая реплика обрезается
    t.match(joined, "Explain the plan for migrating the settings.*…")
    t.ok(not joined:find("What does the parser return", 1, true), "беты нет")
  end)

  it("Сессия с живой панелью", function()
    u.fresh("history-project")
    local d = s.env(
      s.snapshot({
        s.claude_pane("w1:p1", "history-project", { session = alpha[1] }),
        s.claude_pane("w1:p2", "history-project", { session = alpha[3] }),
      }),
      "history-project"
    )
    t.ok(d, "двойник запущен")
    local entries = history.entries(require("claudr.data").project_dir(alpha[1]))
    local running = {}
    for _, e in ipairs(entries) do
      running[e.id] = e.running
    end
    t.eq(running[alpha[1]], true)
    t.eq(running[alpha[2]], false)
    t.eq(running[alpha[3]], true)
    for _, e in ipairs(entries) do
      t.eq(
        history.format_entry(e):sub(1, 3) == "●",
        e.running,
        "отметка в строке " .. e.id
      )
    end
  end)
end)

describe(
  "Темы вопросов по коду — отдельный перечень",
  function()
    it("Проект с темой", function()
      u.fresh("history-project")
      local dir = require("claudr.data").project_dir(alpha[1])
      registry.create({
        session_id = alpha[2],
        project_dir = dir,
        title = "Вопрос",
        mode = "ask",
      })
      local ids = {}
      for _, e in ipairs(history.entries(dir)) do
        ids[e.id] = true
      end
      t.ok(
        not ids[alpha[2]],
        "тема не входит в перечень сессий инстанса"
      )
      t.ok(ids[alpha[1]] and ids[alpha[3]], "остальные сессии на месте")
      local topics = {}
      for _, r in ipairs(registry.list(dir)) do
        topics[r.session_id] = true
      end
      t.ok(topics[alpha[2]], "перечень тем содержит сессию")
    end)
  end
)

describe("Срок хранения транскриптов", function()
  it("Старый транскрипт удалён Claude Code", function()
    u.fresh("history-project")
    local dir = require("claudr.data").project_dir(alpha[1])
    t.eq(#history.entries(dir), 3)
    t.eq(vim.fn.delete(dir .. "/" .. alpha[2] .. ".jsonl"), 0)
    local entries = history.entries(dir)
    t.eq(#entries, 2)
    for _, e in ipairs(entries) do
      t.ok(e.id ~= alpha[2], "удалённая сессия не показана")
    end
  end)
end)

describe("Просмотр диалога", function()
  it("Просмотр завершённой сессии", function()
    u.fresh("history-project")
    stub_select(function(list)
      for _, e in ipairs(list) do
        if e.id == alpha[1] then
          return e
        end
      end
    end)
    history.show_for_session(alpha[3])
    local buf = vim.api.nvim_get_current_buf()
    t.eq(vim.api.nvim_buf_get_name(buf), history.BUF_PREFIX .. alpha[1])
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local order = {
      "Пользователь:",
      "How is the retry logic organised?",
      "Агент:",
      "Retries live in the client module.",
      "And the backoff?",
      "Exponential, capped at 30 seconds.",
    }
    local pos = 1
    for _, piece in ipairs(order) do
      local a, b = text:find(piece, pos, true)
      t.ok(a, "реплика по порядку записи: " .. piece)
      pos = b + 1
    end
    t.eq(vim.bo[buf].modifiable, false)
    t.eq(vim.bo[buf].readonly, true)
    t.ok(
      not pcall(vim.api.nvim_buf_set_lines, buf, 0, 1, false, { "правка" }),
      "правка запрещена"
    )
    t.ok(not pcall(vim.cmd, "normal! ix"), "ввод текста невозможен")
  end)

  it("Транскрипт удалён", function()
    u.fresh("history-project")
    local dir = require("claudr.data").project_dir(alpha[1])
    stub_select(function(list)
      -- файл исчезает после построения перечня, до выбора
      for _, e in ipairs(list) do
        vim.fn.delete(e.path)
      end
      return list[1]
    end)
    local before = vim.api.nvim_get_current_buf()
    history.show_project(dir)
    t.match(note_text(), "недоступен")
    t.eq(vim.api.nvim_get_current_buf(), before, "диалог не открыт")
  end)
end)

describe("Источник — файлы Claude Code", function()
  it("Сервера нет", function()
    u.fresh("history-project")
    herdr.start()
    hsupport.wait_status(herdr, "no_server")
    stub_select()
    history.show_for_session(alpha[1])
    t.eq(#selects, 1, "перечень доступен")
    t.eq(#selects[1].list, 3)
    for _, line in ipairs(selects[1].lines) do
      t.ok(not line:find("●", 1, true), "отметок работающих сессий нет")
    end
    for _, e in ipairs(selects[1].list) do
      t.eq(e.running, false)
    end
  end)
end)

describe("Вызов: действие дерева и подкоманда", function()
  it(
    "действие дерева на узле панели открывает перечень её проекта",
    function()
      u.fresh("history-project")
      s.env(
        s.snapshot({ s.claude_pane("w1:p1", "history-project", { session = alpha[1] }) }),
        "history-project"
      )
      local view = require("claudr.tree.view")
      stub_select()
      view.open()
      s.wait_node("w1:p1")
      t.wait(function()
        return view.line_of("w1:p1") ~= nil
      end, "строка панели")
      view.focus("w1:p1")
      t.ok(view.action("history"), "действие зарегистрировано")
      t.eq(view.action("history").key, history.KEY)
      vim.api.nvim_feedkeys(history.KEY, "x", false)
      t.eq(#selects, 1)
      t.eq(#selects[1].list, 3)
      t.match(table.concat(selects[1].lines, "\n"), "●")
    end
  )

  it(
    "действие на узле без агента Claude Code сообщает об этом",
    function()
      u.fresh("history-project")
      local snap =
        s.snapshot({ s.double.pane({ pane_id = "w1:p1", foreground_process = "cargo" }) })
      s.env(snap, "history-project")
      local view = require("claudr.tree.view")
      stub_select()
      view.open()
      t.wait(function()
        return view.line_of("w1:p1") ~= nil
      end, "строка панели")
      view.focus("w1:p1")
      vim.api.nvim_feedkeys(history.KEY, "x", false)
      t.eq(#selects, 0)
      t.match(note_text(), "панель с агентом")
    end
  )

  it(
    "подкоманда с идентификатором панели и сессии; без транскрипта — сообщение",
    function()
      u.fresh("history-project")
      s.env(
        s.snapshot({ s.claude_pane("w1:p1", "history-project", { session = alpha[2] }) }),
        "history-project"
      )
      stub_select()
      vim.cmd("Claudr history w1:p1")
      t.eq(#selects, 1)
      vim.cmd("Claudr history " .. alpha[3])
      t.eq(#selects, 2)
      vim.cmd("Claudr history " .. fixtures.missing_session_id)
      t.eq(#selects, 2)
      t.match(note_text(), "каталог проекта неизвестен")
    end
  )

  it(
    "подкоманда без аргумента выбирает панель из снимка",
    function()
      u.fresh("history-project")
      s.env(
        s.snapshot({ s.claude_pane("w1:p1", "history-project", { session = alpha[1] }) }),
        "history-project"
      )
      t.wait(function()
        return herdr.state().status == "connected" and #herdr.state().snapshot.panes == 1
      end, "снимок")
      stub_select(function(list)
        return list[1]
      end)
      vim.cmd("Claudr history")
      t.eq(
        #selects,
        2,
        "сначала выбор панели, затем перечень сессий"
      )
      t.eq(#selects[2].list, 3)
    end
  )
end)
