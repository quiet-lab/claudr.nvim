-- Разбор входа хука и записей диалогов (спецификации claude-code-data и agent-dialogs).
local t = require("helpers.t")
local s = require("helpers.hook_samples")
local hook = require("claudr.data.hook")

local function parse(name)
  local req, err = hook.parse_input(s.input(name))
  t.ok(req, "разбор " .. name .. ": " .. tostring(err))
  return req
end

local function find(records, pred)
  for _, r in ipairs(records) do
    if pred(r) then
      return r
    end
  end
end

describe("Разбор входа хука в claude-code-data", function()
  it("Вопрос с вариантами", function()
    local req = parse("question-single")
    t.eq(req.kind, "question")
    t.eq(#req.questions, 1)
    local q = req.questions[1]
    t.eq(q.question, "Which color?")
    t.eq(q.header, "Color")
    t.eq(q.multi, false)
    t.eq(#q.options, 3)
    t.eq(q.options[2], { label = "Green", description = "Choose green" })
    t.eq(req.suggestions, {})
  end)

  it("Пустые предложения", function()
    -- null (вопрос, план, Bash), пустой массив и отсутствие ключа — один результат
    for _, name in ipairs({
      "permission-bash-null",
      "permission-bash-empty",
      "question-multi",
      "plan",
    }) do
      local req = parse(name)
      t.eq(req.suggestions, {}, name)
    end
    t.eq(parse("permission-unknown-tool").suggestions, {})
  end)

  it("Вопрос с множественным выбором", function()
    local q = parse("question-multi").questions[1]
    t.eq(q.multi, true)
    t.eq(#q.options, 3)
  end)

  it("Несколько вопросов", function()
    local req = parse("question-two")
    t.eq(#req.questions, 2)
    t.eq(req.questions[1].multi, false)
    t.eq(req.questions[2].multi, true)
    t.eq(req.questions[2].question, "Which toppings?")
  end)

  it("План", function()
    local req = parse("plan")
    t.eq(req.kind, "plan")
    t.eq(req.permission_mode, "plan")
    t.match(req.plan, "^# Plan: create plan%-out%.txt\n")
    t.eq(req.plan_file, s.input("plan").tool_input.planFilePath)
    t.eq(req.tool_input, s.input("plan").tool_input)
  end)

  it("Разрешение Bash: команда и элемент правила", function()
    local req = parse("permission-bash")
    t.eq(req.kind, "permission")
    t.eq(req.tool_name, "Bash")
    t.eq(req.session_id, s.session_id)
    t.eq(req.cwd, s.cwd)
    t.eq(req.permission_mode, "default")
    t.eq(req.agent_id, nil)
    t.eq(req.content.command, "git init -q gi")
    t.eq(req.content.description, "Initialize git repository in directory gi quietly")
    t.eq(req.content.raw, req.tool_input)
    t.eq(#req.suggestions, 1)
    t.eq(
      req.suggestions[1],
      s.output("allow-suggestion-rule").hookSpecificOutput.decision.updatedPermissions[1]
    )
  end)

  it("Разрешение Write и Edit: файл и текст", function()
    local w = parse("permission-write").content
    t.eq(w.file_path, s.cwd .. "/new.txt")
    t.eq(w.text, "hello\nworld")
    t.eq(w.command, nil)
    local e = parse("permission-edit").content
    t.eq(e.file_path, s.cwd .. "/notes.txt")
    t.eq(e.text, "new text")
  end)

  it("Разрешение Read: правило сессии", function()
    local req = parse("permission-read")
    t.eq(req.content.file_path, "/etc/hostname")
    t.eq(req.suggestions[1].destination, "session")
  end)

  it(
    "Элементы разных видов остаются как пришли, в порядке массива",
    function()
      local raw = s.input("permission-kinds").permission_suggestions
      local req = parse("permission-kinds")
      t.eq(#req.suggestions, #raw)
      t.eq(req.suggestions, raw)
    end
  )

  it("Субагент", function()
    local req = parse("subagent")
    t.eq(req.agent_id, s.agent_id)
    t.eq(req.agent_type, "general-purpose")
    t.eq(#req.suggestions, 2)
  end)

  it("Неизвестные поля и инструменты", function()
    local req = parse("permission-unknown-tool")
    t.eq(req.kind, "permission")
    t.eq(req.tool_name, "FutureTool")
    t.eq(req.content.raw.target, "x")
    t.eq(req.content.command, nil)
  end)

  it("Ошибки разбора", function()
    local req, err = hook.parse_input(nil)
    t.eq(req, nil)
    t.ok(err)
    t.ok(not hook.parse_input({}))
    t.ok(not hook.parse_input({ tool_name = 5 }))
    t.ok(not hook.parse_input({ tool_name = "Bash", tool_input = "x" }))
    t.ok(not hook.parse_input({ "x" }))
    -- вопрос без вопросов показать нечем
    t.ok(not hook.parse_input({ tool_name = "AskUserQuestion", tool_input = { questions = {} } }))
    -- отсутствие tool_input не ошибка: у запроса пустой вход
    local bare = hook.parse_input({ tool_name = "Bash" })
    t.eq(bare.tool_input, {})
    t.eq(bare.kind, "permission")
  end)

  it("Каждый вход образцов разбирается", function()
    for _, name in ipairs(s.names("inputs")) do
      parse(name)
    end
  end)
end)

describe("Записи транскрипта диалогов", function()
  it("Вызов без результата", function()
    local uses = {}
    for _, r in ipairs(s.records("bash-pending")) do
      vim.list_extend(uses, hook.tool_uses(r))
    end
    t.eq(#uses, 1)
    t.eq(uses[1].id, s.tool_use_ids.bash)
    t.eq(uses[1].name, "Bash")
    t.eq(uses[1].input, s.input("permission-bash").tool_input)
    for _, r in ipairs(s.records("bash-pending")) do
      t.eq(hook.tool_results(r), {})
      t.eq(hook.decision_attachment(r), nil)
    end
  end)

  it("Результат ответа", function()
    local res = {}
    for _, r in ipairs(s.records("bash-allowed")) do
      vim.list_extend(res, hook.tool_results(r))
    end
    t.eq(res, { { tool_use_id = s.tool_use_ids.bash, is_error = false } })
  end)

  it("Результат отказа и отмены", function()
    for _, name in ipairs({ "bash-denied", "bash-rejected-panel" }) do
      local res = {}
      for _, r in ipairs(s.records(name)) do
        vim.list_extend(res, hook.tool_results(r))
      end
      t.eq(res, { { tool_use_id = s.tool_use_ids.bash, is_error = true } }, name)
    end
    -- запись «[Request interrupted by user for tool use]» результатом не считается
    local recs = s.records("bash-rejected-panel")
    t.eq(hook.tool_results(recs[#recs]), {})
  end)

  it("Результат вопроса без is_error", function()
    local res = {}
    for _, r in ipairs(s.records("question-answered")) do
      vim.list_extend(res, hook.tool_results(r))
    end
    t.eq(res, { { tool_use_id = s.tool_use_ids.ask, is_error = false } })
  end)

  it("Вложение hook_permission_decision", function()
    local cases = {
      ["bash-allowed"] = { decision = "allow", tool_use_id = s.tool_use_ids.bash },
      ["bash-denied"] = { decision = "deny", tool_use_id = s.tool_use_ids.bash },
      ["question-answered"] = { decision = "allow", tool_use_id = s.tool_use_ids.ask },
      ["plan-approved"] = { decision = "allow", tool_use_id = s.tool_use_ids.plan },
      ["subagent"] = { decision = "allow", tool_use_id = s.tool_use_ids.sub },
    }
    for name, want in pairs(cases) do
      local found = {}
      for _, r in ipairs(s.records(name)) do
        local d = hook.decision_attachment(r)
        if d then
          found[#found + 1] = d
        end
      end
      t.eq(found, { want }, name)
    end
    -- отказ в панели вложения не даёт
    for _, r in ipairs(s.records("bash-rejected-panel")) do
      t.eq(hook.decision_attachment(r), nil)
    end
  end)

  it("Вопрос и план в транскрипте", function()
    local ask = hook.tool_uses(find(s.records("question-answered"), function(r)
      return #hook.tool_uses(r) > 0
    end))
    t.eq(ask[1].name, "AskUserQuestion")
    t.ok(hook.equal_input(ask[1].input, s.input("question-two").tool_input))
    local plan = hook.tool_uses(find(s.records("plan-approved"), function(r)
      return #hook.tool_uses(r) > 0
    end))
    t.eq(plan[1].name, "ExitPlanMode")
    t.ok(hook.equal_input(plan[1].input, s.input("plan").tool_input))
  end)

  it("Параллельные вызовы в одной записи", function()
    local recs = s.records("parallel-reads")
    local uses = hook.tool_uses(recs[2])
    t.eq(#uses, 2)
    t.eq(uses[1].id, s.tool_use_ids.read1)
    t.eq(uses[2].id, s.tool_use_ids.read2)
    t.eq(uses[2].input, { file_path = "/etc/hosts" })
    local res = hook.tool_results(recs[#recs])
    t.eq(res, {
      { tool_use_id = s.tool_use_ids.read1, is_error = false },
      { tool_use_id = s.tool_use_ids.read2, is_error = true },
    })
  end)

  it("Транскрипт субагента", function()
    local uses = {}
    for _, r in ipairs(s.records("subagent")) do
      vim.list_extend(uses, hook.tool_uses(r))
    end
    t.eq(#uses, 1)
    t.eq(uses[1].id, s.tool_use_ids.sub)
    t.ok(hook.equal_input(uses[1].input, s.input("subagent").tool_input))
  end)

  it("Неизвестные записи, блоки и вложения", function()
    local uses, res, atts = {}, {}, {}
    for _, r in ipairs(s.records("unknown-records")) do
      vim.list_extend(uses, hook.tool_uses(r))
      vim.list_extend(res, hook.tool_results(r))
      atts[#atts + 1] = hook.decision_attachment(r) or false
    end
    -- блок без id пропущен, неизвестный инструмент разобран
    t.eq(#uses, 1)
    t.eq(uses[1].name, "FutureTool")
    t.eq(uses[1].input.deep.a[1], 1)
    -- результат без tool_use_id пропущен, содержимое-список не мешает
    t.eq(res, { { tool_use_id = s.tool_use_ids.bash, is_error = false } })
    -- чужое вложение и вложение без идентификатора — не решения
    for _, a in ipairs(atts) do
      t.eq(a, false)
    end
  end)

  it("Не записи", function()
    for _, v in ipairs({ vim.NIL, "x", 1, {} }) do
      t.eq(hook.tool_uses(v), {})
      t.eq(hook.tool_results(v), {})
      t.eq(hook.decision_attachment(v), nil)
    end
  end)
end)

describe("Равенство входа вызова", function()
  it("Порядок ключей не важен", function()
    t.ok(hook.equal_input({ a = 1, b = { c = "x" } }, { b = { c = "x" }, a = 1 }))
  end)

  it("Различие значений", function()
    t.ok(not hook.equal_input({ command = "ls" }, { command = "ls -l" }))
    t.ok(not hook.equal_input({ a = 1 }, { a = 1, b = 2 }))
    t.ok(not hook.equal_input({ 1, 2 }, { 2, 1 }))
  end)

  it("null равен null", function()
    t.ok(hook.equal_input({ a = vim.NIL }, { a = vim.NIL }))
    t.ok(not hook.equal_input({ a = vim.NIL }, { a = 0 }))
  end)

  it(
    "Вход субагента и транскрипта совпадает после разбора JSON",
    function()
      local a = s.input("permission-write").tool_input
      local text = vim.json.encode(a)
      t.ok(hook.equal_input(a, vim.json.decode(text)))
    end
  )
end)
