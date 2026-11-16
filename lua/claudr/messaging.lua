-- Сообщения и клавиши агентам (спецификация messaging, решение D11).
--
-- Текст набирается окном ввода (`claudr.input`) и уходит методом `agent.prompt` с целью — выбранной панелью с агентом; клавиши —
-- методом `pane.send_keys`. Целью служит узел дерева (под курсором или переданный), панель,
-- переданная идентификатором, либо панель с агентом из перечня `vim.ui.select`. Субагентам и
-- фоновым командам писать нельзя: у них нет панели, запросов к серверу нет. Без сервера
-- отправка завершается сообщением, ничего не откладывается. Таймеров и опроса нет.
local commands = require("claudr.commands")
local config = require("claudr.config")
local herdr = require("claudr.herdr")
local model = require("claudr.tree.model")

local M = {}

local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO)
end

local function present(v)
  return v ~= nil and v ~= vim.NIL and v ~= ""
end

local function tree_view()
  return require("claudr.tree.view")
end

-- Сообщение о недоступности сервера; `true`, если сервера нет.
local function server_missing()
  local st = herdr.state()
  if st.status == "connected" then
    return false
  end
  local text = "claudr: сервер herdr недоступен"
  if st.status == "stopped" then
    text = text
      .. " (подключение не запущено: откройте дерево командой :Claudr tree)"
  elseif present(st.message) then
    text = text .. " (" .. st.message .. ")"
  end
  notify(text, vim.log.levels.ERROR)
  return true
end

local function error_text(method, err)
  return ("claudr: %s: %s: %s"):format(method, tostring(err.code), tostring(err.message))
end

-- Отказ для узлов без панели; `true`, если узел отвергнут.
local function refuse_without_pane(node)
  if node and (node.kind == "subagent" or node.kind == "task") then
    local who = node.kind == "subagent" and "субагенту" or "фоновой команде"
    notify(
      ("claudr: у узла нет панели: %s писать нельзя"):format(who),
      vim.log.levels.WARN
    )
    return true
  end
  return false
end

local function pane_title(p)
  local what = present(p.display_agent) and p.display_agent
    or tostring(p.agent or p.foreground_process)
  local title = present(p.terminal_title_stripped) and p.terminal_title_stripped
    or (present(p.terminal_title) and p.terminal_title or "")
  local state = present(p.agent_status) and (" [" .. p.agent_status .. "]") or ""
  return vim.trim(("%s%s %s %s"):format(p.pane_id, state, what, title))
end

-- Панели с агентом из снимка в пределах узла (workspace или вкладка) либо все.
local function agent_panes(node)
  local out = {}
  for _, p in ipairs(herdr.state().snapshot.panes or {}) do
    local inside = true
    if node and node.kind == "workspace" then
      inside = p.workspace_id == node.id
    elseif node and node.kind == "tab" then
      inside = p.tab_id == node.id
    end
    if inside and present(p.agent) then
      out[#out + 1] = p
    end
  end
  table.sort(out, function(a, b)
    return a.pane_id < b.pane_id
  end)
  return out
end

-- Узел цели: переданный, иначе узел дерева под курсором.
local function target_node(opts)
  if opts.node then
    return opts.node
  end
  if opts.pane_id then
    return nil
  end
  return tree_view().node_at_cursor()
end

-- Выбор панели цели; `cb(pane_id, title)`. Панель-узел берётся сразу (для сообщения — тоже
-- панель с командой: сервер ответит ошибкой, если в ней нет агента), иначе — выбор из
-- панелей с агентом.
local function pick_pane(opts, node, cb)
  if opts.pane_id then
    cb(opts.pane_id, opts.pane_id)
    return
  end
  if node and node.kind == "pane" then
    cb(node.id, node.label or node.id)
    return
  end
  if node and node.kind == "tab" then
    -- строка вкладки адресуется агенту вкладки; без агента сообщение не отправляется
    local agent = model.agent_node(node)
    if not agent then
      notify("claudr: во вкладке нет агента", vim.log.levels.WARN)
      return
    end
    cb(agent.id, agent.label or agent.id)
    return
  end
  if node and node.kind == "workspace" and node.agent_pane then
    local agent = model.agent_node(node)
    cb(agent.id, agent.label or agent.id)
    return
  end
  local panes = agent_panes(node)
  if #panes == 0 then
    notify("claudr: нет панелей с агентом", vim.log.levels.WARN)
    return
  end
  vim.ui.select(panes, {
    prompt = "Панель с агентом:",
    format_item = pane_title,
  }, function(choice)
    if choice then
      cb(choice.pane_id, pane_title(choice))
    end
  end)
end

local function done(opts, err, result)
  if opts.on_done then
    opts.on_done(err, result)
  end
end

-- Разбор последовательности клавиш: имена через пробелы или запятые.
local function parse_keys(text)
  local keys = {}
  for key in (text or ""):gmatch("[^%s,]+") do
    keys[#keys + 1] = key
  end
  return keys
end

local function request_keys(pane_id, keys, opts)
  herdr.request("pane.send_keys", { pane_id = pane_id, keys = keys }, function(err, result)
    if err then
      if err.code == "server_unavailable" then
        notify(
          "claudr: сервер herdr недоступен: клавиши не отправлены",
          vim.log.levels.ERROR
        )
      else
        notify(error_text("pane.send_keys", err), vim.log.levels.ERROR)
      end
    else
      notify(
        ("claudr: клавиши отправлены в панель %s: %s"):format(
          pane_id,
          table.concat(keys, " ")
        )
      )
    end
    done(opts, err, result)
  end)
end

-- Клавиши для панели `pane_id`: заданные в `opts.keys` либо введённые через `vim.ui.input`.
local function ask_keys(pane_id, title, opts)
  local function send(text)
    local keys = parse_keys(text)
    if #keys > 0 then
      request_keys(pane_id, keys, opts)
    end
  end
  if opts.keys then
    local keys = opts.keys
    send(type(keys) == "table" and table.concat(keys, " ") or keys)
    return
  end
  vim.ui.input(
    { prompt = ("Клавиши для %s (например, down down enter): "):format(title) },
    send
  )
end

--- Отправка последовательности клавиш панели. `opts`: `node` (узел дерева), `pane_id`,
--- `keys` (строка или список; без неё — ввод через `vim.ui.input`), `on_done(err, result)`.
---@param opts table|nil
function M.send_keys(opts)
  opts = opts or {}
  local node = target_node(opts)
  if refuse_without_pane(node) or server_missing() then
    done(opts, { code = "refused" })
    return
  end
  pick_pane(opts, node, function(pane_id, title)
    ask_keys(pane_id, title, opts)
  end)
end

-- Агент ждёт ответа на диалог: открыть буфер диалога, если у панели есть ждущий запрос
-- (модуль `claudr.dialogs`), иначе сообщить причину и предложить подключение с вводом.
-- Текст остаётся черновиком окна ввода и иным способом не уходит.
local function on_blocked(pane_id, title)
  local ok, dialogs = pcall(require, "claudr.dialogs")
  if ok and type(dialogs) == "table" and dialogs.has_pending(pane_id) then
    notify(
      ("claudr: агент %s ждёт ответа на диалог; текст сохранён как черновик"):format(
        title
      ),
      vim.log.levels.WARN
    )
    dialogs.open_for_pane(pane_id)
    return
  end
  notify(
    (
      "claudr: агент %s ждёт ответа на диалог или разрешение (состояние blocked); "
      .. "сообщение не отправлено, текст сохранён как черновик"
    ):format(title),
    vim.log.levels.WARN
  )
  vim.ui.select({ "Подключиться с вводом", "Отмена" }, {
    prompt = "Агент ждёт ответа:",
  }, function(choice)
    if choice == "Подключиться с вводом" then
      local node = model.get(pane_id)
      if node then
        require("claudr.view").attach(node)
      end
    end
  end)
end

-- Начало с «/» или «!» (решение D31): предупреждение; при включённой защите — ведущий пробел.
local function guard(text)
  local first = text:sub(1, 1)
  if first ~= "/" and first ~= "!" then
    return text
  end
  if config.get().message_input.guard_commands then
    notify(
      (
        "claudr: текст начинается с «%s»: добавлен ведущий пробел, Claude Code "
        .. "примет его как обычное сообщение"
      ):format(first)
    )
    return " " .. text
  end
  local what = first == "/" and "команду" or "режим оболочки"
  notify(
    ("claudr: текст начинается с «%s»: Claude Code поймёт его как %s"):format(
      first,
      what
    ),
    vim.log.levels.WARN
  )
  return text
end

-- Один вызов `agent.prompt` с полным текстом. `ctl.close(keep_draft)` закрывает окно ввода,
-- `ctl.release()` снимает занятость окна; без окна (`ctl == nil`) — только сообщения.
local function request_prompt(pane_id, title, text, opts, ctl)
  local node = model.get(pane_id)
  local working = node ~= nil and node.state == "working"
  text = guard(text)
  herdr.request("agent.prompt", { target = pane_id, text = text }, function(err, result)
    if err then
      if ctl then
        ctl.release()
      end
      if err.code == "agent_blocked" then
        if ctl then
          ctl.close(true)
        end
        on_blocked(pane_id, title)
      elseif err.code == "server_unavailable" then
        notify(
          "claudr: сервер herdr недоступен: сообщение не отправлено",
          vim.log.levels.ERROR
        )
      else
        notify(error_text("agent.prompt", err), vim.log.levels.ERROR)
      end
    else
      if ctl then
        ctl.close()
      end
      if working then
        notify(
          ("claudr: агент %s работает: сообщение встанет в очередь агента"):format(
            title
          )
        )
      else
        notify(("claudr: сообщение отправлено агенту %s"):format(title))
      end
    end
    done(opts, err, result)
  end)
end

-- Ключ черновика: сессия панели, а без неё — сама панель.
local function draft_key(pane_id)
  for _, p in ipairs(herdr.state().snapshot.panes or {}) do
    if p.pane_id == pane_id then
      return herdr.session_id(p) or pane_id
    end
  end
  return pane_id
end

--- Сообщение агенту: текст набирается в окне ввода (`claudr.input`). `opts`: `node` (узел
--- дерева), `pane_id`, `text` (готовый текст: окно не открывается), `on_done(err, result)`.
---@param opts table|nil
function M.send_message(opts)
  opts = opts or {}
  local node = target_node(opts)
  if refuse_without_pane(node) or server_missing() then
    done(opts, { code = "refused" })
    return
  end
  pick_pane(opts, node, function(pane_id, title)
    if opts.text then
      if vim.trim(opts.text) ~= "" then
        request_prompt(pane_id, title, opts.text, opts)
      end
      return
    end
    require("claudr.input").open({
      title = ("Сообщение для %s"):format(title),
      target = { kind = "message", key = draft_key(pane_id) },
      on_submit = function(text, close, release)
        request_prompt(pane_id, title, text, opts, { close = close, release = release })
        return true
      end,
    })
  end)
end

--- Регистрирует подкоманды и действия дерева.
function M.setup()
  commands.register("message", function(args)
    M.send_message({ pane_id = args[1] })
  end, {
    desc = "сообщение агенту (необязательно: идентификатор панели)",
  })
  commands.register("keys", function(args)
    M.send_keys({ pane_id = args[1] })
  end, {
    desc = "клавиши агенту (необязательно: идентификатор панели)",
  })
  local view = tree_view()
  view.register_action("message", {
    key = "m",
    desc = "сообщение агенту",
    run = function(node)
      M.send_message({ node = node })
    end,
  })
  view.register_action("keys", {
    key = "K",
    desc = "клавиши агенту",
    run = function(node)
      M.send_keys({ node = node })
    end,
  })
end

return M
