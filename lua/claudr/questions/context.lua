-- Поставщики контекста вопросов по коду. Поставщик по буферу и выделению возвращает пакет
-- контекста. Общий поставщик даёт файл, строки, выделенный текст (или содержимое буфера для
-- вопроса по файлу), охватывающий узел tree-sitter, определение и описание символа по запросам
-- языкового сервера; без подключённого сервера пакет собирается без них. Дополнительные
-- поставщики регистрируются по типу файла и дополняют пакет общего.
local M = {}

---@class claudr.ContextRequest
---@field bufnr integer
---@field kind "cursor"|"selection"|"file"
---@field range integer[]|nil строки выделения {начало, конец}, с единицы, включительно
---@field cursor integer[] {строка с единицы, столбец в байтах с нуля}
---@field project_dir string

---@type table<string, fun(req: claudr.ContextRequest, packet: table): table|nil>[]
local extra = {}

--- Регистрирует дополнительный поставщик для типа файла. Поставщик вызывается после общего
--- с запросом и пакетом общего поставщика и возвращает таблицу, которая добавляется к пакету.
---@param filetype string
---@param fn fun(req: claudr.ContextRequest, packet: table): table|nil
function M.register(filetype, fn)
  assert(
    type(filetype) == "string" and type(fn) == "function",
    "поставщик: тип файла и функция"
  )
  extra[filetype] = extra[filetype] or {}
  table.insert(extra[filetype], fn)
end

--- Снимает все дополнительные поставщики типа файла (без аргумента — всех).
function M.unregister(filetype)
  if filetype then
    extra[filetype] = nil
  else
    extra = {}
  end
end

local function relpath(project_dir, path)
  if path == "" then
    return path
  end
  local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local rel = vim.fs.relpath(project_dir, abs)
  return rel or abs
end

-- Виды узлов, которые считаются охватывающим определением.
local SCOPE_PATTERNS = {
  "function",
  "method",
  "class",
  "struct",
  "impl",
  "interface",
  "module",
  "enum",
  "trait",
}

local function is_scope(node)
  local ty = node:type()
  for _, p in ipairs(SCOPE_PATTERNS) do
    if ty:find(p, 1, true) then
      return true
    end
  end
  return false
end

local MAX_NODE_LINES = 300

local function ts_info(req, packet)
  local ok, parser = pcall(vim.treesitter.get_parser, req.bufnr, nil, { error = false })
  if not ok or not parser then
    return
  end
  local ok_parse = pcall(function()
    parser:parse(true)
  end)
  if not ok_parse then
    return
  end
  local sr, er
  if req.range then
    sr, er = req.range[1] - 1, req.range[2] - 1
  else
    sr, er = req.cursor[1] - 1, req.cursor[1] - 1
  end
  local sc = req.range and 0 or req.cursor[2]
  local last = vim.api.nvim_buf_get_lines(req.bufnr, er, er + 1, false)[1] or ""
  local ec = req.range and #last or req.cursor[2]
  local node = parser:named_node_for_range({ sr, sc, er, ec }, { ignore_injections = false })
  if not node then
    return
  end
  local scope = node
  while scope and not is_scope(scope) do
    scope = scope:parent()
  end
  local chosen = scope or node
  local s, _, e = chosen:range()
  local info = { type = chosen:type(), lines = { s + 1, e + 1 } }
  if scope then
    local name = scope:field("name")[1]
    if name then
      info.name = vim.treesitter.get_node_text(name, req.bufnr)
      packet.symbol = info.name
    end
  end
  if req.kind == "cursor" and e - s < MAX_NODE_LINES then
    info.text = vim.treesitter.get_node_text(chosen, req.bufnr)
  end
  packet.node = info
end

local function hover_text(contents)
  if type(contents) == "string" then
    return contents
  end
  if type(contents) ~= "table" then
    return nil
  end
  if contents.value then
    return contents.value
  end
  local parts = {}
  for _, c in ipairs(contents) do
    local s = hover_text(c)
    if s and s ~= "" then
      parts[#parts + 1] = s
    end
  end
  return #parts > 0 and table.concat(parts, "\n\n") or nil
end

local function first_location(result)
  if type(result) ~= "table" then
    return nil
  end
  if result.uri or result.targetUri then
    return result
  end
  return result[1]
end

local function line_of(path, lnum)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  end
  local ok, lines = pcall(vim.fn.readfile, path, "", lnum)
  return ok and lines[lnum] or nil
end

local function lsp_info(req, packet, done)
  local clients = vim.lsp.get_clients({ bufnr = req.bufnr })
  local def_clients, hover_clients = 0, 0
  for _, c in ipairs(clients) do
    if c:supports_method("textDocument/definition", req.bufnr) then
      def_clients = def_clients + 1
    end
    if c:supports_method("textDocument/hover", req.bufnr) then
      hover_clients = hover_clients + 1
    end
  end
  local pending = (def_clients > 0 and 1 or 0) + (hover_clients > 0 and 1 or 0)
  if pending == 0 then
    done()
    return
  end
  local row = req.range and req.range[1] or req.cursor[1]
  local col = req.range and 0 or req.cursor[2]
  local text = vim.api.nvim_buf_get_lines(req.bufnr, row - 1, row, false)[1] or ""
  local function params(client)
    local ok, character =
      pcall(vim.str_utfindex, text, client.offset_encoding or "utf-16", math.min(col, #text))
    return {
      textDocument = { uri = vim.uri_from_bufnr(req.bufnr) },
      position = { line = row - 1, character = ok and character or 0 },
    }
  end
  local function finish_one()
    pending = pending - 1
    if pending == 0 then
      done()
    end
  end
  if def_clients > 0 then
    vim.lsp.buf_request_all(req.bufnr, "textDocument/definition", params, function(results)
      for _, r in pairs(results or {}) do
        local loc = not r.err and first_location(r.result)
        if loc then
          local uri = loc.targetUri or loc.uri
          local range = loc.targetSelectionRange or loc.range
          local path = vim.uri_to_fname(uri)
          local lnum = range.start.line + 1
          packet.definition = {
            file = relpath(req.project_dir, path),
            line = lnum,
            text = line_of(path, lnum),
          }
          break
        end
      end
      finish_one()
    end)
  end
  if hover_clients > 0 then
    vim.lsp.buf_request_all(req.bufnr, "textDocument/hover", params, function(results)
      for _, r in pairs(results or {}) do
        local s = not r.err and r.result and hover_text(r.result.contents)
        if s and s ~= "" then
          packet.hover = s
          break
        end
      end
      finish_one()
    end)
  end
end

--- Общий поставщик: собирает пакет и вызывает `done(packet)`. Запросы к языковому серверу
--- асинхронны; без сервера `done` вызывается сразу.
---@param req claudr.ContextRequest
---@param done fun(packet: table)
function M.general(req, done)
  local bufnr = req.bufnr
  local packet = {
    file = relpath(req.project_dir, vim.api.nvim_buf_get_name(bufnr)),
    filetype = vim.bo[bufnr].filetype,
  }
  if req.kind == "file" then
    packet.content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  elseif req.kind == "selection" then
    packet.lines = { req.range[1], req.range[2] }
    packet.text =
      table.concat(vim.api.nvim_buf_get_lines(bufnr, req.range[1] - 1, req.range[2], false), "\n")
  else
    packet.lines = { req.cursor[1], req.cursor[1] }
  end
  ts_info(req, packet)
  lsp_info(req, packet, function()
    done(packet)
  end)
end

--- Полный пакет: общий поставщик и дополнительные поставщики типа файла буфера.
---@param req claudr.ContextRequest
---@param done fun(packet: table)
function M.collect(req, done)
  M.general(req, function(packet)
    for _, fn in ipairs(extra[packet.filetype] or {}) do
      local ok, add = pcall(fn, req, vim.deepcopy(packet))
      if ok and type(add) == "table" then
        packet = vim.tbl_deep_extend("force", packet, add)
      elseif not ok then
        vim.notify(
          "claudr: поставщик контекста: " .. tostring(add),
          vim.log.levels.WARN
        )
      end
    end
    done(packet)
  end)
end

-- Разделитель вопроса и пакета контекста в тексте, который уходит процессу. По нему окно
-- темы показывает только сам вопрос, в том числе при восстановлении из транскрипта.
M.SEPARATOR = "<claudr-context>"

local KNOWN = {
  file = true,
  filetype = true,
  lines = true,
  text = true,
  content = true,
  node = true,
  symbol = true,
  definition = true,
  hover = true,
}

local function fence(lang, body)
  local mark = "```"
  while body:find(mark, 1, true) do
    mark = mark .. "`"
  end
  return mark .. (lang or "") .. "\n" .. body .. "\n" .. mark
end

--- Текст для процесса: вопрос, затем разделитель и пакет контекста.
---@param question string
---@param packet table|nil
function M.format(question, packet)
  if not packet or vim.tbl_isempty(packet) then
    return question
  end
  local out = { question, "", M.SEPARATOR }
  local function add(s)
    out[#out + 1] = s
  end
  local lang = packet.filetype ~= "" and packet.filetype or nil
  if packet.file then
    if packet.lines then
      add(("File: %s, lines %d-%d"):format(packet.file, packet.lines[1], packet.lines[2]))
    else
      add("File: " .. packet.file)
    end
  end
  if packet.symbol then
    add("Symbol: " .. packet.symbol)
  end
  if packet.node then
    add(
      ("Enclosing syntax node: %s, lines %d-%d"):format(
        packet.node.type,
        packet.node.lines[1],
        packet.node.lines[2]
      )
    )
  end
  if packet.text then
    add("Selected text:")
    add(fence(lang, packet.text))
  elseif packet.node and packet.node.text then
    add("Enclosing node text:")
    add(fence(lang, packet.node.text))
  end
  if packet.content then
    add("File content (current buffer, including unsaved changes):")
    add(fence(lang, packet.content))
  end
  if packet.definition then
    add(
      ("Definition: %s:%d%s"):format(
        packet.definition.file,
        packet.definition.line,
        packet.definition.text and (": " .. vim.trim(packet.definition.text)) or ""
      )
    )
  end
  if packet.hover then
    add("Symbol description from the language server:")
    add(fence(nil, packet.hover))
  end
  local keys = {}
  for k in pairs(packet) do
    if not KNOWN[k] then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = packet[k]
    add(("%s: %s"):format(k, type(v) == "string" and v or vim.json.encode(v)))
  end
  return table.concat(out, "\n")
end

--- Вопрос без пакета контекста (для показа в окне темы).
function M.strip(text)
  local pos = text:find("\n" .. M.SEPARATOR, 1, true)
  if pos then
    return vim.trim(text:sub(1, pos - 1))
  end
  return text
end

return M
