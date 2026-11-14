-- Разбор потока stream-json процесса `claude -p` (вывод процесса, а не файл данных Claude Code).
-- Текст ответа копится только по приращениям `text_delta` в `content_block_delta` основного
-- агента; вызовы инструментов, служебные записи и полные записи `assistant`/`user` в текст
-- не попадают. Итог хода — запись `result`.
local M = {}

local Parser = {}
Parser.__index = Parser

---@class claudr.StreamHandlers
---@field on_text fun(chunk: string)|nil приращение текста ответа
---@field on_init fun(frame: table)|nil запись system/init
---@field on_result fun(frame: table)|nil запись result

--- Новый разборщик; `feed` принимает куски вывода в любом разбиении на строки.
---@param handlers claudr.StreamHandlers
function M.new(handlers)
  return setmetatable({ handlers = handlers or {}, pending = "", got_text = false }, Parser)
end

local function is_null(v)
  return v == nil or v == vim.NIL
end

function Parser:_frame(frame)
  if type(frame) ~= "table" then
    return
  end
  local h = self.handlers
  if frame.type == "stream_event" and type(frame.event) == "table" then
    -- текст субагентов (parent_tool_use_id задан) в ответ не входит
    if not is_null(frame.parent_tool_use_id) then
      return
    end
    local ev = frame.event
    if ev.type == "message_start" and self.got_text then
      -- новое сообщение модели после текста (например, после вызова инструмента)
      self.need_break = true
    elseif
      ev.type == "content_block_delta"
      and type(ev.delta) == "table"
      and ev.delta.type == "text_delta"
      and type(ev.delta.text) == "string"
      and ev.delta.text ~= ""
    then
      local chunk = ev.delta.text
      if self.need_break then
        self.need_break = false
        chunk = "\n\n" .. chunk
      end
      self.got_text = true
      if h.on_text then
        h.on_text(chunk)
      end
    end
  elseif frame.type == "system" and frame.subtype == "init" then
    if h.on_init then
      h.on_init(frame)
    end
  elseif frame.type == "result" then
    if h.on_result then
      h.on_result(frame)
    end
  end
end

--- Принимает кусок вывода; разбирает все полные строки.
function Parser:feed(data)
  if not data or data == "" then
    return
  end
  local buf = self.pending .. data
  local start = 1
  while true do
    local nl = buf:find("\n", start, true)
    if not nl then
      break
    end
    local line = buf:sub(start, nl - 1)
    start = nl + 1
    if line:match("%S") then
      local ok, frame = pcall(vim.json.decode, line)
      if ok then
        self:_frame(frame)
      end
    end
  end
  self.pending = buf:sub(start)
end

--- Конец вывода: разбирает недописанную последнюю строку, если она полная запись JSON.
function Parser:finish()
  if self.pending:match("%S") then
    local ok, frame = pcall(vim.json.decode, self.pending)
    if ok then
      self:_frame(frame)
    end
  end
  self.pending = ""
end

return M
