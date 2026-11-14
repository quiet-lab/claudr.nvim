-- Окружение тестов: каталог времени выполнения внутри временного каталога теста.
local t = require("helpers.t")

describe("окружение тестов: XDG_RUNTIME_DIR", function()
  it(
    "каталог времени выполнения — <временный каталог теста>/run с правами 0700",
    function()
      local run = vim.uv.os_getenv("XDG_RUNTIME_DIR")
      t.eq(run, t.tmpdir() .. "/run")
      local st = vim.uv.fs_stat(run)
      t.eq(st.type, "directory")
      t.eq(bit.band(st.mode, tonumber("777", 8)), tonumber("700", 8))
    end
  )

  it(
    "временный каталог теста лежит внутри $TMPDIR, а не в настоящем каталоге",
    function()
      t.eq(vim.uv.os_getenv("TMPDIR"), t.tmpdir())
      t.ok(vim.uv.os_getenv("XDG_RUNTIME_DIR"):find(t.tmpdir(), 1, true) == 1)
    end
  )
end)
