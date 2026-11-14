-- Поддельный `claude` для тестов: запускается обёрткой fake_bin/claude как `nvim -l`.
-- Понимает ключи, которые передаёт плагин; пишет argv, cwd и stdin в журнал
-- (FAKE_CLAUDE_LOG), выдаёт кадры потока по сценарию (FAKE_CLAUDE_SCRIPT), дописывает
-- транскрипт сессии. Ожидание команды теста — блокирующее чтение именованного канала:
-- по событию, без опроса и сроков.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$")
package.path = here .. "/?.lua;" .. package.path
local frames = require("frames")

local NIL = vim.NIL

-- ключи с одним значением; остальные ключи, начинающиеся с «-», — флаги
local VALUE_FLAGS = {
  ["--session-id"] = "session_id",
  ["--resume"] = "resume",
  ["-r"] = "resume",
  ["--model"] = "model",
  ["--output-format"] = "output_format",
  ["--input-format"] = "input_format",
  ["--append-system-prompt"] = "append_system_prompt",
  ["--system-prompt"] = "system_prompt",
  ["--allowedTools"] = "allowed_tools",
  ["--allowed-tools"] = "allowed_tools",
  ["--disallowedTools"] = "disallowed_tools",
  ["--tools"] = "tools",
  ["--mcp-config"] = "mcp_config",
  ["--permission-mode"] = "permission_mode",
  ["--max-turns"] = "max_turns",
}
local BOOL_FLAGS = {
  ["-p"] = "print",
  ["--print"] = "print",
  ["--verbose"] = "verbose",
  ["--include-partial-messages"] = "include_partial_messages",
  ["--strict-mcp-config"] = "strict_mcp_config",
  ["--fork-session"] = "fork_session",
}

local function parse_args(argv)
  local p = { flags = {}, positional = {} }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, inline = a:match("^(%-%-[%w%-]+)=(.*)$")
    if key and VALUE_FLAGS[key] then
      p[VALUE_FLAGS[key]] = inline
    elseif VALUE_FLAGS[a] then
      p[VALUE_FLAGS[a]] = argv[i + 1]
      i = i + 1
    elseif BOOL_FLAGS[a] then
      p[BOOL_FLAGS[a]] = true
    elseif a:sub(1, 1) == "-" and a ~= "-" then
      p.flags[#p.flags + 1] = a -- неизвестный ключ: запоминается, ошибкой не считается
    else
      p.positional[#p.positional + 1] = a
    end
    i = i + 1
  end
  return p
end

local function log(rec)
  local path = vim.uv.os_getenv("FAKE_CLAUDE_LOG")
  if not path or path == "" then
    return
  end
  local f = assert(io.open(path, "a"))
  f:write(vim.json.encode(rec), "\n")
  f:close()
end

local argv = {}
for i = 1, #arg do
  argv[i] = arg[i]
end
local args = parse_args(argv)
local cwd = vim.uv.cwd()

-- вопрос: аргументом или из stdin
local question, stdin_text = nil, nil
if #args.positional > 0 then
  question = table.concat(args.positional, " ")
else
  stdin_text = io.stdin:read("*a")
  question = stdin_text
end

local session_id = args.session_id or args.resume
if not session_id then
  session_id = string.format("%08x-0000-4000-b000-%012x", vim.uv.os_getpid(), os.time())
end

log({
  event = "start",
  argv = argv,
  cwd = cwd,
  stdin = stdin_text or NIL,
  question = question,
  session_id = session_id,
  resume = args.resume or NIL,
  model = args.model or NIL,
})

local ctx = frames.context({
  session_id = session_id,
  cwd = cwd,
  model = args.model,
  mcp = args.mcp_config ~= nil,
})

-- ---------- транскрипт ----------
local function config_dir()
  local dir = vim.uv.os_getenv("CLAUDE_CONFIG_DIR")
  if dir and dir ~= "" then
    return dir
  end
  return vim.uv.os_getenv("HOME") .. "/.claude"
end

local transcript_path =
  string.format("%s/projects/%s/%s.jsonl", config_dir(), (cwd:gsub("[/%.]", "-")), session_id)

local function last_uuid()
  local f = io.open(transcript_path, "r")
  if not f then
    return NIL
  end
  local found = NIL
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" and rec.uuid then
      found = rec.uuid
    end
  end
  f:close()
  return found
end

local function append_transcript(recs)
  vim.fn.mkdir(vim.fs.dirname(transcript_path), "p")
  local f = assert(io.open(transcript_path, "a"))
  for _, r in ipairs(recs) do
    f:write(vim.json.encode(r), "\n")
  end
  f:close()
end

local envelope = function()
  return {
    userType = "external",
    entrypoint = "sdk-cli",
    cwd = cwd,
    sessionId = session_id,
    version = "2.1.325",
    gitBranch = "HEAD",
  }
end

local user_uuid
local function transcript_user()
  local ts = frames.now()
  user_uuid = frames.uuid(ctx)
  local rec = {
    parentUuid = last_uuid(),
    isSidechain = false,
    promptId = frames.uuid(ctx),
    type = "user",
    message = { role = "user", content = question },
    uuid = user_uuid,
    timestamp = ts,
    permissionMode = "default",
    promptSource = "sdk",
    turnOrigin = "sdk",
  }
  for k, v in pairs(envelope()) do
    rec[k] = v
  end
  append_transcript({
    {
      type = "queue-operation",
      operation = "enqueue",
      timestamp = ts,
      sessionId = session_id,
      content = question,
    },
    { type = "queue-operation", operation = "dequeue", timestamp = ts, sessionId = session_id },
    rec,
  })
end

local function transcript_assistant(text)
  local rec = {
    parentUuid = user_uuid or last_uuid(),
    isSidechain = false,
    message = {
      model = ctx.model,
      id = string.format("msg_01Fixture%017d", vim.uv.os_getpid() % 100000 * 100 + 99),
      type = "message",
      role = "assistant",
      content = { { type = "text", text = text } },
      container = NIL,
      stop_reason = "end_turn",
      stop_sequence = NIL,
      stop_details = NIL,
      input_transformations = {},
      diagnostics = NIL,
      context_management = NIL,
    },
    requestId = "req_01Fixture" .. string.format("%017d", vim.uv.os_getpid()),
    type = "assistant",
    uuid = frames.uuid(ctx),
    timestamp = frames.now(),
    madeBy = "model",
  }
  for k, v in pairs(envelope()) do
    rec[k] = v
  end
  append_transcript({ rec })
end

-- ---------- вывод ----------
local out_format = args.output_format or "text"

local function emit(frame)
  if out_format == "stream-json" then
    io.stdout:write(vim.json.encode(frame), "\n")
  elseif out_format == "json" then
    if frame.type == "result" then
      io.stdout:write(vim.json.encode(frame), "\n")
    end
  elseif frame.type == "result" then
    io.stdout:write(frame.result, "\n")
  end
  io.stdout:flush()
end

local function emit_all(list)
  for _, f in ipairs(list) do
    emit(f)
  end
end

local function finish(code)
  io.stdout:flush()
  log({ event = "exit", code = code, session_id = session_id })
  os.exit(code)
end

-- ---------- сценарий ----------
local DEFAULT_PARTS = { "Функция ", "вызывается ", "из ", "`lua/foo.lua:42`." }

local function default_script()
  return {
    "transcript-user",
    "init",
    "tool " .. vim.json.encode({
      name = "Read",
      input = { file_path = "lua/foo.lua" },
      result = "local M = {}",
    }),
    "text " .. vim.json.encode(DEFAULT_PARTS),
    "transcript-assistant " .. table.concat(DEFAULT_PARTS),
    "result " .. vim.json.encode(table.concat(DEFAULT_PARTS)),
  }
end

local function read_script()
  local path = vim.uv.os_getenv("FAKE_CLAUDE_SCRIPT")
  if not path or path == "" then
    return default_script()
  end
  local lines = {}
  local f = assert(io.open(path, "r"))
  for line in f:lines() do
    if line:match("%S") and not line:match("^%s*#") then
      lines[#lines + 1] = line
    end
  end
  f:close()
  return lines
end

local function run_line(line)
  if line:sub(1, 1) == "{" then
    io.stdout:write(line, "\n") -- кадр как есть
    io.stdout:flush()
    return
  end
  local cmd, rest = line:match("^(%S+)%s*(.*)$")
  if cmd == "init" then
    emit(frames.init(ctx))
  elseif cmd == "status" then
    emit(frames.status(ctx))
  elseif cmd == "text" then
    emit(frames.status(ctx))
    emit_all(frames.text_message(ctx, vim.json.decode(rest)))
  elseif cmd == "tool" then
    local spec = vim.json.decode(rest)
    emit(frames.status(ctx))
    emit_all(frames.tool_message(ctx, spec.name, spec.input, spec.result))
    emit(frames.rate_limit(ctx))
  elseif cmd == "result" then
    emit(frames.result(ctx, vim.json.decode(rest)))
  elseif cmd == "result-error" then
    emit(frames.result(ctx, vim.json.decode(rest), { is_error = true }))
  elseif cmd == "wait" then
    -- блокирующее чтение одной строки из именованного канала: возобновление по команде теста
    local fifo = assert(io.open(rest, "r"))
    fifo:read("*l")
    fifo:close()
  elseif cmd == "stderr" then
    io.stderr:write(rest, "\n")
    io.stderr:flush()
  elseif cmd == "transcript-user" then
    transcript_user()
  elseif cmd == "transcript-assistant" then
    transcript_assistant(rest)
  elseif cmd == "exit" then
    finish(tonumber(rest) or 0)
  else
    io.stderr:write(
      "fake claude: неизвестная директива сценария: " .. line .. "\n"
    )
    finish(2)
  end
end

for _, line in ipairs(read_script()) do
  run_line(line)
end
finish(0)
