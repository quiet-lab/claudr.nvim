-- Решения хука (спецификация agent-dialogs): форма вывода сверяется с образцами выводов.
local t = require("helpers.t")
local s = require("helpers.hook_samples")
local decision = require("claudr.dialogs.decision")
local hook = require("claudr.data.hook")

local function raw_decision(out)
  t.eq(out.hookSpecificOutput.hookEventName, "PermissionRequest")
  return out.hookSpecificOutput.decision
end

describe("Решения по запросу разрешения", function()
  it("Разрешить один раз", function()
    t.eq(decision.allow_once(), s.output("allow"))
  end)

  it("Пункт элемента", function()
    local req = hook.parse_input(s.input("permission-bash-dirs"))
    -- второй элемент массива — setMode: в решении ровно он, без изменений
    local out = decision.allow_suggestion(req.suggestions[2])
    t.eq(out, s.output("allow-suggestion-mode"))
    t.eq(#raw_decision(out).updatedPermissions, 1)
    t.eq(decision.allow_suggestion(req.suggestions[1]), s.output("allow-suggestion-dirs"))
    local rule = hook.parse_input(s.input("permission-bash")).suggestions[1]
    t.eq(decision.allow_suggestion(rule), s.output("allow-suggestion-rule"))
  end)

  it("Отказ", function()
    t.eq(decision.deny(), s.output("deny"))
  end)

  it("Отказ с пояснением", function()
    local text = s.output("deny-message").hookSpecificOutput.decision.message
    t.eq(decision.deny_message(text), s.output("deny-message"))
    t.eq(raw_decision(decision.deny_message("a\nb")).message, "a\nb")
  end)

  it("Отказ и прерывание", function()
    local out = decision.deny_interrupt()
    t.eq(out, s.output("deny-interrupt"))
    t.eq(raw_decision(out).interrupt, true)
    t.eq(raw_decision(out).message, nil)
  end)

  it("Вывод кодируется в JSON и читается обратно", function()
    local out = decision.deny_message("текст")
    t.eq(vim.json.decode(vim.json.encode(out)), out)
  end)
end)

describe("Ответ на вопрос с одним выбором", function()
  it("Второй пункт", function()
    local req = hook.parse_input(s.input("question-single"))
    local out = decision.answer(req.tool_input.questions, { ["Which color?"] = "Green" })
    t.eq(out, s.output("answer-single"))
    local d = raw_decision(out)
    t.eq(d.behavior, "allow")
    t.eq(d.updatedInput.answers, { ["Which color?"] = "Green" })
    t.eq(d.updatedInput.questions, s.input("question-single").tool_input.questions)
  end)
end)

describe("Свой ответ на вопрос", function()
  it("Текст из двух строк", function()
    local req = hook.parse_input(s.input("question-single"))
    local text = 'first line\nsecond "line" !x /y'
    local out = decision.answer(req.tool_input.questions, { [req.questions[1].question] = text })
    t.eq(out, s.output("answer-free-text"))
    t.eq(raw_decision(out).updatedInput.answers["Which color?"], text)
    -- перевод строки доходит до JSON и обратно
    local back = vim.json.decode(vim.json.encode(out))
    t.eq(back.hookSpecificOutput.decision.updatedInput.answers["Which color?"], text)
  end)
end)

describe("Множественный выбор", function()
  it("Две отметки", function()
    t.eq(decision.multi_value({ "Cheese", "Olives" }), "Cheese, Olives")
    local req = hook.parse_input(s.input("question-multi"))
    local value = decision.multi_value({ "Cheese", "Olives" })
    local out = decision.answer(req.tool_input.questions, { [req.questions[1].question] = value })
    t.eq(out, s.output("answer-multi"))
  end)

  it("Одна отметка", function()
    t.eq(decision.multi_value({ "Ham" }), "Ham")
  end)

  it("Метка с запятой", function()
    t.eq(decision.multi_value({ "Cheese, aged", "Olives" }), '"Cheese, aged", Olives')
    t.eq(decision.multi_value({ "Ham", "a,b" }), 'Ham, "a,b"')
  end)
end)

describe("Несколько вопросов", function()
  it("Два ключа", function()
    local req = hook.parse_input(s.input("question-two"))
    local answers = {
      [req.questions[1].question] = "Blue",
      [req.questions[2].question] = decision.multi_value({ "Cheese", "Olives" }),
    }
    local out = decision.answer(req.tool_input.questions, answers)
    t.eq(out, s.output("answer-two"))
    local keys = vim.tbl_keys(raw_decision(out).updatedInput.answers)
    t.eq(#keys, 2)
  end)
end)

describe("Отказ от вопроса", function()
  it("Три вида отказа", function()
    t.eq(decision.deny(), s.output("deny"))
    t.eq(
      raw_decision(decision.deny_message("Нужен другой вопрос")).message,
      "Нужен другой вопрос"
    )
    t.eq(raw_decision(decision.deny_interrupt()).interrupt, true)
  end)

  it("Голое allow без answers не собирается", function()
    local req = hook.parse_input(s.input("question-single"))
    local out, err = decision.answer(req.tool_input.questions, {})
    t.eq(out, nil)
    t.ok(err)
    t.eq((decision.answer(req.tool_input.questions, nil)), nil)
  end)
end)

describe("Подтверждение плана", function()
  it("Подтверждение", function()
    local req = hook.parse_input(s.input("plan"))
    local out = decision.approve_plan(req.tool_input)
    t.eq(out, s.output("plan-allow"))
    t.eq(raw_decision(out).updatedInput, s.input("plan").tool_input)
  end)

  it("Правка плана", function()
    local d = raw_decision(decision.deny_message("Добавьте шаг про уборку."))
    t.eq(d.behavior, "deny")
    t.eq(d.message, "Добавьте шаг про уборку.")
    t.eq(d.updatedInput, nil)
  end)
end)
