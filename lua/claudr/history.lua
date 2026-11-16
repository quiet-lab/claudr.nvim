-- История сессий (спецификация session-history): перечень сессий проекта панели и просмотр
-- диалога только для чтения. Перечень и диалог строятся по файлам Claude Code через модуль
-- `claudr.data`; к herdr обращение одно — снимок состояния ради отметки работающих сессий.
-- Таймеров и опроса нет: всё выполняется по действию пользователя.
local commands = require("claudr.commands")
local data = require("claudr.data")
local fs = require("claudr.data.fs")
local herdr = require("claudr.herdr")

local M = {}

--- Клавиша действия «история сессий» в дереве.
M.KEY = "H"
M.BUF_PREFIX = "claudr://history/"
M.FILETYPE = "claudr-history"

local PREVIEW_WIDTH = 60

local function notify(text, level)
  vim.notify("claudr: " .. text, level or vim.log.levels.INFO)
end

-- Идентификаторы сессий живых панелей из снимка herdr; без сервера — пустое множество.
local function live_sessions()
  local out = {}
  local st = herdr.state()
  if st.status ~= "connected" then
    return out
  end
  for _, pane in ipairs((st.snapshot and st.snapshot.panes) or {}) do
    local id = herdr.session_id(pane)
    if id then
      out[id] = true
    end
  end
  return out
end

-- Номер последнего перечня: более новый запрос делает прежний устаревшим.
local list_gen = 0

--- Сессии каталога проекта асинхронно: `cb(entries)` — существующие транскрипты, без тем
--- вопросов по коду, новые первыми. В записи к полям `claudr.data` добавлено `running` —
--- совпадение с сессией живой панели. Устаревший запрос (новый вызов) `cb` не вызывает.
---@param project_dir string
---@param cb fun(entries: table[])
function M.entries(project_dir, cb)
  list_gen = list_gen + 1
  local gen = list_gen
  local registry = require("claudr.questions.registry")
  local live = live_sessions()
  data.list_sessions(project_dir, function(list)
    local out = {}
    for _, s in ipairs(list) do
      if not registry.is_topic(s.id) then
        s.running = live[s.id] == true
        out[#out + 1] = s
      end
    end
    cb(out)
  end, function()
    return gen ~= list_gen
  end)
end

--- Начало первой реплики пользователя в одну строку.
local function preview(text)
  if not text or text:match("^%s*$") then
    return "(нет реплик пользователя)"
  end
  text = vim.trim(text:gsub("%s+", " "))
  if vim.fn.strchars(text) > PREVIEW_WIDTH then
    text = vim.fn.strcharpart(text, 0, PREVIEW_WIDTH) .. "…"
  end
  return text
end

--- Строка перечня: отметка, идентификатор, время последней записи, начало первой реплики.
---@param entry table запись `M.entries`
function M.format_entry(entry)
  return ("%s %s  %s  %s"):format(
    entry.running and "●" or " ",
    entry.id,
    os.date("%Y-%m-%d %H:%M", entry.mtime),
    preview(entry.first_user_text)
  )
end

-- Строки буфера диалога для реплик; `first` — реплики начинаются с начала диалога
-- (между репликами — пустая строка).
local function dialogue_lines(replies, first)
  local lines = {}
  for i, r in ipairs(replies) do
    if i > 1 or not first then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = r.role == "user" and "Пользователь:" or "Агент:"
    for _, l in ipairs(vim.split(r.text or "", "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. l
    end
  end
  return lines
end

-- Дописывает строки в буфер только для чтения; `first` — первая порция заменяет
-- содержимое пустого буфера.
local function append(buf, lines, first)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  if first then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
end

--- Открывает диалог сессии в новом окне, буфер только для чтения. Реплики читаются
--- асинхронно порциями и дописываются в буфер по мере чтения; по концу чтения (реплик и
--- рабочего каталога сессии) буферная переменная `claudr_loaded` становится истинной.
--- Закрытие окна (удаление буфера) и повторное открытие той же сессии прекращают чтение.
--- Транскрипта, которого уже нет, — сообщение о недоступности. Возвращает номер буфера или
--- `nil`.
---@param entry table запись перечня (нужны `id` и `path`)
function M.open_dialogue(entry)
  local function unavailable()
    notify(
      ("транскрипт сессии %s недоступен"):format(entry.id),
      vim.log.levels.WARN
    )
  end
  if not fs.is_file(entry.path) then
    unavailable()
    return nil
  end
  local name = M.BUF_PREFIX .. entry.id
  local old = vim.fn.bufnr(name)
  if old ~= -1 then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  vim.cmd("rightbelow vnew")
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  -- буфер переживает уход из окна (переход по ссылке, `<C-o>` возвращает); закрытие окна,
  -- где он показан, и `q` его удаляют
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end)
    end,
  })
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = M.FILETYPE
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
  local function cancelled()
    return not vim.api.nvim_buf_is_valid(buf)
  end
  -- относительные пути ссылок — от рабочего каталога сессии из её транскрипта; он
  -- читается асинхронно, ссылки спрашивают его при переходе
  local cwd
  local parts = 2 -- чтение рабочего каталога и чтение реплик
  local function part_done()
    parts = parts - 1
    if parts == 0 and vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].claudr_loaded = true
    end
  end
  data.session_cwd(entry.path, function(found)
    cwd = found
    part_done()
  end, cancelled)
  require("claudr.refs").attach(buf, {
    cwd = function()
      return cwd
    end,
  })
  local shown = 0
  data.read_dialogue(entry.path, function(replies)
    append(buf, dialogue_lines(replies, shown == 0), shown == 0)
    shown = shown + #replies
  end, function(found)
    if not found then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      unavailable()
      return
    end
    part_done()
  end, cancelled)
  vim.keymap.set(
    "n",
    "q",
    "<cmd>bwipeout<cr>",
    { buffer = buf, silent = true, desc = "claudr: закрыть диалог" }
  )
  return buf
end

--- Показывает перечень сессий проекта через `vim.ui.select`; выбор открывает диалог.
---@param project_dir string
function M.show_project(project_dir)
  M.entries(project_dir, function(entries)
    if #entries == 0 then
      notify(
        "в проекте нет сессий с доступными транскриптами"
      )
      return
    end
    vim.ui.select(entries, {
      prompt = "Сессии проекта",
      format_item = M.format_entry,
    }, function(choice)
      if choice then
        M.open_dialogue(choice)
      end
    end)
  end)
end

--- Перечень сессий проекта панели с идентификатором сессии `session_id`: каталог проекта —
--- по расположению её транскрипта. Транскрипта ещё нет — сообщение.
---@param session_id string|nil
function M.show_for_session(session_id)
  if not session_id then
    notify("у панели нет сессии Claude Code", vim.log.levels.WARN)
    return
  end
  local dir = data.project_dir(session_id)
  if not dir then
    notify(
      "транскрипта сессии панели ещё нет, каталог проекта неизвестен",
      vim.log.levels.WARN
    )
    return
  end
  M.show_project(dir)
end

--- Перечень для узла дерева: панель с агентом или (для субагента и фоновой команды)
--- панель-владелец.
---@param node table
function M.show_for_node(node)
  local model = require("claudr.tree.model")
  if node.kind == "tab" or node.kind == "workspace" then
    -- строка вкладки — агент вкладки
    node = model.agent_node(node) or node
  elseif node.kind ~= "pane" and node.owner_pane then
    local owner = model.get(node.owner_pane)
    if owner then
      node = owner
    end
  end
  if node.kind ~= "pane" or node.pane_kind ~= "agent" then
    notify("выберите панель с агентом Claude Code", vim.log.levels.WARN)
    return
  end
  M.show_for_session(herdr.session_id(node.data))
end

-- Панели с агентом Claude Code из снимка herdr.
local function claude_panes()
  local out = {}
  local st = herdr.state()
  if st.status == "connected" then
    for _, pane in ipairs((st.snapshot and st.snapshot.panes) or {}) do
      if herdr.session_id(pane) then
        out[#out + 1] = pane
      end
    end
  end
  return out
end

local function pane_title(pane)
  return ("%s  %s"):format(
    pane.pane_id,
    pane.terminal_title_stripped or pane.display_agent or pane.agent or ""
  )
end

-- Подкоманда: без аргумента — узел под курсором в дереве, иначе выбор панели; с аргументом —
-- идентификатор панели или идентификатор сессии (работает и без сервера herdr).
local function run_command(args)
  local arg = args[1]
  if arg then
    for _, pane in ipairs(claude_panes()) do
      if pane.pane_id == arg then
        return M.show_for_session(herdr.session_id(pane))
      end
    end
    return M.show_for_session(arg)
  end
  local node = require("claudr.tree.view").node_at_cursor()
  if node then
    return M.show_for_node(node)
  end
  local panes = claude_panes()
  if #panes == 0 then
    notify(
      "панелей с агентом Claude Code нет (откройте дерево `:Claudr tree` или укажите идентификатор сессии)",
      vim.log.levels.WARN
    )
    return
  end
  vim.ui.select(panes, { prompt = "Панель", format_item = pane_title }, function(pane)
    if pane then
      M.show_for_session(herdr.session_id(pane))
    end
  end)
end

--- Регистрирует подкоманду `history` и действие дерева на клавише `M.KEY`.
function M.setup()
  commands.register("history", run_command, {
    desc = "история сессий проекта панели: перечень и просмотр диалога",
  })
  require("claudr.tree.view").register_action("history", {
    key = M.KEY,
    desc = "история сессий проекта панели",
    run = M.show_for_node,
  })
end

return M
