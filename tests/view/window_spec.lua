-- Вид узла — обычный буфер в окне, из которого открыто дерево (спецификация node-view,
-- решения D50–D57) и открытие файла по ссылке в том же окне (спецификация file-references).
local t = require("helpers.t")
local s = require("view.support")
local view = require("claudr.view")
local model = require("claudr.tree.model")
local refs = require("claudr.refs")
local tree_view = require("claudr.tree.view")
local double = s.double

local project

after_each(function()
  refs.close_preview()
  s.reset()
end)

local function env()
  s.big_editor()
  local d = s.env(
    s.snapshot({
      s.claude_pane("w1:p1", "owner-dialogue"),
      double.pane({ pane_id = "w1:p2", foreground_process = "htop" }),
    }),
    { "owner-dialogue" }
  )
  s.wait_node("w1:p1")
  s.wait_node("w1:p2")
  view.setup()
  project = require("refs.support").project()
  return d
end

-- Окно A с файлом, дерево слева (открыто из A), курсор на узле `id` в дереве.
local function open_tree(id)
  vim.cmd("silent! only")
  vim.cmd("edit " .. vim.fn.fnameescape(project.short))
  local win_a = vim.api.nvim_get_current_win()
  local tree_win = tree_view.open()
  t.ok(tree_view.focus(id), "узел показан в дереве")
  return win_a, tree_win
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function floats()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      out[#out + 1] = win
    end
  end
  return out
end

describe(
  "Вид — буфер в окне, из которого открыто дерево",
  function()
    it(
      "Вид по Enter в окне, из которого открыто дерево",
      function()
        env()
        local win_a, tree_win = open_tree("w1:p2")
        local tree_buf = vim.api.nvim_win_get_buf(tree_win)
        local width = vim.api.nvim_win_get_width(tree_win)
        press("<CR>")
        local v = s.track(view.views()[1])
        t.ok(v, "вид открыт")
        t.eq(v.kind, "observe")
        t.eq(vim.api.nvim_get_current_win(), win_a, "курсор в окне A")
        t.eq(vim.api.nvim_win_get_buf(win_a), v.buf, "вид — буфер окна A")
        t.eq(vim.bo[v.buf].buftype, "terminal")
        t.eq(vim.api.nvim_win_get_buf(tree_win), tree_buf, "дерево на месте")
        t.eq(
          vim.api.nvim_win_get_width(tree_win),
          width,
          "ширина дерева прежняя"
        )
        t.eq(floats(), {}, "плавающих окон нет")
      end
    )

    it(
      "вид открывается в окне источника, а не в соседнем",
      function()
        env()
        vim.cmd("silent! only")
        vim.cmd("edit " .. vim.fn.fnameescape(project.short))
        vim.cmd("vsplit " .. vim.fn.fnameescape(project.foo))
        local win_b = vim.api.nvim_get_current_win()
        vim.cmd("wincmd p")
        local win_a = vim.api.nvim_get_current_win()
        t.ok(win_a ~= win_b)
        tree_view.open()
        -- пользователь ушёл в окно B и снова вызвал дерево оттуда
        vim.api.nvim_set_current_win(win_b)
        tree_view.open()
        t.ok(tree_view.focus("w1:p2"))
        press("<CR>")
        local v = s.track(view.views()[1])
        -- дерево открыто повторно из окна B: источник — B
        t.eq(
          vim.api.nvim_win_get_buf(win_b),
          v.buf,
          "вид в окне, откуда открыто дерево"
        )
        t.eq(
          vim.fn.bufname(vim.api.nvim_win_get_buf(win_a)),
          project.short,
          "окно A не тронуто"
        )
      end
    )

    it(
      "Окна, из которого открыто дерево, больше нет",
      function()
        env()
        local win_a = open_tree("w1:p2")
        vim.cmd("vsplit " .. vim.fn.fnameescape(project.foo))
        local win_b = vim.api.nvim_get_current_win()
        t.ok(win_b ~= win_a)
        vim.api.nvim_win_close(win_a, true)
        local tree_win = vim.fn.bufwinid(tree_view.buf())
        vim.api.nvim_set_current_win(tree_win)
        t.ok(tree_view.focus("w1:p2"))
        press("<CR>")
        local v = s.track(view.views()[1])
        t.eq(
          vim.api.nvim_win_get_buf(win_b),
          v.buf,
          "вид в оставшемся обычном окне"
        )
        t.eq(floats(), {})
      end
    )

    it("Других окон нет", function()
      env()
      vim.cmd("silent! only")
      local tree_win = tree_view.open()
      -- единственное окно вкладки — дерево
      vim.cmd("silent! only")
      t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
      t.ok(tree_view.focus("w1:p2"))
      press("<CR>")
      local v = s.track(view.views()[1])
      t.ok(v, "вид открыт")
      t.eq(#vim.api.nvim_tabpage_list_wins(0), 2, "открыто новое окно")
      t.ok(vim.api.nvim_win_get_buf(tree_win) == tree_view.buf(), "дерево на месте")
      t.eq(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()), v.buf)
      t.eq(floats(), {})
    end)

    it("остальные виды открываются в том же окне", function()
      local d = env()
      d:set_output("w1:p2", { lines = { "history line" } })
      local win_a = open_tree("w1:p2")
      press("S")
      local sv = view.views()[1]
      t.eq(sv.kind, "scrollback")
      t.eq(vim.api.nvim_win_get_buf(win_a), sv.buf, "история в окне A")
      s.wait_text(sv.buf, "history line", "история")
      -- подключение с вводом из вида истории тоже в этом окне
      press("i")
      local av
      for _, x in ipairs(view.views()) do
        if x.kind == "attach" then
          av = s.track(x)
        end
      end
      t.ok(av, "подключение с вводом открыто")
      t.eq(vim.api.nvim_win_get_buf(win_a), av.buf, "ввод в окне A")
      t.eq(floats(), {}, "плавающих окон нет")
      vim.cmd("stopinsert")
    end)

    it(
      "Enter на вкладке — наблюдение за агентом вкладки одним буфером",
      function()
        env()
        local win_a = open_tree("w1:t1")
        local wins = #vim.api.nvim_tabpage_list_wins(0)
        press("<CR>")
        local ov = s.track(view.views()[1])
        t.eq(#view.views(), 1, "один вид")
        t.eq(ov.kind, "observe")
        t.eq(ov.node_id, "w1:p1", "агент вкладки")
        t.eq(vim.api.nvim_win_get_buf(win_a), ov.buf)
        t.eq(
          #vim.api.nvim_tabpage_list_wins(0),
          wins,
          "раскладка окон не меняется"
        )
        t.eq(floats(), {})
      end
    )
  end
)

describe("Закрытие вида оставляет окно", function()
  it("Закрытие клавишей", function()
    env()
    local win_a, tree_win = open_tree("w1:p2")
    press("<CR>")
    local v = s.track(view.views()[1])
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    press("q")
    s.wait_exit(v)
    t.ok(not vim.api.nvim_buf_is_valid(v.buf), "буфер вида удалён")
    t.eq(#vim.api.nvim_tabpage_list_wins(0), wins, "число окон прежнее")
    t.ok(vim.api.nvim_win_is_valid(win_a), "окно A на месте")
    t.eq(
      vim.fn.bufname(vim.api.nvim_win_get_buf(win_a)),
      project.short,
      "прежний файл в окне"
    )
    t.ok(vim.api.nvim_win_is_valid(tree_win), "дерево на месте")
  end)

  it("Единственное окно", function()
    env()
    vim.cmd("silent! only")
    vim.cmd("enew")
    local v = s.track(view.open(model.get("w1:p2")))
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    press("q")
    s.wait_exit(v)
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 1, "окно осталось")
    t.eq(
      vim.bo[vim.api.nvim_get_current_buf()].buftype,
      "",
      "обычный пустой буфер"
    )
  end)

  it("Закрытие окна", function()
    env()
    vim.cmd("silent! only")
    vim.cmd("enew")
    local v = s.track(view.open(model.get("w1:p2")))
    vim.cmd("botright new")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(v.win, true)
    t.ok(vim.api.nvim_win_is_valid(win))
    s.wait_exit(v, "процесс наблюдения завершён")
    t.ok(not vim.api.nvim_buf_is_valid(v.buf), "буфер вида удалён")
  end)

  it(
    "перекрытие окна вида другим файлом вид не закрывает",
    function()
      env()
      vim.cmd("silent! only")
      vim.cmd("enew")
      local v = s.track(view.open(model.get("w1:p2")))
      vim.cmd("edit " .. vim.fn.fnameescape(project.short))
      t.ok(vim.api.nvim_buf_is_valid(v.buf), "буфер вида жив")
      t.ok(s.alive(v.pid), "наблюдение продолжается")
      vim.cmd("normal! \15")
      t.eq(vim.api.nvim_get_current_buf(), v.buf, "<C-o> вернул в вид")
    end
  )
end)

describe("Ссылка на файл в виде", function()
  it(
    "gd открывает файл в том же окне, <C-o> возвращает в вид",
    function()
      local v, win_a
      do
        local d = env()
        win_a = open_tree("w1:p2")
        press("<CR>")
        v = s.track(view.views()[1])
        d:frame("w1:p2", "\27[2J\27[1;1Hsee " .. project.foo .. ":12:3 done", { full = true })
        s.wait_text(v.buf, "done", "кадр")
      end
      local wins = #vim.api.nvim_tabpage_list_wins(0)
      vim.fn.search("foo.lua")
      press("gd")
      t.eq(vim.api.nvim_get_current_win(), win_a, "то же окно")
      t.eq(vim.api.nvim_buf_get_name(0), project.foo)
      t.eq(vim.api.nvim_win_get_cursor(0), { 12, 2 })
      t.eq(#vim.api.nvim_tabpage_list_wins(0), wins, "новых окон нет")
      t.ok(vim.api.nvim_buf_is_valid(v.buf), "вид жив")
      t.ok(s.alive(v.pid), "наблюдение продолжается")
      press("<C-o>")
      t.eq(vim.api.nvim_get_current_buf(), v.buf, "<C-o> вернул в вид")
    end
  )

  it(
    "Shift+K показывает предпросмотр на пути после неразрывного пробела",
    function()
      local v
      do
        local d = env()
        open_tree("w1:p2")
        press("<CR>")
        v = s.track(view.views()[1])
        d:frame("w1:p2", "\27[2J\27[1;1H  ⎿ \u{a0}" .. project.foo .. ":30 done", { full = true })
        s.wait_text(v.buf, "done", "кадр")
      end
      vim.fn.search("foo.lua")
      press("K")
      t.ok(refs.preview_win(), "предпросмотр открыт")
      t.eq(vim.api.nvim_get_current_buf(), v.buf, "фокус остался в виде")
    end
  )
end)

-- Enter на узле `id` в дереве, открытом из текущего окна (без смены буфера окна).
local function enter(id)
  tree_view.open()
  t.ok(tree_view.focus(id), "узел показан в дереве")
  press("<CR>")
  return view.views()
end

local function find_view(kind, node_id)
  for _, v in ipairs(view.views()) do
    if v.kind == kind and v.node_id == node_id then
      return v
    end
  end
  return nil
end

describe("Замена вида в окне", function()
  it(
    "Enter на другом узле закрывает прежний вид окна",
    function()
      env()
      local win_a = open_tree("w1:p2")
      press("<CR>")
      local v1 = s.track(find_view("observe", "w1:p2"))
      t.ok(s.alive(v1.pid))
      enter("w1:p1")
      local v2 = s.track(find_view("observe", "w1:p1"))
      s.wait_exit(v1, "прежнее наблюдение завершено")
      t.ok(
        not vim.api.nvim_buf_is_valid(v1.buf),
        "буфер прежнего вида удалён"
      )
      t.eq(vim.api.nvim_win_get_buf(win_a), v2.buf, "новый вид в том же окне")
      enter("w1:p2")
      local v3 = s.track(find_view("observe", "w1:p2"))
      s.wait_exit(v2, "наблюдение второго вида завершено")
      t.eq(#view.views(), 1, "один вид")
      t.ok(s.alive(v3.pid), "жив один процесс наблюдения")
    end
  )

  it("Повторный Enter на узле с открытым видом", function()
    env()
    local win_a = open_tree("w1:p1")
    press("<CR>")
    local v = s.track(find_view("observe", "w1:p1"))
    -- вкладка ведёт к той же панели агента: вид тот же
    enter("w1:t1")
    enter("w1:p1")
    -- процесс наблюдения есть только у вида: один вид — один процесс
    t.eq(#view.views(), 1, "второго вида и второго процесса нет")
    t.ok(s.alive(v.pid))
    t.eq(vim.api.nvim_win_get_buf(win_a), v.buf)
  end)

  it(
    "Открытый вид, ушедший из окна, показывается снова",
    function()
      env()
      local win_a = open_tree("w1:p2")
      press("<CR>")
      local v = s.track(find_view("observe", "w1:p2"))
      -- файл в окне A: вид скрыт, но жив
      vim.cmd("edit " .. vim.fn.fnameescape(project.short))
      t.ok(s.alive(v.pid), "скрытый вид жив")
      enter("w1:p2")
      t.eq(vim.api.nvim_win_get_buf(win_a), v.buf, "тот же вид в окне A")
      t.eq(#view.views(), 1)
    end
  )

  it("Подключение с вводом не закрывается заменой", function()
    env()
    local win_a = open_tree("w1:p2")
    press("i")
    local av = s.track(find_view("attach", "w1:p2"))
    t.ok(av, "подключение с вводом открыто")
    vim.cmd("stopinsert")
    enter("w1:p1")
    local ov = s.track(find_view("observe", "w1:p1"))
    t.eq(vim.api.nvim_win_get_buf(win_a), ov.buf)
    t.ok(vim.api.nvim_buf_is_valid(av.buf), "буфер подключения жив")
    t.ok(s.alive(av.pid), "подключение не оборвано")
  end)
end)
