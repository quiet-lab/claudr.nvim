-- Запуск одного файла тестов: nvim --headless --clean -u NONE -l tests/bootstrap.lua <файл>.
-- Окружение изолировано: свои каталоги XDG и CLAUDE_CONFIG_DIR, без переменных herdr.
local script = arg[0] or debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")
local spec = arg[1]
if not spec then
  io.stderr:write("bootstrap: не указан файл теста\n")
  os.exit(2)
end

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  root .. "/tests/?/init.lua",
  package.path,
}, ";")

-- Временный каталог теста: внутри $TMPDIR (или системного каталога Neovim).
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
for _, sub in ipairs({ "config", "state", "data", "cache", "claude" }) do
  vim.fn.mkdir(tmpdir .. "/" .. sub, "p")
end
vim.uv.os_setenv("XDG_CONFIG_HOME", tmpdir .. "/config")
vim.uv.os_setenv("XDG_STATE_HOME", tmpdir .. "/state")
vim.uv.os_setenv("XDG_DATA_HOME", tmpdir .. "/data")
vim.uv.os_setenv("XDG_CACHE_HOME", tmpdir .. "/cache")
vim.uv.os_setenv("CLAUDE_CONFIG_DIR", tmpdir .. "/claude")
-- Каталог времени выполнения: сокеты тестов не попадают в настоящий каталог.
vim.fn.mkdir(tmpdir .. "/run", "p", "0700")
vim.uv.fs_chmod(tmpdir .. "/run", tonumber("700", 8))
vim.uv.os_setenv("XDG_RUNTIME_DIR", tmpdir .. "/run")
vim.uv.os_setenv("TMPDIR", tmpdir)

for _, name in ipairs({
  "HERDR_SOCKET_PATH",
  "HERDR_PANE_ID",
  "HERDR_WORKSPACE_ID",
  "HERDR_TAB_ID",
  "HERDR_SESSION",
  "HERDR_ENV",
}) do
  vim.uv.os_unsetenv(name)
end

-- Поддельные herdr и claude — первыми в PATH.
vim.uv.os_setenv("PATH", root .. "/tests/helpers/fake_bin:" .. (vim.uv.os_getenv("PATH") or ""))

local t = require("helpers.t")
t.root = root
t._tmpdir = tmpdir
t.install_globals()

local function cleanup()
  vim.fn.delete(tmpdir, "rf")
end

local ok, err = xpcall(dofile, debug.traceback, vim.fn.fnamemodify(spec, ":p"))
if not ok then
  print("FAIL загрузка файла теста")
  print(tostring(err))
  cleanup()
  os.exit(1)
end

local _, failed = t.run_all()
cleanup()
os.exit(failed == 0 and 0 or 1)
