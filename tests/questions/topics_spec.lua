-- Вопросы по коду: реестр тем, восстановление окна темы, возврат к теме, переход по ссылкам
-- (спецификация code-questions).
local t = require("helpers.t")
local env = require("questions.env")
local registry = require("claudr.questions.registry")
local window = require("claudr.questions.window")
local topic_mod = require("claudr.questions.topic")

local q

before_each(function()
  env.reset()
  q = require("claudr.questions")
end)

--- «Перезапуск Neovim»: темы в памяти и их буферы забываются, реестр и транскрипты остаются.
local function restart()
  env.reset(nil, true)
end

describe("Реестр тем", function()
  it(
    "Новая тема: запись с сессией, проектом, заголовком, режимом, файлом, символом bar",
    function()
      local p = env.project()
      env.edit(p.foo, 4, 4)
      local topic = env.ask({
        question = "Что делает bar и зачем он нужен?\nвторая строка",
      })
      env.wait_idle(topic)
      local rec = registry.get(topic.id)
      t.eq(rec.session_id, topic.id)
      t.eq(rec.project_dir, p.dir)
      t.eq(rec.title, "Что делает bar и зачем он нужен?")
      t.eq(rec.mode, "code")
      t.eq(rec.file, "lua/foo.lua")
      t.eq(rec.symbol, "bar")
      t.ok(type(rec.created_at) == "number" and rec.created_at > 0, "время создания")
      t.ok(registry.is_topic(topic.id))
      t.ok(not registry.is_topic("00000000-0000-4000-8000-0000000000ee"))
    end
  )

  it(
    "Новое обращение: время последнего обращения обновляется",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local before = registry.get(topic.id)
      q.continue(topic.id, { question = "Ещё вопрос" })
      env.wait_idle(topic)
      local after = registry.get(topic.id)
      t.ok(after.last_used_at > before.last_used_at, "время обращения выросло")
      t.eq(after.created_at, before.created_at, "время создания прежнее")
    end
  )

  it(
    "реестр переживает перезапуск Neovim: другой процесс видит запись",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local script = t.tmpdir() .. "/read_registry.lua"
      vim.fn.writefile({
        ("vim.opt.rtp:prepend(%q)"):format(t.root),
        ("package.path = %q .. '/lua/?.lua;' .. %q .. '/lua/?/init.lua;' .. package.path"):format(
          t.root,
          t.root
        ),
        "local list = require('claudr.questions.registry').list(arg[1])",
        "io.stdout:write(vim.json.encode(list))",
      }, script)
      local res = vim
        .system({ "nvim", "--headless", "--clean", "-u", "NONE", "-l", script, p.dir }, { text = true })
        :wait()
      t.eq(res.code, 0, res.stderr)
      local list = vim.json.decode(res.stdout)
      t.eq(#list, 1)
      t.eq(list[1].session_id, topic.id)
    end
  )
end)

describe("Восстановление окна темы", function()
  it(
    "Открытие закрытой темы: вопросы и ответы из транскрипта без запуска процесса",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask({ question = "Первый вопрос" })
      env.wait_idle(topic)
      q.continue(topic.id, { question = "Второй вопрос" })
      env.wait_idle(topic)
      local id = topic.id
      restart()
      local starts = #p.ctl:starts()
      local restored = q.open_topic(id)
      t.wait(function()
        return restored.restoring == nil
      end, "конец чтения транскрипта темы")
      local text = window.text(restored)
      t.ok(text:find("Первый вопрос", 1, true), text)
      t.ok(text:find("Второй вопрос", 1, true))
      t.ok(text:find("`lua/foo.lua:42`", 1, true), "ответ из транскрипта")
      t.ok(
        not text:find("Enclosing", 1, true),
        "пакет контекста не показывается"
      )
      t.eq(#restored.entries, 2)
      t.eq(#p.ctl:starts(), starts, "процесс не запускался")
      t.eq(vim.api.nvim_get_current_buf(), restored.buf, "окно темы открыто")
      -- продолжение восстановленной темы — через --resume
      q.continue(id, { question = "Третий" })
      env.wait_idle(restored)
      t.eq(env.arg(p.ctl:starts()[starts + 1].argv, "--resume"), id)
    end
  )

  it(
    "Транскрипт читается асинхронно: окно открывается до чтения, повторное восстановление ждёт конца",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask({ question = "Первый вопрос" })
      env.wait_idle(topic)
      local id = topic.id
      restart()
      local restored = q.open_topic(id)
      t.ok(
        restored.restoring ~= nil,
        "чтение не закончено при возврате"
      )
      t.eq(#restored.entries, 0, "записей ещё нет")
      t.eq(restored.unavailable, false)
      local second = false
      topic_mod.restore(restored, function()
        second = true
      end)
      t.ok(
        not second,
        "повторное восстановление ждёт конца чтения"
      )
      t.wait(function()
        return second
      end, "конец чтения транскрипта темы")
      t.eq(restored.restoring, nil)
      t.eq(#restored.entries, 1)
      t.match(window.text(restored), "Первый вопрос")
      -- продолжение до конца чтения ждёт его: новый вопрос встаёт после прежних
      restart()
      local again = q.continue(id, { question = "Второй вопрос" })
      t.eq(#again.entries, 0, "вопрос ещё не отправлен")
      t.wait(function()
        return #again.entries == 2
      end, "вопрос отправлен после чтения")
      env.wait_idle(again)
      t.eq(#again.entries, 2)
      t.match(again.entries[1].question, "Первый вопрос")
      t.match(again.entries[2].question, "Второй вопрос")
    end
  )

  it(
    "Транскрипт удалён: тема в перечне с пометкой «содержимое недоступно»",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask({ question = "Вопрос о старом" })
      env.wait_idle(topic)
      local id = topic.id
      local path = assert(topic_mod.transcript(id))
      vim.fn.delete(path)
      restart()
      env.edit(p.foo, 4)
      local items = q.topic_items(p.dir)
      t.eq(#items, 1)
      t.eq(items[1].record.session_id, id)
      t.eq(items[1].unavailable, true)
      t.match(q.format_item(items[1]), "содержимое недоступно")
      local shown
      local orig = vim.ui.select
      vim.ui.select = function(list, opts, cb)
        shown = vim.tbl_map(opts.format_item, list)
        cb(list[1])
      end
      q.topics()
      vim.ui.select = orig
      t.match(shown[1], "Вопрос о старом.*содержимое недоступно")
      local opened = topic_mod.get(id)
      t.match(window.text(opened), "Содержимое недоступно")
    end
  )
end)

describe("Возврат к теме", function()
  it(
    "Последняя тема: открывается тема с самым поздним временем обращения",
    function()
      local p = env.project()
      local buf = env.edit(p.foo, 4)
      local a = env.ask({ question = "Тема А" })
      env.wait_idle(a)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      local b = env.ask({ question = "Тема Б" })
      env.wait_idle(b)
      -- к теме А обратились позже
      q.continue(a.id, { question = "Снова А" })
      env.wait_idle(a)
      local a_id = a.id
      restart()
      env.edit(p.foo, 4)
      local opened = q.last_topic()
      t.eq(opened.id, a_id)
      t.eq(vim.api.nvim_get_current_buf(), opened.buf)
      t.wait(function()
        return opened.restoring == nil
      end, "конец чтения транскрипта темы")
      t.match(window.text(opened), "Снова А")
    end
  )

  it(
    "перечень тем проекта через vim.ui.select, без тем других проектов",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local a = env.ask({ question = "Тема проекта" })
      env.wait_idle(a)
      registry.create({
        session_id = "00000000-0000-4000-8000-0000000000c1",
        project_dir = "/elsewhere",
        title = "Чужая тема",
        mode = "code",
      })
      env.edit(p.foo, 4)
      local seen
      local orig = vim.ui.select
      vim.ui.select = function(list, opts, cb)
        seen = { n = #list, first = opts.format_item(list[1]), kind = opts.kind }
        cb(nil)
      end
      q.topics()
      vim.ui.select = orig
      t.eq(seen.n, 1)
      t.match(seen.first, "Тема проекта")
      t.eq(seen.kind, "claudr.topic")
    end
  )

  it("подкоманды тем зарегистрированы", function()
    local names = require("claudr.commands").names()
    for _, n in ipairs({ "ask", "ask-selection", "ask-file", "topics", "topic-last" }) do
      t.ok(vim.tbl_contains(names, n), n)
    end
  end)
end)

describe("Ссылки на код в ответе", function()
  it(
    "Переход по ссылке: lua/foo.lua:42 открывается в окне редактирования на строке 42",
    function()
      local p = env.project()
      local other = p.dir .. "/README"
      vim.fn.writefile({ "readme" }, other)
      local code_win_buf = env.edit(other, 1)
      local topic = env.ask()
      env.wait_idle(topic)
      local win = vim.fn.bufwinid(topic.buf)
      vim.api.nvim_set_current_win(win)
      local lines = vim.api.nvim_buf_get_lines(topic.buf, 0, -1, false)
      local row
      for i, l in ipairs(lines) do
        if l:find("lua/foo.lua:42", 1, true) then
          row = i
        end
      end
      t.ok(row, "ссылка в ответе")
      local col = lines[row]:find("foo.lua", 1, true)
      vim.api.nvim_win_set_cursor(win, { row, col })
      -- переход по ссылке — клавиша открытия `gd` из claudr.refs
      vim.api.nvim_feedkeys("gd", "mx", false)
      t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), p.foo)
      t.eq(vim.api.nvim_win_get_cursor(0)[1], 42)
      t.eq(vim.api.nvim_get_current_win(), win, "переход в том же окне")
      t.ok(vim.api.nvim_buf_is_valid(topic.buf), "буфер темы жив")
      t.ok(code_win_buf)
    end
  )

  it(
    "ссылка под курсором выбирается среди нескольких в строке",
    function()
      local refs = require("claudr.refs")
      local line = "см. a/b.lua:3 и lua/foo.lua:42, версия 1:2"
      t.eq(refs.parse(line, line:find("foo", 1, true))[1], { path = "lua/foo.lua", line = 42 })
      t.eq(refs.parse(line, line:find("a/b", 1, true))[1], { path = "a/b.lua", line = 3 })
    end
  )
end)
