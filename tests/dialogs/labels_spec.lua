-- Подписи пунктов из данных хука (спецификация agent-dialogs).
local t = require("helpers.t")
local s = require("helpers.hook_samples")
local hook = require("claudr.data.hook")
local labels = require("claudr.dialogs.labels")

local function kinds()
  return s.input("permission-kinds").permission_suggestions
end

describe("Подписи пунктов из данных хука", function()
  it("Правило в местные настройки", function()
    local item = s.input("permission-bash").permission_suggestions[1]
    local label = labels.suggestion(item)
    t.eq(
      label,
      "Правило: разрешать Bash(git init *) — местные настройки проекта"
    )
    t.ok(label:find("Bash", 1, true) and label:find("git init *", 1, true))
  end)

  it("Каталог на сессию", function()
    local item = s.input("permission-bash-dirs").permission_suggestions[1]
    t.eq(labels.suggestion(item), "Каталог: " .. s.cwd .. " — сессия")
  end)

  it("Режим на сессию", function()
    local item = s.input("permission-bash-dirs").permission_suggestions[2]
    t.eq(labels.suggestion(item), "Режим: acceptEdits — сессия")
  end)

  it(
    "Правило без содержимого — любой вызов инструмента",
    function()
      t.eq(
        labels.suggestion(kinds()[3]),
        "Правило: разрешать WebFetch (любой вызов) — настройки проекта"
      )
    end
  )

  it("Правило для Read в сессию", function()
    t.eq(
      labels.suggestion(kinds()[2]),
      "Правило: разрешать Read(//etc/**) — сессия"
    )
  end)

  it("Элемент с несколькими правилами", function()
    t.eq(
      labels.suggestion(kinds()[4]),
      "Правило: разрешать Bash(make test); Bash(make lint) — пользовательские настройки"
    )
  end)

  it("Правило отказа", function()
    t.eq(
      labels.suggestion(kinds()[5]),
      "Правило: запрещать Bash(rm *) — настройки проекта"
    )
  end)

  it("Несколько каталогов", function()
    t.eq(
      labels.suggestion(kinds()[7]),
      "Каталоги: "
        .. s.cwd
        .. "/lib, "
        .. s.cwd
        .. "/vendor — настройки проекта"
    )
  end)

  it("Режим в пользовательские настройки", function()
    t.eq(
      labels.suggestion(kinds()[9]),
      "Режим: plan — пользовательские настройки"
    )
  end)

  it(
    "Элемент неизвестного вида показывается видом и местом",
    function()
      t.eq(labels.suggestion(kinds()[10]), "futureKind — настройки проекта")
    end
  )

  it("Неизвестное место остаётся как есть", function()
    t.eq(labels.suggestion(kinds()[11]), "Режим: default — cloudSettings")
    t.eq(labels.destination("cloudSettings"), "cloudSettings")
  end)

  it("Места сохранения", function()
    t.eq(labels.destination("session"), "сессия")
    t.eq(labels.destination("localSettings"), "местные настройки проекта")
    t.eq(labels.destination("projectSettings"), "настройки проекта")
    t.eq(labels.destination("userSettings"), "пользовательские настройки")
    t.eq(labels.destination(nil), "место не указано")
  end)

  it("Вырожденные элементы не вызывают ошибки", function()
    t.eq(
      labels.suggestion({ type = "addRules", destination = "session" }),
      "Правило: — сессия"
    )
    t.eq(
      labels.suggestion({ destination = "session" }),
      "неизвестный элемент — сессия"
    )
    t.eq(
      labels.suggestion(vim.NIL),
      "неизвестный элемент — место не указано"
    )
    t.eq(
      labels.suggestion({ type = "addDirectories", destination = "session" }),
      "Каталоги: — сессия"
    )
  end)

  it(
    "Каждый элемент образцов получает непустую подпись",
    function()
      for _, name in ipairs(s.names("inputs")) do
        for _, item in ipairs(hook.parse_input(s.input(name)).suggestions) do
          t.ok(labels.suggestion(item) ~= "", name)
        end
      end
    end
  )
end)
