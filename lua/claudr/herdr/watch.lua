-- Ожидание создания файла сокета уведомлениями файловой системы (`vim.uv.new_fs_event`),
-- без опроса. Каталога сокета может не быть: тогда наблюдается ближайший существующий
-- родитель, и наблюдение переходит ниже по мере создания каталогов.
--
-- Обратные вызовы выполняются в быстром контексте `vim.uv`.
local uv = vim.uv

local M = {}

function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

local function parent(path)
  local up = path:match("^(.*)/[^/]*$")
  if up == nil or up == "" then
    return "/"
  end
  return up
end

-- Ближайший существующий каталог из `dir` и его родителей.
local function nearest(dir)
  local p = dir
  while not M.exists(p) do
    local up = parent(p)
    if up == p then
      break
    end
    p = up
  end
  return p
end

local Watch = {}
Watch.__index = Watch

function Watch:_stop_handle()
  if self.ev then
    self.ev:stop()
    if not self.ev:is_closing() then
      self.ev:close()
    end
    self.ev = nil
  end
end

function Watch:close()
  self.closed = true
  self:_stop_handle()
end

function Watch:_fire()
  if self.closed then
    return
  end
  self:close()
  self.on_created()
end

-- Поставить наблюдение на ближайший существующий каталог. Каталог, созданный между
-- выбором и постановкой наблюдения, обнаруживается повторным выбором после постановки.
function Watch:_arm()
  while true do
    self:_stop_handle()
    local target = nearest(self.dir)
    self.target = target
    self.ev = uv.new_fs_event()
    self.ev:start(target, {}, function(_, filename)
      self:_on_event(filename)
    end)
    if nearest(self.dir) == target then
      return
    end
  end
end

function Watch:_on_event(filename)
  if self.closed then
    return
  end
  if self.target ~= self.dir or not M.exists(self.dir) then
    -- Наблюдается родитель (или каталог сокета удалён): перейти к новому ближайшему.
    if nearest(self.dir) ~= self.target then
      self:_arm()
      if self.target == self.dir and M.exists(self.path) then
        self:_fire()
      end
    end
    return
  end
  if (filename == nil or filename == self.name) and M.exists(self.path) then
    self:_fire()
  end
end

--- Ждать появления файла `path`; `on_created()` вызывается один раз, наблюдение
--- снимается само. Возвращает объект с `close()`.
function M.start(path, on_created)
  local dir, name = path:match("^(.*)/([^/]+)$")
  if dir == nil then
    dir, name = ".", path
  elseif dir == "" then
    dir = "/"
  end
  local w = setmetatable({
    path = path,
    dir = dir,
    name = name,
    on_created = on_created,
    closed = false,
  }, Watch)
  w:_arm()
  return w
end

return M
