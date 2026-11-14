-- Буфер вопроса (agent-dialogs): один выбор, свой ответ, множественный выбор, несколько
-- вопросов, отказы.
local t = require("helpers.t")
local samples = require("helpers.hook_samples")
local ds = require("dialogs.support")
local buffer = require("claudr.dialogs.buffer")
local input = require("claudr.input")

local pending, rec

before_each(function()
  pending, rec = ds.setup()
end)

after_each(function()
  ds.reset()
end)

local function open(sample)
  local req = ds.add(pending, sample)
  buffer.open(req)
  return req
end

local function answers()
  return ds.last_decision(pending).updatedInput.answers
end

-- Окно ввода запроса: ключ — часть после идентификатора запроса.
local function input_win(req, key)
  return input.window({ kind = "dialog", key = req.id .. "/" .. key })
end

describe("Ответ на вопрос с одним выбором", function()
  it("Второй пункт", function()
    open("question-single")
    t.match(ds.text(), "Which color%?")
    t.match(ds.text(), "Choose green")
    ds.choose("2%. Green")
    t.eq(#pending.decided, 1)
    local d = ds.last_decision(pending)
    t.eq(d.behavior, "allow")
    t.eq(d.updatedInput.answers, { ["Which color?"] = "Green" })
    t.eq(d.updatedInput.questions, samples.input("question-single").tool_input.questions)
  end)

  it("Курсор на первом пункте", function()
    open("question-single")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    t.match(ds.lines()[row], "1%. Red")
  end)
end)

describe("Свой ответ на вопрос", function()
  it("Текст из двух строк", function()
    local req = open("question-single")
    -- пункт «свой ответ» стоит после перечня пунктов вопроса
    t.ok(ds.line_of("4%. свой ответ") > ds.line_of("3%. Blue"))
    ds.choose("свой ответ")
    local win = input_win(req, "answer/1")
    t.ok(win, "окно ввода открыто")
    ds.ms.set_text(win.buf, 'first line\nsecond "line" !x /y')
    ds.ms.write(win.buf)
    t.eq(#pending.decided, 1)
    t.eq(answers(), { ["Which color?"] = 'first line\nsecond "line" !x /y' })
    t.eq(ds.last_decision(pending), samples.output("answer-free-text").hookSpecificOutput.decision)
  end)
end)

describe("Множественный выбор", function()
  it("Две отметки", function()
    open("question-multi")
    ds.choose("%[ %] Cheese")
    t.eq(#pending.decided, 0, "Enter только отмечает")
    t.match(ds.text(), "%[x%] Cheese")
    ds.choose("%[ %] Olives")
    t.eq(#pending.decided, 0)
    ds.press("c")
    t.eq(#pending.decided, 1)
    t.eq(answers(), { ["Which toppings?"] = "Cheese, Olives" })
    t.eq(ds.last_decision(pending), samples.output("answer-multi").hookSpecificOutput.decision)
  end)

  it("Отметка снимается повторным Enter", function()
    open("question-multi")
    ds.choose("%[ %] Ham")
    ds.choose("%[x%] Ham")
    t.match(ds.text(), "%[ %] Ham")
  end)

  it("Подтверждение без отметок", function()
    open("question-multi")
    ds.press("c")
    t.eq(#pending.decided, 0)
    t.ok(ds.ms.noted(rec, "ничего не отмечено"))
    ds.choose("подтвердить выбор")
    t.eq(#pending.decided, 0)
  end)

  it("Порядок значений — порядок пунктов", function()
    open("question-multi")
    ds.choose("%[ %] Olives")
    ds.choose("%[ %] Cheese")
    ds.choose("подтвердить выбор")
    t.eq(answers(), { ["Which toppings?"] = "Cheese, Olives" })
  end)
end)

describe("Свой ответ в множественном выборе", function()
  it("Свой ответ в множественном выборе", function()
    local req = open("question-multi")
    ds.choose("%[ %] Cheese")
    t.ok(
      ds.line_of("свой ответ") > ds.line_of("Olives"),
      "пункт после перечня пунктов"
    )
    ds.choose("свой ответ")
    local win = input_win(req, "answer/1")
    t.ok(win, "окно ввода открыто")
    ds.ms.set_text(win.buf, "Cheese, no olives")
    ds.ms.write(win.buf)
    t.eq(#pending.decided, 1)
    t.eq(answers(), { ["Which toppings?"] = "Cheese, no olives" })
  end)

  it(
    "свой ответ на втором вопросе из двух заменяет отметки",
    function()
      local req = open("question-two")
      ds.choose("3%. Blue")
      ds.choose("%[ %] Cheese")
      ds.choose("свой ответ")
      local win = input_win(req, "answer/2")
      ds.ms.set_text(win.buf, "only bread")
      ds.ms.write(win.buf)
      t.eq(#pending.decided, 0, "до итогового экрана решения нет")
      if vim.api.nvim_get_current_buf() ~= buffer.current().buf then
        vim.api.nvim_set_current_win(buffer.current().win)
      end
      t.match(ds.text(), "Ответы на все вопросы")
      ds.choose("подтвердить ответы")
      local a = answers()
      t.eq(a["Which toppings?"], "only bread")
      t.eq(a["Which color?"], "Blue")
    end
  )
end)

describe("Несколько вопросов", function()
  it("Два вопроса", function()
    open("question-two")
    t.match(ds.text(), "Вопрос 1 из 2")
    ds.choose("3%. Blue")
    t.eq(#pending.decided, 0, "ответ накапливается")
    t.match(ds.text(), "Вопрос 2 из 2")
    ds.choose("%[ %] Cheese")
    ds.choose("%[ %] Olives")
    ds.press("c")
    t.eq(#pending.decided, 0, "итоговый экран ждёт подтверждения")
    t.match(ds.text(), "Ответы на все вопросы")
    t.match(ds.text(), "Blue")
    t.match(ds.text(), "Cheese, Olives")
    ds.choose("подтвердить ответы")
    t.eq(#pending.decided, 1)
    t.eq(ds.last_decision(pending), samples.output("answer-two").hookSpecificOutput.decision)
  end)

  it("Возврат к вопросу", function()
    open("question-two")
    ds.choose("3%. Blue")
    ds.choose("%[ %] Ham")
    ds.press("c")
    ds.choose("изменить ответ на вопрос 1")
    t.eq(#pending.decided, 0)
    t.match(ds.text(), "Вопрос 1 из 2")
    t.match(ds.text(), "Текущий ответ: Blue")
    ds.choose("1%. Red")
    t.match(
      ds.text(),
      "Ответы на все вопросы",
      "после ответа снова итоговый экран"
    )
    t.match(ds.text(), "Red")
    t.match(ds.text(), "Ham")
    t.eq(#pending.decided, 0)
    ds.press("c")
    t.eq(answers(), { ["Which color?"] = "Red", ["Which toppings?"] = "Ham" })
  end)
end)

describe("Отказ от вопроса", function()
  it("Отказ с пояснением", function()
    local req = open("question-single")
    ds.choose("отказать с пояснением")
    local win = input_win(req, "deny")
    ds.ms.set_text(win.buf, "не нужно")
    ds.ms.write(win.buf)
    local d = ds.last_decision(pending)
    t.eq(d.behavior, "deny")
    t.eq(d.message, "не нужно")
    t.eq(d.updatedInput, nil)
  end)

  it("Отказ и отказ с прерыванием, голого allow нет", function()
    open("question-single")
    ds.choose("%d%. отказать$")
    t.eq(ds.last_decision(pending), samples.output("deny").hookSpecificOutput.decision)
    buffer.close()
    open("question-two")
    ds.choose("отказать и прервать")
    t.eq(ds.last_decision(pending), samples.output("deny-interrupt").hookSpecificOutput.decision)
    for _, d in ipairs(pending.decided) do
      t.ok(d.output.hookSpecificOutput.decision.behavior == "deny")
    end
  end)
end)
