-- Вид вопроса (`AskUserQuestion`): вопрос с одним выбором, множественный выбор, свой ответ
-- через окно ввода, несколько вопросов по очереди с итоговым экраном. Ответы накапливаются
-- в состоянии вида; решение — одно `allow` со всеми ответами.
local common = require("claudr.dialogs.views.common")
local decision = require("claudr.dialogs.decision")

local M = {}

M.TITLE = "Вопрос агента"

-- Состояние вида: текущий вопрос, ответы (текст вопроса → значение), отметки множественного
-- выбора по вопросам, признак итогового экрана.
local function init(st)
  st.qi = st.qi or 1
  st.answers = st.answers or {}
  st.marks = st.marks or {}
  return st
end

local function raw_questions(ctx)
  local raw = ctx.req.tool_input and ctx.req.tool_input.questions
  return type(raw) == "table" and raw or ctx.req.request.questions
end

local function first_unanswered(st, qs)
  for i, q in ipairs(qs) do
    if st.answers[q.question] == nil then
      return i
    end
  end
end

-- Ответ записан: один вопрос — решение; иначе следующий неотвеченный либо итоговый экран.
local function record(ctx, q, value)
  local st = init(ctx.state)
  local qs = ctx.req.request.questions
  st.answers[q.question] = value
  if #qs == 1 then
    local out, why = decision.answer(raw_questions(ctx), st.answers)
    if not out then
      ctx.notify(
        "claudr: решение не собрано: " .. tostring(why),
        vim.log.levels.ERROR
      )
      return false
    end
    return ctx.decide(out)
  end
  local nxt = first_unanswered(st, qs)
  if nxt then
    st.qi = nxt
  else
    st.summary = true
  end
  ctx.refresh(true)
  return true
end

local function confirm_multi(ctx, qi)
  local st = init(ctx.state)
  local q = ctx.req.request.questions[qi]
  local chosen = {}
  for oi, o in ipairs(q.options) do
    if (st.marks[qi] or {})[oi] then
      chosen[#chosen + 1] = o.label
    end
  end
  if #chosen == 0 then
    ctx.notify(
      "claudr: ничего не отмечено, решение не отправлено",
      vim.log.levels.WARN
    )
    return false
  end
  return record(ctx, q, decision.multi_value(chosen))
end

local function question_screen(ctx)
  local st = init(ctx.state)
  local qs = ctx.req.request.questions
  local qi = st.qi
  local q = qs[qi]
  local header = {}
  if #qs > 1 then
    header[#header + 1] = ("Вопрос %d из %d"):format(qi, #qs)
  end
  if q.header then
    header[#header + 1] = q.header
  end
  vim.list_extend(header, common.split(q.question))
  local current = st.answers[q.question]
  if current ~= nil then
    header[#header + 1] = "Текущий ответ: " .. current
  end
  local items = {}
  for oi, o in ipairs(q.options) do
    local item = { detail = o.description and common.indented(o.description, "") or nil }
    if q.multi then
      local on = (st.marks[qi] or {})[oi]
      item.text = (on and "[x] " or "[ ] ") .. o.label
      item.run = function()
        st.marks[qi] = st.marks[qi] or {}
        st.marks[qi][oi] = (not st.marks[qi][oi]) or nil
        ctx.refresh(false)
      end
    else
      item.text = o.label
      item.run = function()
        record(ctx, q, o.label)
      end
    end
    items[#items + 1] = item
  end
  local screen = { header = header, items = items, footer = {} }
  if q.multi then
    items[#items + 1] = {
      text = "подтвердить выбор (c)",
      run = function()
        confirm_multi(ctx, qi)
      end,
    }
    screen.confirm = function()
      confirm_multi(ctx, qi)
    end
    screen.footer =
      { "Enter отмечает пункт, c подтверждает отмеченные." }
  end
  -- свой ответ есть и у множественного выбора: текст заменяет отметки как есть
  items[#items + 1] = {
    text = "свой ответ",
    run = function()
      ctx.ask("Свой ответ", "answer/" .. qi, function(text)
        return record(ctx, q, text)
      end)
    end,
  }
  vim.list_extend(items, common.deny_items(ctx))
  return screen
end

local function summary_screen(ctx)
  local st = init(ctx.state)
  local qs = ctx.req.request.questions
  local header = { "Ответы на все вопросы:" }
  for i, q in ipairs(qs) do
    header[#header + 1] = ("%d. %s"):format(i, q.question)
    for _, l in ipairs(common.indented(tostring(st.answers[q.question]), "     ")) do
      header[#header + 1] = l
    end
  end
  local function submit()
    local out, why = decision.answer(raw_questions(ctx), st.answers)
    if not out then
      ctx.notify(
        "claudr: решение не собрано: " .. tostring(why),
        vim.log.levels.ERROR
      )
      return false
    end
    return ctx.decide(out)
  end
  local items = {
    { text = "подтвердить ответы (c)", run = submit },
  }
  for i, q in ipairs(qs) do
    items[#items + 1] = {
      text = ("изменить ответ на вопрос %d: %s"):format(
        i,
        (q.question:gsub("\n", " "))
      ),
      run = function()
        st.summary = false
        st.qi = i
        ctx.refresh(true)
      end,
    }
  end
  vim.list_extend(items, common.deny_items(ctx))
  return { header = header, items = items, footer = {}, confirm = submit }
end

---@param ctx table
function M.screen(ctx)
  local st = init(ctx.state)
  if #ctx.req.request.questions > 1 and st.summary then
    return summary_screen(ctx)
  end
  return question_screen(ctx)
end

return M
