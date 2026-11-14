-- Помощники тестов видов узлов: окружение дерева (двойник herdr, образцы, модель), ожидание
-- текста в буфере, учёт своих процессов поддельного `herdr`.
local t = require("helpers.t")
local ts = require("tree.support")
local view = require("claudr.view")

local M = setmetatable({}, { __index = ts })

-- виды теста с процессами поддельного `herdr`
M.procs = {}

function M.track(v)
  if v and v.pid then
    M.procs[#M.procs + 1] = v
  end
  return v
end

function M.alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

--- Ждать выхода процесса вида `v` (событие выхода `vim.system`/`jobstart`).
function M.wait_exit(v, msg)
  t.wait(function()
    return v.exited ~= nil
  end, msg or ("выход процесса " .. tostring(v.pid)))
end

--- Уборка после теста: виды, модель, клиент, двойник; затем проверка, что своих живых
--- процессов не осталось.
function M.reset()
  -- Сначала цикл обрабатывает уже пришедшие события (вывод терминала вида подключения
  -- с вводом): если закрыть терминал с необработанным выводом, ожидание выхода его
  -- процесса зацикливает обработку очереди событий в `vim.wait` и не завершается.
  ts.settle()
  view.close_all()
  ts.reset()
  for _, v in ipairs(M.procs) do
    M.wait_exit(v)
    t.ok(not M.alive(v.pid), "процесс поддельного herdr " .. v.pid .. " жив")
  end
  M.procs = {}
end

--- Текст буфера одной строкой (строки через перевод строки).
function M.text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Ждать, пока в буфере не появится `needle` (простой текст).
function M.wait_text(buf, needle, msg)
  t.wait(function()
    return vim.api.nvim_buf_is_valid(buf) and M.text(buf):find(needle, 1, true) ~= nil
  end, msg or ("текст «" .. needle .. "» в буфере"))
end

--- Подменяет `vim.ui.select`: записывает вызовы, отвечает `answer(items)`.
function M.stub_select(answer)
  local orig = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, on_choice)
    calls[#calls + 1] = { items = items, opts = opts }
    on_choice(answer and answer(items) or nil)
  end
  calls.restore = function()
    vim.ui.select = orig
  end
  return calls
end

--- Подменяет `vim.notify`: записывает сообщения.
function M.stub_notify()
  local orig = vim.notify
  local msgs = {}
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg = msg, level = level }
  end
  msgs.restore = function()
    vim.notify = orig
  end
  function msgs.has(needle)
    for _, m in ipairs(msgs) do
      if tostring(m.msg):find(needle, 1, true) then
        return true
      end
    end
    return false
  end
  return msgs
end

--- Просторный редактор, чтобы окна видов не урезались.
function M.big_editor()
  vim.o.columns = 200
  vim.o.lines = 60
end

return M
