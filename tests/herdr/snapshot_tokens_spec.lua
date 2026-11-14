-- Клиент herdr: токены workspace и состояния вкладки и панели в снимке («Состав снимка»).
local t = require("helpers.t")
local support = require("herdr.support")
local herdr = require("claudr.herdr")

local d

before_each(function()
  d = support.connected(herdr)
end)

after_each(function()
  herdr.stop()
  d:close()
end)

local function ws(id)
  for _, w in ipairs(herdr.state().snapshot.workspaces) do
    if w.workspace_id == id then
      return w
    end
  end
end

local function snapshot_reads()
  local n = 0
  for _, r in ipairs(d.requests) do
    if r.method == "session.snapshot" then
      n = n + 1
    end
  end
  return n
end

-- Задать токены и дождаться снимка, прочитанного после события.
local function wait_tokens(id, tokens)
  local before = snapshot_reads()
  d:set_workspace_tokens(id, tokens)
  t.wait(function()
    return snapshot_reads() > before and not herdr._reading() and not herdr.state().stale
  end, "снимок обновлён")
end

describe("Состав снимка", function()
  it("Токены workspace: таблица строк", function()
    t.eq(ws("w1").tokens, { symbol = "S", color = "#336699" })
  end)

  it(
    "Токены workspace: нет поля, null и не таблица дают пустую таблицу",
    function()
      wait_tokens("w1", nil)
      t.eq(ws("w1").tokens, {})
      wait_tokens("w1", vim.NIL)
      t.eq(ws("w1").tokens, {})
      wait_tokens("w1", "text")
      t.eq(ws("w1").tokens, {})
      wait_tokens("w1", 5)
      t.eq(ws("w1").tokens, {})
    end
  )

  it(
    "Токены workspace: нестроковые значения отбрасываются",
    function()
      wait_tokens("w1", { symbol = "S2", color = 5, extra = { 1 }, flag = true })
      t.eq(ws("w1").tokens, { symbol = "S2" })
    end
  )

  it(
    "Состояние вкладки передаётся вместе с остальными полями",
    function()
      d:set_tab_status("w1:t1", "working")
      d:emit("tab.renamed", { tab_id = "w1:t1" })
      t.wait(function()
        return herdr.state().snapshot.tabs[1].agent_status == "working"
      end, "состояние вкладки")
      local tab = herdr.state().snapshot.tabs[1]
      t.eq(tab.tab_id, "w1:t1")
      t.eq(tab.workspace_id, "w1")
      t.eq(tab.number, 1)
    end
  )

  it(
    "Неизвестное состояние передаётся как есть, ошибки нет",
    function()
      local seen = {}
      local off = herdr.subscribe(function(state)
        for _, p in ipairs(state.snapshot.panes) do
          seen[p.pane_id] = p.agent_status
        end
      end)
      d:set_agent_status("w2:p1", "paused")
      d:set_agent_status("w2:p2", "done")
      t.wait(function()
        return seen["w2:p1"] == "paused" and seen["w2:p2"] == "done"
      end, "состояния панелей")
      t.eq(herdr.state().status, "connected")
      off()
    end
  )
end)
