local t = require("helpers.t")

--- Запускает дочерний nvim на временном файле теста; возвращает результат процесса.
local function run_spec(source)
  local path = t.tmpdir() .. "/child_spec.lua"
  vim.fn.writefile(vim.split(source, "\n"), path)
  local res = vim
    .system({
      "nvim",
      "--headless",
      "--clean",
      "-u",
      "NONE",
      "-l",
      t.root .. "/tests/bootstrap.lua",
      path,
    }, {
      text = true,
      env = { HERDR_PANE_ID = "p_leak", HERDR_SOCKET_PATH = "/nonexistent" },
    })
    :wait()
  return res
end

describe("оснастка запуска тестов", function()
  it("проходящий тест даёт код 0", function()
    local res = run_spec([[ it("ok", function() end) ]])
    t.eq(res.code, 0, res.stdout .. res.stderr)
    t.match(res.stdout .. res.stderr, "прошло=1 упало=0")
  end)

  it("падающий тест даёт ненулевой код", function()
    local res = run_spec([[
      it("good", function() end)
      it("bad", function() error("сломано") end)
    ]])
    t.ok(res.code ~= 0)
    local out = res.stdout .. res.stderr
    t.match(out, "FAIL bad")
    t.match(out, "прошло=1 упало=1")
  end)

  it(
    "ошибка загрузки файла теста даёт ненулевой код",
    function()
      local res = run_spec([[ this is not lua ]])
      t.ok(res.code ~= 0)
    end
  )

  it("порядок хуков before_each и after_each", function()
    local res = run_spec([[
      local log = {}
      describe("a", function()
        before_each(function() log[#log + 1] = "b1" end)
        after_each(function() log[#log + 1] = "a1" end)
        describe("b", function()
          before_each(function() log[#log + 1] = "b2" end)
          it("x", function()
            log[#log + 1] = "x"
            assert(table.concat(log, ",") == "b1,b2,x")
          end)
        end)
      end)
    ]])
    t.eq(res.code, 0, res.stdout .. res.stderr)
  end)

  it(
    "окружение изолировано: XDG, CLAUDE_CONFIG_DIR, без HERDR_*, fake_bin первым в PATH",
    function()
      local res = run_spec([[
      local t = require("helpers.t")
      it("env", function()
        local dir = t.tmpdir()
        for _, name in ipairs({ "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "CLAUDE_CONFIG_DIR" }) do
          assert(vim.startswith(vim.env[name], dir), name)
        end
        for _, name in ipairs({ "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_SESSION", "HERDR_ENV" }) do
          assert(vim.env[name] == nil, name)
        end
        assert(vim.startswith(vim.env.PATH, t.root .. "/tests/helpers/fake_bin:"))
        assert(vim.fn.isdirectory(vim.env.CLAUDE_CONFIG_DIR) == 1)
      end)
    ]])
      t.eq(res.code, 0, res.stdout .. res.stderr)
    end
  )

  it(
    "временный каталог теста удаляется после прогона",
    function()
      local res = run_spec([[
      local t = require("helpers.t")
      it("path", function() print("TMP=" .. t.tmpdir()) end)
    ]])
      local dir = (res.stdout .. res.stderr):match("TMP=(%S+)")
      t.ok(dir, "каталог не напечатан")
      t.eq(vim.fn.isdirectory(dir), 0)
    end
  )

  it("t.eq сравнивает глубоко и показывает различие", function()
    t.eq({ a = { 1, 2, { b = true } } }, { a = { 1, 2, { b = true } } })
    local ok, err = pcall(t.eq, { a = 1 }, { a = 2 }, "метка")
    t.ok(not ok)
    t.match(err, "метка")
    t.match(err, "ожидалось")
    t.match(err, "получено")
  end)

  it("t.wait дожидается события цикла Neovim", function()
    local done = false
    vim.schedule(function()
      done = true
    end)
    t.wait(function()
      return done
    end, "schedule")
    t.ok(done)
  end)

  it("t.wait дожидается выхода процесса", function()
    local exited = false
    vim.system({ "true" }, {}, function()
      exited = true
    end)
    t.wait(function()
      return exited
    end)
  end)

  it(
    "run.sh возвращает ненулевой код при падении и 0 при успехе",
    function()
      local dir = t.tmpdir() .. "/specs"
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ 'it("ok", function() end)' }, dir .. "/a_spec.lua")
      local good = vim.system({ t.root .. "/tests/run.sh", dir }, { text = true }):wait()
      t.eq(good.code, 0, good.stdout .. good.stderr)
      vim.fn.writefile({ 'it("bad", function() error("x") end)' }, dir .. "/b_spec.lua")
      local bad = vim.system({ t.root .. "/tests/run.sh", dir }, { text = true }):wait()
      t.ok(bad.code ~= 0)
      t.match(bad.stdout, "FAIL")
    end
  )
end)
