-- Общие помощники тестов сообщений и запуска: подмена `vim.notify`, `vim.ui.input` и
-- `vim.ui.select` с очередями ответов, окружение на двойнике herdr (см. tests/tree/support.lua).
local t = require("helpers.t")
local s = require("tree.support")

local M = {}

M.tree = s

local saved

--- Подменяет `vim.notify`, `vim.ui.input`, `vim.ui.select`. Очереди ответов: `o.input` —
--- строки (`false` — отмена), `o.select` — номера или функции `items -> выбор` (`false` —
--- отмена). Возвращает запись обращений `{notes, inputs, selects}`; `M.restore()` возвращает
--- прежнее.
function M.stub(o)
  o = o or {}
  M.restore()
  saved = { notify = vim.notify, input = vim.ui.input, select = vim.ui.select }
  local rec = { notes = {}, inputs = {}, selects = {} }
  local inputs = vim.deepcopy(o.input or {})
  local selects = o.select or {}
  local sel_i = 0
  vim.notify = function(msg, level)
    rec.notes[#rec.notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
  end
  vim.ui.input = function(opts, cb)
    rec.inputs[#rec.inputs + 1] = opts
    local answer = table.remove(inputs, 1)
    if answer == false or answer == nil then
      cb(nil)
    else
      cb(answer)
    end
  end
  vim.ui.select = function(items, opts, cb)
    rec.selects[#rec.selects + 1] = { items = items, opts = opts }
    sel_i = sel_i + 1
    local pick = selects[sel_i]
    if pick == nil or pick == false then
      cb(nil, nil)
    elseif type(pick) == "function" then
      local choice = pick(items)
      cb(choice, choice and vim.fn.index(items, choice) + 1 or nil)
    else
      cb(items[pick], pick)
    end
  end
  return rec
end

function M.restore()
  if saved then
    vim.notify, vim.ui.input, vim.ui.select = saved.notify, saved.input, saved.select
    saved = nil
  end
end

--- Есть ли среди сообщений такое, что подходит под шаблон (опционально — с уровнем).
function M.noted(rec, pattern, level)
  for _, n in ipairs(rec.notes) do
    if n.msg:find(pattern) and (level == nil or n.level == level) then
      return true
    end
  end
  return false
end

--- Ждать сообщения по шаблону.
function M.wait_note(rec, pattern, msg)
  t.wait(function()
    return M.noted(rec, pattern)
  end, msg or ("сообщение " .. pattern))
end

--- Методы запросов двойника после первых `from` запросов, кроме перечитывания снимка
--- (его вызывают события herdr).
function M.methods_after(d, from)
  local out = {}
  for i = (from or 0) + 1, #d.requests do
    if d.requests[i].method ~= "session.snapshot" then
      out[#out + 1] = d.requests[i].method
    end
  end
  return out
end

--- Уборка после теста.
function M.reset()
  M.restore()
  s.reset()
end

return M
