-- Разрешение относительного пути в каждом виде буфера плагина с содержимым Claude Code
-- (спецификация file-references, «Разрешение пути и существование файла»).
local t = require("helpers.t")
local s = require("view.support")
local rs = require("refs.support")
local u = require("data.util")
local refs = require("claudr.refs")
local view = require("claudr.view")
local model = require("claudr.tree.model")
local data = require("claudr.data")
local fixtures = s.fixtures
local double = s.double

local project

before_each(function()
  rs.reset()
  project = rs.project()
end)

after_each(function()
  refs.close_preview()
  s.reset()
end)

-- Окружение с панелью `w1:p1` сессии образца `sample` и рабочим каталогом проекта; панель
-- `w1:p2` с командой в том же каталоге.
local function env(sample)
  s.big_editor()
  local d = s.env(
    s.snapshot({
      s.claude_pane("w1:p1", sample, { cwd = project.dir }),
      double.pane({ pane_id = "w1:p2", foreground_process = "bash", cwd = project.dir }),
    }),
    { sample }
  )
  s.wait_node("w1:p1")
  s.wait_node("w1:p2")
  return d
end

local function find_node(kind, pred)
  local found
  t.wait(function()
    found = model.find(function(n)
      return n.kind == kind and (pred == nil or pred(n))
    end)[1]
    return found ~= nil
  end, "узел " .. kind)
  return found
end

-- Ссылка под курсором на слове `needle` в буфере вида `v`: курсор ставится в окне вида.
local function link_in_view(v, needle)
  vim.api.nvim_set_current_win(v.win)
  rs.cursor_on(needle)
  return refs.link_at_cursor()
end

describe(
  "Разрешение относительного пути по видам буферов",
  function()
    it("вид наблюдения за панелью: каталог панели", function()
      local d = env("owner-dialogue")
      local v = s.track(view.open(model.get("w1:p1")))
      t.eq(v.kind, "observe")
      -- кадры двойника: экран панели со ссылкой
      d:frame("w1:p1", "\27[2J\27[1;1Hошибка в lua/foo.lua:5:3", { full = true })
      s.wait_text(v.buf, "foo.lua", "экран панели")
      t.eq(link_in_view(v, "foo"), { path = project.foo, line = 5, col = 3 })
    end)

    it(
      "терминальный буфер подключения с вводом: каталог панели",
      function()
        local d = env("owner-dialogue")
        local pane = model.get("w1:p2")
        d:set_attach_screen(pane.data.terminal_id, "make: lua/foo.lua:7")
        local v = s.track(view.attach(pane))
        s.wait_text(v.buf, "foo.lua", "экран панели")
        vim.cmd("stopinsert")
        t.eq(link_in_view(v, "foo"), { path = project.foo, line = 7 })
      end
    )

    it(
      "транскрипт субагента: каталог панели-владельца",
      function()
        env("owner-killed")
        local node = find_node("subagent", function(n)
          return n.state == "running"
        end)
        local v = view.open(node)
        fixtures.append(v.path, {
          fixtures.assistant_record(
            fixtures.session_id("owner-killed"),
            "правка в lua/foo.lua:9"
          ),
        })
        s.wait_text(v.buf, "правка в", "дописанная реплика")
        t.eq(link_in_view(v, "foo"), { path = project.foo, line = 9 })
      end
    )

    it(
      "вывод фоновой команды: каталог панели-владельца",
      function()
        env("command-orphaned")
        local node = find_node("task", function(n)
          return n.state == "running"
        end)
        local v = view.open(node)
        local f = assert(io.open(node.data.output_file, "a"))
        f:write("lua/foo.lua:11: ошибка\n")
        f:close()
        s.wait_text(v.buf, "ошибка", "вывод команды")
        t.eq(link_in_view(v, "foo"), { path = project.foo, line = 11 })
      end
    )

    it(
      "диалог из истории: рабочий каталог сессии из транскрипта",
      function()
        local dir = u.fresh()
        local id = "00000000-0000-4000-8000-0000000000a1"
        local user = fixtures.user_record(id, "что в lua/foo.lua:4")
        user.cwd = project.dir
        local path = dir .. "/projects/-demo/" .. id .. ".jsonl"
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        fixtures.append(
          path,
          { user, fixtures.assistant_record(id, "смотрите lua/foo.lua:4") }
        )
        t.eq(u.session_cwd(path), project.dir)
        local buf = require("claudr.history").open_dialogue({ id = id, path = path })
        t.ok(buf and refs.is_attached(buf))
        t.wait(function()
          return vim.b[buf].claudr_loaded == true
        end, "конец чтения диалога")
        rs.cursor_on("foo")
        t.eq(refs.link_at_cursor(), { path = project.foo, line = 4 })
        rs.press("gd")
        t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), project.foo)
        t.ok(vim.api.nvim_buf_is_valid(buf), "диалог остался")
      end
    )

    it(
      "окно темы вопросов по коду: каталог проекта темы",
      function()
        local window = require("claudr.questions.window")
        local topic = {
          id = "00000000-0000-4000-8000-0000000000b1",
          record = { title = "Тема", project_dir = project.dir },
          entries = {
            {
              question = "Где ошибка?",
              answer = "Ссылка: lua/foo.lua:42:7.",
              status = "done",
            },
          },
        }
        local buf = window.ensure_buffer(topic, { ask = function() end, retry = function() end })
        local win = window.show(topic, { focus = true })
        t.ok(refs.is_attached(buf))
        vim.api.nvim_set_current_win(win)
        rs.cursor_on("foo")
        t.eq(refs.link_at_cursor(), { path = project.foo, line = 42, col = 7 })
        window.show(topic, { focus = false })
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    )

    it(
      "рабочий каталог читается при нажатии, а не при подключении",
      function()
        local cwd = project.dir .. "/lua"
        local buf = rs.plugin_buffer({ "foo.lua:2" }, nil)
        refs.attach(buf, {
          cwd = function()
            return cwd
          end,
        })
        rs.cursor_on("foo")
        t.eq(refs.link_at_cursor(), { path = project.foo, line = 2 })
      end
    )
  end
)
