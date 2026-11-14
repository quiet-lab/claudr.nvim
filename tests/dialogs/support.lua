-- Помощники тестов буфера диалога: заглушка перечня запросов, нажатия клавиш, поиск пунктов.
local t = require("helpers.t")
local samples = require("helpers.hook_samples")
local stub_mod = require("helpers.pending_stub")
local ms = require("messaging.support")

local M = {}

M.ms = ms
M.pane = "w1:p1"

--- Ставит заглушку перечня и подмену `vim.notify`/`vim.ui.*`; возвращает заглушку и запись
--- обращений.
---@param o table|nil параметры `ms.stub`
function M.setup(o)
  local pending = stub_mod.install()
  local rec = ms.stub(o)
  return pending, rec
end

--- Уборка после теста.
function M.reset()
  local ok, buffer = pcall(require, "claudr.dialogs.buffer")
  if ok then
    buffer.close()
  end
  require("claudr.view.window").close_all()
  ms.reset()
  stub_mod.uninstall()
  local nok, notify = pcall(require, "claudr.dialogs.notify")
  if nok then
    notify.stop()
  end
end

--- Запрос в заглушке по образцу входа хука.
function M.add(pending, sample, pane_id)
  return pending.add(samples.input(sample), pane_id or M.pane)
end

--- Строки текущего буфера диалога.
function M.lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- Весь текст текущего буфера.
function M.text()
  return table.concat(M.lines(), "\n")
end

--- Номер строки по шаблону (первая подходящая).
function M.line_of(pattern)
  for i, l in ipairs(M.lines()) do
    if l:find(pattern) then
      return i
    end
  end
end

--- Ставит курсор на строку по шаблону.
function M.goto_line(pattern)
  local row = M.line_of(pattern)
  t.ok(row, "нет строки " .. pattern .. " в буфере:\n" .. M.text())
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  return row
end

--- Нажатие клавиш в нормальном режиме (с отображениями).
function M.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

--- Enter на пункте по шаблону.
function M.choose(pattern)
  M.goto_line(pattern)
  M.press("<CR>")
end

--- Вывод решения заглушки (последнее) — `decision` хука.
function M.last_decision(pending)
  local d = pending.decided[#pending.decided]
  return d and d.output.hookSpecificOutput.decision, d
end

return M
