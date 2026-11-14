-- Мини-оснастка тестов: describe/it/before_each/after_each и проверки.
-- Тесты выполняются последовательно в одном процессе Neovim; ожидания — только до событий.
local M = {}

M.root = nil -- корень репозитория, задаёт bootstrap
M._tmpdir = nil -- каталог теста, задаёт bootstrap

local root_suite = { name = "", tests = {}, children = {}, before = {}, after = {} }
local current = root_suite

local function describe(name, fn)
  local suite =
    { name = name, tests = {}, children = {}, before = {}, after = {}, parent = current }
  table.insert(current.children, suite)
  local prev = current
  current = suite
  local ok, err = pcall(fn)
  current = prev
  if not ok then
    error(err, 0)
  end
end

local function it(name, fn)
  table.insert(current.tests, { name = name, fn = fn })
end

local function before_each(fn)
  table.insert(current.before, fn)
end

local function after_each(fn)
  table.insert(current.after, fn)
end

--- Делает `describe`, `it`, `before_each`, `after_each` глобальными.
function M.install_globals()
  _G.describe = describe
  _G.it = it
  _G.before_each = before_each
  _G.after_each = after_each
end

function M.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(
      string.format(
        "%sожидалось:\n%s\nполучено:\n%s",
        msg and (msg .. "\n") or "",
        vim.inspect(b),
        vim.inspect(a)
      ),
      2
    )
  end
end

function M.ok(v, msg)
  if not v then
    error(msg or "ожидалось истинное значение", 2)
  end
end

function M.match(str, pattern, msg)
  if type(str) ~= "string" or not str:find(pattern) then
    error(
      string.format(
        "%sстрока %s не соответствует шаблону %s",
        msg and (msg .. ": ") or "",
        vim.inspect(str),
        pattern
      ),
      2
    )
  end
end

--- Ждёт события цикла Neovim, пока `cond()` не станет истинным. Срока нет: предел —
--- внешний предел прогона (`CLAUDR_TEST_LIMIT`). Длительность ожидания пишется в журнал.
function M.wait(cond, msg)
  local start = vim.uv.hrtime()
  vim.wait(2 ^ 31 - 1, cond)
  local ms = (vim.uv.hrtime() - start) / 1e6
  print(string.format("  ожидание %.1f мс%s", ms, msg and (": " .. msg) or ""))
  if not cond() then
    error(
      "ожидание прервано без выполнения условия"
        .. (msg and (": " .. msg) or ""),
      2
    )
  end
end

function M.tmpdir()
  return M._tmpdir
end

local function full_name(suite, name)
  local parts = { name }
  while suite and suite.name ~= "" do
    table.insert(parts, 1, suite.name)
    suite = suite.parent
  end
  return table.concat(parts, " ")
end

local function run_hooks(list)
  for _, fn in ipairs(list) do
    fn()
  end
end

local function hooks_chain(suite, key)
  local chain = {}
  while suite do
    table.insert(chain, suite[key])
    suite = suite.parent
  end
  return chain
end

local function run_test(suite, test)
  local befores = hooks_chain(suite, "before")
  for i = #befores, 1, -1 do
    run_hooks(befores[i])
  end
  local ok, err = xpcall(test.fn, debug.traceback)
  local after_err
  for _, list in ipairs(hooks_chain(suite, "after")) do
    local aok, aerr = pcall(run_hooks, list)
    if not aok then
      after_err = after_err or aerr
    end
  end
  if ok and after_err then
    ok, err = false, after_err
  end
  return ok, err
end

--- Выполняет собранные тесты, печатает итог; возвращает число прошедших и упавших.
function M.run_all()
  local passed, failed = 0, 0
  local function walk(suite)
    for _, test in ipairs(suite.tests) do
      local name = full_name(suite, test.name)
      local ok, err = run_test(suite, test)
      if ok then
        passed = passed + 1
        print("ok   " .. name)
      else
        failed = failed + 1
        print("FAIL " .. name)
        print("     " .. tostring(err):gsub("\n", "\n     "))
      end
    end
    for _, child in ipairs(suite.children) do
      walk(child)
    end
  end
  walk(root_suite)
  print(string.format("ИТОГ прошло=%d упало=%d", passed, failed))
  return passed, failed
end

return M
