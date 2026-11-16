-- Диалоги агентов (спецификация agent-dialogs): запрос хука `PermissionRequest` показывается
-- буфером диалога (`dialogs/buffer.lua`), решение уходит хуку через перечень ждущих запросов
-- (`dialogs/pending.lua`). Модуль подключает команду `:Claudr dialog`, действие дерева и
-- сообщение об ожидании; окно и фокус сам не меняет (D33).
local commands = require("claudr.commands")
local model = require("claudr.tree.model")

local M = {}

M.TREE_KEY = "d"

local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO)
end

local function pending()
  local ok, p = pcall(require, "claudr.dialogs.pending")
  return ok and p or nil
end

-- Ждущие запросы узла: строка вкладки — агента вкладки (с его субагентами), workspace с одной
-- вкладкой — так же, workspace с несколькими вкладками — всех панелей с агентом внутри.
local function requests_for(node)
  local p = pending()
  if not p then
    return {}
  end
  local agent = model.agent_node(node)
  if agent then
    return p.for_node(agent)
  end
  if node.kind ~= "workspace" then
    return {}
  end
  local out = {}
  for _, pane in ipairs(model.agent_panes()) do
    local ws = pane.data and pane.data.workspace_id
    if ws == node.id then
      vim.list_extend(out, p.for_node(pane))
    end
  end
  return out
end

local function request_title(req)
  local r = req.request or {}
  local what
  if r.kind == "question" then
    what = r.questions and r.questions[1] and r.questions[1].question
  elseif r.kind == "plan" then
    what = "план"
  elseif r.content then
    what = r.content.command or r.content.file_path
  end
  local who = r.agent_id and (" субагент " .. r.agent_id) or ""
  return vim.trim(
    ("#%s %s%s: %s"):format(
      tostring(req.id),
      tostring(req.tool_name),
      who,
      (tostring(what or ""):gsub("\n", " "))
    )
  )
end

--- Есть ли у панели ждущие запросы (включая запросы её субагентов).
---@param pane_id string
---@return boolean
function M.has_pending(pane_id)
  local node = pane_id and model.get(pane_id)
  local p = pending()
  if not node or not p then
    return false
  end
  return p.count(node) > 0
end

--- Открывает буфер диалога по ждущему запросу узла; несколько запросов — выбор. Возвращает
--- `true`, если запрос есть и буфер открыт (или выбор предложен); иначе сообщает и `false`.
---@param node table|nil
---@return boolean
function M.open_for_node(node)
  local list = node and requests_for(node) or {}
  if #list == 0 then
    notify(
      "claudr: у узла нет ждущего запроса диалога",
      vim.log.levels.WARN
    )
    return false
  end
  local buffer = require("claudr.dialogs.buffer")
  if #list == 1 then
    buffer.open(list[1])
    return true
  end
  vim.ui.select(
    list,
    { prompt = "Запрос диалога:", format_item = request_title },
    function(choice)
      if choice then
        buffer.open(choice)
      end
    end
  )
  return true
end

--- То же по идентификатору панели.
---@param pane_id string
---@return boolean
function M.open_for_pane(pane_id)
  local node = pane_id and model.get(pane_id)
  if not node then
    notify(
      "claudr: панель " .. tostring(pane_id) .. " не найдена",
      vim.log.levels.WARN
    )
    return false
  end
  return M.open_for_node(node)
end

-- Узел для подкоманды: идентификатор из аргумента, узел вида в текущем буфере, узел под
-- курсором дерева.
local function resolve(args)
  local id = args[1] or vim.b.claudr_node_id
  if id then
    model.start()
    local node = model.get(id)
    if not node then
      notify("claudr: узел " .. id .. " не найден", vim.log.levels.ERROR)
    end
    return node
  end
  local node = require("claudr.tree.view").node_at_cursor()
  if not node then
    notify(
      "claudr: укажите узел или выберите его в дереве (:Claudr tree)",
      vim.log.levels.WARN
    )
  end
  return node
end

--- Подключает команду, действие дерева, сообщение об ожидании и сокет хука.
function M.setup()
  commands.register("dialog", function(args)
    local node = resolve(args)
    if node then
      M.open_for_node(node)
    end
  end, {
    desc = "буфер диалога по ждущему запросу узла (необязательно: идентификатор узла)",
    complete = function(arglead)
      local out = {}
      for _, n in
        ipairs(model.find(function(x)
          return x.kind == "pane" or x.kind == "subagent"
        end))
      do
        if vim.startswith(n.id, arglead) then
          out[#out + 1] = n.id
        end
      end
      return out
    end,
  })
  require("claudr.tree.view").register_action("dialog", {
    key = M.TREE_KEY,
    desc = "буфер диалога (ждущий запрос)",
    run = M.open_for_node,
  })
  require("claudr.dialogs.notify").start()
  local p = pending()
  if p and p.start then
    local ok, started, err = pcall(p.start)
    if not ok or not started then
      notify(
        "claudr: сокет диалогов не запущен: "
          .. tostring(ok and err or started),
        vim.log.levels.WARN
      )
    end
  end
end

return M
