-- Виды узлов из файлов Claude Code (спецификация node-view, решение D18): транскрипт
-- субагента репликами диалога и файл вывода фоновой команды. Оба только для чтения;
-- дополнения приходят по уведомлениям файловой системы модуля данных, таймеров нет.
local data = require("claudr.data")
local herdr = require("claudr.herdr")
local model = require("claudr.tree.model")
local window = require("claudr.view.window")

local M = {}

M.ROLE_TEXT = { user = "Пользователь:", assistant = "Агент:" }
M.STATE_TEXT =
  { running = "работает", finished = "завершена", orphaned = "оборвана" }
M.RESULT_TEXT = {
  completed = "выполнена",
  failed = "с ошибкой",
  killed = "остановлена",
}

local function present(v)
  return v ~= nil and v ~= vim.NIL and v ~= ""
end

local function reply_lines(replies)
  local out = {}
  for _, r in ipairs(replies) do
    out[#out + 1] = M.ROLE_TEXT[r.role] or r.role
    for _, l in ipairs(vim.split(r.text or "", "\n", { plain = true })) do
      out[#out + 1] = "  " .. l
    end
    out[#out + 1] = ""
  end
  return out
end

local function follow_end(v)
  if v.win and vim.api.nvim_win_is_valid(v.win) then
    vim.api.nvim_win_set_cursor(v.win, { vim.api.nvim_buf_line_count(v.buf), 0 })
  end
end

local function new_view(kind, node, title)
  local buf = window.scratch()
  vim.bo[buf].modifiable = false
  local win = window.open_float(buf, { title = title .. (node.label or node.id) })
  local v = { kind = kind, node_id = node.id, buf = buf, win = win }
  vim.b[buf].claudr_node_id = node.id
  return v
end

-- Путь транскрипта субагента: сессия панели-владельца, идентификатор субагента.
local function subagent_path(node)
  local owner = node.owner_pane and model.get(node.owner_pane)
  local sid = owner and herdr.session_id(owner.data)
  local agent_id = node.data and node.data.id
  if not sid or not agent_id then
    return nil
  end
  return data.subagent_transcript(sid, agent_id)
end

--- Транскрипт субагента: работающий дополняется по мере записи, завершённый читается
--- асинхронно порциями (`v.loaded` — чтение закончено) без слежения.
function M.open_subagent(node)
  local v = new_view("subagent", node, "субагент: ")
  local path = subagent_path(node)
  v.path = path
  function v.dispose()
    if v.handle then
      v.handle:close()
      v.handle = nil
    end
  end
  window.register(v)
  if not path then
    window.set_lines(v.buf, { "[транскрипт субагента недоступен]" })
    return v
  end
  if node.state == "running" then
    v.handle = data.watch_dialogue(path, function(replies)
      if v.released then
        return
      end
      window.append_lines(v.buf, reply_lines(replies))
      follow_end(v)
    end)
  else
    -- чтение асинхронное порциями: окно показывает прочитанное; закрытие вида его прекращает
    local shown = 0
    data.read_dialogue(path, function(replies)
      shown = shown + #replies
      window.append_lines(v.buf, reply_lines(replies))
    end, function(found)
      if not found then
        window.set_lines(
          v.buf,
          { "[транскрипт субагента недоступен]" }
        )
      elseif shown == 0 then
        window.set_lines(v.buf, { "" })
      end
      v.loaded = true
      follow_end(v)
    end, function()
      return v.released == true
    end)
  end
  return v
end

-- Строки статуса фоновой команды без файла вывода.
local function status_lines(task)
  local t = task or {}
  local lines = { "[файл вывода недоступен]" }
  lines[#lines + 1] = "Состояние: "
    .. (M.STATE_TEXT[t.status] or tostring(t.status or "неизвестно"))
  if present(t.result) then
    lines[#lines + 1] = "Итог: " .. (M.RESULT_TEXT[t.result] or tostring(t.result))
  end
  if present(t.exit_code) then
    lines[#lines + 1] = "Код выхода: " .. tostring(t.exit_code)
  else
    lines[#lines + 1] = "Код выхода: неизвестен"
  end
  return lines
end

-- Дописывает кусок вывода: первая часть продолжает последнюю строку буфера.
local function append_text(buf, chunk)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local text = chunk:gsub("\r\n", "\n"):gsub("\r", "")
  local parts = vim.split(text, "\n", { plain = true })
  vim.bo[buf].modifiable = true
  local count = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1] or ""
  parts[1] = last .. parts[1]
  vim.api.nvim_buf_set_lines(buf, count - 1, count, false, parts)
  vim.bo[buf].modifiable = false
end

--- Файл вывода фоновой команды по мере записи; без файла — сообщение, состояние и код
--- выхода из транскрипта (обновляются по изменениям дерева).
function M.open_task(node)
  local v = new_view("task", node, "команда: ")
  function v.dispose()
    if v.handle then
      v.handle:close()
      v.handle = nil
    end
    if v.unsubscribe then
      v.unsubscribe()
      v.unsubscribe = nil
    end
  end
  window.register(v)
  local file = node.data and node.data.output_file
  local handle = present(file)
    and data.watch_output(file, function(chunk)
      if v.released then
        return
      end
      append_text(v.buf, chunk)
      follow_end(v)
    end)
  if handle then
    v.handle = handle
    return v
  end
  v.unavailable = true
  window.set_lines(v.buf, status_lines(node.data))
  v.unsubscribe = model.subscribe(function()
    local n = model.get(v.node_id)
    if n and not v.released then
      window.set_lines(v.buf, status_lines(n.data))
    end
  end)
  return v
end

return M
