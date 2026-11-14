-- Окно ввода (спецификация message-input, решение D30): отправка сохранением и клавишами,
-- пустой текст, черновик по ключам, занятость окна. Без сервера: цель отправки — функция теста.
local t = require("helpers.t")
local input = require("claudr.input")
local config = require("claudr.config")

local notes
local saved_notify

before_each(function()
  notes = {}
  saved_notify = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
end)

after_each(function()
  vim.notify = saved_notify
  input.reset(true)
  config.setup({})
  vim.cmd("stopinsert")
end)

local function open(key, on_submit, kind)
  local w = input.open({
    title = "тест",
    target = { kind = kind or "message", key = key },
    on_submit = on_submit or function() end,
  })
  return w.buf, w
end

local function set_text(buf, text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

local function write(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
end

describe("Окно ввода сообщения", function()
  it(
    "окно плавающее, буфер обычный и редактируемый",
    function()
      local buf, w = open("s1")
      t.eq(vim.api.nvim_win_get_config(w.win).relative, "editor")
      t.eq(vim.bo[buf].buftype, "acwrite")
      t.ok(vim.bo[buf].modifiable)
      t.eq(vim.api.nvim_get_current_win(), w.win)
      t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "" })
    end
  )

  it(
    "повторное открытие для той же цели только переводит фокус",
    function()
      local buf, w = open("s1")
      vim.cmd("wincmd p")
      local again =
        input.open({ target = { kind = "message", key = "s1" }, on_submit = function() end })
      t.eq(again.buf, buf)
      t.eq(vim.api.nvim_get_current_win(), w.win)
    end
  )
end)

describe("Отправка сообщения", function()
  it("Отправка сохранением", function()
    local got = {}
    local buf = open("s1", function(text, close)
      got[#got + 1] = text
      close()
    end)
    set_text(buf, "текст")
    write(buf)
    t.eq(got, { "текст" })
    t.wait(function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, "окно закрыто")
  end)

  it(
    "Shift+Enter и Shift+Space в нормальном режиме и режиме вставки",
    function()
      for _, case in ipairs({
        { "<S-CR>", "n" },
        { "<S-Space>", "n" },
        { "<S-CR>", "i" },
        { "<S-Space>", "i" },
      }) do
        local got = {}
        local buf = open("k" .. case[1] .. case[2], function(text, close)
          got[#got + 1] = text
          close()
        end)
        set_text(buf, "ключ")
        vim.cmd(case[2] == "i" and "startinsert" or "stopinsert")
        t.ok(
          vim.fn.maparg(case[1], case[2], false, true).buffer == 1,
          case[1] .. " назначена в режиме " .. case[2]
        )
        feed(case[1])
        t.eq(got, { "ключ" }, case[1] .. " в режиме " .. case[2])
      end
    end
  )

  it(
    "клавиши отправки переназначаются настройкой",
    function()
      config.setup({ message_input = { send = { "<C-s>" } } })
      local got = {}
      local buf = open("s1", function(text, close)
        got[#got + 1] = text
        close()
      end)
      set_text(buf, "свой")
      t.eq(
        vim.fn.maparg("<S-CR>", "n", false, true).buffer,
        nil,
        "прежняя клавиша не назначена"
      )
      feed("<C-s>")
      t.eq(got, { "свой" })
    end
  )

  it("Пустое сообщение", function()
    local calls = 0
    local buf = open("s1", function()
      calls = calls + 1
    end)
    write(buf)
    set_text(buf, "  \n\t ")
    write(buf)
    feed("<S-CR>")
    t.eq(calls, 0)
    t.ok(vim.api.nvim_buf_is_valid(buf), "окно остаётся")
  end)

  it("Многострочный текст передаётся как есть", function()
    local got
    local buf = open("s1", function(text, close)
      got = text
      close()
    end)
    local text = '  a "q" \\ ё\n\n\tb\n'
    set_text(buf, text)
    write(buf)
    t.eq(got, text)
  end)

  it(
    "занятое окно не отправляет повторно, пока не вызван release",
    function()
      local calls, release = 0, nil
      local buf = open("s1", function(_, _, rel)
        calls = calls + 1
        release = rel
        return true
      end)
      set_text(buf, "a")
      write(buf)
      write(buf)
      t.eq(calls, 1)
      release()
      write(buf)
      t.eq(calls, 2)
    end
  )

  it(
    ":wq после отправки закрывает только окно ввода",
    function()
      vim.cmd("vsplit")
      local other = vim.api.nvim_get_current_win()
      local buf = open("s1", function(_, close)
        close()
      end)
      set_text(buf, "x")
      vim.cmd("wq")
      t.wait(function()
        return not vim.api.nvim_buf_is_valid(buf)
      end, "окно ввода закрыто")
      t.ok(vim.api.nvim_win_is_valid(other), "соседнее окно цело")
      vim.api.nvim_win_close(other, true)
    end
  )
end)

describe("Черновик", function()
  it("Закрытие без отправки", function()
    local buf, w = open("s1")
    set_text(buf, "черновик\nвторая")
    vim.api.nvim_win_close(w.win, true)
    t.eq(input.draft({ kind = "message", key = "s1" }), "черновик\nвторая")
    local buf2 = open("s1")
    t.eq(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), { "черновик", "вторая" })
  end)

  it(
    "закрытие командой :q не требует отказа от изменений",
    function()
      local buf = open("s1")
      set_text(buf, "ещё")
      vim.api.nvim_feedkeys("", "x", false)
      vim.cmd("stopinsert")
      t.ok(vim.api.nvim_buf_call(buf, function()
        return not vim.bo.modified
      end))
      vim.cmd("close")
      t.eq(input.draft({ kind = "message", key = "s1" }), "ещё")
    end
  )

  it("Другая сессия", function()
    local buf, w = open("s1")
    set_text(buf, "про первую")
    vim.api.nvim_win_close(w.win, true)
    local buf2 = open("s2")
    t.eq(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), { "" })
    set_text(buf2, "про вторую")
    input.reset()
    t.eq(input.draft({ kind = "message", key = "s1" }), "про первую")
    t.eq(input.draft({ kind = "message", key = "s2" }), "про вторую")
  end)

  it(
    "разные виды цели с одним ключом хранятся раздельно",
    function()
      local buf, w = open("k", nil, "message")
      set_text(buf, "сообщение")
      vim.api.nvim_win_close(w.win, true)
      local buf2 = open("k", nil, "text")
      t.eq(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), { "" })
    end
  )

  it("успешная отправка очищает черновик", function()
    local buf = open("s1", function(_, close)
      close()
    end)
    set_text(buf, "ушло")
    write(buf)
    t.wait(function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, "окно закрыто")
    t.eq(input.draft({ kind = "message", key = "s1" }), nil)
    local buf2 = open("s1")
    t.eq(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), { "" })
  end)

  it("close(true) закрывает окно и сохраняет черновик", function()
    local buf = open("s1", function(_, close)
      close(true)
    end)
    set_text(buf, "остаётся")
    write(buf)
    t.wait(function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, "окно закрыто")
    t.eq(input.draft({ kind = "message", key = "s1" }), "остаётся")
  end)
end)

describe("Настройки окна ввода", function()
  it("значения по умолчанию", function()
    local cfg = config.get().message_input
    t.eq(cfg.send, { "<S-CR>", "<S-Space>" })
    t.eq(cfg.guard_commands, false)
    t.eq(cfg.key, "m")
  end)
end)
