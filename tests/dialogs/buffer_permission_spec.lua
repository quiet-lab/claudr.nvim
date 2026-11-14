-- Буфер запроса разрешения (agent-dialogs): содержимое, пункты, подписи, решения, отказы.
local t = require("helpers.t")
local samples = require("helpers.hook_samples")
local ds = require("dialogs.support")
local buffer = require("claudr.dialogs.buffer")
local labels = require("claudr.dialogs.labels")
local input = require("claudr.input")

local pending, rec

before_each(function()
  pending, rec = ds.setup()
end)

after_each(function()
  ds.reset()
end)

-- Номера и тексты пунктов буфера (строки вида «  N. текст»).
local function item_texts()
  local out = {}
  for _, l in ipairs(ds.lines()) do
    local text = l:match("^  %d+%. (.*)$")
    if text then
      out[#out + 1] = text
    end
  end
  return out
end

local function open(sample)
  local req = ds.add(pending, sample)
  buffer.open(req)
  return req
end

describe("Пункты запроса разрешения", function()
  it("Два элемента", function()
    local req = open("permission-bash-dirs")
    local items = item_texts()
    t.eq(#items, 6)
    t.eq(items[1], "разрешить один раз")
    t.eq(items[2], labels.suggestion(req.request.suggestions[1]))
    t.eq(items[3], labels.suggestion(req.request.suggestions[2]))
    t.eq(items[4], "отказать")
    t.eq(items[5], "отказать с пояснением")
    t.eq(items[6], "отказать и прервать")
  end)

  it("Пустые предложения", function()
    for _, sample in ipairs({ "permission-bash-empty", "permission-bash-null" }) do
      buffer.close()
      open(sample)
      t.eq(item_texts(), {
        "разрешить один раз",
        "отказать",
        "отказать с пояснением",
        "отказать и прервать",
      })
    end
  end)

  it("Команда, файл с текстом и вход инструмента", function()
    open("permission-bash")
    t.match(ds.text(), "Инструмент: Bash\nКоманда:\n  ")
    local cmd = samples.input("permission-bash").tool_input.command
    t.match(ds.text(), vim.pesc(cmd))
    buffer.close()
    open("permission-write")
    t.match(ds.text(), "Инструмент: Write")
    t.match(ds.text(), vim.pesc("Файл: " .. samples.cwd .. "/new.txt"))
    t.match(ds.text(), "Текст:\n  hello\n  world")
    buffer.close()
    open("permission-unknown-tool")
    t.match(ds.text(), "Вход инструмента:")
  end)

  it("Пункт auto остаётся терминалу", function()
    open("permission-bash")
    t.match(
      ds.text(),
      "перейти в режим auto» хук не отдаёт: он остаётся терминалу"
    )
    t.match(ds.text(), "T — передать терминалу")
  end)
end)

describe("Подписи пунктов из данных хука", function()
  it("Правило в местные настройки", function()
    open("permission-bash")
    t.match(ds.text(), "Правило: .*Bash.*местные настройки проекта")
  end)

  it("Каталог на сессию", function()
    open("permission-bash-dirs")
    t.match(ds.text(), "Каталог[и]?: .* — сессия")
  end)
end)

describe("Решения по запросу разрешения", function()
  it("Разрешить один раз", function()
    open("permission-bash")
    ds.choose("1%. разрешить один раз")
    t.eq(pending.decided[1].output, samples.output("allow"))
  end)

  it("Пункт элемента", function()
    local req = open("permission-bash-dirs")
    ds.choose("3%. ")
    t.eq(#pending.decided, 1)
    t.eq(pending.decided[1].output, samples.output("allow-suggestion-mode"))
    t.eq(
      pending.decided[1].output.hookSpecificOutput.decision.updatedPermissions,
      { req.request.suggestions[2] }
    )
  end)

  it("Отказ", function()
    open("permission-bash")
    ds.choose("%d%. отказать$")
    t.eq(pending.decided[1].output, samples.output("deny"))
  end)

  it("Отказ и прерывание", function()
    open("permission-bash")
    ds.choose("отказать и прервать")
    t.eq(pending.decided[1].output, samples.output("deny-interrupt"))
  end)

  it("Отказ с пояснением", function()
    local req = open("permission-bash")
    ds.choose("отказать с пояснением")
    local win = input.window({ kind = "dialog", key = req.id .. "/deny" })
    t.ok(win, "окно ввода пояснения открыто")
    ds.ms.set_text(win.buf, "нельзя\nпотому что")
    ds.ms.write(win.buf)
    t.eq(#pending.decided, 1)
    local d = ds.last_decision(pending)
    t.eq(d.behavior, "deny")
    t.eq(d.message, "нельзя\nпотому что")
    t.wait(function()
      return input.window({ kind = "dialog", key = req.id .. "/deny" }) == nil
    end, "закрытие окна ввода")
  end)

  it("Пустое пояснение не отправляется", function()
    local req = open("permission-bash")
    ds.choose("отказать с пояснением")
    local win = input.window({ kind = "dialog", key = req.id .. "/deny" })
    ds.ms.write(win.buf)
    t.eq(#pending.decided, 0)
    t.ok(ds.ms.noted(rec, "текст пуст"))
  end)
end)
