-- Дерево при асинхронном чтении транскриптов: дерево панелей из снимка показано сразу,
-- субагенты и фоновые команды дополняют его после чтения (спецификации agent-tree,
-- claude-code-data). Синтетический транскрипт создаётся тестом, порция чтения уменьшена.
-- Исход не зависит от скорости узла: проверяются порядок событий и состояние.
local t = require("helpers.t")
local s = require("tree.support")
local u = require("data.util")
local model = require("claudr.tree.model")
local view = require("claudr.tree.view")
local fs = require("claudr.data.fs")

local CHUNK = fs.CHUNK
local SAMPLE = "command-completed"

before_each(function()
  fs.CHUNK = 4 * 1024
end)

after_each(function()
  fs.CHUNK = CHUNK
  view.close()
  s.reset()
end)

-- Окружение с панелью агента, чей транскрипт — синтетический на сотни порций; `on_model`
-- (необязательно) подписывается на модель до её запуска.
local function env(on_model)
  local start = vim.uv.hrtime()
  local unsub = on_model and model.subscribe(on_model)
  local d = s.env(s.snapshot({ s.claude_pane("w1:p1", SAMPLE) }), SAMPLE, function()
    -- узел команды показывается только с файлом вывода
    vim.fn.mkdir(s.claude_dir .. "/tmp", "p")
    local out = s.claude_dir .. "/tmp/bbig0001.output"
    local f = assert(io.open(out, "w"))
    f:close()
    u.big_transcript(
      s.fixtures.transcript(SAMPLE),
      s.fixtures.session_id(SAMPLE),
      400,
      8 * 1024,
      out
    )
  end, { loaded = false })
  print(
    string.format(
      "  замер: окружение готово за %.1f мс",
      (vim.uv.hrtime() - start) / 1e6
    )
  )
  return d, unsub
end

local function session()
  local rec = model._sessions()["w1:p1"]
  return rec and rec.handle
end

local function wait_loaded()
  local start = vim.uv.hrtime()
  t.wait(function()
    local h = session()
    return h ~= nil and h:loaded()
  end, "конец чтения транскрипта")
  print(
    string.format(
      "  замер: чтение после окружения %.1f мс",
      (vim.uv.hrtime() - start) / 1e6
    )
  )
end

describe("Асинхронное чтение и дерево", function()
  it(
    "дерево панелей показано до конца чтения транскрипта",
    function()
      local first
      local _, unsub = env(function()
        local h = session()
        if not first and model.get("w1:p1") and h then
          first = { loaded = h:loaded(), task = model.get("w1:p1/bbig0001") ~= nil }
        end
      end)
      unsub()
      t.ok(first, "модель с панелью построена")
      t.eq(first.loaded, false, "панель показана до конца чтения")
      t.eq(
        first.task,
        false,
        "сведения транскрипта ещё не добавлены"
      )
      wait_loaded()
      local task = s.wait_node("w1:p1/bbig0001")
      t.eq(task.state, "finished")
      t.eq(
        task.parent,
        "w1:t1",
        "команда агента вкладки — под вкладкой"
      )
    end
  )

  it(
    "событие herdr во время чтения обработано до конца чтения",
    function()
      local d = env()
      t.ok(not session():loaded(), "чтение идёт")
      local rec = d:_pane("w1:p1")
      rec.terminal_title_stripped = "новая задача"
      rec.terminal_title = "✳ новая задача"
      d:emit("pane_updated", { pane = vim.deepcopy(rec) })
      s.wait_node("w1:p1", function(n)
        return n.label:find("новая задача", 1, true) ~= nil
      end, "подпись панели по событию")
      t.eq(
        session():loaded(),
        false,
        "событие обработано до конца чтения"
      )
      wait_loaded()
      s.wait_node("w1:p1/bbig0001")
    end
  )

  it("дерево закрыто до конца чтения", function()
    env()
    view.open()
    t.ok(view.buf(), "буфер дерева открыт")
    t.ok(not session():loaded(), "чтение идёт")
    local errors = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        errors[#errors + 1] = msg
      end
      return orig(msg, level)
    end
    local ok, err = pcall(function()
      vim.api.nvim_buf_delete(view.buf(), { force = true })
      wait_loaded()
      s.wait_node("w1:p1/bbig0001")
    end)
    vim.notify = orig
    t.ok(ok, err)
    t.eq(errors, {}, "ошибок нет")
    t.eq(view.buf(), nil)
  end)

  it("панель закрыта во время чтения", function()
    local d = env()
    local h = session()
    t.ok(not h:loaded(), "чтение идёт")
    d:set_snapshot(s.snapshot({}))
    d:emit("pane_closed", { pane_id = "w1:p1", workspace_id = "w1" })
    s.wait_gone("w1:p1")
    t.ok(h.closed, "слежение за сессией закрыто")
    u.settle()
    t.eq(model.get("w1:p1/bbig0001"), nil)
  end)
end)
