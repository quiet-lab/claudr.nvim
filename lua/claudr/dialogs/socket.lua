-- Сокет плагина для хука `PermissionRequest` (спецификация agent-dialogs, решения D25, D26).
--
-- Unix-сокет `<каталог>/<pid>.sock`; каталог — `$XDG_RUNTIME_DIR/claudr`, без переменной —
-- `<временный каталог>/claudr-<uid>`, доступ только владельцу. Соединения принимаются по
-- событиям, кадры — строки JSON. Первый кадр соединения — `request`; запрос принимается,
-- только если `HERDR_SOCKET_PATH` запроса — сервер herdr плагина, а `HERDR_PANE_ID` — панель
-- дерева, иначе соединение закрывается без ответа. Принятый запрос получает обработчик
-- `on_request(conn, frame)`; дальнейшие кадры и закрытие соединения — через `conn.on_frame`
-- и `conn.on_close`.
--
-- При запуске из каталога удаляются сокеты, к которым нельзя подключиться (проба
-- соединением, ответ — событие); при выходе из Neovim и при `stop()` свой сокет удаляется.
-- Обратные вызовы `vim.uv` идут в быстром контексте, поэтому разбор кадров и вызовы
-- обработчиков переносятся в обычный контекст через `vim.schedule`. Таймеров и опроса нет.
local uv = vim.uv

local M = {}

local S = {
  server = nil,
  path = nil,
  on_request = nil,
  conns = {}, -- соединение → true: открытые соединения
  augroup = nil,
}

--- Каталог сокетов.
function M.dir()
  local run = uv.os_getenv("XDG_RUNTIME_DIR")
  if run and run ~= "" then
    return (run:gsub("(.)/+$", "%1")) .. "/claudr"
  end
  return uv.os_tmpdir() .. "/claudr-" .. tostring(uv.getuid())
end

--- Путь своего сокета или nil, если сокет не запущен.
function M.path()
  return S.path
end

-- Каталог с доступом только владельцу; nil, причина — каталог чужой или не создаётся.
local function ensure_dir(dir)
  vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
  uv.fs_mkdir(dir, 448)
  local st = uv.fs_lstat(dir)
  if not st or st.type ~= "directory" then
    return nil, "каталог сокетов не создан: " .. dir
  end
  if st.uid ~= uv.getuid() then
    return nil,
      "каталог сокетов принадлежит другому пользователю: "
        .. dir
  end
  if st.mode % 512 ~= 448 then
    uv.fs_chmod(dir, 448)
  end
  return true
end

-- Удаляет сокеты каталога, к которым нельзя подключиться; свой путь и живые сокеты остаются.
local function sweep(dir, own)
  local fd = uv.fs_scandir(dir)
  if not fd then
    return
  end
  while true do
    local name = uv.fs_scandir_next(fd)
    if not name then
      break
    end
    local path = dir .. "/" .. name
    if name:match("%.sock$") and path ~= own then
      local probe = uv.new_pipe(false)
      probe:connect(path, function(err)
        probe:close()
        if err and tostring(err):match("^ECONNREFUSED") then
          -- слушателя нет: сокет умершего экземпляра
          uv.fs_unlink(path)
        end
      end)
    end
  end
end

-- Сервер herdr плагина и сервер запроса — один и тот же путь (с учётом символьных ссылок).
local function same_server(a)
  if type(a) ~= "string" or a == "" then
    return false
  end
  local mine = require("claudr.herdr").socket_path()
  if a == mine then
    return true
  end
  local ra, rb = uv.fs_realpath(a), uv.fs_realpath(mine)
  return ra ~= nil and ra == rb
end

--- Принимается ли запрос: сервер herdr плагина и панель дерева.
function M.acceptable(frame)
  local env = type(frame) == "table" and frame.env
  if type(env) ~= "table" or not same_server(env.HERDR_SOCKET_PATH) then
    return false
  end
  local pane_id = env.HERDR_PANE_ID
  if type(pane_id) ~= "string" or pane_id == "" then
    return false
  end
  local node = require("claudr.tree.model").get(pane_id)
  return node ~= nil and node.kind == "pane"
end

-- Соединение ---------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

--- Посылает кадр строкой JSON. `cb(err)` — по завершении записи (в обычном контексте).
--- false — соединение уже закрыто (в том числе собеседником).
function Conn:send(frame, cb)
  if self.closed or self.eof then
    return false
  end
  local ok, res = pcall(self.pipe.write, self.pipe, vim.json.encode(frame) .. "\n", function(err)
    if cb then
      vim.schedule(function()
        cb(err)
      end)
    end
  end)
  return ok and res ~= nil
end

--- Закрывает соединение со своей стороны; `on_close` при этом не вызывается.
function Conn:close()
  if self.closed then
    return
  end
  self.closed = true
  S.conns[self] = nil
  if not self.pipe:is_closing() then
    self.pipe:close()
  end
end

-- Собеседник закрыл соединение (или ошибка чтения).
function Conn:_peer_closed()
  if self.closed then
    return
  end
  self:close()
  if self.on_close then
    self.on_close(self)
  end
end

function Conn:_line(line)
  if self.closed then
    return
  end
  local ok, frame = pcall(vim.json.decode, line)
  if not ok or type(frame) ~= "table" then
    frame = nil
  end
  if not self.accepted then
    if not frame or frame.type ~= "request" or type(frame.input) ~= "table" then
      self:close()
      return
    end
    if not M.acceptable(frame) or not S.on_request then
      self:close()
      return
    end
    self.accepted = true
    S.on_request(self, frame)
    return
  end
  if frame and self.on_frame then
    self.on_frame(self, frame)
  end
end

local function accept()
  local pipe = uv.new_pipe(false)
  if not S.server:accept(pipe) then
    pipe:close()
    return
  end
  local c = setmetatable({ pipe = pipe, closed = false, eof = false, buf = "" }, Conn)
  S.conns[c] = true
  pipe:read_start(function(err, chunk)
    if err or not chunk then
      -- отметка без API Neovim: решение больше не уходит в закрытое соединение
      c.eof = true
      vim.schedule(function()
        c:_peer_closed()
      end)
      return
    end
    c.buf = c.buf .. chunk
    local lines = {}
    while true do
      local nl = c.buf:find("\n", 1, true)
      if not nl then
        break
      end
      lines[#lines + 1] = c.buf:sub(1, nl - 1)
      c.buf = c.buf:sub(nl + 1)
    end
    if #lines > 0 then
      vim.schedule(function()
        for _, line in ipairs(lines) do
          c:_line(line)
        end
      end)
    end
  end)
end

-- Запуск и остановка -------------------------------------------------------------------

local function remove_socket()
  if S.server then
    if not S.server:is_closing() then
      S.server:close()
    end
    S.server = nil
  end
  if S.path then
    uv.fs_unlink(S.path)
    S.path = nil
  end
end

--- Запускает сокет. `opts.on_request(conn, frame)` — принятый запрос. Повторный вызов
--- только меняет обработчик. Возвращает true или nil, причина.
function M.start(opts)
  opts = opts or {}
  if opts.on_request then
    S.on_request = opts.on_request
  end
  if S.server then
    return true
  end
  local dir = M.dir()
  local ok, err = ensure_dir(dir)
  if not ok then
    return nil, err
  end
  local path = dir .. "/" .. tostring(uv.os_getpid()) .. ".sock"
  -- файл с собственным pid остался от умершего процесса с тем же номером
  uv.fs_unlink(path)
  local server = uv.new_pipe(false)
  local bok, berr = server:bind(path)
  if not bok then
    server:close()
    return nil, "сокет не создан: " .. tostring(berr)
  end
  uv.fs_chmod(path, 384)
  local lok, lerr = server:listen(16, function(e)
    if not e and S.server == server then
      accept()
    end
  end)
  if not lok then
    server:close()
    uv.fs_unlink(path)
    return nil, "сокет не слушает: " .. tostring(lerr)
  end
  S.server, S.path = server, path
  S.augroup = vim.api.nvim_create_augroup("claudr.dialogs.socket", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = S.augroup,
    callback = remove_socket,
  })
  sweep(dir, path)
  return true
end

--- Останавливает сокет: открытые соединения закрываются без решения, файл сокета удаляется.
function M.stop()
  for c in pairs(S.conns) do
    c:close()
  end
  S.conns = {}
  remove_socket()
  if S.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, S.augroup)
    S.augroup = nil
  end
  S.on_request = nil
end

-- Только для тестов: число открытых соединений.
function M._conn_count()
  local n = 0
  for _ in pairs(S.conns) do
    n = n + 1
  end
  return n
end

return M
