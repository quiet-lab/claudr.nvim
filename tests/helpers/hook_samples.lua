-- Образцы хука `PermissionRequest` и записей транскрипта диалогов для тестов: обезличенные
-- копии форм, наблюдавшихся на Claude Code 2.1.325 (hook-wait-checks, perm-checks,
-- dialog-checks). Образец — файл в tests/fixtures/hook/ трёх видов:
--   inputs/<имя>.json        вход хука (stdin сценария хука)
--   outputs/<имя>.json       вывод хука (решение) одной строкой JSON
--   transcripts/<имя>.jsonl  записи транскрипта сессии или субагента
-- Метки путей подставляются при загрузке: @CWD@ — рабочий каталог проекта (`M.cwd`), @CLAUDE@ —
-- каталог данных Claude Code (аргумент `claude` или `$CLAUDE_CONFIG_DIR`). Идентификаторы
-- везде вида 00000000-0000-4000-8000-0000000000xx.
--
-- Входы (inputs):
--   permission-bash           Bash, один элемент addRules (localSettings)
--   permission-bash-empty     Bash, permission_suggestions — пустой массив
--   permission-bash-null      Bash, permission_suggestions — null
--   permission-bash-dirs      Bash, addDirectories и setMode (session)
--   permission-write          Write (file_path, content), setMode
--   permission-edit           Edit (old_string, new_string), setMode
--   permission-read           Read вне проекта, addRules (session)
--   permission-kinds          Bash с элементами всех видов, мест сохранения и неизвестными
--   permission-unknown-tool   неизвестный инструмент, лишние поля, предложений нет
--   question-single           AskUserQuestion, один вопрос с одним выбором (ключа предложений нет)
--   question-multi            AskUserQuestion, один вопрос с multiSelect (предложения — null)
--   question-two              AskUserQuestion, два вопроса: выбор и multiSelect
--   plan                      ExitPlanMode (plan, planFilePath), режим plan
--   subagent                  Bash субагента (agent_id, agent_type)
-- Выводы (outputs): allow, allow-suggestion-rule, allow-suggestion-dirs, allow-suggestion-mode,
--   answer-single, answer-multi, answer-two, answer-free-text, plan-allow, deny, deny-message,
--   deny-interrupt (последний без message: форма без пояснения не наблюдалась, см. design.md).
-- Транскрипты (transcripts): bash-pending (tool_use без результата), bash-allowed (вложение
--   allow и результат), bash-denied (вложение deny, результат с ошибкой), bash-rejected-panel
--   (отказ в панели: результат с ошибкой и запись «[Request interrupted by user for tool use]»),
--   bash-answered-panel (результат без вложения), question-answered, plan-approved,
--   parallel-reads (две tool_use в одной записи), subagent (транскрипт субагента),
--   unknown-records (неизвестные записи, блоки и вложения).
local M = {}

M.cwd = "/srv/demo/alpha"
M.session_id = "00000000-0000-4000-8000-000000000031"
M.agent_id = "a1b2c3d4e5f607182"

--- Идентификаторы вызовов транскриптов (имя → значение).
M.tool_use_ids = {
  bash = "toolu_01SampleBash00000000000001",
  ask = "toolu_01SampleAsk000000000000002",
  plan = "toolu_01SamplePlan00000000000003",
  read1 = "toolu_01SampleRead00000000000004",
  read2 = "toolu_01SampleRead00000000000005",
  sub = "toolu_01SampleSub000000000000006",
}

local source_root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/tests/helpers/[^/]*$")
M.source = source_root .. "/tests/fixtures/hook"

local function read_file(path)
  local f = assert(io.open(path, "rb"), "нет образца: " .. path)
  local data = f:read("*a")
  f:close()
  return data
end

local function plain_replace(s, from, to)
  local out, pos = {}, 1
  while true do
    local a, b = s:find(from, pos, true)
    if not a then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    out[#out + 1] = to
    pos = b + 1
  end
  return table.concat(out)
end

local function substitute(s, claude)
  claude = claude or vim.uv.os_getenv("CLAUDE_CONFIG_DIR") or "/srv/demo/claude"
  s = plain_replace(s, "@CWD@", M.cwd)
  return plain_replace(s, "@CLAUDE@", claude)
end

local function path(kind, name)
  local ext = kind == "transcripts" and ".jsonl" or ".json"
  return M.source .. "/" .. kind .. "/" .. name .. ext
end

--- Текст образца с подставленными метками.
function M.text(kind, name, claude)
  return substitute(read_file(path(kind, name)), claude)
end

--- Вход хука (таблица) по имени образца.
function M.input(name, claude)
  return vim.json.decode(M.text("inputs", name, claude))
end

--- Вывод хука (таблица) по имени образца.
function M.output(name, claude)
  return vim.json.decode(M.text("outputs", name, claude))
end

--- Записи транскрипта по имени образца (список таблиц, по порядку).
function M.records(name, claude)
  local out = {}
  for line in M.text("transcripts", name, claude):gmatch("[^\n]+") do
    out[#out + 1] = vim.json.decode(line)
  end
  return out
end

--- Имена образцов вида (`inputs`, `outputs`, `transcripts`) по алфавиту.
function M.names(kind)
  local out = {}
  for name, t in vim.fs.dir(M.source .. "/" .. kind) do
    if t == "file" then
      out[#out + 1] = (name:gsub("%.jsonl?$", ""))
    end
  end
  table.sort(out)
  return out
end

return M
