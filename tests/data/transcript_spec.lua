-- Модуль данных Claude Code: каталог данных, поиск транскрипта, чтение и реплики диалога,
-- перечень сессий проекта (спецификация claude-code-data).
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")

describe("каталог данных", function()
  it("каталог данных — CLAUDE_CONFIG_DIR, без неё — ~/.claude", function()
    local dir = u.fresh()
    t.eq(data.root(), dir)
    vim.uv.os_setenv("CLAUDE_CONFIG_DIR", dir .. "/")
    t.eq(data.root(), dir)
    vim.uv.os_unsetenv("CLAUDE_CONFIG_DIR")
    t.eq(data.root(), vim.uv.os_homedir() .. "/.claude")
    vim.uv.os_setenv("CLAUDE_CONFIG_DIR", dir)
  end)
end)

describe("Поиск транскрипта сессии", function()
  it("Сессия сменила каталог", function()
    local dir = u.fresh({ "session-moved", "history-project" })
    local id = fixtures.session_id("session-moved")
    -- рабочий каталог записей — подкаталог, по имени которого каталога проекта нет
    t.eq(fixtures.records(fixtures.transcript("session-moved"))[4].cwd, "/srv/demo/alpha/subdir")
    t.eq(data.find_transcript(id), fixtures.transcript("session-moved", dir))
    t.eq(
      data.find_transcript(fixtures.history.beta),
      dir .. "/projects/-srv-demo-beta/" .. fixtures.history.beta .. ".jsonl"
    )
    t.eq(data.project_dir(id), dir .. "/projects/" .. fixtures.project)
  end)

  it("Транскрипта нет", function()
    u.fresh("no-transcript")
    t.eq(data.find_transcript(fixtures.missing_session_id), nil)
    t.eq(data.project_dir(fixtures.missing_session_id), nil)
    -- каталога projects/ нет вовсе — тоже не ошибка
    u.fresh()
    t.eq(data.find_transcript(fixtures.missing_session_id), nil)
  end)

  it("недопустимый идентификатор не ищется", function()
    u.fresh("owner-dialogue")
    t.eq(data.find_transcript("../x"), nil)
    t.eq(data.find_transcript(""), nil)
    t.eq(data.find_transcript(nil), nil)
  end)
end)

describe("Чтение транскрипта", function()
  it("Дописывание", function()
    u.fresh("owner-dialogue")
    local id = fixtures.session_id("owner-dialogue")
    local path = fixtures.transcript("owner-dialogue")
    local got = {}
    local h = data.watch_dialogue(id, function(replies)
      vim.list_extend(got, replies)
    end)
    u.wait(function()
      return #got == 14
    end, "уже записанные реплики")
    local before = #got
    fixtures.append(path, {
      fixtures.user_record(id, "first added"),
      fixtures.assistant_record(id, "second added"),
    })
    u.wait(function()
      return #got == before + 2
    end, "две дописанные записи")
    t.eq({ got[#got - 1], got[#got] }, {
      { role = "user", text = "first added" },
      { role = "assistant", text = "second added" },
    })
    u.settle()
    t.eq(
      #got,
      before + 2,
      "прочитанные записи не возвращаются повторно"
    )
    h:close()
  end)

  it("Недописанная строка", function()
    u.fresh("owner-dialogue")
    local id = fixtures.session_id("owner-dialogue")
    local path = fixtures.transcript("owner-dialogue")
    local got = {}
    local h = data.watch_dialogue(path, function(replies)
      vim.list_extend(got, replies)
    end)
    u.wait(function()
      return #got == 14
    end, "уже записанные реплики")
    local line = vim.json.encode(fixtures.user_record(id, "split line"))
    local half = math.floor(#line / 2)
    fixtures.append_partial(path, line:sub(1, half))
    t.eq(
      #data.read_dialogue(path),
      14,
      "незаконченная строка не разбирается"
    )
    u.settle()
    t.eq(
      #got,
      14,
      "незаконченная строка не разбирается при слежении"
    )
    fixtures.append_partial(path, line:sub(half + 1) .. "\n")
    u.wait(function()
      return #got == 15
    end, "дописанная строка")
    t.eq(got[15], { role = "user", text = "split line" })
    h:close()
  end)
end)

describe("Реплики диалога", function()
  it("Диалог сессии", function()
    local dir = u.fresh()
    local id = "00000000-0000-4000-8000-0000000000a1"
    local path = dir .. "/projects/" .. fixtures.project .. "/" .. id .. ".jsonl"
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    fixtures.append(path, {
      fixtures.user_record(id, "question"),
      fixtures.queue_record(id, "dequeue"),
      fixtures.assistant_record(id, "answer"),
    })
    t.eq(data.read_dialogue(path), {
      { role = "user", text = "question" },
      { role = "assistant", text = "answer" },
    })
  end)

  it(
    "реплики транскрипта владельца по порядку записи без служебных записей",
    function()
      u.fresh("owner-dialogue")
      local replies = data.read_dialogue(fixtures.transcript("owner-dialogue"))
      t.eq(#replies, 14)
      t.eq(
        replies[1],
        { role = "user", text = "Remember the code word MANGO. Reply with just: ok" }
      )
      t.eq(replies[2], { role = "assistant", text = "ok" })
      t.eq(replies[4], { role = "assistant", text = "MANGO" })
      -- две параллельные ветви в конце образца: два вопроса подряд, затем два ответа
      t.eq(
        vim.tbl_map(function(r)
          return r.text
        end, vim.list_slice(replies, 11, 14)),
        { "Reply exactly: BETA", "Reply exactly: ALPHA", "ALPHA", "BETA" }
      )
    end
  )

  it(
    "уведомления, вызовы и результаты инструментов не входят в диалог",
    function()
      u.fresh("command-completed")
      local replies = data.read_dialogue(fixtures.transcript("command-completed"))
      t.eq(#replies, 3)
      t.eq(replies[1].role, "user")
      t.match(replies[1].text, "^Using Bash")
      t.eq(replies[2].role, "assistant")
      t.eq(replies[3], { role = "assistant", text = "done" })
    end
  )

  it("файла нет — недоступен", function()
    local dir = u.fresh()
    local replies, err = data.read_dialogue(dir .. "/projects/x/none.jsonl")
    t.eq(replies, nil)
    t.eq(err, "unavailable")
  end)
end)

describe("перечень сессий проекта", function()
  it(
    "сессии каталога проекта с временем и первой репликой, новые первыми",
    function()
      local dir = u.fresh("history-project")
      local project = dir .. "/projects/" .. fixtures.project
      local list = data.list_sessions(project)
      t.eq(#list, 3)
      local ids = vim.tbl_map(function(s)
        return s.id
      end, list)
      t.eq(ids, { fixtures.history.alpha[3], fixtures.history.alpha[2], fixtures.history.alpha[1] })
      t.eq(list[1].first_user_text, "Rename the helper and update callers")
      t.eq(list[3].first_user_text, "How is the retry logic organised?")
      t.eq(list[3].path, project .. "/" .. fixtures.history.alpha[1] .. ".jsonl")
      t.ok(
        list[1].mtime > list[2].mtime and list[2].mtime > list[3].mtime,
        "время последней записи"
      )
      t.eq(data.list_sessions(dir .. "/projects/none"), {})
    end
  )
end)
