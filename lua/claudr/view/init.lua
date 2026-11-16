-- Подключение к узлам дерева (спецификация node-view, решения D4, D18, D61, D62).
--
-- Вид определяется видом узла: панель (с агентом и с командой одинаково) — наблюдение за
-- терминалом, вкладка и workspace — наблюдение за терминалом агента вкладки (без агента —
-- панели в фокусе), субагент — транскрипт, фоновая команда — файл вывода, вызов Bash — его
-- вывод. Подключение к панели с вводом и прокрутка её истории — отдельные явные действия.
-- Действия регистрируются в дереве, подкоманды — в `setup()`.
local commands = require("claudr.commands")
local model = require("claudr.tree.model")
local window = require("claudr.view.window")

local M = {}

-- Клавиши действий в окне дерева и в видах.
M.KEYS = { open = "<CR>", attach = "i", scrollback = "S" }

-- Панель строки: у вкладки и workspace — агент вкладки, без него панель в фокусе.
local function pane_of(node)
  if node and (node.kind == "tab" or node.kind == "workspace") then
    return model.pane_node(node)
  end
  return node
end

local function pane_only(node, what)
  if not node or node.kind ~= "pane" then
    vim.notify("claudr: " .. what .. " — только для панели", vim.log.levels.WARN)
    return false
  end
  return true
end

-- Рабочий каталог сессии владельца вида: `cwd` панели (для субагента и фоновой команды —
-- панели-владельца).
local function owner_cwd(node_id)
  local node = model.get(node_id)
  if node and node.kind ~= "pane" then
    node = node.owner_pane and model.get(node.owner_pane)
  end
  local d = node and node.data
  return d and (d.cwd or d.foreground_cwd) or nil
end

local function add_view_keys(v)
  if not v or not vim.api.nvim_buf_is_valid(v.buf) then
    return v
  end
  if v.kind ~= "scrollback" then
    require("claudr.refs").attach(v.buf, {
      cwd = function()
        return owner_cwd(v.node_id)
      end,
    })
  end
  local function map(key, fn, desc)
    vim.keymap.set("n", key, function()
      local node = model.get(v.node_id)
      if node then
        fn(node)
      else
        vim.notify("claudr: узел закрыт", vim.log.levels.WARN)
      end
    end, { buffer = v.buf, nowait = true, silent = true, desc = desc })
  end
  if v.kind == "observe" or v.kind == "scrollback" then
    map(M.KEYS.attach, M.attach, "claudr: подключиться с вводом")
  end
  if v.kind == "observe" then
    map(M.KEYS.scrollback, M.scrollback, "claudr: история панели")
  end
  local message_key = require("claudr.config").get().message_input.key
  if message_key and (v.kind == "observe" or v.kind == "scrollback") then
    map(message_key, function(node)
      require("claudr.messaging").send_message({ node = node })
    end, "claudr: сообщение агенту")
  end
  local dialog_key = require("claudr.config").get().dialogs.key
  if dialog_key and (v.kind == "observe" or v.kind == "scrollback") then
    map(dialog_key, function(node)
      require("claudr.dialogs").open_for_node(node)
    end, "claudr: буфер диалога")
  end
  return v
end

-- Вид каждого вида узла, открываемый по Enter.
local OPEN_KIND = { pane = "observe", subagent = "subagent", task = "task", bash = "bash" }

-- Уже открытый вид узла `node` (того вида, который открывает Enter) или nil.
local function open_view_of(node)
  for _, v in ipairs(window.list()) do
    if not v.released and v.node_id == node.id and v.kind == OPEN_KIND[node.kind] then
      return v
    end
  end
  return nil
end

--- Открывает вид узла по его виду; вид узла, который уже открыт, показывается снова
--- (решение D68). Возвращает вид или nil.
function M.open(node)
  local v
  if node.kind == "tab" or node.kind == "workspace" then
    local pane = pane_of(node)
    if not pane then
      vim.notify("claudr: во вкладке нет панелей", vim.log.levels.WARN)
      return nil
    end
    node = pane
  end
  local opened = open_view_of(node)
  if opened then
    opened.win = window.open_view(opened.buf)
    return opened
  end
  if node.kind == "pane" then
    v = require("claudr.view.observe").open(node)
  elseif node.kind == "subagent" then
    v = require("claudr.view.files").open_subagent(node)
  elseif node.kind == "task" then
    v = require("claudr.view.files").open_task(node)
  elseif node.kind == "bash" then
    v = require("claudr.view.files").open_bash(node)
  else
    vim.notify(
      "claudr: неизвестный вид узла " .. tostring(node.kind),
      vim.log.levels.ERROR
    )
    return nil
  end
  return add_view_keys(v)
end

--- Подключение к панели с вводом; `opts.takeover` — с вытеснением другого клиента.
function M.attach(node, opts)
  node = pane_of(node)
  if not pane_only(node, "подключение с вводом") then
    return nil
  end
  return require("claudr.view.attach").open(node, opts)
end

--- История панели через `pane.read`.
function M.scrollback(node)
  node = pane_of(node)
  if not pane_only(node, "история") then
    return nil
  end
  return add_view_keys(require("claudr.view.scrollback").open(node))
end

--- Закрывает все открытые виды (процессы наблюдения и подключения завершаются).
function M.close_all()
  window.close_all()
end

--- Открытые виды (для проверок).
function M.views()
  return window.list()
end

-- Узел для подкоманды: по идентификатору из аргумента, иначе узел вида в текущем буфере,
-- иначе узел под курсором дерева.
local function resolve(args)
  local id = args[1]
  if not id then
    id = vim.b.claudr_node_id
  end
  if id then
    model.start()
    local node = model.get(id)
    if not node then
      vim.notify("claudr: узел " .. id .. " не найден", vim.log.levels.ERROR)
    end
    return node
  end
  local node = require("claudr.tree.view").node_at_cursor()
  if not node then
    vim.notify(
      "claudr: укажите узел или выберите его в дереве (:Claudr tree)",
      vim.log.levels.WARN
    )
  end
  return node
end

local function complete_ids(pred)
  return function(arglead)
    local out = {}
    for _, node in ipairs(model.find(pred)) do
      if vim.startswith(node.id, arglead) then
        out[#out + 1] = node.id
      end
    end
    return out
  end
end

local function is_pane(node)
  return node.kind == "pane"
end

local defined = false

--- Регистрирует подкоманды и действия дерева.
function M.setup()
  commands.register("view", function(args)
    local node = resolve(args)
    if node then
      M.open(node)
    end
  end, {
    desc = "подключиться к узлу (вид по виду узла)",
    complete = complete_ids(),
  })
  commands.register("attach", function(args)
    local node = resolve(args)
    if node then
      M.attach(node)
    end
  end, {
    desc = "подключиться к панели с вводом",
    complete = complete_ids(is_pane),
  })
  commands.register("scrollback", function(args)
    local node = resolve(args)
    if node then
      M.scrollback(node)
    end
  end, { desc = "история панели (pane.read)", complete = complete_ids(is_pane) })

  local tree_view = require("claudr.tree.view")
  tree_view.register_action("view", {
    key = M.KEYS.open,
    desc = "подключиться к узлу",
    run = M.open,
  })
  tree_view.register_action("attach", {
    key = M.KEYS.attach,
    desc = "подключиться к панели с вводом",
    run = M.attach,
  })
  tree_view.register_action("scrollback", {
    key = M.KEYS.scrollback,
    desc = "история панели",
    run = M.scrollback,
  })

  if not defined then
    defined = true
    -- процессы наблюдения и подключения не переживают Neovim
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("claudr.view", { clear = true }),
      callback = M.close_all,
    })
  end
end

return M
