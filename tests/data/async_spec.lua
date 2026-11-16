-- Модуль данных Claude Code: асинхронное чтение транскриптов порциями и отбор строк учёта
-- (спецификация claude-code-data, «Чтение транскрипта», «Слежение за изменениями»).
-- Синтетический транскрипт создаётся тестом; порция чтения уменьшена, чтобы файл в пару
-- мегабайт читался сотнями порций. Исход не зависит от скорости узла: проверяются порядок
-- событий и счётчики, длительности пишутся в журнал.
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")
local fs = require("claudr.data.fs")
local parse = require("claudr.data.parse")

local CHUNK = fs.CHUNK
local COUNT, SIZE = 200, 8 * 1024

local scans
local orig_scan = parse.scan

before_each(function()
  fs.CHUNK = 4 * 1024
  scans = 0
  parse.scan = function(...)
    scans = scans + 1
    return orig_scan(...)
  end
end)

after_each(function()
  fs.CHUNK = CHUNK
  parse.scan = orig_scan
end)

-- Каталог данных с сессией образца `command-completed`, транскрипт которой заменён
-- синтетическим.
local function big_session()
  u.fresh("command-completed")
  local sid = fixtures.session_id("command-completed")
  local path = fixtures.transcript("command-completed")
  u.big_transcript(path, sid, COUNT, SIZE)
  return sid, path
end

-- Собственное наблюдение теста за отдельным каталогом: `fired()` истинно после события.
local function own_event()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local handle = vim.uv.new_fs_event()
  local state = { fired = false }
  handle:start(dir, {}, function()
    vim.schedule(function()
      if not state.fired then
        state.fired = true
        state.scans = scans
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

describe("Асинхронное чтение транскрипта", function()
  it(
    "цикл событий обрабатывает события во время чтения большого транскрипта",
    function()
      local sid = big_session()
      local start = vim.uv.hrtime()
      local changes = {}
      local h
      h = data.watch_session(sid, function(s)
        changes[#changes + 1] = { s = s, loaded = h:loaded(), scans = scans }
      end)
      t.ok(
        not h:loaded(),
        "чтение не закончено при возврате watch_session"
      )
      local ev = own_event()
      t.wait(function()
        return ev.fired
      end, "событие собственного наблюдения")
      t.ok(not h:loaded(), "событие обработано до конца чтения")
      t.wait(function()
        return h:loaded()
      end, "конец первого чтения")
      ev.close()
      print(
        string.format(
          "  замер: чтение %.1f мс, порций %d, событие после %d порций",
          (vim.uv.hrtime() - start) / 1e6,
          scans,
          ev.scans
        )
      )
      t.ok(ev.scans < scans, "событие обработано между порциями")
      t.eq(
        #changes,
        1,
        "подписчик получает одно состояние после чтения"
      )
      local task = h:state().tasks.bbig0001
      t.eq(task.status, "finished")
      t.eq(task.exit_code, 0)
      t.eq(vim.tbl_count(h:state().tasks), 1, "заполнители команд не дают")
      h:close()
    end
  )

  it(
    "до конца чтения состояние не содержит прочитанного наполовину",
    function()
      local sid = big_session()
      local h = data.watch_session(sid, function() end)
      t.wait(function()
        return scans >= 2
      end, "прочитаны первые порции")
      t.ok(not h:loaded())
      -- запуск команды уже прочитан, уведомление о завершении ещё нет
      t.eq(h:state().tasks, {})
      t.wait(function()
        return h:loaded()
      end, "конец первого чтения")
      t.eq(h:state().tasks.bbig0001.status, "finished")
      h:close()
    end
  )

  it("файл дописан во время чтения", function()
    local sid, path = big_session()
    local seen = {}
    local h = data.watch_session(sid, function(s)
      seen[#seen + 1] = s
    end)
    t.wait(function()
      return scans >= 2
    end, "прочитаны первые порции")
    t.ok(not h:loaded())
    fixtures.append(
      path,
      u.bash_launch(sid, "toolu_01FixtureBig000000000002", "bbig0002", "sleep 2", "/y.output")
    )
    t.wait(function()
      return #seen > 0 and seen[#seen].tasks.bbig0002 ~= nil
    end, "команда из дописанного во время чтения")
    t.eq(vim.tbl_count(seen[#seen].tasks), 2)
    t.eq(seen[#seen].tasks.bbig0001.status, "finished")
    t.eq(seen[#seen].tasks.bbig0002.status, "running")
    -- дописанное прочитано один раз: повторного учёта нет, дальнейшее чтение — только новое
    local before = scans
    fixtures.append(path, { fixtures.assistant_record(sid, "tail") })
    t.wait(function()
      return scans > before
    end, "чтение дописанной реплики")
    u.settle()
    t.eq(scans, before + 1, "дописанная строка — одна порция")
    h:close()
  end)

  it("сессия закрыта во время чтения", function()
    local sid = big_session()
    local calls = 0
    local h = data.watch_session(sid, function()
      calls = calls + 1
    end)
    t.wait(function()
      return scans >= 2
    end, "прочитаны первые порции")
    h:close()
    local at_close = scans
    u.settle()
    u.settle()
    t.eq(scans, at_close, "после закрытия порции не разбираются")
    t.eq(calls, 0, "подписчик не вызывается")
  end)
end)

describe("Отбор строк учёта", function()
  -- Учёт, в который записи переданы все подряд, как до отбора строк.
  local function feed_all(text)
    local ledger = parse.ledger()
    for line in text:gmatch("[^\n]+") do
      local rec = parse.decode(line)
      if rec then
        parse.feed(ledger, rec, nil)
      end
    end
    return ledger
  end

  it(
    "отбор строк даёт тот же учёт, что разбор всех записей",
    function()
      local dir = u.fresh(vim.tbl_keys(fixtures.catalog))
      local files = vim.fn.globpath(dir .. "/projects", "**/*.jsonl", false, true)
      t.ok(#files > 10, "образцы транскриптов найдены")
      for _, path in ipairs(files) do
        local f = assert(io.open(path, "rb"))
        local text = f:read("*a")
        f:close()
        if text:sub(-1) ~= "\n" then
          text = text .. "\n"
        end
        local scanned = parse.ledger()
        orig_scan(scanned, text, nil)
        local full = feed_all(text)
        t.eq(
          parse.build(scanned, {}, {}, true),
          parse.build(full, {}, {}, true),
          path:match("[^/]+/[^/]+$")
        )
      end
    end
  )

  it("заполнители не декодируются", function()
    local sid = fixtures.session_id("command-completed")
    local path = vim.fn.tempname()
    u.big_transcript(path, sid, 50, 1024)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    local decoded = 0
    local orig_decode = parse.decode
    parse.decode = function(line)
      decoded = decoded + 1
      return orig_decode(line)
    end
    local ledger = parse.ledger()
    local ok, err = pcall(orig_scan, ledger, text, nil)
    parse.decode = orig_decode
    t.ok(ok, err)
    -- запуск (вызов и результат), 25 вызовов Bash без фона с результатами (вывод вызова
    -- Bash нужен узлу дерева), уведомление
    t.eq(decoded, 2 + 25 * 2 + 1)
    t.eq(parse.build(ledger, {}, {}, true).tasks.bbig0001.status, "finished")
  end)
end)
