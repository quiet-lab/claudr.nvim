-- Значки состояний агента из конфигурации herdr (`ui.status_icons`, `ui.status_indicators`).
-- Разбор конфигурации herdr живёт только здесь: нужное подмножество TOML разбирается
-- здесь же, остальное пропускается. Файл читается синхронно (он мал) при первом `get()` и
-- далее по уведомлению файловой системы (`vim.uv.new_fs_event` на каталоге файла); опроса
-- и таймеров нет. Нет файла или он не разбирается — значки встроенные, ошибка не
-- показывается.
local uv = vim.uv

local M = {}

local STATES = { "idle", "working", "blocked", "done", "unknown" }
local DEFAULT_PERIOD = 400
local MIN_PERIOD, MAX_PERIOD = 50, 5000
-- Файл больше предела не читается: конфигурация herdr так велика не бывает.
local MAX_SIZE = 1024 * 1024

local BUILTIN = {
  dots = { idle = "○", working = "●", blocked = "●", done = "●", unknown = "·" },
  symbols = { idle = "○", working = "◐", blocked = "×", done = "✓", unknown = "·" },
}

-- Разбор подмножества TOML --------------------------------------------------------------

-- Значение, которое пропускается без разбора (даты, `inf`, `nan` и подобное).
local OTHER = {}

local function utf8_char(n)
  if n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  elseif n < 0x10000 then
    return string.char(
      0xE0 + math.floor(n / 0x1000),
      0x80 + math.floor(n / 0x40) % 0x40,
      0x80 + n % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(n / 0x40000),
    0x80 + math.floor(n / 0x1000) % 0x40,
    0x80 + math.floor(n / 0x40) % 0x40,
    0x80 + n % 0x40
  )
end

local ESCAPES = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

local P = {}
P.__index = P

function P:fail(why)
  error({ unsupported = why or "unsupported" }, 0)
end

function P:peek(n)
  return self.text:sub(self.pos, self.pos + (n or 1) - 1)
end

function P:skip_blank()
  local _, e = self.text:find("^[ \t]*", self.pos)
  self.pos = e + 1
end

-- Пробелы, переводы строк и комментарии (внутри массивов и встроенных таблиц).
function P:skip_space()
  while true do
    local _, e = self.text:find("^[ \t\r\n]*", self.pos)
    self.pos = e + 1
    if self:peek() == "#" then
      local nl = self.text:find("\n", self.pos, true)
      self.pos = nl and nl + 1 or #self.text + 1
    else
      return
    end
  end
end

-- Многострочная строка: в нужном разделе не разбирается, в остальных пропускается.
function P:multiline(delim, relevant)
  if relevant then
    self:fail("multiline string")
  end
  local i = self.pos + 3
  while true do
    local c = self.text:sub(i, i)
    if c == "" then
      self:fail("unterminated string")
    elseif c == "\\" and delim == '"""' then
      i = i + 2
    elseif self.text:sub(i, i + 2) == delim then
      -- Допускается до двух кавычек перед закрывающими.
      local j = i + 3
      while self.text:sub(j, j) == delim:sub(1, 1) and j < i + 5 do
        j = j + 1
      end
      self.pos = j
      return OTHER
    else
      i = i + 1
    end
  end
end

function P:basic_string()
  local out = {}
  local i = self.pos + 1
  while true do
    local c = self.text:sub(i, i)
    if c == "" or c == "\n" then
      self:fail("unterminated string")
    elseif c == '"' then
      self.pos = i + 1
      return table.concat(out)
    elseif c == "\\" then
      local n = self.text:sub(i + 1, i + 1)
      if ESCAPES[n] then
        table.insert(out, ESCAPES[n])
        i = i + 2
      elseif n == "u" or n == "U" then
        local len = n == "u" and 4 or 8
        local hex = self.text:sub(i + 2, i + 1 + len)
        if #hex ~= len or not hex:match("^%x+$") then
          self:fail("bad escape")
        end
        local cp = tonumber(hex, 16)
        if cp >= 0xD800 and cp <= 0xDFFF or cp > 0x10FFFF then
          self:fail("bad escape")
        end
        table.insert(out, utf8_char(cp))
        i = i + 2 + len
      else
        self:fail("bad escape")
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end
end

function P:literal_string()
  local e = self.text:find("['\n]", self.pos + 1)
  if not e or self.text:sub(e, e) ~= "'" then
    self:fail("unterminated string")
  end
  local s = self.text:sub(self.pos + 1, e - 1)
  self.pos = e + 1
  return s
end

-- Ключ: простой (`a-b_1`), в кавычках или точечный (`a.b`); возвращается исходная запись и
-- признак точечного ключа.
function P:key()
  local parts, dotted = {}, false
  while true do
    self:skip_blank()
    local c = self:peek()
    local part
    if c == '"' then
      part = self:basic_string()
    elseif c == "'" then
      part = self:literal_string()
    else
      local _, e = self.text:find("^[%w_%-]+", self.pos)
      if not e then
        self:fail("bad key")
      end
      part = self.text:sub(self.pos, e)
      self.pos = e + 1
    end
    table.insert(parts, part)
    self:skip_blank()
    if self:peek() == "." then
      dotted = true
      self.pos = self.pos + 1
    else
      return table.concat(parts, "."), dotted
    end
  end
end

function P:array(relevant)
  self.pos = self.pos + 1
  local out = {}
  while true do
    self:skip_space()
    if self:peek() == "]" then
      self.pos = self.pos + 1
      return out
    end
    table.insert(out, self:value(relevant))
    self:skip_space()
    local c = self:peek()
    if c == "," then
      self.pos = self.pos + 1
    elseif c ~= "]" then
      self:fail("bad array")
    end
  end
end

function P:inline_table(relevant)
  self.pos = self.pos + 1
  local out = {}
  while true do
    self:skip_space()
    if self:peek() == "}" then
      self.pos = self.pos + 1
      return out
    end
    local key, dotted = self:key()
    if dotted and relevant then
      self:fail("dotted key")
    end
    self:skip_blank()
    if self:peek() ~= "=" then
      self:fail("no =")
    end
    self.pos = self.pos + 1
    self:skip_blank()
    out[key] = self:value(relevant)
    self:skip_space()
    local c = self:peek()
    if c == "," then
      self.pos = self.pos + 1
    elseif c ~= "}" then
      self:fail("bad inline table")
    end
  end
end

function P:value(relevant)
  self:skip_blank()
  local c = self:peek()
  if c == '"' then
    if self:peek(3) == '"""' then
      return self:multiline('"""', relevant)
    end
    return self:basic_string()
  elseif c == "'" then
    if self:peek(3) == "'''" then
      return self:multiline("'''", relevant)
    end
    return self:literal_string()
  elseif c == "[" then
    return self:array(relevant)
  elseif c == "{" then
    return self:inline_table(relevant)
  end
  local _, e = self.text:find("^[^%s,%]}#]+", self.pos)
  if not e then
    self:fail("no value")
  end
  local raw = self.text:sub(self.pos, e)
  self.pos = e + 1
  if raw == "true" then
    return true
  elseif raw == "false" then
    return false
  end
  local n = raw:match("^[+-]?%d[%d_]*%.?[%d_]*[eE]?[+-]?%d*$") and tonumber((raw:gsub("_", "")))
  if n then
    return n
  end
  return OTHER
end

-- Конец оператора: пробелы, комментарий, перевод строки или конец файла.
function P:end_of_line()
  self:skip_blank()
  local c = self:peek()
  if c == "#" then
    local nl = self.text:find("\n", self.pos, true)
    self.pos = nl and nl + 1 or #self.text + 1
  elseif c == "\r" and self:peek(2) == "\r\n" then
    self.pos = self.pos + 2
  elseif c == "\n" then
    self.pos = self.pos + 1
  elseif c ~= "" then
    self:fail("trailing text")
  end
end

-- Заголовок раздела: простое имя (`ui`, `ui.status_icons`) или любое другое имя,
-- которое пропускается.
function P:header()
  local array = self:peek(2) == "[["
  self.pos = self.pos + (array and 2 or 1)
  local name = self:key()
  self:skip_blank()
  local close = array and "]]" or "]"
  if self:peek(#close) ~= close then
    self:fail("bad header")
  end
  self.pos = self.pos + #close
  if array then
    return "skip"
  elseif name == "ui" then
    return "ui"
  elseif name == "ui.status_icons" then
    return "icons"
  end
  return "skip"
end

local ICON_KEYS = { frame_interval_ms = true }
for _, s in ipairs(STATES) do
  ICON_KEYS[s] = true
end

--- Нужное подмножество конфигурации herdr:
--- `{ status_icons = {…}, status_indicators = "dots"|"symbols"|nil }`; `nil`, если
--- конфигурация записана так, что нужные разделы не разбираются.
function M.parse(text)
  if type(text) ~= "string" then
    return nil
  end
  local p = setmetatable({ text = text, pos = 1 }, P)
  local out = { status_icons = {} }
  local ok, err = pcall(function()
    local section = "root"
    while p.pos <= #text do
      p:skip_blank()
      local c = p:peek()
      if c == "" then
        break
      elseif c == "#" or c == "\n" or c == "\r" then
        p:end_of_line()
      elseif c == "[" then
        section = p:header()
        p:end_of_line()
      else
        local key, dotted = p:key()
        p:skip_blank()
        if p:peek() ~= "=" then
          p:fail("no =")
        end
        p.pos = p.pos + 1
        local relevant = section == "ui" or section == "icons"
        if dotted and (relevant or (section == "root" and key:match("^ui%."))) then
          p:fail("dotted key")
        end
        if section == "root" and key == "ui" then
          p:fail("inline ui")
        end
        local v = p:value(relevant)
        p:end_of_line()
        if section == "ui" then
          if key == "status_indicators" and (v == "dots" or v == "symbols") then
            out.status_indicators = v
          elseif key == "status_icons" and type(v) == "table" then
            for k, val in pairs(v) do
              if ICON_KEYS[k] then
                out.status_icons[k] = val
              end
            end
          end
        elseif section == "icons" and ICON_KEYS[key] then
          out.status_icons[key] = v
        end
      end
    end
  end)
  if not ok then
    if type(err) == "table" and err.unsupported then
      return nil
    end
    error(err, 0)
  end
  return out
end

-- Значки ---------------------------------------------------------------------------------

local function frames_of(v)
  if type(v) == "string" and v ~= "" then
    return { v }
  elseif type(v) == "table" and #v > 0 then
    for _, f in ipairs(v) do
      if type(f) ~= "string" or f == "" then
        return nil
      end
    end
    return vim.list_slice(v)
  end
end

local function period_of(v)
  if type(v) == "number" and v % 1 == 0 and v >= MIN_PERIOD and v <= MAX_PERIOD then
    return v
  end
  return DEFAULT_PERIOD
end

--- Значки пяти состояний по разобранной конфигурации (`nil` — только встроенные):
--- `{ idle = { frames = {…}, period = мс }, … }`.
function M.resolve(parsed)
  local style = BUILTIN[parsed and parsed.status_indicators or "dots"] or BUILTIN.dots
  local icons = parsed and parsed.status_icons or {}
  local interval = icons.frame_interval_ms
  local out = {}
  for _, state in ipairs(STATES) do
    local p = interval
    if type(interval) == "table" then
      p = interval[state]
    end
    out[state] = {
      frames = frames_of(icons[state]) or { style[state] },
      period = period_of(p),
    }
  end
  return out
end

-- Чтение и перечитывание ---------------------------------------------------------------

--- Путь файла: `HERDR_CONFIG_PATH`, без неё `config.toml` в каталоге конфигурации herdr
--- (`$XDG_CONFIG_HOME/herdr`, без неё — `~/.config/herdr`).
function M.path()
  local p = uv.os_getenv("HERDR_CONFIG_PATH")
  if p and p ~= "" then
    return p
  end
  local cfg = uv.os_getenv("XDG_CONFIG_HOME")
  if not cfg or cfg == "" then
    cfg = uv.os_homedir() .. "/.config"
  end
  return cfg .. "/herdr/config.toml"
end

local S = {
  cache = nil, -- последний результат `resolve`
  path = nil, -- путь, по которому прочитан кэш
  sig = nil, -- отпечаток файла при чтении (для чтения без наблюдателя)
  reads = 0,
  watcher = nil,
  subs = {},
}

local function signature(path)
  local st = uv.fs_stat(path)
  if not st then
    return "none"
  end
  return table.concat(
    { st.ino, st.size, st.mtime.sec, st.mtime.nsec, st.ctime.sec, st.ctime.nsec },
    ":"
  )
end

-- Читает файл и возвращает значки; нет файла, слишком большой или не разбирается — встроенные.
local function load(path)
  S.reads = S.reads + 1
  local st = uv.fs_stat(path)
  local parsed
  if st and st.type == "file" and st.size <= MAX_SIZE then
    local f = io.open(path, "rb")
    if f then
      local text = f:read("*a")
      f:close()
      parsed = M.parse(text)
    end
  end
  return M.resolve(parsed)
end

local function refresh(path)
  S.path = path
  S.sig = signature(path)
  S.cache = load(path)
end

--- Значки состояний: все пять, `frames` — непустой список непустых строк, `period` — мс.
--- Таблицу изменять нельзя.
function M.get()
  local path = M.path()
  if S.cache == nil or S.path ~= path then
    refresh(path)
  elseif S.watcher == nil and S.sig ~= signature(path) then
    -- Наблюдателя нет: неизменность файла проверяется отпечатком, без чтения.
    refresh(path)
  end
  return S.cache
end

local function stop_watcher()
  local w = S.watcher
  if w then
    S.watcher = nil
    w.ev:stop()
    if not w.ev:is_closing() then
      w.ev:close()
    end
  end
end

local function notify()
  for _, sub in ipairs(vim.list_slice(S.subs)) do
    pcall(sub.fn)
  end
end

-- Событие файловой системы: файл перечитывается, подписчики уведомляются, если значки
-- изменились.
local function on_event(w)
  if S.watcher ~= w then
    return
  end
  local before = S.cache
  refresh(w.path)
  if not vim.deep_equal(before, S.cache) then
    notify()
  end
end

local function start_watcher()
  local path = M.path()
  local dir, name = path:match("^(.*)/([^/]+)$")
  if not dir then
    dir, name = ".", path
  elseif dir == "" then
    dir = "/"
  end
  local st = uv.fs_stat(dir)
  if not st or st.type ~= "directory" then
    return
  end
  local ev = uv.new_fs_event()
  local w = { ev = ev, path = path }
  local ok = pcall(function()
    assert(ev:start(dir, {}, function(err, filename)
      if err or (filename ~= nil and filename ~= name) then
        return
      end
      vim.schedule(function()
        on_event(w)
      end)
    end))
  end)
  if not ok then
    if not ev:is_closing() then
      ev:close()
    end
    return
  end
  S.watcher = w
end

--- Подписка на смену значков: `fn()` вызывается в главном цикле, только если результат
--- `get()` изменился. Первый подписчик заводит наблюдатель, отписка последнего его
--- закрывает. Возвращает функцию отписки.
function M.subscribe(fn)
  M.get()
  local entry = { fn = fn }
  table.insert(S.subs, entry)
  if S.watcher == nil then
    local sig = S.sig
    start_watcher()
    -- Файл мог измениться между чтением и постановкой наблюдателя.
    if S.watcher and sig ~= signature(S.path) then
      vim.schedule(function()
        if S.watcher then
          on_event(S.watcher)
        end
      end)
    end
  end
  local done = false
  return function()
    if done then
      return
    end
    done = true
    for i, f in ipairs(S.subs) do
      if f == entry then
        table.remove(S.subs, i)
        break
      end
    end
    if #S.subs == 0 then
      stop_watcher()
    end
  end
end

--- Заведён ли наблюдатель (для проверки утечек в тестах).
function M.watching()
  return S.watcher ~= nil
end

--- Сколько раз прочитан файл (только для тестов).
function M._reads()
  return S.reads
end

--- Сбросить кэш, подписчиков и наблюдатель (только для тестов).
function M._reset()
  stop_watcher()
  S.cache, S.path, S.sig = nil, nil, nil
  S.reads = 0
  S.subs = {}
end

return M
