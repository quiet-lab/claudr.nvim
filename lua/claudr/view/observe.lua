-- Вид панели по умолчанию — наблюдение за терминалом (спецификация node-view, решение D20).
--
-- Процесс `herdr terminal session observe <панель>` печатает строки JSON кадров
-- `terminal.frame`: байты ANSI в base64, первый кадр полный, далее приращения. Кадры
-- передаются в буфер терминала Neovim (`nvim_open_term`): эмулятор терминала сам применяет
-- приращения. Ввода у буфера нет, процесс наблюдения ввод не читает. Размер окна берётся из
-- `width`/`height` кадра. Закрытие вида завершает процесс наблюдения по его PID сигналом
-- SIGTERM, панель остаётся живой. Обновление — только по выводу процесса, таймеров и опроса нет.
local herdr = require("claudr.herdr")
local window = require("claudr.view.window")

local M = {}

-- Кадр из строки вывода или nil.
local function parse_frame(line)
  local ok, rec = pcall(vim.json.decode, line)
  if not ok or type(rec) ~= "table" or rec.type ~= "terminal.frame" then
    return nil
  end
  if type(rec.bytes) ~= "string" then
    return nil
  end
  local dok, bytes = pcall(vim.base64.decode, rec.bytes)
  if not dok then
    return nil
  end
  return {
    bytes = bytes,
    full = rec.full == true,
    seq = rec.seq,
    width = tonumber(rec.width),
    height = tonumber(rec.height),
  }
end

local function apply(v, frames)
  if v.released then
    return
  end
  for _, f in ipairs(frames) do
    if f.width and f.height and (f.width ~= v.width or f.height ~= v.height) then
      v.width, v.height = f.width, f.height
      window.resize(v.win, f.width, f.height)
    end
    local bytes = f.bytes
    if f.full then
      -- полный кадр рисует экран заново
      bytes = "\27[H\27[2J" .. bytes
    end
    vim.api.nvim_chan_send(v.chan, bytes)
    v.frames = v.frames + 1
    v.seq = f.seq
  end
end

local function on_exit(v, res)
  v.exited = res
  if v.released then
    return
  end
  local msg = vim.trim((v.stderr or ""):gsub("\r", ""))
  local text = "\r\n[наблюдение завершено"
  if msg ~= "" then
    text = text .. ": " .. msg:gsub("\n", " ")
  end
  vim.api.nvim_chan_send(v.chan, text .. "]\r\n")
end

--- Открывает вид наблюдения за панелью `node` (узел дерева вида "pane"). Возвращает вид.
function M.open(node)
  local pane_id = node.id
  local buf = window.scratch()
  local win =
    window.open_float(buf, { title = "наблюдение: " .. (node.label or pane_id) })
  local chan = vim.api.nvim_open_term(buf, {})
  local v = {
    kind = "observe",
    node_id = pane_id,
    buf = buf,
    win = win,
    chan = chan,
    frames = 0,
    stderr = "",
  }
  vim.b[buf].claudr_node_id = pane_id

  local pending = ""
  local ok, proc = pcall(vim.system, { "herdr", "terminal", "session", "observe", pane_id }, {
    env = { HERDR_SOCKET_PATH = herdr.socket_path() },
    stdout = function(_, data)
      if not data then
        return
      end
      pending = pending .. data
      local frames = {}
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local f = parse_frame(pending:sub(1, nl - 1))
        pending = pending:sub(nl + 1)
        if f then
          frames[#frames + 1] = f
        end
      end
      if #frames > 0 then
        vim.schedule(function()
          apply(v, frames)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        v.stderr = v.stderr .. data
      end
    end,
  }, function(res)
    vim.schedule(function()
      on_exit(v, res)
    end)
  end)
  if not ok then
    vim.api.nvim_chan_send(
      chan,
      "[не удалось запустить herdr: " .. tostring(proc) .. "]\r\n"
    )
    v.exited = { code = -1 }
  else
    v.proc = proc
    v.pid = proc.pid
  end

  function v.dispose()
    if v.proc and not v.exited then
      -- клиент наблюдения сам не завершается и ввод не читает, останавливается сигналом
      v.proc:kill("sigterm")
    end
  end
  return window.register(v)
end

M._parse_frame = parse_frame

return M
