-- Процесс двойника хука: `nvim --clean -l tests/helpers/hook_double_proc.lua`.
-- Управляется родителем строками JSON через stdin, события пишет строками JSON в stdout.
--
-- Команды родителя (stdin):
--   {"cmd":"start","socket":"<путь>","request":"<строка кадра request>"|null}
--       соединиться с сокетом и, если `request` задан, послать его строкой;
--   {"cmd":"answered"}  послать кадр `answered` и закрыть соединение;
--   {"cmd":"close"}     закрыть соединение без кадра.
-- События (stdout): {"ev":"connected"}, {"ev":"error","message":…},
--   {"ev":"frame","frame":<таблица>}, {"ev":"bad","line":<строка>}, {"ev":"closed"}
--   (соединение закрыл плагин).
-- SIGTERM и конец stdin завершают процесс кодом 0 (SIGTERM — через автокоманду VimLeave).
local uv = vim.uv

local function emit(ev)
  io.stdout:write(vim.json.encode(ev) .. "\n")
  io.stdout:flush()
end

local conn
local finished = false

local function close_conn()
  if conn and not conn:is_closing() then
    conn:close()
  end
end

local function finish()
  finished = true
end

local function on_peer_data(err, chunk, state)
  if err or not chunk then
    if not state.mine then
      emit({ ev = "closed" })
    end
    close_conn()
    return
  end
  state.buf = state.buf .. chunk
  while true do
    local nl = state.buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = state.buf:sub(1, nl - 1)
    state.buf = state.buf:sub(nl + 1)
    local ok, frame = pcall(vim.json.decode, line)
    if ok and type(frame) == "table" then
      emit({ ev = "frame", frame = frame })
    else
      emit({ ev = "bad", line = line })
    end
  end
end

local state = { buf = "", mine = false }

local function start(cmd)
  conn = uv.new_pipe(false)
  conn:connect(cmd.socket, function(err)
    if err then
      emit({ ev = "error", message = err })
      close_conn()
      return
    end
    conn:read_start(function(rerr, chunk)
      on_peer_data(rerr, chunk, state)
    end)
    if cmd.request and cmd.request ~= vim.NIL then
      conn:write(cmd.request .. "\n")
    end
    emit({ ev = "connected" })
  end)
end

local function handle(cmd)
  if cmd.cmd == "start" then
    start(cmd)
  elseif cmd.cmd == "answered" then
    if conn and not conn:is_closing() then
      state.mine = true
      conn:write('{"type":"answered"}\n', function()
        close_conn()
      end)
    end
  elseif cmd.cmd == "close" then
    state.mine = true
    close_conn()
  end
end

-- Neovim сам перехватывает SIGTERM и выходит с кодом 1 после автокоманд VimLeave; хук
-- завершается по сигналу кодом 0, поэтому код выхода в этой автокоманде подменяется
-- (`_exit` закрывает и соединение).
local ffi = require("ffi")
ffi.cdef("void _exit(int status);")
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function()
    io.stdout:flush()
    ffi.C._exit(0)
  end,
})

local stdin = uv.new_pipe(false)
stdin:open(0)
local ibuf = ""
stdin:read_start(function(err, chunk)
  if err or not chunk then
    finish()
    return
  end
  ibuf = ibuf .. chunk
  while true do
    local nl = ibuf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = ibuf:sub(1, nl - 1)
    ibuf = ibuf:sub(nl + 1)
    local ok, cmd = pcall(vim.json.decode, line)
    if ok and type(cmd) == "table" then
      handle(cmd)
    end
  end
end)

vim.wait(2 ^ 31 - 1, function()
  return finished
end)
close_conn()
os.exit(0)
