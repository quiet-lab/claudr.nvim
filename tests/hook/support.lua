-- Запуск настоящего сценария хука отдельным процессом так, как его запускает Claude Code:
-- команда и аргументы из `claude-plugin/hooks/hooks.json` с подстановкой
-- `${CLAUDE_PLUGIN_ROOT}`, вход — на stdin, окружение теста. Ожидание — по выходу процесса.
local t = require("helpers.t")

local uv = vim.uv
local M = {}

M.plugin_root = t.root .. "/claude-plugin"

--- Описание хуков плагина Claude Code (разобранный `hooks.json`).
function M.hooks_config()
  local fd = assert(io.open(M.plugin_root .. "/hooks/hooks.json", "r"))
  local text = fd:read("a")
  fd:close()
  return vim.json.decode(text)
end

--- Команда хука `PermissionRequest`: исполняемый файл и аргументы после подстановки.
function M.hook_argv()
  local handler = M.hooks_config().hooks.PermissionRequest[1].hooks[1]
  local args = {}
  for _, a in ipairs(handler.args or {}) do
    table.insert(args, (a:gsub("%${CLAUDE_PLUGIN_ROOT}", M.plugin_root)))
  end
  return handler.command, args
end

--- Каталог времени выполнения теста (`XDG_RUNTIME_DIR` процесса хука), права 0700.
function M.runtime_dir()
  local dir = t.tmpdir() .. "/run"
  if not uv.fs_stat(dir) then
    assert(uv.fs_mkdir(dir, tonumber("700", 8)))
  end
  return dir
end

--- Каталог сокетов по правилу плагина.
function M.socket_dir()
  return M.runtime_dir() .. "/claudr"
end

--- Вход хука PermissionRequest для Bash (обезличенный образец).
function M.sample_input()
  return {
    session_id = "00000000-0000-4000-8000-000000000001",
    transcript_path = "/project/.claude/transcript.jsonl",
    cwd = "/project",
    prompt_id = "00000000-0000-4000-8000-000000000002",
    permission_mode = "default",
    hook_event_name = "PermissionRequest",
    tool_name = "Bash",
    tool_input = {
      command = "ls -la",
      description = "Список файлов",
      extra = vim.empty_dict(),
    },
    permission_suggestions = {
      {
        type = "addRules",
        rules = { { toolName = "Bash", ruleContent = "ls -la" } },
        behavior = "allow",
        destination = "localSettings",
      },
    },
  }
end

--- Перечень всех путей под каталогом теста (для проверки, что хук не создал файлов).
function M.snapshot()
  local list = {}
  local function walk(dir)
    local handle = uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local path = dir .. "/" .. name
      table.insert(list, path)
      if kind == "directory" then
        walk(path)
      end
    end
  end
  walk(t.tmpdir())
  table.sort(list)
  return list
end

--- Запускает хук. `opts.input` — таблица входа (кодируется в JSON) или `opts.stdin` — текст
--- как есть; `opts.env` — дополнительные переменные (значение `false` убирает переменную).
--- Возвращает объект `h`: `h.stdout`, `h.stderr`, `h.exited`, `h.code`, `h.signal`,
--- `h:term()`, `h:wait_exit()`.
function M.spawn(opts)
  opts = opts or {}
  local env = vim.fn.environ()
  env.XDG_RUNTIME_DIR = M.runtime_dir()
  -- Процесс теста получил от Neovim журнал и адрес своего сервера; Claude Code, запущенный
  -- в панели herdr, их не передаёт.
  env.NVIM_LOG_FILE = nil
  env.NVIM = nil
  for k, v in pairs(opts.env or {}) do
    env[k] = v or nil
  end
  local env_list = {}
  for k, v in pairs(env) do
    table.insert(env_list, k .. "=" .. v)
  end

  local h = { stdout = "", stderr = "", exited = false }
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local open_streams = 2
  local proc_done = false
  local function finish()
    if proc_done and open_streams == 0 then
      h.exited = true
    end
  end
  local cmd, args = M.hook_argv()
  local proc, pid = uv.spawn(cmd, {
    args = args,
    env = env_list,
    cwd = t.tmpdir(),
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    h.code, h.signal = code, signal
    proc_done = true
    finish()
  end)
  assert(proc, pid)
  h.proc, h.pid = proc, pid
  local function reader(pipe, key)
    pipe:read_start(function(err, data)
      if data then
        h[key] = h[key] .. data
      else
        pipe:close()
        open_streams = open_streams - 1
        finish()
      end
      assert(not err, err)
    end)
  end
  reader(stdout, "stdout")
  reader(stderr, "stderr")
  local text = opts.stdin or vim.json.encode(opts.input or M.sample_input())
  stdin:write(text, function()
    stdin:close()
  end)

  function h:term()
    self.proc:kill("sigterm")
  end

  function h:wait_exit()
    t.wait(function()
      return self.exited
    end, "выход хука")
    if not self.proc:is_closing() then
      self.proc:close()
    end
  end

  return h
end

--- Проверяет исход «без решения»: код 0, пустые stdout и stderr.
function M.assert_silent_exit(h)
  t.eq(h.code, 0, "код выхода")
  t.eq(h.signal, 0, "сигнал")
  t.eq(h.stdout, "", "stdout")
  t.eq(h.stderr, "", "stderr")
end

return M
