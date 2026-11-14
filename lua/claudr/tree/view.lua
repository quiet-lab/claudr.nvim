-- Отображение дерева (спецификация agent-tree, решения D2 и D17): собственный буфер и окно
-- Neovim без сторонних плагинов. Буфер перерисовывается по каждому уведомлению модели;
-- таймеров нет.
--
-- Другие модули добавляют действия над узлом под курсором через `register_action`, файлы
-- дерева при этом не правятся.
local model = require("claudr.tree.model")

local M = {}

M.BUF_NAME = "claudr://tree"
M.FILETYPE = "claudr-tree"
M.WIDTH = 50

local ns = vim.api.nvim_create_namespace("claudr.tree")

local S = {
  buf = nil,
  line_ids = {}, -- строка (с 1) → идентификатор узла
  collapsed = {}, -- идентификатор узла → true, если узел свёрнут
  unsubscribe = nil,
  unsubscribe_pending = nil,
}

---@class claudr.TreeAction
---@field key string|nil клавиша в буфере дерева
---@field desc string|nil описание для подсказки
---@field run fun(node: table) действие над узлом под курсором

---@type table<string, claudr.TreeAction>
local actions = {}
local action_order = {}

-- Обозначения видов узлов.
M.ICONS = {
  workspace = "W",
  tab = "T",
  agent = "A",
  command = "$",
  subagent = "S",
  task = "&",
}

-- Подписи состояний субагентов и фоновых команд.
M.STATE_TEXT = {
  running = "работает",
  finished = "завершён",
  orphaned = "оборван",
}

-- Подписи состояния клиента herdr над деревом (при подключённом клиенте строки нет).
M.STATUS_TEXT = {
  stopped = "herdr: не подключено",
  connecting = "herdr: подключение…",
  no_server = "herdr: нет сервера",
  incompatible = "herdr: несовместимый сервер",
}

local HL = {
  header = "ClaudrTreeStatus",
  running = "ClaudrTreeRunning",
  finished = "ClaudrTreeFinished",
  orphaned = "ClaudrTreeOrphaned",
  idle = "ClaudrTreeIdle",
  working = "ClaudrTreeWorking",
  blocked = "ClaudrTreeBlocked",
  unknown = "ClaudrTreeUnknown",
}

local function define_highlights()
  local links = {
    ClaudrTreeStatus = "WarningMsg",
    ClaudrTreeRunning = "DiagnosticInfo",
    ClaudrTreeFinished = "Comment",
    ClaudrTreeOrphaned = "DiagnosticWarn",
    ClaudrTreeIdle = "DiagnosticOk",
    ClaudrTreeWorking = "DiagnosticInfo",
    ClaudrTreeBlocked = "DiagnosticWarn",
    ClaudrTreeUnknown = "Comment",
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local function buf_valid()
  return S.buf ~= nil and vim.api.nvim_buf_is_valid(S.buf)
end

-- Окна текущей вкладки Neovim, в которых показан буфер дерева.
local function tree_windows()
  local out = {}
  if not buf_valid() then
    return out
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == S.buf then
      out[#out + 1] = win
    end
  end
  return out
end

local function tree_window()
  local cur = vim.api.nvim_get_current_win()
  if buf_valid() and vim.api.nvim_win_get_buf(cur) == S.buf then
    return cur
  end
  return tree_windows()[1]
end

--- Текст состояния узла для строки дерева или nil.
function M.state_text(node)
  if node.kind == "subagent" or node.kind == "task" then
    return M.STATE_TEXT[node.state] or node.state
  end
  if node.kind == "pane" and node.pane_kind == "agent" then
    return node.state
  end
  return nil
end

--- Число ждущих запросов диалога узла (панель — вместе с запросами субагентов) или 0.
function M.pending_count(node)
  if node.kind ~= "pane" and node.kind ~= "subagent" then
    return 0
  end
  local ok, pending = pcall(require, "claudr.dialogs.pending")
  if not ok then
    return 0
  end
  local cok, n = pcall(pending.count, node)
  return cok and tonumber(n) or 0
end

--- Текст в одну строку: управляющие символы и переводы строк (в заголовках терминала,
--- командах, описаниях) заменяются пробелом, подряд идущие сливаются. Модель хранит
--- исходное значение; буфер Neovim принимает только строки без перевода строки.
function M.one_line(text)
  local out = tostring(text):gsub("[%c\127]+", " ")
  return out
end

local function icon(node)
  if node.kind == "pane" then
    return M.ICONS[node.pane_kind] or "?"
  end
  return M.ICONS[node.kind] or "?"
end

local function visible_children(node)
  local out = {}
  for _, cid in ipairs(node.children) do
    local child = model.get(cid)
    if model.visible(child) then
      out[#out + 1] = child
    end
  end
  return out
end

-- Строки буфера, идентификаторы узлов по строкам и подсветка.
local function compose()
  local lines, ids, marks = {}, {}, {}
  local st = model.status()
  if st.status ~= "connected" then
    local text = M.STATUS_TEXT[st.status] or ("herdr: " .. tostring(st.status))
    if st.message and st.message ~= "" then
      text = text .. " (" .. st.message .. ")"
    end
    text = M.one_line(text)
    lines[#lines + 1] = text
    marks[#marks + 1] = { #lines, 0, #text, HL.header }
  end
  local function walk(node, depth)
    if not model.visible(node) then
      return
    end
    local kids = visible_children(node)
    local fold = " "
    if #kids > 0 then
      fold = S.collapsed[node.id] and "▸" or "▾"
    end
    local line = string.rep("  ", depth)
      .. fold
      .. " "
      .. icon(node)
      .. " "
      .. M.one_line(node.label)
    local state = M.state_text(node)
    if state then
      local start = #line + 1
      line = line .. " [" .. state .. "]"
      local group = HL[node.state] or HL.unknown
      marks[#marks + 1] = { #lines + 1, start, #line, group }
    end
    local waiting = M.pending_count(node)
    if waiting > 0 then
      local start = #line + 1
      line = line .. " [ждут: " .. waiting .. "]"
      marks[#marks + 1] = { #lines + 1, start, #line, HL.blocked }
    end
    lines[#lines + 1] = line
    ids[#lines] = node.id
    if not S.collapsed[node.id] then
      for _, child in ipairs(kids) do
        walk(child, depth + 1)
      end
    end
  end
  for _, root in ipairs(model.roots()) do
    walk(root, 0)
  end
  if #lines == 0 then
    lines[1] = "(нет workspace)"
  end
  return lines, ids, marks
end

local function line_of(id)
  for line, nid in pairs(S.line_ids) do
    if nid == id then
      return line
    end
  end
end

--- Перерисовывает буфер дерева по текущему состоянию модели; курсор остаётся на том же
--- узле.
function M.render()
  if not buf_valid() then
    return
  end
  local lines, ids, marks = compose()
  -- Содержимое не изменилось (например, снимок перечитан по событию вывода панели, а
  -- подписи и состояния те же): буфер не перерисовывается.
  local drawn = S.drawn
  if
    drawn
    and drawn.buf == S.buf
    and vim.deep_equal(drawn.lines, lines)
    and vim.deep_equal(drawn.marks, marks)
  then
    S.line_ids = ids
    return
  end
  S.drawn = { buf = S.buf, lines = lines, marks = marks }
  local keep = {}
  for _, win in ipairs(vim.fn.win_findbuf(S.buf)) do
    local row = vim.api.nvim_win_get_cursor(win)[1]
    keep[win] = { id = S.line_ids[row], row = row }
  end
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  vim.bo[S.buf].modified = false
  S.line_ids = ids
  vim.api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(S.buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4] })
  end
  for win, k in pairs(keep) do
    if vim.api.nvim_win_is_valid(win) then
      local row = (k.id and line_of(k.id)) or math.min(k.row, #lines)
      vim.api.nvim_win_set_cursor(win, { math.max(row, 1), 0 })
    end
  end
end

--- Узел под курсором в окне дерева (текущем, а если текущее окно не дерево — в первом окне
--- дерева текущей вкладки) или nil.
function M.node_at_cursor()
  local win = tree_window()
  if not win then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local id = S.line_ids[row]
  return id and model.get(id) or nil
end

local function run_action(action)
  local node = M.node_at_cursor()
  if not node then
    vim.notify("claudr: под курсором нет узла", vim.log.levels.WARN)
    return
  end
  action.run(node)
end

local function map(key, fn, desc)
  vim.keymap.set("n", key, fn, { buffer = S.buf, nowait = true, silent = true, desc = desc })
end

--- Свернуть или развернуть узел под курсором.
function M.toggle_fold()
  local node = M.node_at_cursor()
  if not node or #node.children == 0 then
    return
  end
  S.collapsed[node.id] = not S.collapsed[node.id] or nil
  M.render()
end

--- Перечень клавиш буфера дерева: встроенные и зарегистрированные действия.
function M.keys()
  local out = {
    { key = "<Tab>", desc = "свернуть или развернуть узел" },
    { key = "za", desc = "свернуть или развернуть узел" },
    {
      key = "F",
      desc = "показать или скрыть завершённые субагенты и команды",
    },
    { key = "q", desc = "закрыть окно дерева" },
    { key = "g?", desc = "перечень клавиш" },
  }
  for _, name in ipairs(action_order) do
    local a = actions[name]
    if a.key then
      out[#out + 1] = { key = a.key, desc = a.desc or name, action = name }
    end
  end
  return out
end

local function show_help()
  local lines = { "claudr: клавиши дерева" }
  for _, k in ipairs(M.keys()) do
    lines[#lines + 1] = string.format("  %-8s %s", k.key, k.desc)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function apply_action_key(action)
  if buf_valid() and action.key then
    map(action.key, function()
      run_action(action)
    end, action.desc)
  end
end

local function apply_keys()
  map("<Tab>", M.toggle_fold, "claudr: свернуть или развернуть узел")
  map("za", M.toggle_fold, "claudr: свернуть или развернуть узел")
  map("F", function()
    model.toggle_finished()
  end, "claudr: показать или скрыть завершённые")
  map("q", M.close, "claudr: закрыть дерево")
  map("g?", show_help, "claudr: клавиши дерева")
  for _, name in ipairs(action_order) do
    apply_action_key(actions[name])
  end
end

--- Регистрирует действие над узлом: клавиша `spec.key` в буфере дерева вызывает
--- `spec.run(node)` для узла под курсором. Повторная регистрация имени заменяет прежнюю;
--- клавиша действия перекрывает встроенную клавишу с тем же сочетанием.
---@param name string
---@param spec claudr.TreeAction
function M.register_action(name, spec)
  assert(type(name) == "string" and name ~= "", "register_action: нужно имя")
  assert(type(spec) == "table" and type(spec.run) == "function", "register_action: нужен run")
  local prev = actions[name]
  if prev and prev.key and buf_valid() and prev.key ~= spec.key then
    pcall(vim.keymap.del, "n", prev.key, { buffer = S.buf })
  end
  if not prev then
    action_order[#action_order + 1] = name
  end
  actions[name] = { key = spec.key, desc = spec.desc, run = spec.run }
  apply_action_key(actions[name])
end

--- Зарегистрированное действие по имени или nil.
function M.action(name)
  return actions[name]
end

--- Выполнить зарегистрированное действие над узлом под курсором.
function M.run_action(name)
  local a = actions[name]
  if a then
    run_action(a)
  end
end

local function ensure_buf()
  if buf_valid() then
    return S.buf
  end
  define_highlights()
  local existing = vim.fn.bufnr(M.BUF_NAME)
  if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
    S.buf = existing
  else
    S.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(S.buf, M.BUF_NAME)
  end
  local bo = vim.bo[S.buf]
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.modifiable = false
  bo.filetype = M.FILETYPE
  apply_keys()
  if not S.unsubscribe then
    S.unsubscribe = model.subscribe(M.render)
  end
  -- число ждущих запросов диалога меняется без событий модели
  local pok, pending = pcall(require, "claudr.dialogs.pending")
  if pok and not S.unsubscribe_pending then
    S.unsubscribe_pending = pending.subscribe(function()
      M.render()
    end)
  end
  local buf = S.buf
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if S.buf == buf then
        S.buf = nil
        S.line_ids = {}
        if S.unsubscribe then
          S.unsubscribe()
          S.unsubscribe = nil
        end
        if S.unsubscribe_pending then
          S.unsubscribe_pending()
          S.unsubscribe_pending = nil
        end
      end
    end,
  })
  return S.buf
end

--- Открывает дерево: запускает модель, показывает буфер дерева в окне слева (или переходит
--- в уже открытое окно дерева текущей вкладки).
function M.open()
  model.start()
  ensure_buf()
  local win = tree_windows()[1]
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("topleft vertical " .. M.WIDTH .. "split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, S.buf)
    local wo = vim.wo[win]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.wrap = false
    wo.cursorline = true
    wo.winfixwidth = true
    wo.foldenable = false
  end
  M.render()
  return win
end

--- Закрывает окна дерева текущей вкладки (буфер остаётся).
function M.close()
  local wins = tree_windows()
  for _, win in ipairs(wins) do
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_close(win, false)
    end
  end
end

--- Ставит курсор окна дерева на узел `id`, разворачивая его предков. Возвращает true,
--- если узел показан.
function M.focus(id)
  local node = model.get(id)
  if not node or not buf_valid() then
    return false
  end
  local p = node.parent
  while p do
    S.collapsed[p] = nil
    local pn = model.get(p)
    p = pn and pn.parent
  end
  M.render()
  local line = line_of(id)
  local win = tree_window()
  if not line or not win then
    return false
  end
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  return true
end

--- Буфер дерева или nil.
function M.buf()
  return buf_valid() and S.buf or nil
end

--- Строки буфера дерева (пустой список, если буфера нет).
function M.lines()
  if not buf_valid() then
    return {}
  end
  return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
end

--- Строка буфера, на которой показан узел `id`, или nil.
function M.line_of(id)
  return line_of(id)
end

return M
