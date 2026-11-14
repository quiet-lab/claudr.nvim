-- Помощник теста для поддельного `claude` (tests/helpers/fake_bin/claude): сценарии, точки
-- остановки, журнал. Поддельный `claude` лежит в PATH первым (bootstrap); тест задаёт ему
-- окружение через `fake.env(...)` и передаёт его процессу, который запускает плагин
-- (в самом Neovim — `vim.uv.os_setenv` через `fake.apply(...)`).
--
-- API:
--   fake.setup(dir) -> ctl       каталог управления: журнал `<dir>/claude.log`, сценарии
--   ctl.log_path, ctl.script_path
--   ctl:script(steps)            записать сценарий и выбрать его (FAKE_CLAUDE_SCRIPT)
--   ctl:default_script()         вернуть сценарий по умолчанию
--   ctl:gate(name) -> gate       именованный канал точки остановки; в сценарии шаг {"wait", gate}
--   gate:release()               возобновить процесс, ждущий в этой точке
--   gate:close()                 закрыть канал
--   ctl:log() -> список записей  журнал: {event="start", argv, cwd, stdin, question, …}, {event="exit", code}
--   ctl:starts()                 только записи start
--   ctl:env() -> таблица         переменные окружения для vim.system / jobstart
--   ctl:apply()                  задать переменные в окружении Neovim
--   fake.default_parts           приращения текста ответа по умолчанию
--
-- Шаги сценария (таблицы): {"transcript_user"}, {"init"}, {"tool", name, input, result},
-- {"text", {части}}, {"transcript_assistant", text}, {"result", text}, {"result_error", text},
-- {"wait", gate}, {"stderr", text}, {"exit", code}, {"raw", строка или таблица}.
local M = {}

M.default_parts = { "Функция ", "вызывается ", "из ", "`lua/foo.lua:42`." }

local function step_line(step)
  local cmd = step[1]
  if cmd == "raw" then
    local v = step[2]
    return type(v) == "string" and v or vim.json.encode(v)
  elseif cmd == "tool" then
    return "tool "
      .. vim.json.encode({
        name = step[2],
        input = step[3] or vim.empty_dict(),
        result = step[4] or "",
      })
  elseif cmd == "text" then
    return "text " .. vim.json.encode(step[2])
  elseif cmd == "result" then
    return "result " .. vim.json.encode(step[2])
  elseif cmd == "result_error" then
    return "result-error " .. vim.json.encode(step[2])
  elseif cmd == "wait" then
    return "wait " .. (type(step[2]) == "table" and step[2].path or step[2])
  elseif cmd == "stderr" then
    return "stderr " .. step[2]
  elseif cmd == "exit" then
    return "exit " .. tostring(step[2])
  elseif cmd == "transcript_user" then
    return "transcript-user"
  elseif cmd == "transcript_assistant" then
    return "transcript-assistant " .. step[2]
  elseif cmd == "init" then
    return "init"
  end
  error("неизвестный шаг сценария: " .. tostring(cmd))
end

local Ctl = {}
Ctl.__index = Ctl

function M.setup(dir)
  vim.fn.mkdir(dir, "p")
  local ctl = setmetatable({
    dir = dir,
    log_path = dir .. "/claude.log",
    script_path = dir .. "/script.txt",
    _gates = {},
    _script = false,
  }, Ctl)
  local f = assert(io.open(ctl.log_path, "w"))
  f:close()
  return ctl
end

function Ctl:script(steps)
  local lines = {}
  for _, step in ipairs(steps) do
    lines[#lines + 1] = step_line(step)
  end
  local f = assert(io.open(self.script_path, "w"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  self._script = true
  return self.script_path
end

function Ctl:default_script()
  self._script = false
end

--- Именованный канал точки остановки. Канал открывается на чтение и запись и держится
--- открытым, поэтому `release` не блокируется и команда не теряется, даже если процесс
--- дойдёт до точки позже.
function Ctl:gate(name)
  local path = self.dir .. "/" .. name .. ".fifo"
  local res = vim.system({ "mkfifo", path }):wait()
  assert(res.code == 0, "mkfifo: " .. (res.stderr or ""))
  local fd = assert(vim.uv.fs_open(path, "r+", 438))
  local gate = { path = path }
  function gate:release()
    assert(vim.uv.fs_write(fd, "go\n"))
  end
  function gate:close()
    if fd then
      vim.uv.fs_close(fd)
      fd = nil
    end
    vim.uv.fs_unlink(path)
  end
  self._gates[#self._gates + 1] = gate
  return gate
end

function Ctl:close()
  for _, g in ipairs(self._gates) do
    g:close()
  end
  self._gates = {}
end

function Ctl:log()
  local out = {}
  local f = io.open(self.log_path, "r")
  if not f then
    return out
  end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line)
    if ok then
      out[#out + 1] = rec
    end
  end
  f:close()
  return out
end

function Ctl:starts()
  local out = {}
  for _, rec in ipairs(self:log()) do
    if rec.event == "start" then
      out[#out + 1] = rec
    end
  end
  return out
end

function Ctl:env()
  local env = { FAKE_CLAUDE_LOG = self.log_path }
  if self._script then
    env.FAKE_CLAUDE_SCRIPT = self.script_path
  end
  return env
end

function Ctl:apply()
  vim.uv.os_setenv("FAKE_CLAUDE_LOG", self.log_path)
  if self._script then
    vim.uv.os_setenv("FAKE_CLAUDE_SCRIPT", self.script_path)
  else
    vim.uv.os_unsetenv("FAKE_CLAUDE_SCRIPT")
  end
end

return M
