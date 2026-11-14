-- Требование «Плагин Claude Code с хуком»: описание хуков плагина Claude Code.
local t = require("helpers.t")
local support = require("hook.support")

describe("Плагин Claude Code с хуком", function()
  it("Описание хуков", function()
    local config = support.hooks_config()
    t.eq(vim.tbl_keys(config.hooks), { "PermissionRequest" }, "события хуков")
    local groups = config.hooks.PermissionRequest
    t.eq(#groups, 1, "одна запись PermissionRequest")
    local matcher = groups[1].matcher
    t.ok(
      matcher == nil or matcher == "" or matcher == "*",
      "без ограничения по инструменту"
    )
    t.eq(#groups[1].hooks, 1, "один обработчик")
    local handler = groups[1].hooks[1]
    t.eq(handler.type, "command")
    t.ok(
      type(handler.timeout) == "number" and handler.timeout >= 86400,
      "timeout не меньше суток"
    )

    -- Сценарий запускается `nvim --clean -l` из каталога плагина и лежит там.
    local cmd, args = support.hook_argv()
    local argv = vim.list_extend({ cmd }, args)
    local joined = table.concat(argv, " ")
    t.match(joined, "nvim %-%-clean %-l ", "команда nvim --clean -l")
    local script = argv[#argv]
    t.eq(script, support.plugin_root .. "/hooks/permission-request.lua")
    t.ok(
      vim.uv.fs_stat(script),
      "сценарий хука есть в каталоге плагина"
    )
    t.ok(
      vim.tbl_contains(handler.args, "${CLAUDE_PLUGIN_ROOT}/hooks/permission-request.lua"),
      "путь сценария через ${CLAUDE_PLUGIN_ROOT}"
    )
  end)
end)
