-- Окно ввода (спецификация message-input, «Отправка сообщения»): после отправки клавишей из
-- режима вставки окно закрывается, а Neovim возвращается в нормальный режим в прежнем окне.
-- Режим вставки в безголовом процессе теста не наступает до конца команды, поэтому проверка
-- идёт в дочернем Neovim по RPC: нажатия — `nvim_input`, состояние — следующим запросом,
-- который обрабатывается после введённых клавиш.
local t = require("helpers.t")

local child

local function request(method, ...)
  return vim.rpcrequest(child, method, ...)
end

local function lua(code)
  return request("nvim_exec_lua", code, {})
end

before_each(function()
  child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "--clean", "-n" }, {
    rpc = true,
  })
  t.ok(child > 0, "дочерний Neovim запущен")
  lua(([[
    vim.opt.runtimepath:prepend(%q)
    package.path = %q .. "/lua/?.lua;" .. %q .. "/lua/?/init.lua;" .. package.path
    _G.sent = {}
    _G.prev = vim.api.nvim_get_current_win()
    require("claudr.input").open({
      title = "тест",
      target = { kind = "message", key = "s1" },
      on_submit = function(text, close)
        table.insert(_G.sent, text)
        if not _G.keep then
          close()
        end
      end,
    })
    _G.input_win = vim.api.nvim_get_current_win()
  ]]):format(t.root, t.root, t.root))
end)

after_each(function()
  vim.fn.jobstop(child)
  vim.fn.jobwait({ child })
end)

describe("Отправка сообщения", function()
  for _, key in ipairs({ "<S-CR>", "<S-Space>" }) do
    it(
      "отправка "
        .. key
        .. " из режима вставки возвращает нормальный режим в прежнем окне",
      function()
        request("nvim_input", "текст" .. key)
        local st = lua([[
          return {
            sent = _G.sent,
            mode = vim.api.nvim_get_mode().mode,
            back = vim.api.nvim_get_current_win() == _G.prev,
            wins = #vim.api.nvim_list_wins(),
          }
        ]])
        t.eq(st.sent, { "текст" })
        t.eq(st.mode, "n")
        t.ok(st.back, "фокус в прежнем окне")
        t.eq(st.wins, 1, "окно ввода закрыто")
      end
    )
  end

  it(
    "окно, оставшееся открытым после отправки, не выходит из режима вставки",
    function()
      lua("_G.keep = true")
      request("nvim_input", "текст<S-CR>")
      local st = lua([[
        return {
          mode = vim.api.nvim_get_mode().mode,
          cur = vim.api.nvim_get_current_win() == _G.input_win,
          sent = _G.sent,
        }
      ]])
      t.eq(st.sent, { "текст" })
      t.eq(st.mode, "i")
      t.ok(st.cur, "фокус в окне ввода")
    end
  )
end)
