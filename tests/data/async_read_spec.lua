-- Асинхронное чтение порциями диалога, перечня сессий, рабочего каталога сессии и файла
-- вывода (спецификации claude-code-data, session-history, node-view). Исход не зависит от
-- скорости узла: проверяются порядок событий и счётчики; порция чтения уменьшена, чтобы
-- файл в сотни килобайт читался десятками порций.
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")
local fs = require("claudr.data.fs")

local CHUNK = fs.CHUNK
local COUNT, SIZE = 120, 4 * 1024
local SID = "00000000-0000-4000-8000-0000000000b1"

local reads, fds

before_each(function()
  fs.CHUNK = 8 * 1024
  fds = u.count_fds()
end)

after_each(function()
  fs.CHUNK = CHUNK
  if reads then
    reads.restore()
    reads = nil
  end
  fds.restore()
end)

-- Собственное наблюдение теста за отдельным каталогом: `fired` истинно после события;
-- `chunks` — число порций, прочитанных к этому моменту (через `count()`).
local function own_event(count)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local handle = vim.uv.new_fs_event()
  local state = { fired = false }
  handle:start(dir, {}, function()
    vim.schedule(function()
      if not state.fired then
        state.fired = true
        state.chunks = count()
      end
    end)
  end)
  local f = assert(io.open(dir .. "/mark", "w"))
  f:write("x")
  f:close()
  function state.close()
    handle:stop()
    handle:close()
  end
  return state
end

local function dialogue_file()
  local dir = u.fresh()
  local path = dir .. "/dialogue.jsonl"
  local expected = u.big_dialogue(path, SID, COUNT, SIZE)
  return path, expected
end

describe("Диалог транскрипта — чтение порциями", function()
  it(
    "вызов возвращается до чтения; содержимое после конца чтения прежнее",
    function()
      local path, expected = dialogue_file()
      reads = u.count_reads()
      local got, chunks, done = {}, 0, nil
      data.read_dialogue(path, function(replies)
        chunks = chunks + 1
        vim.list_extend(got, replies)
      end, function(found)
        done = found
      end)
      t.eq(
        reads.read,
        0,
        "при возврате ни одной порции не прочитано"
      )
      t.eq(chunks, 0)
      t.ok(done == nil, "конец чтения не наступил")
      local ev = own_event(function()
        return chunks
      end)
      t.wait(function()
        return done ~= nil
      end, "конец чтения диалога")
      ev.close()
      t.eq(done, true)
      t.eq(got, expected)
      t.ok(chunks > 5, "реплики пришли порциями: " .. chunks)
      t.ok(ev.chunks < chunks, "событие обработано между порциями")
      t.eq(fds.live(), 0, "дескрипторы закрыты")
    end
  )

  it("файла нет: found = false, без реплик", function()
    local calls = 0
    local done
    data.read_dialogue(vim.fn.tempname() .. ".jsonl", function()
      calls = calls + 1
    end, function(found)
      done = found
    end)
    t.wait(function()
      return done ~= nil
    end, "конец чтения")
    t.eq(done, false)
    t.eq(calls, 0)
    t.eq(fds.live(), 0)
  end)

  it(
    "отмена во время чтения: порции и конец не приходят, дескриптор закрыт",
    function()
      local path = dialogue_file()
      local chunks, done, cancel = 0, false, false
      data.read_dialogue(path, function()
        chunks = chunks + 1
        cancel = true
      end, function()
        done = true
      end, function()
        return cancel
      end)
      t.wait(function()
        return chunks >= 1
      end, "первая порция")
      u.settle()
      u.settle()
      t.eq(chunks, 1, "после отмены порции не приходят")
      t.ok(not done, "конец чтения не сообщается")
      t.eq(fds.live(), 0, "дескриптор закрыт")
    end
  )

  it("отмена до первой порции", function()
    local path = dialogue_file()
    local cancel, calls = false, 0
    data.read_dialogue(path, function()
      calls = calls + 1
    end, function()
      calls = calls + 1
    end, function()
      return cancel
    end)
    cancel = true
    u.settle()
    u.settle()
    t.eq(calls, 0)
    t.eq(fds.live(), 0)
  end)
end)

describe("Перечень сессий — чтение порциями", function()
  it(
    "вызов возвращается до чтения; перечень прежний",
    function()
      local dir = u.fresh("history-project")
      local project = dir .. "/projects/" .. fixtures.project
      reads = u.count_reads()
      local list
      data.list_sessions(project, function(l)
        list = l
      end)
      t.eq(reads.read, 0, "при возврате транскрипты не читаются")
      t.ok(list == nil)
      t.wait(function()
        return list ~= nil
      end, "конец чтения перечня")
      t.eq(#list, 3)
      t.eq(list[1].id, fixtures.history.alpha[3])
      t.eq(list[1].first_user_text, "Rename the helper and update callers")
      t.eq(list[3].first_user_text, "How is the retry logic organised?")
      t.ok(reads.read >= 3, "транскрипты прочитаны")
      t.eq(fds.live(), 0)
    end
  )

  it("каталога нет: пустой перечень", function()
    u.fresh()
    local list
    data.list_sessions(vim.fn.tempname(), function(l)
      list = l
    end)
    t.wait(function()
      return list ~= nil
    end, "конец чтения перечня")
    t.eq(list, {})
  end)

  it(
    "первая реплика далеко от начала: чтение до неё, дальше не идёт",
    function()
      local dir = u.fresh()
      local project = dir .. "/projects/p"
      vim.fn.mkdir(project, "p")
      local path = project .. "/" .. SID .. ".jsonl"
      local f = assert(io.open(path, "w"))
      for _ = 1, 40 do
        f:write(vim.json.encode({ type = "queue-operation", pad = ("x"):rep(2048) }), "\n")
      end
      f:write(vim.json.encode(fixtures.user_record(SID, "первый вопрос")), "\n")
      for _ = 1, 400 do
        f:write(vim.json.encode({ type = "queue-operation", pad = ("x"):rep(2048) }), "\n")
      end
      f:close()
      reads = u.count_reads()
      local list
      data.list_sessions(project, function(l)
        list = l
      end)
      t.wait(function()
        return list ~= nil
      end, "конец чтения перечня")
      t.eq(list[1].first_user_text, "первый вопрос")
      local size = vim.uv.fs_stat(path).size
      t.ok(
        reads.read < size / fs.CHUNK / 2,
        "файл целиком не читался: порций " .. reads.read
      )
      t.eq(fds.live(), 0)
    end
  )

  it("запрос устарел: перечень не отдаётся", function()
    local dir = u.fresh("history-project")
    local project = dir .. "/projects/" .. fixtures.project
    local stale, calls = false, 0
    data.list_sessions(project, function()
      calls = calls + 1
    end, function()
      return stale
    end)
    stale = true
    u.settle()
    u.settle()
    t.eq(calls, 0)
    t.eq(fds.live(), 0)
  end)
end)

describe(
  "Рабочий каталог сессии — чтение до первой записи с ним",
  function()
    it(
      "чтение останавливается на найденной записи",
      function()
        local dir = u.fresh()
        local path = dir .. "/s.jsonl"
        local f = assert(io.open(path, "w"))
        f:write(vim.json.encode({ type = "queue-operation" }), "\n")
        f:write(
          vim.json.encode(
            vim.tbl_extend("force", fixtures.user_record(SID, "q"), { cwd = "/srv/demo" })
          ),
          "\n"
        )
        for _ = 1, 300 do
          f:write(vim.json.encode({ type = "queue-operation", pad = ("x"):rep(2048) }), "\n")
        end
        f:close()
        reads = u.count_reads()
        local cwd, done = nil, false
        data.session_cwd(path, function(c)
          cwd, done = c, true
        end)
        t.eq(reads.read, 0, "при возврате файл не читается")
        t.wait(function()
          return done
        end, "конец чтения")
        t.eq(cwd, "/srv/demo")
        local size = vim.uv.fs_stat(path).size
        t.ok(reads.read < size / fs.CHUNK / 2, "файл целиком не читался")
        t.eq(fds.live(), 0)
      end
    )

    it("записи с каталогом нет или файла нет: nil", function()
      local dir = u.fresh()
      local path = dir .. "/s.jsonl"
      fixtures.append(path, { { type = "queue-operation" } })
      t.eq(u.session_cwd(path), nil)
      t.eq(u.session_cwd(dir .. "/none.jsonl"), nil)
      t.eq(fds.live(), 0)
    end)
  end
)

describe("Файл вывода — начальное чтение порциями", function()
  local function output_file(text)
    local dir = u.fresh()
    local path = dir .. "/task.output"
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
    return path
  end

  it(
    "вызов возвращается до чтения; куски в сумме дают файл",
    function()
      -- многобайтные символы доходят до границ порций: символ не рвётся
      local text = ("строка вывода — ёж\n"):rep(2000)
        .. "хвост без перевода строки"
      local path = output_file(text)
      reads = u.count_reads()
      local got, chunks = {}, 0
      local h = assert(data.watch_output(path, function(chunk)
        chunks = chunks + 1
        got[#got + 1] = chunk
      end))
      t.eq(reads.read, 0, "при возврате файл не читается")
      t.eq(chunks, 0)
      local ev = own_event(function()
        return chunks
      end)
      t.wait(function()
        return table.concat(got) == text
      end, "весь вывод")
      ev.close()
      t.ok(chunks > 3, "порциями: " .. chunks)
      for _, c in ipairs(got) do
        t.ok(
          vim.fn.strchars(c) > 0 and vim.str_utf_pos(c) ~= nil,
          "порция — целые символы"
        )
      end
      t.ok(ev.chunks < chunks, "событие обработано между порциями")
      h:close()
      u.settle()
      t.eq(fds.live(), 0)
    end
  )

  it("закрытие во время чтения прекращает чтение", function()
    local path = output_file(("x"):rep(256 * 1024))
    local chunks = 0
    local h
    h = assert(data.watch_output(path, function()
      chunks = chunks + 1
      h:close()
    end))
    t.wait(function()
      return chunks >= 1
    end, "первая порция")
    u.settle()
    u.settle()
    t.eq(chunks, 1)
    t.eq(fds.live(), 0, "дескриптор закрыт")
  end)

  it(
    "дописанное во время чтения читается один раз",
    function()
      local path = output_file(("a"):rep(64 * 1024) .. "\n")
      local got = {}
      local h = assert(data.watch_output(path, function(chunk)
        got[#got + 1] = chunk
      end))
      local f = assert(io.open(path, "ab"))
      f:write("добавка\n")
      f:close()
      t.wait(function()
        return table.concat(got):find("добавка\n", 1, true) ~= nil
      end, "дописанное")
      u.settle()
      u.settle()
      local all = table.concat(got)
      t.eq(all, ("a"):rep(64 * 1024) .. "\nдобавка\n")
      h:close()
    end
  )
end)
