-- Реестр тем вопросов по коду: файл JSON в каталоге состояния Neovim.
-- Запись темы: session_id, project_dir, title, mode, file, symbol, created_at, last_used_at
-- (время — секунды Unix с долями секунды). Файл читается при каждом обращении и переписывается целиком
-- после изменения, поэтому реестр переживает перезапуск Neovim и общий для всех экземпляров.
local M = {}

local FIELDS =
  { "session_id", "project_dir", "title", "mode", "file", "symbol", "created_at", "last_used_at" }

--- Путь файла реестра.
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "claudr", "topics.json")
end

--- Текущее время в секундах Unix с долями секунды: порядок обращений различим и внутри
--- одной секунды.
function M.now()
  local t = vim.uv.clock_gettime("realtime")
  return t.sec + t.nsec / 1e9
end

local function read_all()
  local f = io.open(M.path(), "r")
  if not f then
    return {}
  end
  local text = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" or type(decoded.topics) ~= "table" then
    return {}
  end
  return decoded.topics
end

local function write_all(topics)
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode({ version = 1, topics = topics }))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

local function copy(rec)
  local out = {}
  for _, k in ipairs(FIELDS) do
    out[k] = rec[k]
  end
  return out
end

--- Создаёт запись темы; `created_at` и `last_used_at` проставляются, если не заданы.
---@param rec table поля записи; `session_id` и `project_dir` обязательны
---@return table запись
function M.create(rec)
  assert(
    rec.session_id and rec.project_dir,
    "registry.create: нужны session_id и project_dir"
  )
  local topics = read_all()
  local now = M.now()
  local out = copy(rec)
  out.created_at = out.created_at or now
  out.last_used_at = out.last_used_at or out.created_at
  topics[out.session_id] = out
  write_all(topics)
  return copy(out)
end

--- Запись темы по идентификатору сессии или `nil`.
function M.get(session_id)
  local rec = read_all()[session_id]
  return rec and copy(rec) or nil
end

--- Обновляет время последнего обращения к теме.
function M.touch(session_id, time)
  local topics = read_all()
  local rec = topics[session_id]
  if not rec then
    return nil
  end
  rec.last_used_at = time or M.now()
  write_all(topics)
  return copy(rec)
end

--- Записи тем проекта (без аргумента — всех проектов), новые обращения первыми.
---@param project_dir string|nil
function M.list(project_dir)
  local out = {}
  for _, rec in pairs(read_all()) do
    if project_dir == nil or rec.project_dir == project_dir then
      out[#out + 1] = copy(rec)
    end
  end
  table.sort(out, function(a, b)
    if (a.last_used_at or 0) ~= (b.last_used_at or 0) then
      return (a.last_used_at or 0) > (b.last_used_at or 0)
    end
    return a.session_id < b.session_id
  end)
  return out
end

--- Тема проекта с самым поздним временем последнего обращения или `nil`.
function M.latest(project_dir)
  return M.list(project_dir)[1]
end

--- Является ли сессия темой вопросов по коду.
function M.is_topic(session_id)
  return read_all()[session_id] ~= nil
end

return M
