local t = require("helpers.t")

describe("каркас плагина", function()
  it("setup без сервера herdr и без Claude Code не падает", function()
    t.eq(vim.env.HERDR_SOCKET_PATH, nil)
    require("claudr").setup()
    require("claudr").setup({ show_finished = false })
  end)

  it("команда :Claudr существует после setup", function()
    require("claudr").setup()
    t.eq(vim.fn.exists(":Claudr"), 2)
  end)

  it(
    "команда :Claudr существует после загрузки plugin/ без setup",
    function()
      vim.cmd("runtime plugin/claudr.lua")
      t.eq(vim.fn.exists(":Claudr"), 2)
    end
  )

  it("настройки по умолчанию", function()
    local config = require("claudr.config")
    config.setup()
    t.eq(config.get().show_finished, true)
    t.eq(config.get().code_questions.model, "sonnet")
    t.eq(config.get().code_questions.fork_from_base, false)
    t.eq(config.get().code_questions.mcp, nil)
  end)

  it(
    "пользовательские настройки перекрывают значения по умолчанию",
    function()
      local config = require("claudr.config")
      config.setup({ code_questions = { model = "opus" } })
      t.eq(config.get().code_questions.model, "opus")
      t.eq(config.get().code_questions.fork_from_base, false)
      config.setup()
    end
  )

  it(
    "подкоманды регистрируются, выполняются и дополняются",
    function()
      local commands = require("claudr.commands")
      local got
      commands.register("probe", function(args)
        got = args
      end, {
        desc = "проверка",
        complete = function()
          return { "one", "two" }
        end,
      })
      commands.define()
      vim.cmd("Claudr probe a b")
      t.eq(got, { "a", "b" })
      t.ok(vim.tbl_contains(vim.fn.getcompletion("Claudr pro", "cmdline"), "probe"))
      t.eq(vim.fn.getcompletion("Claudr probe ", "cmdline"), { "one", "two" })
    end
  )

  it(
    "неизвестная подкоманда сообщает об ошибке и не падает",
    function()
      local notified
      local orig = vim.notify
      vim.notify = function(msg)
        notified = msg
      end
      vim.cmd("Claudr nonexistent")
      vim.notify = orig
      t.match(notified, "неизвестная подкоманда")
    end
  )
end)
