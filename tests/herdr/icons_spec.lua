-- Значки состояний из конфигурации herdr: разбор, встроенные значки, перечитывание по
-- уведомлению файловой системы. Файл конфигурации лежит в каталоге теста
-- (`HERDR_CONFIG_PATH`), ожидание — до вызова подписчика.
local t = require("helpers.t")
local support = require("herdr.support")
local icons = require("claudr.herdr.icons")

local uv = vim.uv

local dir, path, unsubs, calls

local function fixture(name)
  local f = assert(io.open(t.root .. "/tests/fixtures/herdr/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function write(file, text)
  local f = assert(io.open(file, "wb"))
  f:write(text)
  f:close()
end

local function install(name)
  write(path, fixture(name))
end

local function listen()
  local off = icons.subscribe(function()
    calls = calls + 1
  end)
  table.insert(unsubs, off)
  return off
end

local function frames(state)
  return icons.get()[state].frames
end

before_each(function()
  icons._reset()
  dir = support.dir("icons")
  path = dir .. "/config.toml"
  uv.os_setenv("HERDR_CONFIG_PATH", path)
  unsubs, calls = {}, 0
end)

after_each(function()
  for _, off in ipairs(unsubs) do
    off()
  end
  icons._reset()
  uv.os_unsetenv("HERDR_CONFIG_PATH")
end)

describe("Значки состояний из конфигурации herdr", function()
  it("Кадры и период", function()
    install("frames.toml")
    local got = icons.get()
    t.eq(got.working, { frames = { "a", "b" }, period = 80 })
    t.eq(got.idle, { frames = { "c" }, period = 400 })
    -- Остальные состояния — встроенные точки с периодом по умолчанию.
    t.eq(got.blocked, { frames = { "●" }, period = 400 })
  end)

  it("Период вне диапазона", function()
    install("out-of-range.toml")
    for _, state in ipairs({ "idle", "working", "blocked", "done", "unknown" }) do
      t.eq(icons.get()[state].period, 400)
    end
    t.eq(frames("working"), { "a", "b" })
  end)

  it("Посторонние ключи", function()
    install("extra-keys.toml")
    t.eq(icons.get().working, { frames = { "a", "b" }, period = 400 })
    t.ok(icons.parse(fixture("extra-keys.toml")) ~= nil, "файл разобран")
  end)

  it(
    "Период: число для всех, граница диапазона и нецелое значение",
    function()
      local function period(text)
        return icons.resolve(icons.parse(text)).working.period
      end
      t.eq(period("[ui.status_icons]\nframe_interval_ms = 50\n"), 50)
      t.eq(period("[ui.status_icons]\nframe_interval_ms = 5000\n"), 5000)
      t.eq(period("[ui.status_icons]\nframe_interval_ms = 5001\n"), 400)
      t.eq(period("[ui.status_icons]\nframe_interval_ms = 80.5\n"), 400)
      t.eq(period('[ui.status_icons]\nframe_interval_ms = "80"\n'), 400)
      t.eq(period("[ui.status_icons]\nframe_interval_ms = { working = 10 }\n"), 400)
      t.eq(period("[ui.status_icons]\nframe_interval_ms = { blocked = 90 }\n"), 400)
    end
  )

  it("Экранирование и одинарные кавычки в строках", function()
    install("escapes.toml")
    t.eq(frames("working"), { "A", "b\\n", '"q"', "\\" })
    t.eq(icons.parse('[ui.status_icons]\nidle = "\\u2713"\n').status_icons.idle, "✓")
  end)

  it(
    "Таблица значков встроенной таблицей в разделе ui",
    function()
      local got = icons.resolve(icons.parse('[ui]\nstatus_icons = { idle = "q" }\n'))
      t.eq(got.idle.frames, { "q" })
    end
  )

  it(
    "Некорректное значение значка заменяется встроенным",
    function()
      local got = icons.resolve(icons.parse('[ui.status_icons]\nidle = ""\nworking = ["a", 5]\n'))
      t.eq(got.idle.frames, { "○" })
      t.eq(got.working.frames, { "●" })
    end
  )

  it(
    "Путь файла: HERDR_CONFIG_PATH, XDG_CONFIG_HOME, домашний каталог",
    function()
      t.eq(icons.path(), path)
      uv.os_unsetenv("HERDR_CONFIG_PATH")
      t.eq(icons.path(), uv.os_getenv("XDG_CONFIG_HOME") .. "/herdr/config.toml")
      local xdg = uv.os_getenv("XDG_CONFIG_HOME")
      uv.os_unsetenv("XDG_CONFIG_HOME")
      t.eq(icons.path(), uv.os_homedir() .. "/.config/herdr/config.toml")
      uv.os_setenv("XDG_CONFIG_HOME", xdg)
    end
  )
end)

describe("Встроенные значки herdr", function()
  it("Конфигурации нет", function()
    t.eq(uv.fs_stat(path), nil)
    local got = icons.get()
    t.eq(got.working.frames, { "●" })
    t.eq(got.idle.frames, { "○" })
    t.eq(got.unknown.frames, { "·" })
    t.eq(got.blocked.frames, { "●" })
    t.eq(got.done.frames, { "●" })
    t.eq(got.working.period, 400)
  end)

  it("Часть значков задана", function()
    install("symbols.toml")
    local got = icons.get()
    t.eq(got.working.frames, { "x" })
    t.eq(got.blocked.frames, { "×" })
    t.eq(got.done.frames, { "✓" })
    t.eq(got.idle.frames, { "○" })
    t.eq(got.unknown.frames, { "·" })
  end)

  it("Файл не разбирается", function()
    install("unparsable.toml")
    t.eq(icons.parse(fixture("unparsable.toml")), nil)
    -- Встроенные значки по умолчанию (`dots`): `status_indicators` из файла не учитывается.
    t.eq(icons.get().working.frames, { "●" })
    t.eq(icons.get().blocked.frames, { "●" })
  end)

  it("Файл без раздела значков", function()
    install("no-section.toml")
    t.ok(icons.parse(fixture("no-section.toml")) ~= nil)
    t.eq(icons.get().working.frames, { "●" })
  end)

  it(
    "Синтаксис, который клиент не разбирает, даёт nil, а испорченный файл не падает",
    function()
      t.eq(icons.parse("[ui]\nstatus_icons.working = 'a'\n"), nil)
      t.eq(icons.parse("ui.status_icons.working = 'a'\n"), nil)
      t.eq(icons.parse("ui = { status_indicators = 'symbols' }\n"), nil)
      t.eq(icons.parse("[ui.status_icons\nworking = 'a'\n"), nil)
      t.eq(icons.parse('[ui.status_icons]\nworking = "abc\n'), nil)
      t.eq(icons.parse('[ui.status_icons]\nworking = ["a"\n'), nil)
      t.eq(icons.parse(nil), nil)
      write(path, "\0\1\2 ==== [[[")
      t.eq(icons.get().working.frames, { "●" })
    end
  )

  it(
    "Посторонние разделы со сложным синтаксисом пропускаются",
    function()
      local parsed = icons.parse(table.concat({
        "[other]",
        "a.b.c = 1979-05-27T07:32:00Z",
        "s = '''",
        "text ] = [",
        "'''",
        "n = [[1, 2], [3]]",
        "t = { x = 1, y = { z = [1, 2] } }",
        "[ui.status_icons]",
        "idle = 'k'",
      }, "\n"))
      t.eq(parsed.status_icons.idle, "k")
    end
  )
end)

describe(
  "Обновление значков при смене конфигурации",
  function()
    it("Правка значков", function()
      install("frames.toml")
      t.eq(frames("idle"), { "c" })
      listen()
      t.ok(icons.watching(), "наблюдатель заведён")
      write(path, '[ui.status_icons]\nidle = "Z"\n')
      t.wait(function()
        return calls > 0 and frames("idle")[1] == "Z"
      end, "уведомление о смене значка")
      t.eq(frames("idle"), { "Z" })
    end)

    it("Файл заменён переименованием", function()
      install("frames.toml")
      t.eq(frames("idle"), { "c" })
      listen()
      write(dir .. "/config.toml.tmp", '[ui.status_icons]\nidle = "R"\n')
      t.ok(uv.fs_rename(dir .. "/config.toml.tmp", path))
      t.wait(function()
        return calls > 0 and frames("idle")[1] == "R"
      end, "уведомление после переименования")
    end)

    it("Появление файла, которого не было", function()
      t.eq(frames("idle"), { "○" })
      listen()
      write(path, '[ui.status_icons]\nidle = "N"\n')
      t.wait(function()
        return calls > 0 and frames("idle")[1] == "N"
      end, "уведомление о появлении файла")
    end)

    it(
      "Удаление файла возвращает встроенные значки",
      function()
        install("frames.toml")
        t.eq(frames("idle"), { "c" })
        listen()
        t.ok(uv.fs_unlink(path))
        t.wait(function()
          return calls > 0 and frames("idle")[1] == "○"
        end, "уведомление об удалении файла")
      end
    )

    it("Изменений нет", function()
      install("frames.toml")
      icons.get()
      listen()
      for _ = 1, 5 do
        icons.get()
      end
      t.eq(icons._reads(), 1)
      -- Посторонний файл в каталоге чтения не вызывает; границу ставит замена конфигурации:
      -- к её уведомлению посторонняя запись уже обработана.
      write(dir .. "/other.toml", "x = 1\n")
      write(dir .. "/config.toml.tmp", '[ui.status_icons]\nidle = "S"\n')
      t.ok(uv.fs_rename(dir .. "/config.toml.tmp", path))
      t.wait(function()
        return calls > 0
      end, "замена конфигурации")
      t.eq(icons._reads(), 2)
      local reads = icons._reads()
      for _ = 1, 5 do
        icons.get()
      end
      t.eq(icons._reads(), reads)
    end)

    it(
      "Запись без смены значков подписчиков не уведомляет",
      function()
        install("frames.toml")
        icons.get()
        listen()
        -- Тот же текст с другим комментарием: значки прежние.
        write(path, "# другой комментарий\n" .. fixture("frames.toml"))
        local reads = icons._reads()
        t.wait(function()
          return icons._reads() > reads
        end, "перечитывание")
        -- Событие обработано; смена значка ниже даёт ровно одно первое уведомление.
        t.eq(calls, 0)
        write(path, '[ui.status_icons]\nidle = "Y"\n')
        t.wait(function()
          return calls > 0
        end, "уведомление")
        t.eq(frames("idle"), { "Y" })
      end
    )

    it(
      "Без наблюдателя неизменный файл не читается, изменённый читается",
      function()
        install("frames.toml")
        icons.get()
        icons.get()
        t.eq(icons._reads(), 1)
        t.eq(icons.watching(), false)
        write(path, '[ui.status_icons]\nidle = "W"\n.\n')
        t.eq(frames("idle"), { "○" })
        write(path, '[ui.status_icons]\nidle = "V"\n')
        t.eq(frames("idle"), { "V" })
      end
    )

    it(
      "Нет каталога: наблюдатель не заводится, ошибки нет",
      function()
        uv.os_setenv("HERDR_CONFIG_PATH", dir .. "/missing/config.toml")
        listen()
        t.eq(icons.watching(), false)
        t.eq(frames("idle"), { "○" })
      end
    )

    it(
      "Отписка последнего подписчика закрывает наблюдатель",
      function()
        install("frames.toml")
        local off1 = listen()
        local off2 = listen()
        t.eq(icons.watching(), true)
        off1()
        off1()
        t.eq(icons.watching(), true)
        off2()
        t.eq(icons.watching(), false)
        local off3 = listen()
        t.eq(icons.watching(), true)
        off3()
        t.eq(icons.watching(), false)
      end
    )
  end
)
