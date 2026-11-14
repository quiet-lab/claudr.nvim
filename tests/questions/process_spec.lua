-- Вопросы по коду: отвечающий процесс `claude -p`, поток ответа, ошибки, очередь темы,
-- несколько тем, модель, режимы, источник знаний, ответвление (спецификация code-questions).
local t = require("helpers.t")
local fake = require("helpers.fake_claude")
local env = require("questions.env")
local registry = require("claudr.questions.registry")
local window = require("claudr.questions.window")

local q

before_each(function()
  env.reset()
  q = require("claudr.questions")
end)

local function answer_of(topic, i)
  return topic.entries[i or #topic.entries].answer
end

describe("Тема — отдельная сессия Claude Code", function()
  it(
    "Первый вопрос: процесс claude -p в каталоге проекта, в дереве нового узла нет",
    function()
      local p = env.project()
      -- двойник herdr: тема не должна обращаться к серверу herdr (панель не создаётся)
      local hdir = t.tmpdir() .. "/herdr1"
      vim.fn.mkdir(hdir, "p")
      local double = require("helpers.herdr_double").start({ dir = hdir })
      vim.uv.os_setenv("HERDR_SOCKET_PATH", double.socket_path)
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local starts = p.ctl:starts()
      t.eq(#starts, 1)
      t.eq(starts[1].argv[1], "-p")
      t.eq(starts[1].cwd, p.dir)
      t.eq(#double.requests, 0, "к herdr обращений нет")
      vim.uv.os_unsetenv("HERDR_SOCKET_PATH")
      double:stop()
    end
  )
end)

describe("Каталог проекта", function()
  it(
    "Файл в репозитории: процесс запускается в корне репозитория",
    function()
      local p = env.project()
      local deep = p.dir .. "/lua/sub/deeper"
      vim.fn.mkdir(deep, "p")
      vim.fn.writefile({ "return 1" }, deep .. "/x.lua")
      vim.cmd.cd(vim.fn.fnameescape(deep))
      env.edit(deep .. "/x.lua", 1)
      local topic = env.ask()
      env.wait_idle(topic)
      t.eq(p.ctl:starts()[1].cwd, p.dir)
      t.eq(topic.record.project_dir, p.dir)
      vim.cmd.cd(vim.fn.fnameescape(t.tmpdir()))
    end
  )

  it(
    "без репозитория — текущий рабочий каталог Neovim",
    function()
      local p = env.project()
      local plain = t.tmpdir() .. "/plain"
      vim.fn.mkdir(plain, "p")
      plain = vim.uv.fs_realpath(plain)
      vim.fn.writefile({ "x" }, plain .. "/a.txt")
      vim.cmd.cd(vim.fn.fnameescape(plain))
      env.edit(plain .. "/a.txt", 1)
      local topic = env.ask()
      env.wait_idle(topic)
      t.eq(p.ctl:starts()[1].cwd, plain)
      vim.cmd.cd(vim.fn.fnameescape(t.tmpdir()))
    end
  )
end)

describe("Идентификатор сессии темы", function()
  it(
    "Новая тема: запись реестра до запуска, процесс получает идентификатор, транскрипт по нему",
    function()
      local p = env.project()
      local gate = p.ctl:gate("before")
      p.ctl:script({
        { "wait", gate },
        { "transcript_user" },
        { "init" },
        { "text", { "ответ" } },
        { "transcript_assistant", "ответ" },
        { "result", "ответ" },
      })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local topic = env.ask()
      t.wait(function()
        return #p.ctl:starts() == 1
      end, "процесс запущен")
      -- процесс стоит до первого вывода, запись реестра уже есть
      local rec = registry.get(topic.id)
      t.ok(rec, "запись реестра есть до ответа процесса")
      t.eq(p.ctl:starts()[1].session_id, topic.id)
      t.eq(env.arg(p.ctl:starts()[1].argv, "--session-id"), topic.id)
      gate:release()
      env.wait_idle(topic)
      local mangled = p.dir:gsub("[/%.]", "-")
      local path = ("%s/projects/%s/%s.jsonl"):format(vim.env.CLAUDE_CONFIG_DIR, mangled, topic.id)
      t.ok(
        vim.uv.fs_stat(path),
        "транскрипт назван по идентификатору"
      )
      gate:close()
    end
  )

  it(
    "Процесс не запустился: запись остаётся, повтор с тем же идентификатором",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local saved = vim.env.PATH
      local empty = t.tmpdir() .. "/empty-bin"
      vim.fn.mkdir(empty, "p")
      vim.uv.os_setenv("PATH", empty)
      local topic = env.ask()
      vim.uv.os_setenv("PATH", saved)
      t.eq(topic.entries[1].status, "error")
      t.ok(registry.get(topic.id), "запись реестра осталась")
      t.ok(topic.failed, "вопрос доступен для повтора")
      -- повтор клавишей окна ответа
      vim.api.nvim_set_current_win(vim.fn.bufwinid(topic.buf))
      vim.api.nvim_feedkeys(window.keys.retry, "x", false)
      env.wait_idle(topic)
      local starts = p.ctl:starts()
      t.eq(#starts, 1)
      t.eq(env.arg(starts[1].argv, "--session-id"), topic.id)
      t.eq(starts[1].question:match("^[^\n]*"), "Что делает bar?")
      t.eq(topic.entries[#topic.entries].status, "done")
    end
  )
end)

describe("Новая тема и продолжение темы", function()
  it(
    "Второй вопрос из буфера: новая тема с новой сессией",
    function()
      local p = env.project()
      local buf = env.edit(p.foo, 4)
      local a = env.ask()
      env.wait_idle(a)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      local b = env.ask({ question = "А что возвращает?" })
      env.wait_idle(b)
      t.ok(a.id ~= b.id, "разные сессии")
      local starts = p.ctl:starts()
      t.eq(#starts, 2)
      t.eq(env.arg(starts[2].argv, "--session-id"), b.id)
      t.eq(env.arg(starts[2].argv, "--resume"), nil)
      t.eq(#registry.list(p.dir), 2)
    end
  )

  it(
    "Вопрос из окна ответа: процесс с --resume и идентификатором темы",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(topic.buf))
      local orig = vim.ui.input
      vim.ui.input = function(_, cb)
        cb("Продолжение")
      end
      vim.api.nvim_feedkeys(window.keys.ask, "x", false)
      vim.ui.input = orig
      env.wait_idle(topic)
      local starts = p.ctl:starts()
      t.eq(#starts, 2)
      t.eq(env.arg(starts[2].argv, "--resume"), topic.id)
      t.eq(env.arg(starts[2].argv, "--session-id"), nil)
      t.eq(starts[2].question, "Продолжение")
      t.eq(#registry.list(p.dir), 1, "новой темы нет")
    end
  )

  it(
    "вопрос командой ask из окна ответа тоже продолжает тему",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(topic.buf))
      q.ask({ question = "Ещё" })
      env.wait_idle(topic)
      t.eq(env.arg(p.ctl:starts()[2].argv, "--resume"), topic.id)
    end
  )
end)

describe("Ответ по мере генерации", function()
  it(
    "Длинный ответ: окно дополняется частями до завершения процесса",
    function()
      local p = env.project()
      local gate = p.ctl:gate("mid")
      p.ctl:script({
        { "transcript_user" },
        { "init" },
        { "text", { "Первая ", "часть." } },
        { "wait", gate },
        { "text", { "Вторая часть." } },
        { "result", "…" },
      })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local topic = env.ask()
      t.wait(function()
        return window.text(topic):find("Первая часть.", 1, true) ~= nil
      end, "первая часть в окне")
      t.ok(topic.proc ~= nil, "процесс ещё работает")
      t.ok(not window.text(topic):find("Вторая", 1, true))
      t.eq(vim.bo[topic.buf].modifiable, false, "окно только для чтения")
      gate:release()
      env.wait_idle(topic)
      t.match(window.text(topic), "Первая часть%.\n\nВторая часть%.")
      gate:close()
    end
  )

  it(
    "Вызов инструмента в ответе: окно показывает только накопленный текст",
    function()
      local p = env.project()
      p.ctl:script({
        { "transcript_user" },
        { "init" },
        { "tool", "Read", { file_path = "lua/foo.lua" }, "local SECRET_TOOL_OUTPUT = 1" },
        { "text", { "Итог ", "ответа." } },
        {
          "raw",
          { type = "system", subtype = "status", status = "служебная запись" },
        },
        { "result", "Итог ответа." },
      })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      t.eq(answer_of(topic), "Итог ответа.")
      local text = window.text(topic)
      t.ok(
        not text:find("SECRET_TOOL_OUTPUT", 1, true),
        "результата инструмента нет"
      )
      t.ok(not text:find("file_path", 1, true), "вызова инструмента нет")
      t.ok(not text:find("служебная", 1, true), "служебной записи нет")
    end
  )
end)

describe("Ошибка запуска и обрыв процесса", function()
  it(
    "Процесс оборвался: часть ответа и причина в окне, вопрос можно повторить",
    function()
      local p = env.project()
      p.ctl:script({
        { "transcript_user" },
        { "init" },
        { "text", { "Полученная ", "часть" } },
        { "stderr", "связь оборвана" },
        { "exit", 3 },
      })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local text = window.text(topic)
      t.match(text, "Полученная часть")
      t.match(text, "кодом 3")
      t.match(text, "связь оборвана")
      p.ctl:default_script()
      p.ctl:apply()
      vim.api.nvim_set_current_win(vim.fn.bufwinid(topic.buf))
      vim.api.nvim_feedkeys(window.keys.retry, "x", false)
      env.wait_idle(topic)
      local starts = p.ctl:starts()
      t.eq(#starts, 2)
      t.eq(
        starts[2].question,
        starts[1].question,
        "тот же вопрос без повторного ввода"
      )
      t.eq(env.arg(starts[2].argv, "--resume"), topic.id)
      t.eq(topic.entries[#topic.entries].status, "done")
    end
  )

  it(
    "ответ с ошибкой в записи result — причина в окне",
    function()
      local p = env.project()
      p.ctl:script({
        { "init" },
        { "result_error", "превышен предел" },
        { "exit", 1 },
      })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      t.match(window.text(topic), "превышен предел")
      t.ok(topic.failed)
    end
  )

  it(
    "Claude Code не найден: окно темы показывает ошибку запуска",
    function()
      env.project()
      env.edit(env.project().foo, 4)
      local saved = vim.env.PATH
      local empty = t.tmpdir() .. "/empty-bin2"
      vim.fn.mkdir(empty, "p")
      vim.uv.os_setenv("PATH", empty)
      local topic = env.ask()
      vim.uv.os_setenv("PATH", saved)
      t.match(window.text(topic), "не удалось запустить claude")
      t.ok(vim.fn.bufwinid(topic.buf) ~= -1, "окно темы открыто")
    end
  )
end)

describe("Один отвечающий процесс на тему", function()
  it(
    "Вопрос во время ответа: в очередь темы, затем продолжением той же сессии",
    function()
      local p = env.project()
      local gate = p.ctl:gate("busy")
      p.ctl:script({
        { "transcript_user" },
        { "init" },
        { "wait", gate },
        { "text", { "ответ" } },
        { "transcript_assistant", "ответ" },
        { "result", "ответ" },
      })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local topic = env.ask()
      t.wait(function()
        return #p.ctl:starts() == 1
      end, "первый процесс")
      q.continue(topic.id, { question = "Второй" })
      t.eq(#topic.queue, 1, "вопрос в очереди")
      t.match(window.text(topic), "в очереди")
      t.eq(#p.ctl:starts(), 1, "второй процесс не запущен")
      gate:release() -- первый процесс
      -- второй процесс идёт по тому же сценарию; команда — после его запуска, чтобы первый
      -- процесс не прочитал из канала обе
      t.wait(function()
        return #p.ctl:starts() == 2
      end, "второй процесс")
      gate:release()
      env.wait_idle(topic)
      local starts = p.ctl:starts()
      t.eq(#starts, 2)
      t.eq(starts[2].question, "Второй")
      t.eq(env.arg(starts[2].argv, "--resume"), topic.id)
      -- второй процесс запущен после выхода первого
      local log = p.ctl:log()
      local order = {}
      for _, r in ipairs(log) do
        order[#order + 1] = r.event
      end
      t.eq(order, { "start", "exit", "start", "exit" })
      gate:close()
    end
  )

  it(
    "Два вопроса подряд в одной теме: уходят по одному в порядке постановки",
    function()
      local p = env.project()
      local gate = p.ctl:gate("busy2")
      p.ctl:script({
        { "transcript_user" },
        { "init" },
        { "wait", gate },
        { "text", { "ответ" } },
        { "result", "ответ" },
      })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local topic = env.ask()
      q.continue(topic.id, { question = "Второй" })
      q.continue(topic.id, { question = "Третий" })
      t.eq(#topic.queue, 2)
      for i = 1, 3 do
        t.wait(function()
          return #p.ctl:starts() == i
        end, "процесс " .. i)
        gate:release()
      end
      env.wait_idle(topic)
      local starts = p.ctl:starts()
      t.eq(#starts, 3)
      t.eq(starts[2].question, "Второй")
      t.eq(starts[3].question, "Третий")
      local order = {}
      for _, r in ipairs(p.ctl:log()) do
        order[#order + 1] = r.event
      end
      t.eq(order, { "start", "exit", "start", "exit", "start", "exit" })
      gate:close()
    end
  )
end)

describe("Несколько тем одновременно", function()
  it(
    "Два вопроса подряд: обе темы получают ответы каждая в своём окне",
    function()
      local p = env.project()
      local gate = p.ctl:gate("slow")
      p.ctl:script({
        { "transcript_user" },
        { "init" },
        { "wait", gate },
        { "text", { "ответ А" } },
        { "result", "ответ А" },
      })
      p.ctl:apply()
      local buf = env.edit(p.foo, 4)
      local a = env.ask()
      t.wait(function()
        return #p.ctl:starts() == 1
      end, "тема А запущена")
      -- второй процесс — со своим сценарием
      local ctl_b = fake.setup(t.tmpdir() .. "/ctl-b")
      ctl_b:script({
        { "transcript_user" },
        { "init" },
        { "text", { "ответ Б" } },
        { "result", "ответ Б" },
      })
      ctl_b:apply()
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      local b = env.ask({ question = "Другой вопрос" })
      env.wait_idle(b)
      t.ok(a.proc ~= nil, "тема А ещё отвечает")
      gate:release()
      env.wait_idle(a)
      t.eq(answer_of(a), "ответ А")
      t.eq(answer_of(b), "ответ Б")
      t.ok(not window.text(a):find("ответ Б", 1, true))
      t.ok(not window.text(b):find("ответ А", 1, true))
      local wa, wb = vim.fn.bufwinid(a.buf), vim.fn.bufwinid(b.buf)
      t.ok(wa ~= -1 and wb ~= -1 and wa ~= wb, "у каждой темы своё окно")
      gate:close()
    end
  )
end)

describe("Модель и инструменты", function()
  it(
    "Настройки по умолчанию: модель sonnet и только инструменты чтения",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local argv = p.ctl:starts()[1].argv
      t.eq(env.arg(argv, "--model"), "sonnet")
      t.eq(env.arg(argv, "--tools"), "Read,Grep,Glob")
      t.eq(env.arg(argv, "--allowedTools"), "Read,Grep,Glob")
      t.eq(env.arg(argv, "--output-format"), "stream-json")
      t.ok(env.has(argv, "--verbose") and env.has(argv, "--include-partial-messages"))
    end
  )

  it("модель из настройки model", function()
    env.reset({ code_questions = { model = "haiku" } })
    local p = env.project()
    env.edit(p.foo, 4)
    local topic = env.ask()
    env.wait_idle(topic)
    t.eq(env.arg(p.ctl:starts()[1].argv, "--model"), "haiku")
  end)
end)

describe("Режимы", function()
  it(
    "Свой режим: наставление как дополнение к системному запросу и свой набор инструментов",
    function()
      q.register_mode("review", {
        desc = "разбор",
        prompt = "Отвечай как рецензент.",
        tools = { "Read", "Bash" },
        model = "opus",
      })
      local p = env.project()
      local buf = env.edit(p.foo, 4)
      local topic = env.ask({ mode = "review" })
      env.wait_idle(topic)
      local argv = p.ctl:starts()[1].argv
      t.eq(env.arg(argv, "--append-system-prompt"), "Отвечай как рецензент.")
      t.eq(env.arg(argv, "--tools"), "Read,Bash")
      t.eq(env.arg(argv, "--model"), "opus")
      t.eq(registry.get(topic.id).mode, "review")
      -- наставление неизменно в пределах темы
      vim.api.nvim_set_current_win(vim.fn.bufwinid(topic.buf))
      q.ask({ question = "Ещё" })
      env.wait_idle(topic)
      t.eq(
        env.arg(p.ctl:starts()[2].argv, "--append-system-prompt"),
        "Отвечай как рецензент."
      )
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    end
  )

  it("встроенный режим один — вопрос по коду", function()
    t.eq(require("claudr.questions.modes").get("code").desc, "вопрос по коду")
    local p = env.project()
    env.edit(p.foo, 4)
    local topic = env.ask()
    env.wait_idle(topic)
    t.eq(topic.record.mode, "code")
    t.ok(env.arg(p.ctl:starts()[1].argv, "--append-system-prompt"))
  end)
end)

describe("Источник знаний", function()
  it(
    "Источник задан: процесс получает MCP-сервер проекта",
    function()
      local p = env.project()
      local server = { mcpServers = { docs = { command = "docs-server", args = { "--stdio" } } } }
      env.reset({ code_questions = { mcp = { [p.dir] = server } } })
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local argv = p.ctl:starts()[1].argv
      t.eq(vim.json.decode(env.arg(argv, "--mcp-config")), server)
      t.ok(env.has(argv, "--strict-mcp-config"))
      t.eq(env.arg(argv, "--allowedTools"), "Read,Grep,Glob,mcp__docs")
    end
  )

  it(
    "Источника нет: вопросы по коду работают без него",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local argv = p.ctl:starts()[1].argv
      t.ok(not env.has(argv, "--mcp-config"))
      t.ok(not env.has(argv, "--strict-mcp-config"))
      t.eq(topic.entries[1].status, "done")
    end
  )

  it("источник другого проекта не передаётся", function()
    local p = env.project()
    env.reset({
      code_questions = {
        mcp = function(dir)
          return dir == "/elsewhere" and { mcpServers = { x = {} } } or nil
        end,
      },
    })
    env.edit(p.foo, 4)
    local topic = env.ask()
    env.wait_idle(topic)
    t.ok(not env.has(p.ctl:starts()[1].argv, "--mcp-config"))
  end)
end)

describe("Ответвление от базовой сессии", function()
  it(
    "Настройка по умолчанию: тема — новая сессия, не ответвление",
    function()
      t.eq(require("claudr.config").get().code_questions.fork_from_base, false)
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local argv = p.ctl:starts()[1].argv
      t.ok(not env.has(argv, "--fork-session"))
      t.ok(not env.has(argv, "--resume"))
      t.eq(env.arg(argv, "--session-id"), topic.id)
    end
  )

  it(
    "базовая сессия задана, но настройка выключена — ответвления нет",
    function()
      local p = env.project()
      env.reset({ code_questions = { base_session = "00000000-0000-4000-8000-0000000000b0" } })
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      t.ok(not env.has(p.ctl:starts()[1].argv, "--fork-session"))
    end
  )

  it(
    "включённая настройка с базовой сессией — ответвление с идентификатором темы",
    function()
      local p = env.project()
      local base = "00000000-0000-4000-8000-0000000000b0"
      env.reset({ code_questions = { fork_from_base = true, base_session = base } })
      env.edit(p.foo, 4)
      local topic = env.ask()
      env.wait_idle(topic)
      local argv = p.ctl:starts()[1].argv
      t.eq(env.arg(argv, "--resume"), base)
      t.ok(env.has(argv, "--fork-session"))
      t.eq(env.arg(argv, "--session-id"), topic.id)
    end
  )
end)

describe("Отсутствие таймеров и опроса", function()
  it(
    "Ожидание ответа: плагин не выполняет периодических проверок",
    function()
      local function timers()
        local n = 0
        vim.uv.walk(function(h)
          if h:get_type() == "timer" and h:is_active() then
            n = n + 1
          end
        end)
        return n
      end
      local p = env.project()
      local gate = p.ctl:gate("idle")
      p.ctl:script({ { "transcript_user" }, { "init" }, { "wait", gate }, { "result", "x" } })
      p.ctl:apply()
      env.edit(p.foo, 4)
      local before = timers()
      local topic = env.ask()
      t.wait(function()
        return #p.ctl:starts() == 1
      end, "процесс ждёт")
      t.eq(timers(), before, "активных таймеров не прибавилось")
      gate:release()
      env.wait_idle(topic)
      gate:close()
    end
  )
end)
