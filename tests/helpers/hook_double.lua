-- Двойник хука: отдельный процесс (`nvim --clean -l tests/helpers/hook_double_proc.lua`),
-- который соединяется с сокетом плагина, шлёт кадр `request` и читает кадры. Управление —
-- по событиям: строки JSON через stdin/stdout процесса и его выход, без опроса и сна.
local t = require("helpers.t")

local M = {}
local H = {}
H.__index = H

local handles = {}

--- Запускает двойника. `opts`: `socket` (путь), `input` (вход хука, таблица), `env`
--- (`HERDR_PANE_ID`, `HERDR_SOCKET_PATH`; отсутствующая переменная — ключа нет),
--- `silent` — соединиться и не слать кадр `request`.
--- Поля объекта: `frames` (принятые кадры), `bad_lines` (строки, не ставшие кадрами),
--- `connected`, `connect_error`, `closed_by_peer`, `exited`, `code`, `signal`, `stderr`.
function M.spawn(opts)
  local h = setmetatable({
    frames = {},
    bad_lines = {},
    connected = false,
    closed_by_peer = false,
    exited = false,
    stderr = "",
  }, H)
  local request
  if not opts.silent then
    request = vim.json.encode({
      type = "request",
      version = 1,
      input = opts.input == nil and vim.empty_dict() or opts.input,
      env = vim.tbl_isempty(opts.env or {}) and vim.empty_dict() or opts.env,
    })
  end
  local buf = ""
  h.proc = vim.system({
    vim.v.progpath,
    "--clean",
    "-u",
    "NONE",
    "-l",
    t.root .. "/tests/helpers/hook_double_proc.lua",
  }, {
    stdin = true,
    stdout = function(_, chunk)
      if not chunk then
        return
      end
      buf = buf .. chunk
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" then
          if ev.ev == "frame" then
            table.insert(h.frames, ev.frame)
          elseif ev.ev == "bad" then
            table.insert(h.bad_lines, ev.line)
          elseif ev.ev == "connected" then
            h.connected = true
          elseif ev.ev == "error" then
            h.connect_error = ev.message
          elseif ev.ev == "closed" then
            h.closed_by_peer = true
          end
        end
      end
    end,
    stderr = function(_, chunk)
      if chunk then
        h.stderr = h.stderr .. chunk
      end
    end,
  }, function(res)
    h.code = res.code
    h.signal = res.signal
    h.exited = true
  end)
  table.insert(handles, h)
  h:_send({ cmd = "start", socket = opts.socket, request = request or vim.NIL })
  return h
end

function H:_send(cmd)
  if not self.exited then
    pcall(self.proc.write, self.proc, vim.json.encode(cmd) .. "\n")
  end
end

--- Ждёт соединения с сокетом (или ошибки соединения).
function H:wait_connected()
  t.wait(function()
    return self.connected or self.connect_error ~= nil
  end, "двойник хука: соединение")
  return self.connected
end

--- Ждёт, пока придёт `n`-й кадр (по умолчанию первый) или плагин закроет соединение;
--- возвращает этот кадр либо `nil`, если соединение закрыто раньше.
function H:wait_frame(n)
  n = n or 1
  t.wait(function()
    return #self.frames >= n or self.closed_by_peer
  end, "двойник хука: кадр " .. n)
  return self.frames[n]
end

--- Ждёт, пока плагин закроет соединение.
function H:wait_closed()
  t.wait(function()
    return self.closed_by_peer
  end, "двойник хука: закрытие плагином")
end

--- Посылает кадр `answered` и закрывает соединение.
function H:answered()
  self:_send({ cmd = "answered" })
end

--- Закрывает соединение без кадра (как хук, завершённый по сигналу).
function H:close()
  self:_send({ cmd = "close" })
end

--- Посылает процессу SIGTERM.
function H:term()
  if not self.exited then
    self.proc:kill(15)
  end
end

--- Ждёт выхода процесса; возвращает код выхода.
function H:wait_exit()
  t.wait(function()
    return self.exited
  end, "двойник хука: выход процесса")
  return self.code
end

--- Останавливает всех двойников этого теста, ещё не вышедших (для `after_each`).
function M.stop_all()
  for _, h in ipairs(handles) do
    if not h.exited then
      h:term()
      h:wait_exit()
    end
  end
  handles = {}
end

return M
