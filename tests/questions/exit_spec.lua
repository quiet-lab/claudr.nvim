-- Вопросы по коду: выход из Neovim во время ответа (спецификация code-questions,
-- «Ответ по мере генерации», «Выход из Neovim во время ответа»).
local t = require("helpers.t")
local env = require("questions.env")
local q = require("claudr.questions")
local window = require("claudr.questions.window")

before_each(function()
  env.reset()
end)

describe("Выход из Neovim во время ответа", function()
  it(
    "Выход из Neovim во время ответа: процесс не останавливается, ответ дописывается и виден при открытии темы",
    function()
      local p = env.project()
      local gate = p.ctl:gate("running")
      p.ctl:script({
        { "transcript_user" },
        { "init" },
        { "wait", gate },
        { "text", { "Ответ ", "после ", "выхода." } },
        { "transcript_assistant", "Ответ после выхода." },
        { "result", "Ответ после выхода." },
      })
      p.ctl:apply()

      -- «Neovim» задаёт вопрос и завершается, пока отвечающий процесс стоит в точке остановки
      local nvim_out, nvim_exited = "", false
      vim.system({
        vim.v.progpath,
        "--headless",
        "--clean",
        "-u",
        "NONE",
        "-l",
        t.root .. "/tests/questions/ask_exit_proc.lua",
        t.root,
        p.foo,
      }, {
        text = true,
        stdout = function(_, data)
          if data then
            nvim_out = nvim_out .. data
          end
        end,
      }, function()
        nvim_exited = true
      end)
      t.wait(function()
        return nvim_exited
      end, "Neovim завершился во время ответа")
      local id = vim.trim(nvim_out)
      t.ok(id ~= "", "идентификатор темы получен")
      local function exits()
        local n = 0
        for _, rec in ipairs(p.ctl:log()) do
          if rec.event == "exit" then
            n = n + 1
          end
        end
        return n
      end
      t.eq(
        exits(),
        0,
        "после выхода Neovim процесс ответа ещё работает"
      )

      -- процесс продолжает работу и заканчивает ответ
      gate:release()
      t.wait(function()
        return exits() == 1
      end, "отвечающий процесс завершил ответ")
      gate:close()
      local log = p.ctl:log()
      t.eq(log[#log].code, 0, "процесс завершился без ошибки")

      -- новый Neovim: тема открывается из реестра, ответ виден из транскрипта
      env.reset(nil, true)
      local topic = q.open_topic(id)
      local text = window.text(topic)
      t.match(
        text,
        "Ответ после выхода.",
        "ответ из дописанного транскрипта"
      )
      t.eq(
        #p.ctl:starts(),
        1,
        "новый процесс для показа не запускался"
      )
    end
  )
end)
