-- Файловые помощники модуля данных Claude Code: чтение файлов, чтение дописываемого файла
-- с запомненного смещения, наблюдение уведомлениями файловой системы и ожидание появления
-- пути. Таймеров и опроса нет: каждое чтение вызвано уведомлением или запросом подписчика.
local uv = vim.uv

local M = {}

function M.dirname(path)
  local dir = path:match("^(.*)/[^/]*$")
  if dir == "" then
    return "/"
  end
  return dir or "."
end

function M.basename(path)
  return path:match("([^/]*)$")
end

function M.is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

function M.is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

--- Содержимое файла целиком или nil, если файла нет или он не читается.
function M.read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = st and uv.fs_read(fd, st.size, 0) or nil
  uv.fs_close(fd)
  return data
end

--- Элементы каталога: список `{name, type}`; каталога нет — пустой список.
function M.list_dir(path)
  local out = {}
  local fd = uv.fs_scandir(path)
  if not fd then
    return out
  end
  while true do
    local name, kind = uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if not kind then
      -- файловая система не сообщила вид элемента
      local st = uv.fs_stat(path .. "/" .. name)
      kind = st and st.type or nil
    end
    out[#out + 1] = { name = name, type = kind }
  end
  return out
end

--- Читатель дописываемого файла: помнит смещение конца последней прочитанной полной строки.
function M.tail(path)
  return { path = path, offset = 0 }
end

-- Читает байты файла от смещения читателя до конца; nil — файла нет.
local function read_from(t)
  local fd = uv.fs_open(t.path, "r", 438)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  if not st then
    uv.fs_close(fd)
    return nil
  end
  if st.size < t.offset then
    -- файл заменён или усечён: читается заново
    t.offset = 0
  end
  local data = ""
  if st.size > t.offset then
    data = uv.fs_read(fd, st.size - t.offset, t.offset) or ""
  end
  uv.fs_close(fd)
  return data
end

--- Новые полные строки файла с запомненного смещения. Незаконченная последняя строка
--- не возвращается и не сдвигает смещение. nil — файла нет.
function M.read_lines(t)
  local data = read_from(t)
  if not data then
    return nil
  end
  local last = nil
  local pos = #data
  while pos > 0 do
    if data:byte(pos) == 10 then
      last = pos
      break
    end
    pos = pos - 1
  end
  local lines = {}
  if not last then
    return lines
  end
  t.offset = t.offset + last
  for line in data:sub(1, last):gmatch("([^\n]*)\n") do
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

--- Новые байты файла с запомненного смещения (кусок вывода). nil — файла нет.
function M.read_chunk(t)
  local data = read_from(t)
  if data then
    t.offset = t.offset + #data
  end
  return data
end

--- Наблюдение за путём (`vim.uv.new_fs_event`). `cb(filename, events)` вызывается в обычном
--- контексте Neovim (через `vim.schedule`: обратный вызов fs_event идёт в быстром контексте).
--- Возвращает объект с `close()` или nil, если путь не наблюдается.
function M.watch(path, cb)
  local handle = uv.new_fs_event()
  if not handle then
    return nil
  end
  local w = { closed = false }
  local ok = handle:start(path, {}, function(err, filename, events)
    if err then
      return
    end
    vim.schedule(function()
      if not w.closed then
        cb(filename, events)
      end
    end)
  end)
  if not ok then
    handle:close()
    return nil
  end
  function w.close()
    if not w.closed then
      w.closed = true
      handle:stop()
      handle:close()
    end
  end
  return w
end

--- Ждёт появления пути: наблюдает ближайший существующий каталог-предок и после каждого
--- уведомления проверяет путь заново. `cb()` вызывается один раз (сразу, если путь уже есть).
--- Возвращает объект с `close()`.
function M.wait_path(path, cb)
  local w = { closed = false }
  local function stop()
    if w.watch then
      w.watch.close()
      w.watch = nil
    end
  end
  local function attempt()
    if w.closed then
      return
    end
    if uv.fs_stat(path) then
      w.closed = true
      stop()
      cb()
      return
    end
    local dir = M.dirname(path)
    while dir ~= "/" and dir ~= "." and not uv.fs_stat(dir) do
      dir = M.dirname(dir)
    end
    if w.dir ~= dir then
      stop()
      w.dir = dir
      w.watch = M.watch(dir, attempt)
      -- путь мог появиться, пока ставилось наблюдение
      attempt()
    end
  end
  function w.close()
    w.closed = true
    stop()
  end
  attempt()
  return w
end

return M
