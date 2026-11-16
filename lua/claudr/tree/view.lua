-- Отображение дерева (спецификация agent-tree, решения D2, D17, D36–D42): собственный буфер
-- и окно Neovim без сторонних плагинов. Буфер перерисовывается по каждому уведомлению модели.
--
-- Значок состояния узла — встроенный виртуальный текст (extmark, `virt_text_pos = "inline"`)
-- в начале строки узла; кадры значков берутся из `claudr.herdr.icons`. Единственный таймер —
-- таймер кадров анимации (см. «Таймер кадров» ниже): он меняет только метки значков.
--
-- Другие модули добавляют действия над узлом под курсором через `register_action`, файлы
-- дерева при этом не правятся.
local model = require("claudr.tree.model")
local config = require("claudr.config")

local M = {}

M.BUF_NAME = "claudr://tree"
M.FILETYPE = "claudr-tree"
M.WIDTH = 50

local ns = vim.api.nvim_create_namespace("claudr.tree")
-- метки значков состояний: перерисовываются отдельно от подсветки строк
local ns_icons = vim.api.nvim_create_namespace("claudr.tree.icons")

local S = {
  buf = nil,
  line_ids = {}, -- строка (с 1) → идентификатор узла
  collapsed = {}, -- идентификатор узла → true, если узел свёрнут
  unsubscribe = nil,
  unsubscribe_pending = nil,
  unsubscribe_icons = nil,
  -- значки строк последней перерисовки: `{ row (с 0), col, key, id }`
  icons = {},
  -- таблица значков, по которой нарисованы `icons`
  icon_table = nil,
  -- таймер кадров или nil
  timer = nil,
  augroup = nil,
  -- окно, из которого открыто дерево: в нём открываются виды узлов (решение D50)
  origin_win = nil,
}

---@class claudr.TreeAction
---@field key string|nil клавиша в буфере дерева
---@field desc string|nil описание для подсказки
---@field run fun(node: table) действие над узлом под курсором

---@type table<string, claudr.TreeAction>
local actions = {}
local action_order = {}

-- Обозначения видов узлов в режиме `icons = "text"`.
M.ICONS = {
  workspace = "W",
  tab = "T",
  agent = "A",
  command = "$",
  subagent = "S",
  task = "&",
  bash = "!",
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

-- Состояния с собственным значком в таблице значков herdr и группы подсветки значков-символов
-- (решение D37).
M.ICON_HL = {
  idle = "DiagnosticOk",
  working = "DiagnosticInfo",
  blocked = "DiagnosticError",
  done = "DiagnosticHint",
  unknown = "Comment",
}

-- Знаки вида узлов (решения D41, D49): эмодзи без U+FE0F. Панель с агентом получает символ
-- своего workspace, как строка агента в herdr; `agent` — знак панели с агентом в workspace
-- без символа. Остальных узлов herdr не показывает.
M.KIND_SIGN = {
  agent = "🧠",
  subagent = "🤖",
  task = "🔧",
  command = "💻",
  bash = "🐚",
}

local function mode()
  return config.get().icons == "text" and "text" or "herdr"
end

--- Модуль значков herdr; загружается при первом использовании в отображении.
local function icons_module()
  return require("claudr.herdr.icons")
end

--- Номер кадра (с 0) для времени `now_ms`: целая часть от времени, делённого на период, по
--- модулю числа кадров (общие кадры, `frame_phase = "synced"`).
function M.frame_index(count, period, now_ms)
  if count <= 1 or not period or period <= 0 then
    return 0
  end
  return math.floor(now_ms / period) % count
end

-- Начальное значение строки, как `row_phase` herdr (`status_frames.rs`): FNV-1a 64 по
-- пустому ключу машины, байту 0xff и идентификатору строки, затем перемешивание splitmix64.
-- Возвращает старшие 32 бита (разброс скорости) и функцию остатка от деления значения
-- (сдвиг начала). Без LuaJIT FFI — 32-битное значение того же назначения.
local has_ffi, ffi = pcall(require, "ffi")
local seeds = {}
local seed_count = 0

local function seed_ffi(id)
  local U = function(hi, lo)
    return ffi.cast("uint64_t", hi) * 0x100000000 + lo
  end
  local h = U(0xcbf29ce4, 0x84222325)
  local prime = U(0x00000100, 0x000001b3)
  local function mix(byte)
    h = bit.bxor(h, ffi.cast("uint64_t", byte)) * prime
  end
  mix(0xff)
  for i = 1, #id do
    mix(id:byte(i))
  end
  h = bit.bxor(h, bit.rshift(h, 30)) * U(0xbf58476d, 0x1ce4e5b9)
  h = bit.bxor(h, bit.rshift(h, 27)) * U(0x94d049bb, 0x133111eb)
  h = bit.bxor(h, bit.rshift(h, 31))
  local value = h
  return tonumber(bit.rshift(value, 32)), function(m)
    return tonumber(value % m)
  end
end

local function seed_plain(id)
  local h = 2166136261
  for i = 1, #id do
    h = (h * 31 + id:byte(i)) % 4294967296
  end
  local value = (h * 2654435761) % 4294967296
  return h, function(m)
    return value % m
  end
end

local function row_seed(id)
  local e = seeds[id]
  if not e then
    if seed_count >= 4096 then
      seeds, seed_count = {}, 0
    end
    local hi, rem
    if has_ffi then
      hi, rem = seed_ffi(id)
    else
      hi, rem = seed_plain(id)
    end
    e = { hi = hi, rem = rem }
    seeds[id] = e
    seed_count = seed_count + 1
  end
  return e
end

--- Часы строки, как `RowClock` herdr: период кадра и сдвиг начала в микросекундах. Без
--- `per_row` — период состояния и нулевой сдвиг (кадры общие); с `per_row` период умножается
--- на коэффициент строки от `1 - spread` до `1 + spread`, а сдвиг равномерен в пределах
--- полного круга кадров; оба выводятся из идентификатора строки `id`.
function M.row_clock(entry, id)
  local period_us = math.max(1, math.floor((tonumber(entry.period) or 400) * 1000))
  if not entry.per_row or id == nil then
    return period_us, 0
  end
  local seed = row_seed(tostring(id))
  local spread = math.max(0, math.min(500, tonumber(entry.spread) or 0))
  local speed = 1000 - spread + seed.hi % (2 * spread + 1)
  period_us = math.max(1, math.floor(period_us * speed / 1000))
  local frames = math.max(1, #entry.frames)
  return period_us, seed.rem(period_us * frames)
end

--- Номер кадра (с 0) строки `id` в момент `now_ms` по часам `M.row_clock`.
function M.row_frame_index(entry, id, now_ms)
  local count = #entry.frames
  if count <= 1 then
    return 0
  end
  local period_us, offset_us = M.row_clock(entry, id)
  return math.floor((math.floor(now_ms * 1000) + offset_us) / period_us) % count
end

-- Ближайшая граница кадра строки строго после `now_us`, в микросекундах.
local function row_boundary(entry, id, now_us)
  local period_us, offset_us = M.row_clock(entry, id)
  return (math.floor((now_us + offset_us) / period_us) + 1) * period_us - offset_us
end

-- Границы разных строк ближе этого окна обслуживаются одним срабатыванием (как в herdr).
local MERGE_WINDOW_US = 2000

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

-- Группа подсветки цвета workspace `#RRGGBB`; создаётся при каждой перерисовке, чтобы
-- пережить смену цветовой схемы.
local function color_group(color)
  local name = "ClaudrTreeColor" .. color:sub(2)
  vim.api.nvim_set_hl(0, name, { fg = color })
  return name
end

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
  if node.kind == "subagent" or node.kind == "task" or node.kind == "bash" then
    return M.STATE_TEXT[node.state] or node.state
  end
  if node.kind == "tab" or (node.kind == "pane" and node.pane_kind == "agent") then
    return node.state
  end
  return nil
end

--- Число ждущих запросов диалога узла или 0: строка агента (вкладка, workspace со скрытой
--- единственной вкладкой, прочий агент) — вместе с запросами субагентов, субагент — свои.
function M.pending_count(node)
  if node.kind == "workspace" and mode() ~= "herdr" then
    -- в текстовом режиме вкладка всегда своей строкой: запросы показывает она
    return 0
  end
  node = model.agent_node(node)
  if not node or (node.kind ~= "pane" and node.kind ~= "subagent") then
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

--- Дети узла, как они показаны в дереве: в режиме `icons = "herdr"` единственная вкладка
--- workspace отдельной строкой не показывается, её панели стоят прямо под workspace — у
--- herdr вкладка без пары повторяет свой workspace и подписи не получает (`labels.rs`,
--- `tab_token_shown`). Режим `icons = "text"` показывает все уровни, как раньше (D42).
function M.shown_children(node)
  local kids = visible_children(node)
  if node.kind ~= "workspace" or mode() ~= "herdr" then
    return kids
  end
  local tabs = 0
  for _, c in ipairs(kids) do
    if c.kind == "tab" then
      tabs = tabs + 1
    end
  end
  if tabs ~= 1 then
    return kids
  end
  local out = {}
  for _, c in ipairs(kids) do
    if c.kind == "tab" then
      vim.list_extend(out, visible_children(c))
    else
      out[#out + 1] = c
    end
  end
  return out
end

-- Строка узла в режиме `icons = "text"`: буква вида, подпись, состояние словом.
local function text_line(node, prefix, row, marks)
  local label = node.kind == "workspace" and node.text_label or node.label
  local line = prefix .. icon(node) .. " " .. M.one_line(label)
  local state = M.state_text(node)
  if state then
    local start = #line + 1
    line = line .. " [" .. state .. "]"
    marks[#marks + 1] = { row, start, #line, HL[node.state] or HL.unknown }
  end
  return line
end

-- Строка узла в режиме `icons = "herdr"`: место значка состояния (метка в `icons`), знак
-- вида, подпись с цветом workspace, неизвестное значение состояния.
local function herdr_line(node, prefix, row, marks, icons)
  local line = prefix
  if node.icon then
    local key = M.ICON_HL[node.icon] and node.icon or "unknown"
    -- ключ часов строки вкладки — панель её агента, как у строки агента herdr
    icons[#icons + 1] =
      { row = row - 1, col = #prefix, key = key, node = node.phase_key or node.id }
  end
  local sign
  if node.kind == "pane" then
    if node.pane_kind == "command" then
      sign = M.KIND_SIGN.command
    else
      sign = node.symbol or M.KIND_SIGN.agent
    end
  else
    sign = M.KIND_SIGN[node.kind]
  end
  if sign then
    line = line .. sign .. " "
  end
  local start = #line
  line = line .. M.one_line(node.label)
  if node.color then
    marks[#marks + 1] = { row, start, #line, color_group(node.color) }
  end
  if node.icon and not M.ICON_HL[node.icon] then
    local vstart = #line + 1
    line = line .. " [" .. M.one_line(node.icon) .. "]"
    marks[#marks + 1] = { row, vstart, #line, HL.unknown }
  end
  return line
end

-- Строки буфера, идентификаторы узлов по строкам, подсветка и места значков состояний.
local function compose()
  local lines, ids, marks, icons = {}, {}, {}, {}
  local text_mode = mode() == "text"
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
    local kids = M.shown_children(node)
    local fold = " "
    if #kids > 0 then
      fold = S.collapsed[node.id] and "▸" or "▾"
    end
    local prefix = string.rep("  ", depth) .. fold .. " "
    local row = #lines + 1
    local line
    if text_mode then
      line = text_line(node, prefix, row, marks)
    else
      line = herdr_line(node, prefix, row, marks, icons)
    end
    local waiting = M.pending_count(node)
    if waiting > 0 then
      local start = #line + 1
      line = line .. " [ждут: " .. waiting .. "]"
      marks[#marks + 1] = { row, start, #line, HL.blocked }
    end
    lines[row] = line
    ids[row] = node.id
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
  return lines, ids, marks, icons
end

-- Таймер кадров ---------------------------------------------------------------------------
--
-- WARNING: таймер — исключение из правила «без таймеров», разрешённое пользователем
-- (решение D38): источника событий для смены кадров анимированных значков нет ни в herdr,
-- ни в Neovim. Таймер заведён, только пока буфер дерева показан в окне текущей вкладки
-- Neovim и среди показанных узлов есть значок из нескольких кадров; срабатывание меняет только
-- метки значков (не пишет буфер, не трогает курсор и модель, не читает сокет и файлы).
-- Условие замены: появление в herdr или Neovim события смены кадра либо отказ от
-- анимированных значков.
local function uv_timer()
  return vim.uv.new_timer()
end
local timer_factory = uv_timer

local on_timer

-- Запись таблицы значков по ключу состояния (кадры, период, фаза) или nil.
local function entry_of(key)
  local e = S.icon_table and S.icon_table[key]
  if type(e) ~= "table" or type(e.frames) ~= "table" or #e.frames == 0 then
    return nil
  end
  return e
end

-- Задержка в миллисекундах до ближайшей границы кадра среди показанных анимируемых значков
-- (границы в пределах 2 мс от ближайшей обслуживаются вместе) или nil, если таймер заводить
-- не нужно.
local function next_delay(now)
  if mode() ~= "herdr" or not model.started() or not buf_valid() then
    return nil
  end
  if #S.icons == 0 or #tree_windows() == 0 then
    return nil
  end
  local now_us = math.floor(now * 1000)
  local bounds = {}
  local first
  for _, ic in ipairs(S.icons) do
    local e = entry_of(ic.key)
    if e and #e.frames > 1 then
      local b = row_boundary(e, ic.node, now_us)
      bounds[#bounds + 1] = b
      if not first or b < first then
        first = b
      end
    end
  end
  if not first then
    return nil
  end
  local target = first
  for _, b in ipairs(bounds) do
    if b > target and b <= first + MERGE_WINDOW_US then
      target = b
    end
  end
  return math.max(1, math.ceil((target - now_us) / 1000))
end

local function stop_timer()
  if S.timer then
    S.timer:stop()
    S.timer:close()
    S.timer = nil
  end
end

-- Привести таймер к условиям: завести на ближайшую границу кадра или остановить.
local function update_timer(now)
  now = now or now_ms()
  local delay = next_delay(now)
  if not delay then
    stop_timer()
    return
  end
  if not S.timer then
    S.timer = timer_factory()
  end
  S.timer:start(delay, 0, on_timer)
end

local recheck_pending = false

-- Перепроверка условий таймера после текущего события (одна на несколько событий подряд).
local function recheck_timer()
  if recheck_pending then
    return
  end
  recheck_pending = true
  vim.schedule(function()
    recheck_pending = false
    update_timer()
  end)
end

-- Метка значка строки с кадром для времени `now`; метка с тем же кадром не переставляется.
local function draw_icon(ic, now)
  local e = entry_of(ic.key)
  if not e then
    if ic.id then
      pcall(vim.api.nvim_buf_del_extmark, S.buf, ns_icons, ic.id)
      ic.id = nil
    end
    return
  end
  local frame = tostring(e.frames[M.row_frame_index(e, ic.node, now) + 1])
  if ic.id and ic.frame == frame then
    return
  end
  ic.frame = frame
  ic.id = vim.api.nvim_buf_set_extmark(S.buf, ns_icons, ic.row, ic.col, {
    id = ic.id,
    virt_text = { { frame, M.ICON_HL[ic.key] }, { " " } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

--- Срабатывание таймера кадров: перепроверка условий и смена кадров анимируемых значков.
--- `now` — время в миллисекундах (в тестах задаётся явно).
function M._tick(now)
  now = now or now_ms()
  if not next_delay(now) then
    stop_timer()
    return
  end
  for _, ic in ipairs(S.icons) do
    local e = entry_of(ic.key)
    if e and #e.frames > 1 then
      draw_icon(ic, now)
    end
  end
  update_timer(now)
end

on_timer = vim.schedule_wrap(function()
  M._tick()
end)

--- Только для тестов: подменяет фабрику таймера кадров (`fn() -> таймер` с методами
--- `start`, `stop`, `close`); без аргумента возвращает настоящую.
function M._set_timer_factory(fn)
  stop_timer()
  timer_factory = fn or uv_timer
end

--- Только для тестов: заведён ли таймер кадров.
function M._timer_active()
  return S.timer ~= nil
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
    update_timer()
    return
  end
  local herdr_mode = mode() == "herdr"
  if herdr_mode and not S.unsubscribe_icons then
    -- смена значков в конфигурации herdr перерисовывает дерево целиком
    S.unsubscribe_icons = icons_module().subscribe(function()
      S.drawn = nil
      M.render()
    end)
  end
  local lines, ids, marks, icons = compose()
  -- Содержимое не изменилось (например, снимок перечитан по событию вывода панели, а
  -- подписи и состояния те же): буфер не перерисовывается.
  local drawn = S.drawn
  if
    drawn
    and drawn.buf == S.buf
    and vim.deep_equal(drawn.lines, lines)
    and vim.deep_equal(drawn.marks, marks)
    and vim.deep_equal(drawn.icons, icons)
  then
    S.line_ids = ids
    update_timer()
    return
  end
  S.drawn = { buf = S.buf, lines = lines, marks = marks, icons = vim.deepcopy(icons) }
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
  vim.api.nvim_buf_clear_namespace(S.buf, ns_icons, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(S.buf, ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4] })
  end
  S.icons = icons
  S.icon_table = herdr_mode and #icons > 0 and icons_module().get() or nil
  local now = now_ms()
  for _, ic in ipairs(icons) do
    draw_icon(ic, now)
  end
  for win, k in pairs(keep) do
    if vim.api.nvim_win_is_valid(win) then
      local row = (k.id and line_of(k.id)) or math.min(k.row, #lines)
      vim.api.nvim_win_set_cursor(win, { math.max(row, 1), 0 })
    end
  end
  update_timer(now)
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
  -- условия таймера кадров перепроверяются при показе, скрытии и закрытии окна дерева и при
  -- смене вкладки Neovim — после того, как смена закончена: во время события окно новой
  -- вкладки ещё показывает прежний буфер, а закрываемое окно ещё существует
  S.augroup = vim.api.nvim_create_augroup("claudr.tree.frames", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave" }, {
    group = S.augroup,
    buffer = buf,
    callback = recheck_timer,
  })
  vim.api.nvim_create_autocmd({ "WinClosed", "TabEnter" }, {
    group = S.augroup,
    callback = recheck_timer,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = S.augroup,
    buffer = buf,
    once = true,
    callback = function()
      if S.buf == buf then
        S.buf = nil
        S.line_ids = {}
        S.icons = {}
        S.icon_table = nil
        S.drawn = nil
        stop_timer()
        if S.unsubscribe_icons then
          S.unsubscribe_icons()
          S.unsubscribe_icons = nil
        end
        pcall(vim.api.nvim_del_augroup_by_id, S.augroup)
        S.augroup = nil
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
  local from = vim.api.nvim_get_current_win()
  if
    vim.api.nvim_win_get_config(from).relative == ""
    and not (buf_valid() and vim.api.nvim_win_get_buf(from) == S.buf)
  then
    S.origin_win = from
  end
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

--- Окно, из которого открыто дерево (последнее обычное окно, где вызвана команда), или nil.
function M.origin_win()
  local win = S.origin_win
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  return nil
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
  if node and node.hidden then
    -- панель без строки: агента вкладки показывает строка вкладки
    node = model.row_of_pane(id)
    id = node and node.id
  end
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
  if not line and node.kind == "tab" and node.parent then
    -- единственная вкладка своей строки не имеет: курсор встаёт на её workspace
    line = line_of(node.parent)
  end
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

--- Только для тестов: значок строки узла `id` — `{ text, hl, col }` по метке в буфере или nil.
function M._icon(id)
  local row = buf_valid() and line_of(id)
  if not row then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    S.buf,
    ns_icons,
    { row - 1, 0 },
    { row - 1, -1 },
    { details = true }
  )
  local m = marks[1]
  if not m then
    return nil
  end
  local vt = m[4].virt_text
  return { text = vt[1][1], hl = vt[1][2], col = m[3], pos = m[4].virt_text_pos }
end

return M
