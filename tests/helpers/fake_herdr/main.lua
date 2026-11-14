-- Поддельный `herdr` для тестов, запускается сценарием tests/helpers/fake_bin/herdr через
-- `nvim -l`. Поддерживает:
--   terminal session observe <цель>   — поток кадров `terminal.frame` (JSON по строке);
--   terminal attach [--takeover] <id> — подключение с вводом в псевдотерминале.
-- Каталог управления — `$FAKE_HERDR_DIR`, без неё — `fake_herdr/` рядом с сокетом из
-- `HERDR_SOCKET_PATH` (его создаёт двойник сервера). Каждый вызов дописывает свои аргументы
-- в `calls.jsonl`. Все ожидания — по событиям `vim.uv` (файловая система, ввод, сигналы),
-- таймеров и опроса нет.
local uv = vim.uv

-- Завершение по сигналу. Neovim с самого запуска сам перехватывает SIGTERM и SIGHUP и ставит
-- их в свою очередь событий; сигнал, пришедший до установки обработчиков ниже, попадает только
-- туда. Поэтому обработчики ставятся первой же строкой и завершают процесс прямо из обратного
-- вызова, раньше, чем Neovim обработает свою копию сигнала; сигнал, опередивший обработчики,
-- Neovim обрабатывает сам (пишет в stderr «Caught deadly signal», выставляет `v:dying`)
-- и вызывает VimLeavePre, где процесс завершается кодом SIGTERM (так же и опередивший SIGHUP).
-- Выход по ошибке сценария `v:dying` не выставляет и свой код сохраняет. Цикл ожидания внизу —
-- `vim.wait`: он обрабатывает очередь Neovim, а `uv.run` её не обрабатывает, и такой сигнал
-- терялся.
local cleanups = {}
local function terminate(code)
  for _, fn in ipairs(cleanups) do
    pcall(fn)
  end
  os.exit(code)
end
local SIGNAL_CODES = { sigterm = 143, sigint = 130, sighup = 129 }
for sig, code in pairs(SIGNAL_CODES) do
  uv.new_signal():start(sig, function()
    terminate(code)
  end)
end
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if vim.v.dying > 0 then
      terminate(SIGNAL_CODES.sigterm)
    end
  end,
})
local here = vim.fn.fnamemodify(arg[0], ":p:h")
package.path = here .. "/../../?.lua;" .. package.path
local json = require("helpers.herdr_double.json")

local args = {}
for i = 1, #arg do
  args[i] = arg[i]
end

local function die(msg, code)
  io.stderr:write(msg .. "\n")
  io.stderr:flush()
  os.exit(code)
end

local ctl = os.getenv("FAKE_HERDR_DIR")
if not ctl or ctl == "" then
  local sock = os.getenv("HERDR_SOCKET_PATH")
  if not sock or sock == "" then
    die("fake herdr: не задан HERDR_SOCKET_PATH", 2)
  end
  ctl = vim.fn.fnamemodify(sock, ":h") .. "/fake_herdr"
end
vim.fn.mkdir(ctl .. "/observe", "p")
vim.fn.mkdir(ctl .. "/attach", "p")

local pid = uv.os_getpid()

local function append(path, s)
  local f = assert(io.open(path, "ab"))
  f:write(s)
  f:close()
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function out(s)
  io.stdout:write(s)
  io.stdout:flush()
end

local function safe_name(s)
  return (tostring(s):gsub("[^%w%-_.:]", "_"))
end

append(ctl .. "/calls.jsonl", json.encode({ argv = args, pid = pid }) .. "\n")

-- Цикл событий: выполняется до вызова finish() или сигнала; выход процесса — после цикла.
local exit_code
local function finish(code)
  if exit_code == nil then
    exit_code = code
  end
end

-- terminal session observe ---------------------------------------------------------------

local function observe(target)
  if not target then
    die("fake herdr: не указана цель наблюдения", 2)
  end
  local path = ctl .. "/observe/" .. safe_name(target) .. ".frames"
  append(path, "")
  local offset, buf, seq = 0, "", 0

  -- Чтение дописанного с запомненного смещения и печать полных строк кадрами.
  local function drain()
    local fd = uv.fs_open(path, "r", 0)
    if not fd then
      return
    end
    local stat = uv.fs_fstat(fd)
    if stat and stat.size > offset then
      local data = uv.fs_read(fd, stat.size - offset, offset) or ""
      offset = offset + #data
      buf = buf .. data
    end
    uv.fs_close(fd)
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      if line ~= "" then
        local rec = vim.json.decode(line)
        seq = seq + 1
        out(json.encode({
          bytes = rec.bytes,
          encoding = "ansi",
          full = rec.full,
          height = rec.height,
          seq = seq,
          type = "terminal.frame",
          width = rec.width,
        }) .. "\n")
      end
    end
  end

  local watcher = uv.new_fs_event()
  watcher:start(path, {}, function()
    drain()
  end)
  drain()
  -- Как настоящий клиент: ввод не читается, сам процесс не завершается, только по сигналу.
end

-- terminal attach ------------------------------------------------------------------------

-- Перевод строки печатается как "\n": псевдотерминал с включённым onlcr (по умолчанию)
-- отдаёт читателю "\r\n", как в выводе настоящего клиента.
local ENTER = "\27[?1049h\27[?25l"
local LEAVE = "\27[?1049l\27[?25h"

local function pid_alive(s)
  local n = tonumber(s)
  if not n then
    return true -- "external": занят клиентом, которого пометил тест
  end
  return uv.kill(n, 0) == 0
end

local function attach(rest)
  local takeover, tid = false, nil
  for _, a in ipairs(rest) do
    if a == "--takeover" then
      takeover = true
    else
      tid = a
    end
  end
  if not tid then
    die("fake herdr: не указан terminal_id", 2)
  end

  local out_tty = uv.guess_handle(1) == "tty" and uv.new_tty(1, false)
  local width, height
  if out_tty then
    width, height = out_tty:get_winsize()
  end
  if not out_tty or not width or width == 0 or height == 0 then
    die("Error: Custom { kind: InvalidData, error: ZeroSizedGridError }", 1)
  end

  local dir = ctl .. "/attach"
  local busy = dir .. "/" .. safe_name(tid) .. ".busy"
  local me = tostring(pid)

  local holder = read(busy)
  if holder and holder ~= "" and pid_alive(holder) and not takeover then
    out(ENTER .. LEAVE)
    out(
      "herdr: server shut down: terminal attach failed: terminal "
        .. tid
        .. " already has an attached client; retry with --takeover\n"
    )
    finish(1)
    return
  end

  local function release_marker()
    if read(busy) == me then
      os.remove(busy)
    end
  end
  table.insert(cleanups, release_marker)

  -- Вытеснение: другой процесс записал в отметку себя.
  local watcher = uv.new_fs_event()
  watcher:start(dir, {}, function(_, fname)
    if exit_code ~= nil or fname ~= safe_name(tid) .. ".busy" then
      return
    end
    local h = read(busy)
    if h and h ~= "" and h ~= me then
      out(LEAVE .. "herdr: server shut down: terminal attach taken over\n")
      finish(1)
    end
  end)

  local tmp = busy .. "." .. me .. ".new"
  local f = assert(io.open(tmp, "wb"))
  f:write(me)
  f:close()
  assert(os.rename(tmp, busy))

  local input_path = dir .. "/" .. safe_name(tid) .. ".input"
  local tin = uv.new_tty(0, true)
  tin:set_mode(1)
  table.insert(cleanups, function()
    uv.tty_reset_mode()
  end)
  -- Экран рисуется после перевода ввода в сырой режим: увидев экран, тест может слать клавиши.
  local screen = read(dir .. "/" .. safe_name(tid) .. ".screen")
    or ("fake herdr: terminal " .. tid .. "\n")
  out(ENTER .. "\27[2J\27[1;1H" .. screen:gsub("\r\n", "\n") .. "\27[?25h")

  local prefix = false
  tin:read_start(function(err, data)
    if exit_code ~= nil then
      return
    end
    if err or not data then
      finish(0)
      return
    end
    local got = {}
    for i = 1, #data do
      local b = data:byte(i)
      if prefix then
        prefix = false
        if b == 0x71 then -- Ctrl+b q — отключение
          append(input_path, table.concat(got))
          out(LEAVE)
          finish(0)
          return
        elseif b == 0x02 then -- Ctrl+b Ctrl+b — литеральный Ctrl+b
          table.insert(got, "\2")
        end
        -- Прочие сочетания с префиксом поддельный клиент не поддерживает и отбрасывает.
      elseif b == 0x02 then
        prefix = true
      else
        table.insert(got, string.char(b))
      end
    end
    append(input_path, table.concat(got))
  end)
end

-- Разбор подкоманды ----------------------------------------------------------------------

if args[1] == "terminal" and args[2] == "session" and args[3] == "observe" then
  -- `--cols N` и `--rows N` (размер клиента наблюдения) перед целью; кадры тестов несут свой размер
  local i = 4
  while args[i] == "--cols" or args[i] == "--rows" do
    i = i + 2
  end
  observe(args[i])
elseif args[1] == "terminal" and args[2] == "attach" then
  attach(vim.list_slice(args, 3))
else
  die(
    "fake herdr: подкоманда не поддерживается: "
      .. table.concat(args, " "),
    2
  )
end

vim.wait(math.huge, function()
  return exit_code ~= nil
end)
terminate(exit_code)
