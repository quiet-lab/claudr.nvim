-- Виды субагента и фоновой команды (спецификация node-view): транскрипт и файл вывода по
-- мере записи, только чтение.
local t = require("helpers.t")
local s = require("view.support")
local view = require("claudr.view")
local model = require("claudr.tree.model")
local u = require("data.util")
local fixtures = s.fixtures

after_each(function()
  s.reset()
end)

-- Окружение с панелью `w1:p1` сессии образца `sample`; возвращает первый узел вида `kind`.
local function env(sample, kind, pred)
  s.big_editor()
  s.env(s.snapshot({ s.claude_pane("w1:p1", sample) }), { sample })
  local found
  t.wait(function()
    found = model.find(function(n)
      return n.kind == kind and (pred == nil or pred(n))
    end)[1]
    return found ~= nil
  end, "узел " .. kind)
  return found
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("Субагент — транскрипт по мере записи", function()
  it("Работающий субагент", function()
    local node = env("owner-killed", "subagent", function(n)
      return n.state == "running"
    end)
    local v = view.open(node)
    t.eq(v.kind, "subagent")
    t.ok(v.handle, "слежение за транскриптом")
    t.eq(
      v.path,
      fixtures.session_dir("owner-killed") .. "/subagents/agent-" .. node.data.id .. ".jsonl"
    )
    -- уже записанное
    local before = u.read_dialogue(v.path)
    t.ok(#before > 0, "в образце есть реплики")
    s.wait_text(v.buf, before[#before].text:match("[^\n]+"), "записанные реплики")
    fixtures.append(v.path, {
      fixtures.assistant_record(
        fixtures.session_id("owner-killed"),
        "новая реплика субагента"
      ),
    })
    s.wait_text(
      v.buf,
      "новая реплика субагента",
      "дописанная реплика"
    )
    local text = s.text(v.buf)
    t.match(text, "Агент:\n  новая реплика субагента")
    t.ok(not text:find('"type"', 1, true), "не сырые строки JSON")
    t.eq(vim.bo[v.buf].modifiable, false)
    s.close_win(v)
    t.eq(v.handle, nil, "слежение закрыто вместе с видом")
  end)

  it("Завершённый субагент", function()
    local node = env("subagent-command", "subagent", function(n)
      return n.state == "finished"
    end)
    local v = view.open(node)
    t.wait(function()
      return v.loaded
    end, "конец чтения транскрипта")
    local replies = u.read_dialogue(v.path)
    t.ok(#replies > 0, "в образце есть реплики")
    local buf_lines = lines(v.buf)
    local roles = 0
    for _, l in ipairs(buf_lines) do
      if l == "Пользователь:" or l == "Агент:" then
        roles = roles + 1
      end
    end
    t.eq(roles, #replies, "весь транскрипт репликами")
    t.eq(v.handle, nil, "слежения нет: дополнений не будет")
    fixtures.append(v.path, {
      fixtures.assistant_record(fixtures.session_id("subagent-command"), "позднее"),
    })
    s.settle()
    t.eq(lines(v.buf), buf_lines)
  end)
end)

describe("Фоновая команда — файл вывода", function()
  it("Команда ещё работает", function()
    local node = env("command-orphaned", "task", function(n)
      return n.state == "running"
    end)
    local v = view.open(node)
    t.eq(v.kind, "task")
    t.ok(v.handle, "слежение за файлом вывода")
    local f = assert(io.open(node.data.output_file, "a"))
    f:write("first line\nsecond ")
    f:close()
    s.wait_text(v.buf, "second", "первый кусок")
    f = assert(io.open(node.data.output_file, "a"))
    f:write("part\nthird\n")
    f:close()
    s.wait_text(v.buf, "third", "дописанный вывод")
    t.eq(lines(v.buf), { "first line", "second part", "third", "" })
    t.eq(vim.bo[v.buf].modifiable, false)
  end)

  it("Файла вывода нет", function()
    local node = env("command-completed", "task", function(n)
      return n.state == "finished"
    end)
    -- файл исчез после того, как узел показан
    os.remove(node.data.output_file)
    local v = view.open(node)
    t.eq(v.unavailable, true)
    local text = s.text(v.buf)
    t.match(text, "файл вывода недоступен")
    t.match(text, "Состояние: завершена")
    t.match(text, "Код выхода: 0")
  end)
end)

describe("Вызов Bash — вывод", function()
  local files = require("claudr.view.files")

  it("Работающий вызов и его завершение", function()
    s.big_editor()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), { "owner-killed" })
    local tasks = fixtures.tasks_dir("owner-killed", s.claude_dir)
    vim.fn.mkdir(tasks, "p")
    local path = tasks .. "/bcall0001.output"
    local f = assert(io.open(path, "w"))
    f:write("начало\n")
    f:close()
    local node = s.wait_node("w1:p1/bcall0001")
    local v = s.track(view.open(node))
    t.eq(v.kind, "bash")
    s.wait_text(v.buf, "начало", "уже записанный вывод")
    f = assert(io.open(path, "a"))
    f:write("ещё\n")
    f:close()
    s.wait_text(v.buf, "ещё", "дописанный вывод")
    os.remove(path)
    t.wait(function()
      return v.done == true
    end, "сообщение о завершении")
    t.eq(lines(v.buf), { "начало", "ещё", files.CALL_DONE })
    t.eq(vim.bo[v.buf].modifiable, false)
  end)

  it("Завершённый вызов", function()
    s.big_editor()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), { "owner-killed" })
    s.wait_node("w1:p1/a0000000000000005")
    local sid = fixtures.session_id("owner-killed")
    fixtures.append(
      fixtures.transcript("owner-killed", s.claude_dir),
      u.bash_call(sid, "toolu_01FixtureCall00000000001", "ls", { stdout = "a\nb" })
    )
    fixtures.append(
      fixtures.transcript("owner-killed", s.claude_dir),
      u.bash_call(sid, "toolu_01FixtureCall00000000002", "true", {})
    )
    local node = s.wait_node("w1:p1/toolu_01FixtureCall00000000002")
    local v = s.track(view.open(model.get("w1:p1/toolu_01FixtureCall00000000001")))
    t.eq(lines(v.buf), { "a", "b" })
    local e = s.track(view.open(node))
    t.eq(lines(e.buf), { files.CALL_EMPTY })
  end)

  it("Завершённый вызов с большим выводом", function()
    s.big_editor()
    s.env(s.snapshot({ s.claude_pane("w1:p1", "owner-killed") }), { "owner-killed" })
    s.wait_node("w1:p1/a0000000000000005")
    local full = s.claude_dir .. "/full.txt"
    local f = assert(io.open(full, "w"))
    f:write("полный вывод\n")
    f:close()
    local sid = fixtures.session_id("owner-killed")
    fixtures.append(
      fixtures.transcript("owner-killed", s.claude_dir),
      u.bash_call(sid, "toolu_01FixtureCall00000000003", "find /", { persisted = full })
    )
    local node = s.wait_node("w1:p1/toolu_01FixtureCall00000000003")
    local v = s.track(view.open(node))
    s.wait_text(v.buf, "полный вывод", "сохранённый полный вывод")
  end)
end)
