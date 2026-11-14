-- Требование «Хук не мешает диалогу»: ошибка разбора входа завершает хук кодом 0 без вывода.
local t = require("helpers.t")
local support = require("hook.support")
local listener_double = require("helpers.listener_double")

local function run_with(stdin)
  local l = listener_double.start({ dir = support.socket_dir(), name = "601.sock" })
  local before = support.snapshot()
  local h = support.spawn({ stdin = stdin })
  h:wait_exit()
  support.assert_silent_exit(h)
  t.eq(#l.requests, 0, "запрос не отправлен")
  t.eq(support.snapshot(), before, "хук не создал файлов")
  l:stop()
end

describe("Хук не мешает диалогу", function()
  it("Неверный вход: не JSON", function()
    run_with("not json")
  end)

  it("Неверный вход: массив вместо объекта", function()
    run_with("[1, 2]")
  end)

  it("Неверный вход: пустой stdin", function()
    run_with("")
  end)
end)
