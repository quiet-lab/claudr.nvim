-- Определение ссылки под курсором, границы, разрешение пути (спецификация file-references).
local t = require("helpers.t")
local s = require("refs.support")
local refs = require("claudr.refs")

local project

before_each(function()
  s.reset()
  project = s.project()
end)

-- Ссылка под курсором в тексте `line` на слове `needle` в подключённом буфере.
local function link_on(line, needle, cwd)
  s.plugin_buffer({ line }, cwd or project.dir)
  s.cursor_on(needle)
  return refs.link_at_cursor()
end

describe("Путь под курсором — ссылка", function()
  it("Ссылка со строкой и столбцом", function()
    local link = link_on("см. lua/foo.lua:42:7 в проекте", "foo")
    t.eq(link, { path = project.foo, line = 42, col = 7 })
  end)

  it("Ссылка без строки", function()
    local link = link_on("файл " .. project.foo .. " изменён", "foo")
    t.eq(link, { path = project.foo })
  end)

  it("ссылка со строкой без столбца", function()
    local link = link_on("lua/foo.lua:42", "lua")
    t.eq(link, { path = project.foo, line = 42 })
  end)

  it(
    "курсор на любом символе ссылки, включая номера",
    function()
      local text = "lua/foo.lua:42:7"
      s.plugin_buffer({ text }, project.dir)
      for col = 0, #text - 1 do
        vim.api.nvim_win_set_cursor(0, { 1, col })
        t.eq(
          refs.link_at_cursor(),
          { path = project.foo, line = 42, col = 7 },
          "столбец " .. col
        )
      end
    end
  )
end)

describe("Границы ссылки", function()
  it("Ссылка в обратных апострофах", function()
    t.eq(
      link_on("в тексте (`lua/foo.lua:42`), далее", "foo"),
      { path = project.foo, line = 42 }
    )
    t.eq(link_on('"lua/foo.lua:42"', "foo"), { path = project.foo, line = 42 })
    t.eq(link_on("[lua/foo.lua:42]", "foo"), { path = project.foo, line = 42 })
    t.eq(link_on("'lua/foo.lua'", "foo"), { path = project.foo })
  end)

  it("Знак препинания после ссылки", function()
    for _, tail in ipairs({ ".", ",", ";", ":", ").", ":." }) do
      local line = "смотри lua/foo.lua:42" .. tail
      t.eq(link_on(line, "foo"), { path = project.foo, line = 42 }, "знак «" .. tail .. "»")
    end
    t.eq(link_on("смотри lua/foo.lua.", "foo"), { path = project.foo })
    -- сам знак препинания ссылкой не является
    s.plugin_buffer({ "смотри lua/foo.lua:42." }, project.dir)
    vim.api.nvim_win_set_cursor(0, { 1, #"смотри lua/foo.lua:42." - 1 })
    t.eq(refs.link_at_cursor(), nil)
  end)

  it("разбор без проверки файла", function()
    t.eq(refs.parse("a/b.lua:3:4", 0)[1], { path = "a/b.lua", line = 3, col = 4 })
    t.eq(refs.parse("a/b.lua:3,", 0)[1], { path = "a/b.lua", line = 3 })
    t.eq(refs.parse("   ", 1), nil)
    t.eq(refs.parse("(x)", 0), nil)
  end)
end)

describe("Разрешение пути и существование файла", function()
  it("Относительный путь", function()
    local link = link_on("lua/foo.lua:1", "foo")
    t.eq(link.path, project.dir .. "/lua/foo.lua")
    t.eq(refs.resolve("lua/foo.lua", project.dir), project.dir .. "/lua/foo.lua")
    t.eq(refs.resolve("../short.txt", project.dir .. "/lua"), project.short)
    t.eq(
      refs.resolve("lua/foo.lua", nil),
      nil,
      "без каталога сессии относительный путь не разрешается"
    )
  end)

  it("Файла нет", function()
    t.eq(link_on("lua/missing.lua:3", "missing"), nil)
    t.eq(link_on("слово", "слово"), nil)
  end)

  it("каталог ссылкой не считается", function()
    t.eq(link_on("docs/", "docs"), nil)
    t.eq(link_on("docs:12", "docs"), nil)
    t.eq(link_on(project.dir, "src"), nil)
  end)
end)
