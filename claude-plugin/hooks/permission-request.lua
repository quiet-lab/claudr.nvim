-- Хук PermissionRequest плагина Claude Code claudr: передаёт запрос всем экземплярам Neovim
-- с плагином claudr.nvim через их Unix-сокеты и печатает первое полученное решение.
--
-- Запуск: nvim --clean -l permission-request.lua (вход хука — на stdin). Сценарий
-- самодостаточен: Claude Code копирует каталог плагина в свой кэш, модули claudr.nvim ему
-- недоступны.
--
-- Обмен — строки JSON, каждая заканчивается переводом строки:
--   хук → Neovim: {"type":"request","version":1,"input":<вход>,"env":{HERDR_PANE_ID, HERDR_SOCKET_PATH}}
--   Neovim → хук: {"type":"decision","output":<вывод хука>} либо закрытие соединения;
--   хук → Neovim: {"type":"answered"} и закрытие — остальным соединениям после решения.
--
-- Хук ничего не делает, кроме соединения с сокетами и печати решения: файлов не пишет, чужих
-- сокетов не удаляет, при любой ошибке, без слушателей и по SIGTERM завершается кодом 0
-- с пустым stdout, и диалог Claude Code остаётся рабочим. Ожидание идёт по событиям цикла
-- `vim.uv` (соединение, чтение, сигнал); таймеров и опроса нет, срок ожидания задаёт
-- Claude Code полем `timeout` записи хука.

local uv = vim.uv

local VERSION = 1
local ENV_KEYS = { "HERDR_PANE_ID", "HERDR_SOCKET_PATH" }

-- Каталог сокетов: то же правило, что у плагина claudr.nvim.
local function socket_dir()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if runtime and runtime ~= "" then
    return runtime .. "/claudr"
  end
  return uv.os_tmpdir() .. "/claudr-" .. tostring(uv.getuid())
end

-- Пути сокетов каталога по имени; нет каталога — пустой список.
local function socket_paths(dir)
  local paths = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return paths
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:sub(-5) == ".sock" then
      table.insert(paths, dir .. "/" .. name)
    end
  end
  table.sort(paths)
  return paths
end

-- Кадр запроса из текста входа. Вход передаётся текстом как есть (после проверки, что это
-- объект JSON), чтобы его значения не менялись повторным кодированием; переводы строк вне
-- строковых значений — пробельные символы JSON, внутри строк их быть не может.
local function request_frame(raw)
  if not raw:match("^%s*{") then
    return nil
  end
  local ok, input = pcall(vim.json.decode, raw)
  if not ok or type(input) ~= "table" then
    return nil
  end
  local env = {}
  local empty = true
  for _, key in ipairs(ENV_KEYS) do
    local value = os.getenv(key)
    if value and value ~= "" then
      env[key] = value
      empty = false
    end
  end
  local body = vim.trim(raw):gsub("[\r\n]", " ")
  return string.format(
    '{"type":"request","version":%d,"input":%s,"env":%s}\n',
    VERSION,
    body,
    vim.json.encode(empty and vim.empty_dict() or env)
  )
end

-- Решение из строки кадра или nil, если строка не является кадром решения.
local function decision_line(line)
  local ok, frame = pcall(vim.json.decode, line)
  if
    not ok
    or type(frame) ~= "table"
    or frame.type ~= "decision"
    or type(frame.output) ~= "table"
  then
    return nil
  end
  local eok, text = pcall(vim.json.encode, frame.output)
  if not eok then
    return nil
  end
  return text
end

local conns = {} -- открытые соединения: pipe → { buf = <непрочитанное> }
local pending = 0 -- соединения в процессе подключения и незавершённые записи «отвечено»
local decision -- первое полученное решение (строка JSON)
local finished = false

local function close(pipe)
  conns[pipe] = nil
  if not pipe:is_closing() then
    pipe:close()
  end
end

local function close_all()
  for pipe in pairs(conns) do
    close(pipe)
  end
end

-- Цикл завершается, когда решение получено и «отвечено» дописано, либо открытых и
-- подключающихся соединений не осталось.
local function check_done()
  if pending == 0 and next(conns) == nil then
    finished = true
  end
end

local function fail()
  decision = nil
  close_all()
  finished = true
end

local function guard(fn)
  return function(...)
    local ok = pcall(fn, ...)
    if not ok then
      fail()
    end
  end
end

-- Первое решение побеждает: остальным соединениям — «отвечено» и закрытие.
local function on_decision(winner, text)
  decision = text
  close(winner)
  for pipe in pairs(conns) do
    conns[pipe] = nil
    pipe:read_stop()
    pending = pending + 1
    local ok = pcall(
      pipe.write,
      pipe,
      '{"type":"answered"}\n',
      guard(function()
        pending = pending - 1
        if not pipe:is_closing() then
          pipe:close()
        end
        check_done()
      end)
    )
    if not ok then
      pending = pending - 1
      if not pipe:is_closing() then
        pipe:close()
      end
    end
  end
  check_done()
end

local function on_read(pipe)
  return guard(function(err, data)
    local conn = conns[pipe]
    if not conn or decision then
      return
    end
    if err or not data then
      -- Закрытие соединения или ошибка чтения: экземпляр не принял запрос.
      close(pipe)
      check_done()
      return
    end
    conn.buf = conn.buf .. data
    local nl = conn.buf:find("\n", 1, true)
    if not nl then
      return
    end
    local text = decision_line(conn.buf:sub(1, nl - 1))
    if text then
      on_decision(pipe, text)
    else
      -- Неверная строка: соединение не считается.
      close(pipe)
      check_done()
    end
  end)
end

local function connect(path, frame)
  local pipe = uv.new_pipe(false)
  if not pipe then
    return
  end
  pending = pending + 1
  local ok = pcall(
    pipe.connect,
    pipe,
    path,
    guard(function(err)
      pending = pending - 1
      if err or decision or finished then
        -- Отказ в соединении (мёртвый сокет, не сокет): пропускается, файл не трогается.
        if not pipe:is_closing() then
          pipe:close()
        end
        check_done()
        return
      end
      conns[pipe] = { buf = "" }
      pipe:write(frame)
      pipe:read_start(on_read(pipe))
    end)
  )
  if not ok then
    pending = pending - 1
    if not pipe:is_closing() then
      pipe:close()
    end
  end
end

local function main()
  -- Сервер RPC, который Neovim поднимает при запуске, хуку не нужен: его сокет убирается
  -- сразу, чтобы процесс хука не оставлял файлов.
  if vim.v.servername ~= "" then
    pcall(vim.fn.serverstop, vim.v.servername)
  end

  local raw = io.stdin:read("a") or ""
  local paths = socket_paths(socket_dir())
  if #paths == 0 then
    return
  end
  local frame = request_frame(raw)
  if not frame then
    return
  end

  local signal = uv.new_signal()
  signal:start(
    "sigterm",
    guard(function()
      fail()
    end)
  )

  for _, path in ipairs(paths) do
    connect(path, frame)
  end
  check_done()

  while not finished do
    uv.run("once")
  end

  signal:stop()
  signal:close()
  if decision then
    io.stdout:write(decision, "\n")
    io.stdout:flush()
  end
end

pcall(main)
os.exit(0)
