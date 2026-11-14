-- Реестр тем: запись двумя независимыми экземплярами Neovim (спецификация code-questions,
-- «Реестр тем»).
local t = require("helpers.t")
local env = require("questions.env")
local registry = require("claudr.questions.registry")

before_each(function()
  env.reset()
end)

--- Запускает отдельный процесс, который создаёт в реестре тему `session_id`.
local function spawn_writer(session_id, project_dir)
  local script = vim.fs.joinpath(t.tmpdir(), "write_" .. session_id .. ".lua")
  vim.fn.writefile({
    ("vim.opt.rtp:prepend(%q)"):format(t.root),
    ("package.path = %q .. '/lua/?.lua;' .. %q .. '/lua/?/init.lua;' .. package.path"):format(
      t.root,
      t.root
    ),
    "local registry = require('claudr.questions.registry')",
    ("registry.create({ session_id = %q, project_dir = %q, title = 'тема', mode = 'code' })"):format(
      session_id,
      project_dir
    ),
  }, script)
  local done, res = false, nil
  vim.system(
    { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", script },
    { text = true },
    function(r)
      res = r
      done = true
    end
  )
  return function()
    t.wait(function()
      return done
    end, "писатель реестра завершился")
    t.eq(res.code, 0, res.stderr)
  end
end

describe("Реестр тем", function()
  it(
    "Два экземпляра Neovim пишут разные темы: в файле обе",
    function()
      local a = "00000000-0000-4000-8000-0000000000a1"
      local b = "00000000-0000-4000-8000-0000000000b2"
      local c = "00000000-0000-4000-8000-0000000000c3"
      -- третья запись сделана этим процессом до писателей: перечитывание её не теряет
      registry.create({ session_id = c, project_dir = "/p", title = "своя", mode = "code" })
      local wait_a = spawn_writer(a, "/p")
      local wait_b = spawn_writer(b, "/p")
      wait_a()
      wait_b()
      -- запись этого процесса после чужих: перечитывание перед записью сохраняет чужие
      registry.touch(c)
      t.ok(registry.is_topic(a), "тема первого экземпляра")
      t.ok(registry.is_topic(b), "тема второго экземпляра")
      t.ok(registry.is_topic(c), "своя тема")
    end
  )

  it("Запись не оставляет временных файлов", function()
    registry.create({
      session_id = "00000000-0000-4000-8000-0000000000d4",
      project_dir = "/p",
      title = "тема",
      mode = "code",
    })
    registry.touch("00000000-0000-4000-8000-0000000000d4")
    local dir = vim.fs.dirname(registry.path())
    local names = {}
    for name in vim.fs.dir(dir) do
      names[#names + 1] = name
    end
    t.eq(names, { "topics.json" })
  end)
end)
