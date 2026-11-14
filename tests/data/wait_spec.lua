-- Модуль данных Claude Code: ожидание создания транскрипта по уведомлениям файловой системы
-- (спецификация claude-code-data, «Ожидание транскрипта»).
local t = require("helpers.t")
local fixtures = require("helpers.fixtures")
local u = require("data.util")
local data = require("claudr.data")

local id = fixtures.missing_session_id

local function dialogue(sid)
  return {
    fixtures.user_record(sid, "first message"),
    fixtures.assistant_record(sid, "first answer"),
  }
end

describe("Ожидание транскрипта", function()
  it("Первое сообщение сессии", function()
    local dir = u.fresh("no-transcript")
    local replies, changes = {}, {}
    local hd = data.watch_dialogue(id, function(r)
      vim.list_extend(replies, r)
    end)
    local hs = data.watch_session(id, function(s)
      changes[#changes + 1] = s
    end)
    t.eq(hs:state().transcript, nil)
    local path = dir .. "/projects/" .. fixtures.project .. "/" .. id .. ".jsonl"
    fixtures.append(path, dialogue(id))
    u.wait(function()
      return #replies == 2 and #changes > 0
    end, "реплики и состояние по уведомлению о создании")
    t.eq(replies, {
      { role = "user", text = "first message" },
      { role = "assistant", text = "first answer" },
    })
    t.eq(hs:state().transcript, path)
    -- после появления файла чтение идёт с запомненного смещения
    fixtures.append(path, { fixtures.assistant_record(id, "more") })
    u.wait(function()
      return #replies == 3
    end, "дописанная реплика")
    hd:close()
    hs:close()
  end)

  it(
    "Первое сообщение сессии в новом каталоге проекта",
    function()
      local dir = u.fresh() -- каталога projects/ ещё нет
      local replies = {}
      local hd = data.watch_dialogue(id, function(r)
        vim.list_extend(replies, r)
      end)
      local hs = data.watch_session(id, function() end)
      vim.fn.mkdir(dir .. "/projects", "p")
      local project = dir .. "/projects/-srv-demo-gamma"
      vim.fn.mkdir(project, "p")
      fixtures.append(project .. "/" .. id .. ".jsonl", dialogue(id))
      u.wait(function()
        return #replies == 2 and hs:state().transcript ~= nil
      end, "транскрипт в новом каталоге проекта")
      t.eq(hs:state().transcript, project .. "/" .. id .. ".jsonl")
      hd:close()
      hs:close()
    end
  )

  it("Сессия без сообщений", function()
    u.fresh("no-transcript")
    local calls = 0
    local reads = u.count_reads()
    local ok, err = pcall(function()
      local hd = data.watch_dialogue(id, function()
        calls = calls + 1
      end)
      local hs = data.watch_session(id, function()
        calls = calls + 1
      end)
      local s = hs:state()
      t.eq(s.transcript, nil)
      t.eq(s.subagents, {})
      t.eq(s.tasks, {})
      -- запись в чужой транскрипт того же каталога проекта даёт уведомление, но не чтение
      fixtures.append(fixtures.transcript("no-transcript"), {
        fixtures.user_record(fixtures.session_id("no-transcript"), "other"),
      })
      u.settle()
      hd:close()
      hs:close()
    end)
    reads.restore()
    t.ok(ok, err)
    t.eq(calls, 0, "записей нет")
    t.eq(reads.open, 0, "файлы не читаются: " .. table.concat(reads.paths, ", "))
  end)
end)
