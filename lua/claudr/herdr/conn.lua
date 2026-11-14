-- Одно соединение с сокетом API herdr: строки JSON по одному объекту, ответы
-- сопоставляются запросам по `id`, несколько запросов могут быть в полёте.
--
-- Все обратные вызовы выполняются в обратных вызовах `vim.uv` (быстрый контекст):
-- `vim.api` и `vim.fn` в них недоступны, переход в обычный контекст — дело вызывающего.
local uv = vim.uv

local M = {}

local DECODE_OPTS = { luanil = { object = true, array = true } }

-- Счётчик идентификаторов запросов, общий для всех соединений; идентификатор — строка.
local seq = 0

local Conn = {}
Conn.__index = Conn

local CLOSED = {
  code = "server_unavailable",
  message = "соединение с сервером herdr закрыто",
}

-- Закрыть соединение и ответить ошибкой всем ждущим запросам.
function Conn:_shutdown()
  if self.closed then
    return
  end
  self.closed = true
  local pending = self.pending
  self.pending = {}
  if not self.pipe:is_closing() then
    self.pipe:close()
  end
  for _, cb in pairs(pending) do
    cb({ code = CLOSED.code, message = CLOSED.message })
  end
end

function Conn:_on_line(line)
  if line == "" then
    return
  end
  local ok, frame = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok or type(frame) ~= "table" then
    return
  end
  if frame.event ~= nil then
    if self.handlers.on_event then
      self.handlers.on_event(frame)
    end
    return
  end
  local id = frame.id ~= nil and tostring(frame.id) or nil
  local cb = id and self.pending[id]
  if cb then
    self.pending[id] = nil
    if frame.error ~= nil then
      local e = type(frame.error) == "table" and frame.error or {}
      cb({ code = e.code, message = e.message })
    else
      cb(nil, frame.result)
    end
  elseif frame.error ~= nil and self.handlers.on_error then
    -- Ошибка не в ответ на ждущий запрос: например, `events_lost` в потоке подписки.
    self.handlers.on_error(frame.error)
  end
end

--- Запрос `method` с `params`; `cb(err, result)`, `err = {code, message}`.
function Conn:request(method, params, cb)
  if self.closed then
    cb({ code = CLOSED.code, message = CLOSED.message })
    return
  end
  seq = seq + 1
  local id = tostring(seq)
  if params == nil or next(params) == nil then
    params = vim.empty_dict()
  end
  self.pending[id] = cb
  self.pipe:write(vim.json.encode({ id = id, method = method, params = params }) .. "\n")
end

--- Закрыть соединение по решению клиента: `on_close` не вызывается, ждущие запросы
--- получают `server_unavailable`, `closed_by_client` становится истинным.
function Conn:close()
  self.closed_by_client = true
  self:_shutdown()
end

--- Открыть соединение с сокетом `path`. Обработчики:
--- `on_open(err)` — подключение (err — текст ошибки libuv, например `ENOENT: …`);
--- `on_event(frame)` — кадр события `{event, data}`;
--- `on_error(err)` — ошибка вне ответа на запрос;
--- `on_close()` — сервер закрыл соединение (конец потока или ошибка чтения).
function M.open(path, handlers)
  local c = setmetatable({ pending = {}, closed = false, buf = "", handlers = handlers }, Conn)
  c.pipe = uv.new_pipe(false)
  c.pipe:connect(path, function(err)
    if c.closed then
      return
    end
    if err then
      c:_shutdown()
      handlers.on_open(err)
      return
    end
    c.pipe:read_start(function(rerr, chunk)
      if c.closed then
        return
      end
      if rerr or not chunk then
        c:_shutdown()
        if handlers.on_close then
          handlers.on_close()
        end
        return
      end
      c.buf = c.buf .. chunk
      while not c.closed do
        local nl = c.buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = c.buf:sub(1, nl - 1)
        c.buf = c.buf:sub(nl + 1)
        c:_on_line(line)
      end
    end)
    handlers.on_open(nil)
  end)
  return c
end

return M
