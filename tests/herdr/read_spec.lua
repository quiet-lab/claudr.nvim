-- Клиент herdr: чтение вывода панели `pane.read`.
local t = require("helpers.t")
local support = require("herdr.support")
local herdr = require("claudr.herdr")

local d

local function read(pane_id, opts)
  local done, err, res = false, nil, nil
  herdr.read_pane(pane_id, opts, function(e, r)
    done, err, res = true, e, r
  end)
  t.wait(function()
    return done
  end, "ответ pane.read")
  t.eq(err, nil)
  return res
end

before_each(function()
  d = support.connected(herdr)
end)

after_each(function()
  herdr.stop()
  d:close()
end)

describe("Чтение панели", function()
  it("Чтение вывода", function()
    d:set_output("w2:p1", { lines = { "alpha", "beta" }, revision = 7 })
    local r = read("w2:p1")
    local req = d:last("pane.read")
    t.eq(req.params.source, "recent_unwrapped")
    t.eq(req.params.pane_id, "w2:p1")
    t.eq(r.text, "alpha\nbeta")
    t.eq(r.revision, 7)
    t.eq(r.truncated, false)
    t.eq(r.source, "recent_unwrapped")
    t.eq(r.format, "text")
  end)

  it("Предел строк", function()
    local lines = {}
    for i = 1, 3000 do
      lines[i] = tostring(i)
    end
    d:set_output("w2:p1", { lines = lines })
    local r = read("w2:p1", { source = "recent", lines = 5000 })
    t.eq(d:last("pane.read").params.lines, 5000)
    local got = vim.split(r.text, "\n", { trimempty = true })
    t.ok(#got <= 1000, "не более 1000 строк")
    t.eq(#got, 1000)
    t.eq(got[1], "2001")
    t.eq(r.truncated, true)
    -- Без числа строк — 80.
    local r80 = read("w2:p1", { source = "recent" })
    t.eq(#vim.split(r80.text, "\n", { trimempty = true }), 80)
    t.eq(d:last("pane.read").params.lines, nil)
  end)

  it("Полноэкранная программа", function()
    local screen = {}
    for i = 1, 41 do
      screen[i] = "row " .. i
    end
    d:set_output("w1:p1", { lines = screen, fullscreen = true, height = 41 })
    local texts = {}
    for _, source in ipairs({ "visible", "recent", "recent_unwrapped" }) do
      local r = read("w1:p1", { source = source })
      t.eq(r.truncated, false, source)
      texts[source] = vim.trim(r.text)
    end
    t.eq(texts.recent, texts.visible)
    t.eq(texts.recent_unwrapped, texts.visible)
    t.eq(#vim.split(texts.visible, "\n"), 41)
  end)

  it("Формат ansi", function()
    d:set_output("w2:p1", {
      lines = { "\27[0m\27[38;5;1mRED\27[0m \27[0m\27[1m\27[38;5;2mgreen\27[0m", "@sh-5.3$ " },
    })
    local r = read("w2:p1", { source = "recent", format = "ansi" })
    t.eq(d:last("pane.read").params.format, "ansi")
    t.ok(
      r.text:find("\27[38;5;1m", 1, true),
      "последовательность оформления"
    )
    t.ok(r.text:find("\r\n", 1, true), "строки разделены \\r\\n")
    t.eq(r.format, "ansi")
    local plain = read("w2:p1", { source = "recent", format = "text" })
    t.eq(plain.text, "RED green\n@sh-5.3$\n")
  end)

  it("ошибка чтения отдаётся вызывающему", function()
    local done, err
    herdr.read_pane("w9:p9", {}, function(e)
      done, err = true, e
    end)
    t.wait(function()
      return done
    end, "ответ")
    t.eq(err.code, "pane_not_found")
  end)
end)
