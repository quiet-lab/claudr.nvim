-- Пользовательская команда `:Claudr <подкоманда> [аргументы]` и регистрация подкоманд.
-- Модули возможностей регистрируют свои подкоманды в собственном `setup()`.
local M = {}

---@class claudr.Subcommand
---@field fn fun(args: string[], ctx: table)
---@field desc string|nil
---@field complete (fun(arglead: string, args: string[]): string[])|nil

---@type table<string, claudr.Subcommand>
local subcommands = {}

--- Регистрирует подкоманду; повторная регистрация имени заменяет прежнюю.
---@param name string
---@param fn fun(args: string[], ctx: table)
---@param opts { desc: string|nil, complete: (fun(arglead: string, args: string[]): string[])|nil }|nil
function M.register(name, fn, opts)
  opts = opts or {}
  subcommands[name] = { fn = fn, desc = opts.desc, complete = opts.complete }
end

--- Имена зарегистрированных подкоманд по алфавиту.
function M.names()
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return names
end

--- Описание подкоманды или `nil`.
function M.get(name)
  return subcommands[name]
end

--- Выполняет подкоманду по имени; неизвестное имя — сообщение пользователю.
---@param name string|nil
---@param args string[]
---@param ctx table|nil
function M.run(name, args, ctx)
  local sub = name and subcommands[name]
  if not sub then
    local known = M.names()
    local text
    if name == nil or name == "" then
      text = "claudr: укажите подкоманду"
    else
      text = ("claudr: неизвестная подкоманда %q"):format(name)
    end
    if #known > 0 then
      text = text .. " (доступны: " .. table.concat(known, ", ") .. ")"
    else
      text = text .. "; вызовите require('claudr').setup()"
    end
    vim.notify(text, vim.log.levels.ERROR)
    return
  end
  sub.fn(args or {}, ctx or {})
end

local function complete(arglead, cmdline)
  local words = vim.split(vim.trim(cmdline), "%s+")
  local at_name = #words <= 1 or (#words == 2 and not cmdline:match("%s$"))
  if at_name then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, M.names())
  end
  local sub = subcommands[words[2]]
  if sub and sub.complete then
    local rest = vim.list_slice(words, 3)
    return sub.complete(arglead, rest)
  end
  return {}
end

--- Создаёт пользовательскую команду `:Claudr`; повторный вызов безвреден.
function M.define()
  vim.api.nvim_create_user_command("Claudr", function(cmd)
    local fargs = cmd.fargs
    M.run(fargs[1], vim.list_slice(fargs, 2), { bang = cmd.bang, smods = cmd.smods })
  end, {
    nargs = "*",
    bang = true,
    complete = complete,
    desc = "claudr.nvim: подкоманды плагина",
  })
end

return M
