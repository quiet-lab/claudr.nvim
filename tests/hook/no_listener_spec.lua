-- Требование «Запрос хука к Neovim», сценарий «Слушателя нет».
local t = require("helpers.t")
local support = require("hook.support")
local listener_double = require("helpers.listener_double")

local function run_without_listener()
  local before = support.snapshot()
  local h = support.spawn()
  h:wait_exit()
  support.assert_silent_exit(h)
  t.eq(support.snapshot(), before, "хук не создал и не удалил файлов")
end

describe("Запрос хука к Neovim", function()
  it("Слушателя нет: нет каталога сокетов", function()
    t.ok(not vim.uv.fs_stat(support.socket_dir()), "каталога нет")
    run_without_listener()
  end)

  it("Слушателя нет: пустой каталог сокетов", function()
    vim.fn.mkdir(support.socket_dir(), "p", tonumber("700", 8))
    run_without_listener()
  end)

  it(
    "Слушателя нет: подключение к мёртвому сокету отказано",
    function()
      local path = listener_double.dead({ dir = support.socket_dir(), name = "1.sock" })
      run_without_listener()
      t.ok(vim.uv.fs_stat(path), "чужой сокет не удалён")
    end
  )

  it("Слушателя нет: файлы не сокеты пропускаются", function()
    local dir = support.socket_dir()
    vim.fn.mkdir(dir, "p", tonumber("700", 8))
    vim.fn.writefile({ "x" }, dir .. "/2.sock")
    vim.fn.mkdir(dir .. "/3.sock")
    listener_double.dead({ dir = dir, name = "4.sock" })
    run_without_listener()
  end)
end)
