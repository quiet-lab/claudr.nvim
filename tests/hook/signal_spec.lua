-- Требование «Хук не мешает диалогу», сценарий «Сигнал завершения».
local t = require("helpers.t")
local support = require("hook.support")
local listener_double = require("helpers.listener_double")

describe("Хук не мешает диалогу", function()
  it("Сигнал завершения", function()
    local l1 = listener_double.start({ dir = support.socket_dir(), name = "501.sock" })
    local l2 = listener_double.start({ dir = support.socket_dir(), name = "502.sock" })
    local h = support.spawn()
    t.wait(function()
      return #l1.requests == 1 and #l2.requests == 1
    end, "запросы у слушателей")
    local before = support.snapshot()
    h:term()
    h:wait_exit()
    support.assert_silent_exit(h)
    t.wait(function()
      return l1.closed_by_peer and l2.closed_by_peer
    end, "соединения закрыты хуком")
    t.ok(
      not l1.got_answered and not l2.got_answered,
      "«отвечено» не отправлено"
    )
    t.eq(support.snapshot(), before, "хук не создал файлов")
    l1:stop()
    l2:stop()
  end)
end)
