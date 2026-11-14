-- Вид завершённого субагента читает транскрипт асинхронно порциями (спецификации node-view,
-- claude-code-data): окно открывается до чтения и показывает прочитанное, закрытие вида
-- прекращает чтение.
local t = require("helpers.t")
local s = require("view.support")
local u = require("data.util")
local view = require("claudr.view")
local model = require("claudr.tree.model")
local fs = require("claudr.data.fs")
local fixtures = s.fixtures

local CHUNK = fs.CHUNK
local reads

before_each(function()
  fs.CHUNK = 8 * 1024
end)

after_each(function()
  if reads then
    reads.restore()
    reads = nil
  end
  fs.CHUNK = CHUNK
  s.reset()
end)

-- Узел завершённого субагента; его транскрипт заменён синтетическим диалогом.
local function finished_node()
  s.big_editor()
  s.env(s.snapshot({ s.claude_pane("w1:p1", "subagent-command") }), { "subagent-command" })
  local node
  t.wait(function()
    node = model.find(function(n)
      return n.kind == "subagent" and n.state == "finished"
    end)[1]
    return node ~= nil
  end, "узел субагента")
  local path = fixtures.session_dir("subagent-command")
    .. "/subagents/agent-"
    .. node.data.id
    .. ".jsonl"
  local replies = u.big_dialogue(path, fixtures.session_id("subagent-command"), 100, 4 * 1024)
  return node, replies
end

local function role_lines(buf)
  local n = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == "Пользователь:" or l == "Агент:" then
      n = n + 1
    end
  end
  return n
end

describe(
  "Завершённый субагент — асинхронное чтение",
  function()
    it(
      "окно открывается до чтения; прочитанное показано; итог прежний",
      function()
        local node, replies = finished_node()
        reads = u.count_reads()
        local v = view.open(node)
        t.eq(
          reads.read,
          0,
          "при возврате ни одной порции не прочитано"
        )
        t.ok(not v.loaded)
        t.ok(vim.api.nvim_win_is_valid(v.win), "окно открыто")
        local at_first
        vim.api.nvim_buf_attach(v.buf, false, {
          on_lines = function()
            at_first = at_first or { loaded = v.loaded }
          end,
        })
        t.wait(function()
          return v.loaded
        end, "конец чтения транскрипта")
        t.ok(
          not at_first.loaded,
          "первая порция показана до конца чтения"
        )
        t.eq(role_lines(v.buf), #replies, "весь транскрипт репликами")
        t.eq(v.handle, nil, "слежения нет")
      end
    )

    it(
      "закрытие вида во время чтения прекращает чтение",
      function()
        local node = finished_node()
        -- порции диалога этого вида считаются отдельно: дерево читает свои файлы сам
        local data = require("claudr.data")
        local orig = data.read_dialogue
        local delivered = 0
        data.read_dialogue = function(path, on_replies, ...)
          return orig(path, function(replies)
            delivered = delivered + 1
            return on_replies(replies)
          end, ...)
        end
        local v = view.open(node)
        local closed = false
        vim.api.nvim_buf_attach(v.buf, false, {
          on_lines = function()
            if not closed then
              closed = true
              vim.schedule(function()
                if vim.api.nvim_win_is_valid(v.win) then
                  s.close_win(v)
                end
              end)
            end
          end,
        })
        t.wait(function()
          return v.released == true
        end, "вид закрыт после первой порции")
        u.settle()
        local after_close = delivered
        u.settle()
        u.settle()
        data.read_dialogue = orig
        t.eq(
          delivered,
          after_close,
          "после закрытия порции не читаются"
        )
        t.ok(not v.loaded, "конец чтения не сообщается")
      end
    )
  end
)
