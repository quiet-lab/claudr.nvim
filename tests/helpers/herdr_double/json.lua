-- Кодирование JSON с ключами объектов по алфавиту — так кадры печатает настоящий herdr.
-- Пустая таблица кодируется массивом `[]`, `vim.empty_dict()` — объектом `{}`.
-- Модуль общий для двойника сервера и поддельного `herdr`, зависит только от `vim.json`.
local M = {}

local empty_dict_mt = getmetatable(vim.empty_dict())

local function is_list(t)
  if getmetatable(t) == empty_dict_mt then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true
end

local encode

local function encode_table(t)
  if is_list(t) then
    local parts = {}
    for i = 1, #t do
      parts[i] = encode(t[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    local v = t[k]
    if v == nil then
      v = t[tonumber(k)]
    end
    parts[i] = vim.json.encode(k) .. ":" .. encode(v)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

encode = function(v)
  if type(v) == "table" then
    return encode_table(v)
  end
  return vim.json.encode(v)
end

--- Кодирует значение в строку JSON без перевода строки, ключи по алфавиту.
M.encode = encode

--- Кадр ответа: `id` первым, затем `result` или `error` (порядок настоящего сервера).
function M.response(id, result)
  return '{"id":' .. vim.json.encode(id) .. ',"result":' .. encode(result) .. "}"
end

function M.error(id, code, message)
  return '{"id":'
    .. vim.json.encode(id)
    .. ',"error":'
    .. encode({ code = code, message = message })
    .. "}"
end

return M
