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
    vim.api.nvim_win_close(v.win, true)
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
    t.ok(
      vim.uv.fs_stat(node.data.output_file or "") == nil,
      "в образце файла вывода нет"
    )
    local v = view.open(node)
    t.eq(v.unavailable, true)
    local text = s.text(v.buf)
    t.match(text, "файл вывода недоступен")
    t.match(text, "Состояние: завершена")
    t.match(text, "Код выхода: 0")
  end)
end)
