-- Вопросы по коду: поставщики контекста, вопрос по выделению и по файлу (спецификация
-- code-questions).
local t = require("helpers.t")
local env = require("questions.env")
local context = require("claudr.questions.context")

local q

before_each(function()
  env.reset()
  q = require("claudr.questions")
end)

local function collect(req)
  local packet
  context.collect(req, function(p)
    packet = p
  end)
  t.wait(function()
    return packet ~= nil
  end, "пакет контекста")
  return packet
end

--- Языковой сервер в том же процессе: отвечает на definition и hover.
local function start_fake_lsp(bufnr, root, def_path)
  local id = 0
  local client_id = vim.lsp.start({
    name = "fake-ls",
    root_dir = root,
    cmd = function()
      local closing = false
      return {
        request = function(method, _, callback)
          id = id + 1
          local result
          if method == "initialize" then
            result = { capabilities = { definitionProvider = true, hoverProvider = true } }
          elseif method == "textDocument/definition" then
            result = {
              uri = vim.uri_from_fname(def_path),
              range = {
                start = { line = 2, character = 15 },
                ["end"] = { line = 2, character = 18 },
              },
            }
          elseif method == "textDocument/hover" then
            result = { contents = { kind = "markdown", value = "function bar(x: number): number" } }
          elseif method == "shutdown" then
            result = vim.NIL
          end
          vim.schedule(function()
            callback(nil, result)
          end)
          return true, id
        end,
        notify = function()
          return true
        end,
        is_closing = function()
          return closing
        end,
        terminate = function()
          closing = true
        end,
      }
    end,
  }, { bufnr = bufnr })
  t.wait(function()
    local c = vim.lsp.get_client_by_id(client_id)
    return c ~= nil and c.initialized
  end, "языковой сервер готов")
  return client_id
end

describe("Вопрос по выделению", function()
  it(
    "Вопрос по выделению: текст вопроса, путь, диапазон 10–20 и текст строк",
    function()
      local p = env.project()
      local buf = env.edit(p.foo, 10)
      vim.cmd("normal! 10GV20G")
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
      local topic
      q.ask_selection({
        question = "Зачем эти строки?",
        on_topic = function(tp)
          topic = tp
        end,
      })
      t.wait(function()
        return topic ~= nil
      end)
      env.wait_idle(topic)
      local sent = p.ctl:starts()[1].question
      t.match(sent, "^Зачем эти строки%?")
      t.ok(sent:find("lua/foo.lua", 1, true), "путь файла")
      t.ok(sent:find("lines 10-20", 1, true), "диапазон строк")
      local lines = vim.api.nvim_buf_get_lines(buf, 9, 20, false)
      t.ok(
        sent:find(table.concat(lines, "\n"), 1, true),
        "текст выделенных строк"
      )
      t.ok(
        not sent:find("-- строка 21", 1, true),
        "строки вне выделения не уходят"
      )
    end
  )

  it(
    "выделение клавишей <Plug>(claudr-ask) в визуальном режиме",
    function()
      local p = env.project()
      env.edit(p.foo, 3)
      local orig = vim.ui.input
      vim.ui.input = function(_, cb)
        cb("Что здесь?")
      end
      vim.keymap.set("x", "<F5>", "<Plug>(claudr-ask)", { remap = true })
      vim.cmd("normal! 3GV6G")
      vim.api.nvim_feedkeys(vim.keycode("<F5>"), "x", false)
      vim.ui.input = orig
      t.wait(function()
        return #p.ctl:starts() == 1
      end, "вопрос отправлен")
      local sent = p.ctl:starts()[1].question
      t.ok(sent:find("lines 3-6", 1, true))
      t.ok(sent:find("local function bar(x)", 1, true))
    end
  )
end)

describe("Вопрос по файлу", function()
  it(
    "Вопрос по файлу: путь файла и содержимое буфера с несохранёнными правками",
    function()
      local p = env.project()
      local buf = env.edit(p.foo, 1)
      vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "-- несохранённая правка" })
      local topic
      q.ask_file({
        question = "О чём файл?",
        on_topic = function(tp)
          topic = tp
        end,
      })
      t.wait(function()
        return topic ~= nil
      end)
      env.wait_idle(topic)
      local sent = p.ctl:starts()[1].question
      t.match(sent, "^О чём файл%?")
      t.ok(sent:find("File: lua/foo.lua", 1, true), "путь файла")
      t.ok(
        sent:find("-- несохранённая правка", 1, true),
        "несохранённая правка"
      )
      t.ok(sent:find("return M", 1, true), "содержимое целиком")
      t.eq(vim.bo[buf].modified, true, "буфер не сохранялся")
    end
  )
end)

describe("Поставщики контекста", function()
  it(
    "Нет языкового сервера: файл, строки, выделение и узел tree-sitter, ошибки нет",
    function()
      local p = env.project()
      local buf = env.edit(p.foo, 4)
      t.eq(#vim.lsp.get_clients({ bufnr = buf }), 0)
      local packet = collect({
        bufnr = buf,
        kind = "selection",
        range = { 4, 5 },
        cursor = { 4, 2 },
        project_dir = p.dir,
      })
      t.eq(packet.file, "lua/foo.lua")
      t.eq(packet.lines, { 4, 5 })
      t.eq(packet.text, "  local y = x + 1\n  return y * 2")
      t.ok(packet.node, "узел tree-sitter")
      t.match(packet.node.type, "function")
      t.eq(packet.node.lines, { 3, 6 })
      t.eq(packet.symbol, "bar")
      t.eq(packet.definition, nil)
      t.eq(packet.hover, nil)
    end
  )

  it(
    "с языковым сервером — определение и описание символа",
    function()
      local p = env.project()
      local buf = env.edit(p.foo, 8, 6)
      local cid = start_fake_lsp(buf, p.dir, p.foo)
      local packet =
        collect({ bufnr = buf, kind = "cursor", cursor = { 8, 6 }, project_dir = p.dir })
      t.eq(packet.definition, { file = "lua/foo.lua", line = 3, text = "local function bar(x)" })
      t.eq(packet.hover, "function bar(x: number): number")
      local text = context.format("Вопрос", packet)
      t.ok(text:find("Definition: lua/foo.lua:3", 1, true))
      t.ok(text:find("function bar(x: number): number", 1, true))
      vim.lsp.stop_client(cid, true)
    end
  )

  it(
    "Поставщик для типа файла: его данные добавляются к данным общего",
    function()
      local p = env.project()
      local buf = env.edit(p.foo, 4)
      local seen
      q.register_provider("lua", function(req, packet)
        seen = { req.bufnr, packet.file }
        return { runtime = "LuaJIT", module = "foo" }
      end)
      q.register_provider("python", function()
        return { wrong = true }
      end)
      local packet =
        collect({ bufnr = buf, kind = "cursor", cursor = { 4, 2 }, project_dir = p.dir })
      t.eq(seen, { buf, "lua/foo.lua" })
      t.eq(packet.runtime, "LuaJIT")
      t.eq(packet.module, "foo")
      t.eq(
        packet.wrong,
        nil,
        "поставщик другого типа файла не вызывается"
      )
      t.eq(
        packet.file,
        "lua/foo.lua",
        "данные общего поставщика сохранены"
      )
      t.ok(packet.node)
      local topic = env.ask()
      env.wait_idle(topic)
      local sent = p.ctl:starts()[1].question
      t.ok(sent:find("runtime: LuaJIT", 1, true))
    end
  )
end)

describe("Текст вопроса и пакет контекста", function()
  it(
    "окно темы показывает только вопрос, без пакета контекста",
    function()
      local p = env.project()
      env.edit(p.foo, 4)
      local topic = env.ask({ question = "Короткий вопрос" })
      env.wait_idle(topic)
      local text = require("claudr.questions.window").text(topic)
      t.ok(text:find("Короткий вопрос", 1, true))
      t.ok(not text:find(context.SEPARATOR, 1, true))
      t.ok(not text:find("Enclosing", 1, true))
      t.eq(context.strip(p.ctl:starts()[1].question), "Короткий вопрос")
    end
  )
end)
