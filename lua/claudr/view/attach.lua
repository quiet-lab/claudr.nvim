-- Подключение к панели с вводом (спецификация node-view, решение D20): буфер терминала
-- Neovim с `herdr terminal attach <terminal_id>`. Работает для любой панели с терминалом,
-- `herdr agent attach` не используется. Если терминал занят другим клиентом, сервер
-- отказывает; плагин показывает причину и предлагает вытеснение, подключение с `--takeover`
-- — только по выбору пользователя. Отключение (`Ctrl+b q` или закрытие вида) завершает
-- только клиента, панель остаётся живой.
local herdr = require("claudr.herdr")
local window = require("claudr.view.window")

local M = {}

M.BUSY_PATTERN = "already has an attached client"
M.CHOICE_TAKEOVER = "Вытеснить другого клиента и подключиться"
M.CHOICE_CANCEL = "Отмена"

local function strip(s)
  s = s:gsub("\27%[[%d;?]*[%a]", ""):gsub("\r", "")
  return s
end

-- Последняя строка сообщения herdr в выводе клиента или nil.
local function herdr_message(output)
  local found
  for line in strip(output):gmatch("[^\n]+") do
    if line:find("^herdr:") or line:find("^Error:") then
      found = line
    end
  end
  return found
end

local function offer_takeover(node, reason)
  vim.notify("claudr: " .. reason, vim.log.levels.WARN)
  vim.ui.select({ M.CHOICE_TAKEOVER, M.CHOICE_CANCEL }, {
    prompt = "Терминал панели занят другим клиентом с вводом",
  }, function(choice)
    if choice == M.CHOICE_TAKEOVER then
      M.open(node, { takeover = true })
    end
  end)
end

local function on_exit(v, code)
  v.exited = code
  local output = table.concat(v.output)
  local message = herdr_message(output)
  local released = v.released
  window.close(v)
  if released then
    return
  end
  if code ~= 0 and output:find(M.BUSY_PATTERN, 1, true) then
    offer_takeover(v.node, message or "терминал занят другим клиентом")
  elseif code ~= 0 then
    vim.notify(
      "claudr: подключение к панели завершено: "
        .. (message or ("код выхода " .. code)),
      vim.log.levels.WARN
    )
  end
end

--- Подключается с вводом к панели `node`; `opts.takeover` — с вытеснением другого клиента
--- (только по решению пользователя). Возвращает вид или nil.
function M.open(node, opts)
  opts = opts or {}
  local tid = node.data and node.data.terminal_id
  if type(tid) ~= "string" or tid == "" then
    vim.notify(
      "claudr: у панели нет терминала для подключения",
      vim.log.levels.ERROR
    )
    return nil
  end
  local buf = window.scratch()
  local win = window.open_view(buf, { title = "ввод: " .. (node.label or node.id) })
  local v = { kind = "attach", node_id = node.id, node = node, buf = buf, win = win, output = {} }
  vim.b[buf].claudr_node_id = node.id
  local cmd = { "herdr", "terminal", "attach" }
  if opts.takeover then
    cmd[#cmd + 1] = "--takeover"
  end
  cmd[#cmd + 1] = tid
  v.takeover = opts.takeover == true
  local ok, job = pcall(vim.fn.jobstart, cmd, {
    term = true,
    env = { HERDR_SOCKET_PATH = herdr.socket_path() },
    on_stdout = function(_, data)
      v.output[#v.output + 1] = table.concat(data, "\n")
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        on_exit(v, code)
      end)
    end,
  })
  if not ok or job <= 0 then
    window.close(v)
    vim.notify(
      "claudr: не удалось запустить herdr: " .. tostring(job),
      vim.log.levels.ERROR
    )
    return nil
  end
  v.job = job
  local pok, pid = pcall(vim.fn.jobpid, job)
  v.pid = pok and pid or nil

  function v.dispose()
    if v.exited == nil then
      pcall(vim.fn.jobstop, v.job)
    end
  end
  window.register(v)
  -- ссылки на файлы действуют в нормальном режиме, после выхода из режима ввода терминала
  require("claudr.refs").attach(buf, {
    cwd = function()
      local live = require("claudr.tree.model").get(node.id) or node
      local d = live.data
      return d and (d.cwd or d.foreground_cwd) or nil
    end,
  })
  vim.cmd.startinsert()
  return v
end

return M
