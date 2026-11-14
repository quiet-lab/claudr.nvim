-- Диалог из истории читается асинхронно порциями (спецификации session-history,
-- claude-code-data): окно открывается до чтения и показывает прочитанное, закрытие окна и
-- повторное открытие прекращают прежнее чтение. Проверяются порядок событий и счётчики.
local t = require("helpers.t")
local u = require("data.util")
local fs = require("claudr.data.fs")
local history = require("claudr.history")

local CHUNK = fs.CHUNK
local SID = "00000000-0000-4000-8000-0000000000c1"
local COUNT, SIZE = 120, 4 * 1024

local reads, fds

before_each(function()
  fs.CHUNK = 8 * 1024
  fds = u.count_fds()
  vim.cmd("silent! only")
  vim.cmd("enew")
end)

after_each(function()
  if reads then
    reads.restore()
    reads = nil
  end
  fds.restore()
  fs.CHUNK = CHUNK
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("^claudr://history/") then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end)

local function dialogue()
  local dir = u.fresh()
  local path = dir .. "/" .. SID .. ".jsonl"
  local expected = u.big_dialogue(path, SID, COUNT, SIZE)
  return { id = SID, path = path }, expected
end

local function expected_lines(replies)
  local lines = {}
  for i, r in ipairs(replies) do
    if i > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = r.role == "user" and "Пользователь:" or "Агент:"
    for _, l in ipairs(vim.split(r.text, "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. l
    end
  end
  return lines
end

local function loaded(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.b[buf].claudr_loaded == true
end

describe("Диалог из истории — асинхронное чтение", function()
  it(
    "окно открывается до чтения, показывает прочитанное, итог прежний",
    function()
      local entry, replies = dialogue()
      reads = u.count_reads()
      local buf = history.open_dialogue(entry)
      t.ok(buf, "окно открыто")
      t.eq(
        reads.read,
        0,
        "при возврате ни одной порции не прочитано"
      )
      t.ok(not loaded(buf))
      t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "" })
      -- при первом изменении буфера чтение не закончено
      local at_first
      local changes = 0
      vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
          changes = changes + 1
          if not at_first then
            at_first =
              { loaded = vim.b[buf].claudr_loaded, lines = vim.api.nvim_buf_line_count(buf) }
          end
        end,
      })
      t.wait(function()
        return loaded(buf)
      end, "конец чтения диалога")
      t.ok(changes > 3, "реплики пришли порциями: " .. changes)
      t.ok(
        not at_first.loaded,
        "первая порция показана до конца чтения"
      )
      t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected_lines(replies))
      t.eq(vim.bo[buf].modifiable, false)
      t.eq(vim.bo[buf].readonly, true)
      t.eq(fds.live(), 0, "дескрипторы закрыты")
    end
  )

  it(
    "закрытие окна во время чтения прекращает чтение",
    function()
      local entry = dialogue()
      reads = u.count_reads()
      local buf = history.open_dialogue(entry)
      local closed = false
      vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
          if not closed then
            closed = true
            vim.schedule(function()
              pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end)
          end
        end,
      })
      t.wait(function()
        return closed and not vim.api.nvim_buf_is_valid(buf)
      end, "окно закрыто после первой порции")
      u.settle()
      local after_close = reads.read
      u.settle()
      u.settle()
      t.eq(
        reads.read,
        after_close,
        "после закрытия порции не читаются"
      )
      t.eq(fds.live(), 0, "дескрипторы закрыты")
    end
  )

  it(
    "повторное открытие: прежнее чтение устарело, ответ в новое окно",
    function()
      local entry, replies = dialogue()
      local first = history.open_dialogue(entry)
      local second = history.open_dialogue(entry)
      t.ok(first ~= second)
      t.ok(not vim.api.nvim_buf_is_valid(first), "прежнее окно закрыто")
      t.wait(function()
        return loaded(second)
      end, "конец чтения диалога")
      u.settle()
      t.eq(vim.api.nvim_buf_get_lines(second, 0, -1, false), expected_lines(replies))
      t.eq(fds.live(), 0)
    end
  )

  it(
    "перечень сессий: устаревший запрос не отдаёт перечень",
    function()
      local dir = u.fresh("history-project")
      local project = dir .. "/projects/" .. require("helpers.fixtures").project
      local first, second = 0, nil
      history.entries(project, function()
        first = first + 1
      end)
      history.entries(project, function(list)
        second = list
      end)
      t.wait(function()
        return second ~= nil
      end, "перечень сессий")
      u.settle()
      u.settle()
      t.eq(first, 0, "устаревший запрос без ответа")
      t.eq(#second, 3)
      t.eq(fds.live(), 0)
    end
  )
end)
