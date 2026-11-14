-- Общая подготовка тестов вопросов по коду: проект с репозиторием git, поддельный `claude`,
-- чистое состояние плагина перед каждым тестом.
local t = require("helpers.t")
local fake = require("helpers.fake_claude")

local M = {}

local counter = 0

--- Текст файла `lua/foo.lua` проекта: функция `bar` в строках 3–6, всего 50 строк.
function M.foo_lines()
  local lines = {
    "local M = {}",
    "",
    "local function bar(x)",
    "  local y = x + 1",
    "  return y * 2",
    "end",
    "",
    "M.bar = bar",
  }
  for i = #lines + 1, 49 do
    lines[i] = ("-- строка %d"):format(i)
  end
  lines[50] = "return M"
  return lines
end

--- Новый проект: каталог с `.git` и файлом `lua/foo.lua`; поддельный `claude` с журналом.
---@return { dir: string, foo: string, ctl: table }
function M.project()
  counter = counter + 1
  local base = vim.fs.joinpath(t.tmpdir(), ("p%d"):format(counter))
  local dir = vim.fs.joinpath(base, "proj")
  vim.fn.mkdir(vim.fs.joinpath(dir, ".git"), "p")
  vim.fn.mkdir(vim.fs.joinpath(dir, "lua"), "p")
  dir = assert(vim.uv.fs_realpath(dir))
  local foo = vim.fs.joinpath(dir, "lua", "foo.lua")
  vim.fn.writefile(M.foo_lines(), foo)
  local ctl = fake.setup(vim.fs.joinpath(base, "ctl"))
  ctl:apply()
  return { dir = dir, foo = foo, ctl = ctl }
end

--- Открывает файл в единственном окне и ставит курсор.
function M.edit(path, line, col)
  vim.cmd("silent! only")
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { line or 1, col or 0 })
  return vim.api.nvim_get_current_buf()
end

--- Чистое состояние: модуль, реестр, буферы тем, настройки. С `keep_registry` — как после
--- перезапуска Neovim: реестр и транскрипты остаются.
function M.reset(opts, keep_registry)
  vim.cmd("silent! only")
  vim.cmd("enew")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  require("claudr.questions.topic")._reset()
  require("claudr.questions.context").unregister()
  if not keep_registry then
    vim.fn.delete(require("claudr.questions.registry").path())
  end
  require("claudr").setup(opts)
end

--- Задаёт вопрос из текущего буфера и возвращает тему.
function M.ask(opts)
  local q = require("claudr.questions")
  local topic
  opts = vim.tbl_extend("force", { question = "Что делает bar?" }, opts or {})
  local on_topic = opts.on_topic
  opts.on_topic = function(tp)
    topic = tp
    if on_topic then
      on_topic(tp)
    end
  end
  q.ask(opts)
  t.wait(function()
    return topic ~= nil
  end, "тема создана")
  return topic
end

--- Ждёт, пока процесс темы закончит все вопросы.
function M.wait_idle(topic, msg)
  t.wait(function()
    if topic.proc or #topic.queue > 0 then
      return false
    end
    for _, e in ipairs(topic.entries) do
      if e.status == "running" or e.status == "queued" then
        return false
      end
    end
    return true
  end, msg or "ответ получен")
end

--- Значение ключа в argv (`nil`, если ключа нет).
function M.arg(argv, key)
  for i, a in ipairs(argv) do
    if a == key then
      return argv[i + 1] or true
    end
  end
  return nil
end

function M.has(argv, key)
  return vim.tbl_contains(argv, key)
end

return M
