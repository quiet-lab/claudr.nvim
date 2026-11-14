-- Собственные тесты поддельного `claude` (tests/helpers/fake_bin/claude). Не зависят от кода плагина.
local t = require("helpers.t")
local fake = require("helpers.fake_claude")
local fixtures = require("helpers.fixtures")

local STREAM = {
  "-p",
  "--output-format",
  "stream-json",
  "--verbose",
  "--include-partial-messages",
}

local function setup()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, "p")
  local work = base .. "/work.dir/sub"
  vim.fn.mkdir(work, "p")
  local config = base .. "/config"
  vim.fn.mkdir(config, "p")
  local ctl = fake.setup(base .. "/ctl")
  return {
    ctl = ctl,
    work = assert(vim.uv.fs_realpath(work)),
    config = config,
  }
end

local function args(list, extra)
  local out = vim.list_extend({ "claude" }, list)
  return vim.list_extend(out, extra or {})
end

--- Запуск до конца; возвращает результат и разобранные кадры stdout.
local function run(env, argv, opts)
  local e = env.ctl:env()
  e.CLAUDE_CONFIG_DIR = env.config
  local res = vim
    .system(argv, vim.tbl_extend("force", { text = true, cwd = env.work, env = e }, opts or {}))
    :wait()
  local frames = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    frames[#frames + 1] = vim.json.decode(line)
  end
  return res, frames
end

local function mangled(cwd)
  return (cwd:gsub("[/%.]", "-"))
end

local function transcript_path(env, session)
  return string.format("%s/projects/%s/%s.jsonl", env.config, mangled(env.work), session)
end

local function kind(f)
  if f.type == "stream_event" then
    return "stream_event/" .. f.event.type
  end
  return f.type .. (f.subtype and ("/" .. f.subtype) or "")
end

local SID = "00000000-0000-4000-8000-0000000000a1"

describe("поддельный claude: журнал и ключи", function()
  it("пишет в журнал argv, cwd и вопрос из аргумента", function()
    local env = setup()
    local res = run(
      env,
      args(STREAM, { "--session-id", SID, "--model", "sonnet", "Как это работает?" })
    )
    t.eq(res.code, 0, res.stderr)
    local starts = env.ctl:starts()
    t.eq(#starts, 1)
    t.eq(starts[1].cwd, env.work)
    t.eq(starts[1].question, "Как это работает?")
    t.eq(starts[1].stdin, vim.NIL)
    t.eq(starts[1].argv[1], "-p")
    t.eq(starts[1].argv[#starts[1].argv], "Как это работает?")
    t.eq(starts[1].session_id, SID)
    t.eq(starts[1].model, "sonnet")
    local last = env.ctl:log()
    t.eq(last[#last].event, "exit")
    t.eq(last[#last].code, 0)
  end)

  it("вопрос из stdin", function()
    local env = setup()
    local res = run(
      env,
      args(STREAM, { "--session-id", SID }),
      { stdin = "Вопрос из канала\nвторая строка" }
    )
    t.eq(res.code, 0, res.stderr)
    local s = env.ctl:starts()[1]
    t.eq(s.stdin, "Вопрос из канала\nвторая строка")
    t.eq(s.question, "Вопрос из канала\nвторая строка")
  end)

  it("понимает все ключи плагина без ошибок", function()
    local env = setup()
    local res = run(
      env,
      args(STREAM, {
        "--resume",
        SID,
        "--model",
        "haiku",
        "--append-system-prompt",
        "Наставление",
        "--allowedTools",
        "Read,Grep",
        "--tools",
        "Read",
        "--mcp-config",
        '{"mcpServers":{}}',
        "--strict-mcp-config",
        "Вопрос",
      })
    )
    t.eq(res.code, 0, res.stderr)
    local s = env.ctl:starts()[1]
    t.eq(s.resume, SID)
    t.eq(s.question, "Вопрос")
  end)

  it("модель, session_id и каталог попадают в system/init", function()
    local env = setup()
    local _, frames = run(
      env,
      args(STREAM, { "--session-id", SID, "--model", "sonnet", "--mcp-config", "{}", "Q" })
    )
    local init = frames[1]
    t.eq(kind(init), "system/init")
    t.eq(init.session_id, SID)
    t.eq(init.cwd, env.work)
    t.eq(init.model, "claude-sonnet-5-5")
    t.eq(init.mcp_servers[1].status, "connected")
  end)
end)

describe("поддельный claude: поток", function()
  it(
    "выдаёт правдоподобный поток: init, части текста, вызов инструмента и результат между ними",
    function()
      local env = setup()
      local res, frames = run(env, args(STREAM, { "--session-id", SID, "Q" }))
      t.eq(res.code, 0, res.stderr)
      t.eq(kind(frames[1]), "system/init")
      local deltas, tool_use, tool_result, assistant_text = {}, nil, nil, nil
      local first_delta, tool_index, result
      for i, f in ipairs(frames) do
        if
          f.type == "stream_event"
          and f.event.type == "content_block_delta"
          and f.event.delta.type == "text_delta"
        then
          deltas[#deltas + 1] = f.event.delta.text
          first_delta = first_delta or i
        end
        if f.type == "assistant" and f.message.content[1].type == "tool_use" then
          tool_use = f
          tool_index = i
        end
        if f.type == "user" and f.message.content[1].type == "tool_result" then
          tool_result = f
        end
        if f.type == "assistant" and f.message.content[1].type == "text" then
          assistant_text = f
        end
        if f.type == "result" then
          result = f
        end
      end
      t.ok(#deltas >= 3, "несколько приращений text_delta")
      t.ok(tool_use and tool_result and assistant_text and result)
      t.ok(
        tool_index < first_delta,
        "вызов инструмента идёт до текста ответа"
      )
      t.eq(tool_result.message.content[1].tool_use_id, tool_use.message.content[1].id)
      t.eq(table.concat(deltas), assistant_text.message.content[1].text)
      t.eq(result.result, table.concat(deltas))
      t.eq(result.subtype, "success")
      t.eq(result.is_error, false)
      t.eq(result.session_id, SID)
      t.eq(kind(frames[#frames]), "result/success")
    end
  )

  it(
    "кадры stream_event несут идентификаторы и форму наблюдавшихся записей",
    function()
      local env = setup()
      local _, frames = run(env, args(STREAM, { "--session-id", SID, "Q" }))
      local kinds = {}
      for _, f in ipairs(frames) do
        kinds[kind(f)] = true
        if f.type == "stream_event" then
          t.eq(f.session_id, SID)
          t.eq(f.parent_tool_use_id, vim.NIL)
          t.ok(f.uuid and f.api_message_id)
        end
      end
      for _, k in ipairs({
        "system/init",
        "system/status",
        "stream_event/message_start",
        "stream_event/content_block_start",
        "stream_event/content_block_delta",
        "stream_event/content_block_stop",
        "stream_event/message_delta",
        "stream_event/message_stop",
        "assistant",
        "user",
        "rate_limit_event",
        "result/success",
      }) do
        t.ok(kinds[k], "нет кадра " .. k)
      end
    end
  )

  it("без stream-json выдаёт только текст ответа", function()
    local env = setup()
    local res = vim
      .system({ "claude", "-p", "--session-id", SID, "Q" }, {
        text = true,
        cwd = env.work,
        env = vim.tbl_extend("force", env.ctl:env(), { CLAUDE_CONFIG_DIR = env.config }),
      })
      :wait()
    t.eq(res.code, 0)
    t.eq(res.stdout, table.concat(fake.default_parts) .. "\n")
  end)

  it("сценарий из файла: свои части текста", function()
    local env = setup()
    env.ctl:script({
      { "transcript_user" },
      { "init" },
      { "text", { "раз", "два" } },
      { "transcript_assistant", "раздва" },
      { "result", "раздва" },
    })
    local _, frames = run(env, args(STREAM, { "--session-id", SID, "Q" }))
    local deltas = {}
    for _, f in ipairs(frames) do
      if f.type == "stream_event" and f.event.type == "content_block_delta" then
        deltas[#deltas + 1] = f.event.delta.text
      end
    end
    t.eq(deltas, { "раз", "два" })
  end)

  it("неизвестная директива сценария — код 2", function()
    local env = setup()
    env.ctl:script({ { "raw", "{}" } })
    local f = assert(io.open(env.ctl.script_path, "a"))
    f:write("no-such-directive\n")
    f:close()
    local res = run(env, args(STREAM, { "Q" }))
    t.eq(res.code, 2)
    t.match(res.stderr, "неизвестная директива")
  end)
end)

describe("поддельный claude: транскрипт", function()
  it(
    "дописывает транскрипт по каталогу проекта: путь с заменой / и . на -",
    function()
      local env = setup()
      run(env, args(STREAM, { "--session-id", SID, "Вопрос про код" }))
      local path = transcript_path(env, SID)
      t.ok(vim.uv.fs_stat(path), path)
      t.ok(
        env.work:find(".", 1, true),
        "в пути рабочего каталога есть точка"
      )
      local recs = fixtures.records(path)
      local user, assistant
      for _, r in ipairs(recs) do
        user = user or (r.type == "user" and r)
        assistant = assistant or (r.type == "assistant" and r)
      end
      t.eq(user.message.content, "Вопрос про код")
      t.eq(user.sessionId, SID)
      t.eq(user.cwd, env.work)
      t.eq(assistant.message.content[1].text, table.concat(fake.default_parts))
      t.eq(assistant.parentUuid, user.uuid)
      t.eq(recs[1].type, "queue-operation")
    end
  )

  it(
    "с --resume дописывает в тот же файл и продолжает цепочку parentUuid",
    function()
      local env = setup()
      run(env, args(STREAM, { "--session-id", SID, "Первый" }))
      run(env, args(STREAM, { "--resume", SID, "Второй" }))
      local recs = fixtures.records(transcript_path(env, SID))
      local users, assistants = {}, {}
      for _, r in ipairs(recs) do
        if r.type == "user" then
          users[#users + 1] = r
        elseif r.type == "assistant" then
          assistants[#assistants + 1] = r
        end
      end
      t.eq(#users, 2)
      t.eq(#assistants, 2)
      t.eq(users[1].message.content, "Первый")
      t.eq(users[2].message.content, "Второй")
      t.eq(users[2].parentUuid, assistants[1].uuid)
      t.eq(#vim.fn.glob(env.config .. "/projects/*/*.jsonl", false, true), 1)
    end
  )
end)

describe("поддельный claude: точки остановки и обрыв", function()
  it(
    "останавливается в точке до команды теста и продолжает после неё",
    function()
      local env = setup()
      local gate = env.ctl:gate("point1")
      env.ctl:script({
        { "transcript_user" },
        { "init" },
        { "wait", gate },
        { "text", { "после ", "точки" } },
        { "result", "после точки" },
      })
      local e = env.ctl:env()
      e.CLAUDE_CONFIG_DIR = env.config
      local out, exited, code = {}, false, nil
      local proc = vim.system(args(STREAM, { "--session-id", SID, "Q" }), {
        cwd = env.work,
        env = e,
        text = true,
        stdout = function(_, data)
          if data then
            out[#out + 1] = data
          end
        end,
      }, function(res)
        exited, code = true, res.code
      end)
      t.wait(function()
        return table.concat(out):find('"subtype":"init"', 1, true) ~= nil
      end, "кадр init до точки")
      t.ok(not table.concat(out):find("text_delta", 1, true), "текста до точки нет")
      t.ok(not exited, "процесс стоит в точке")
      gate:release()
      t.wait(function()
        return exited
      end, "процесс завершился после команды")
      t.eq(code, 0)
      t.match(table.concat(out), "text_delta")
      t.match(table.concat(out), '"type":"result"')
      proc:wait()
      gate:close()
    end
  )

  it(
    "команда теста, поданная до прихода процесса в точку, не теряется",
    function()
      local env = setup()
      local gate = env.ctl:gate("early")
      gate:release()
      env.ctl:script({ { "init" }, { "wait", gate }, { "result", "готово" } })
      local res = run(env, args(STREAM, { "Q" }))
      t.eq(res.code, 0, res.stderr)
      gate:close()
    end
  )

  it(
    "обрыв с ненулевым кодом: часть потока, stderr, без result и без ответа в транскрипте",
    function()
      local env = setup()
      env.ctl:script({
        { "transcript_user" },
        { "init" },
        { "raw", { type = "stream_event", event = { type = "message_start" }, session_id = SID } },
        { "stderr", "связь оборвана" },
        { "exit", 3 },
        { "result", "не должно быть выдано" },
      })
      local res, frames = run(env, args(STREAM, { "--session-id", SID, "Q" }))
      t.eq(res.code, 3)
      t.match(res.stderr, "связь оборвана")
      t.eq(#frames, 2)
      t.ok(not res.stdout:find('"type":"result"', 1, true))
      local recs = fixtures.records(transcript_path(env, SID))
      for _, r in ipairs(recs) do
        t.ok(r.type ~= "assistant", "ответа в транскрипте нет")
      end
      local log = env.ctl:log()
      t.eq(log[#log].event, "exit")
      t.eq(log[#log].code, 3)
    end
  )

  it(
    "ошибка до вывода: пустой stdout, код 1, транскрипта нет",
    function()
      local env = setup()
      env.ctl:script({ { "stderr", "No conversation found with session ID" }, { "exit", 1 } })
      local res = run(env, args(STREAM, { "--resume", SID, "Q" }))
      t.eq(res.code, 1)
      t.eq(res.stdout, "")
      t.match(res.stderr, "No conversation found")
      t.ok(not vim.uv.fs_stat(transcript_path(env, SID)))
    end
  )

  it(
    "отсутствие журнала в окружении не мешает работе",
    function()
      local env = setup()
      local e = { CLAUDE_CONFIG_DIR = env.config }
      local res = vim.system(args(STREAM, { "Q" }), { text = true, cwd = env.work, env = e }):wait()
      t.eq(res.code, 0, res.stderr)
    end
  )
end)
