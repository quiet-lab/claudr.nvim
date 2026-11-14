-- Двойник слушателя claudr.nvim для проверки сценария хука: Unix-сокет на `vim.uv` в процессе
-- теста, в каталоге сокетов теста. Принимает соединения хука, разбирает кадры JSON по строке
-- и по команде теста отвечает решением, закрывает соединение или шлёт произвольную строку.
--
-- Режимы (`mode`): "hold" (по умолчанию) — принять запрос и молчать до команды теста;
-- "close" — закрыть соединение сразу после запроса, без ответа (экземпляр не принял запрос).
-- `M.dead()` создаёт файл сокета без слушателя.
--
-- Обработчики выполняются в обратных вызовах `vim.uv` (быстрый контекст): в них нет `vim.fn` и
-- `vim.api`. Таймеров и опроса нет: тест ждёт полей объекта через `t.wait`.
local uv = vim.uv
local M = {}

local Listener = {}
Listener.__index = Listener

local function ensure_dir(dir)
  if not uv.fs_stat(dir) then
    assert(uv.fs_mkdir(dir, tonumber("700", 8)))
  end
end

local function on_line(self, conn, line)
  local ok, frame = pcall(vim.json.decode, line)
  if not ok or type(frame) ~= "table" then
    table.insert(self.bad_lines, line)
    return
  end
  table.insert(self.frames, frame)
  if frame.type == "request" then
    table.insert(self.requests, frame)
    if self.mode == "close" then
      self:close_conn(conn)
    end
  elseif frame.type == "answered" then
    self.got_answered = true
  end
end

local function on_connection(self)
  local conn = uv.new_pipe(false)
  self.server:accept(conn)
  table.insert(self.conns, conn)
  self.conn = conn
  local buf = ""
  conn:read_start(function(err, data)
    if err or not data then
      if not conn:is_closing() then
        -- Соединение закрыл хук.
        self.closed_by_peer = true
        conn:close()
      end
      return
    end
    buf = buf .. data
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      on_line(self, conn, line)
      if conn:is_closing() then
        return
      end
    end
  end)
end

--- Запускает слушателя: `opts.dir` — каталог сокетов (создаётся с правами 0700),
--- `opts.name` — имя файла сокета (по умолчанию `<pid>.sock` процесса теста),
--- `opts.mode` — "hold" или "close".
function M.start(opts)
  local self = setmetatable({
    dir = opts.dir,
    name = opts.name or (tostring(uv.os_getpid()) .. ".sock"),
    mode = opts.mode or "hold",
    frames = {}, -- все принятые кадры
    requests = {}, -- принятые кадры `request`
    bad_lines = {}, -- строки, которые не разбираются как объект JSON
    conns = {},
    conn = nil, -- последнее принятое соединение
    got_answered = false,
    closed_by_peer = false,
  }, Listener)
  ensure_dir(self.dir)
  self.path = self.dir .. "/" .. self.name
  self.server = uv.new_pipe(false)
  assert(self.server:bind(self.path))
  assert(self.server:listen(16, function(err)
    if not err then
      on_connection(self)
    end
  end))
  return self
end

--- Создаёт в `opts.dir` файл сокета `opts.name` без слушателя (как после аварийного
--- завершения Neovim): сокет привязывается под временным именем, переименовывается и
--- закрывается — libuv удаляет только файл под исходным именем, которого уже нет.
--- Возвращает путь к файлу.
function M.dead(opts)
  ensure_dir(opts.dir)
  local path = opts.dir .. "/" .. opts.name
  local tmp = path .. ".bind"
  local pipe = uv.new_pipe(false)
  assert(pipe:bind(tmp))
  assert(uv.fs_rename(tmp, path))
  pipe:close()
  return path
end

--- Отправляет решение: кадр `decision` с объектом вывода хука `output`.
function Listener:reply(output, conn)
  self:send_raw(vim.json.encode({ type = "decision", output = output }) .. "\n", conn)
end

--- Отправляет строку как есть (для неверных кадров).
function Listener:send_raw(text, conn)
  conn = conn or self.conn
  assert(conn and not conn:is_closing(), "нет открытого соединения")
  conn:write(text)
end

--- Закрывает соединение без ответа (по умолчанию — последнее).
function Listener:close_conn(conn)
  conn = conn or self.conn
  if conn and not conn:is_closing() then
    conn:read_stop()
    conn:close()
  end
end

--- Есть ли открытое соединение.
function Listener:connected()
  return self.conn ~= nil and not self.conn:is_closing()
end

--- Останавливает слушателя: закрывает соединения и сокет (libuv удаляет файл сокета).
function Listener:stop()
  for _, conn in ipairs(self.conns) do
    if not conn:is_closing() then
      conn:close()
    end
  end
  if not self.server:is_closing() then
    self.server:close()
  end
end

return M
