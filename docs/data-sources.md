# Источники данных

Плагин читает данные из двух источников: сокета API herdr и файлов Claude Code.
Разбор формата сокета — в модуле клиента, разбор файлов Claude Code — в одном
модуле разбора форматов. Проверено на сервере herdr сборки `duty-v0.9.5.19`
(протокол 22) и Claude Code 2.1.325.

## Сокет herdr

### Путь и идентификаторы

- Сокет API — `~/.config/herdr/herdr.sock`. Порядок выбора пути: ключ `--session`,
  переменная `HERDR_SOCKET_PATH`, переменная `HERDR_SESSION` (путь
  `~/.config/herdr/sessions/<имя>/herdr.sock`), сокет по умолчанию. Плагин
  берёт `HERDR_SOCKET_PATH`, без неё — сокет по умолчанию.
- Внутри панели herdr заданы `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`,
  `HERDR_PANE_ID`. Идентификаторы публичные: workspace `w1`, вкладка `w1:t1`,
  панель `w1:p1`.
- Схема API — `herdr api schema --json`; описание для агентов — `herdr --skill`;
  описание сокета — `docs/versions/<версия>/website/src/content/docs/socket-api.mdx`
  в исходниках форка (`~/work/pets/duty-herdr`).

### Кадры

Транспорт — Unix-сокет, один JSON-объект в строке (newline-delimited JSON).

- Запрос: `{"id":"<строка>","method":"<метод>","params":{…}}`.
- Успех: `{"id":"<тот же>","result":{"type":"<вид>",…}}`.
- Ошибка: `{"id":"<тот же>","error":{"code":"<код>","message":"<текст>"}}`;
  для строки, не разобранной как JSON, `id` пустой; ошибка транспорта (например,
  неверный UTF-8) может закрыть соединение без ответа.
- Ответ `ping`: `result.type = "pong"`, поля `version`, `protocol` (22) и
  `capabilities`.

### Подписка

`events.subscribe` с `params.subscriptions` — массивом записей `{"type":"<событие>",…}`.

- Первый ответ — `{"id":…,"result":{"type":"subscription_started"}}`, дальше
  по тому же соединению приходят строки событий; одно соединение подписки не
  годится для других запросов, снимок запрашивается другим соединением.
- Все записи подписки должны быть допустимы: запись на несуществующую панель
  отвергает весь запрос ошибкой и закрывает соединение.
- Подписки действуют с момента принятия запроса, прошлые события не
  воспроизводятся. История событий не долговечна: если читатель отстал,
  сервер присылает ошибку `events_lost` с `id` запроса и закрывает соединение.
  После этого состояние устарело: открывается новая подписка, после
  `subscription_started` запрашивается `session.snapshot` другим соединением,
  и кэш заменяется снимком.
- Снимок и события не имеют общей последовательности: события служат сигналом
  перечитать состояние, а не данными для наложения на снимок.
- Типы записей подписки без параметров (на все панели): `workspace.created`,
  `workspace.updated`, `workspace.renamed`, `workspace.moved`,
  `workspace.reordered`, `workspace.closed`, `workspace.focused`,
  `tab.created`, `tab.closed`, `tab.focused`, `tab.renamed`, `tab.moved`,
  `pane.created`, `pane.updated`, `pane.closed`, `pane.focused`, `pane.moved`,
  `pane.exited`, `pane.agent_detected`, `layout.updated`.
- Типы с параметром `pane_id` (запись на одну панель): `pane.agent_status_changed`
  (необязательный фильтр `agent_status`), `pane.output_changed`
  (необязательный `min_revision`), `pane.scroll_changed`, `pane.output_matched`.
  Подписка на панель, которой ещё нет или уже нет, отвергается, поэтому состав
  таких записей пересобирается по событиям `pane.created` и `pane.closed`.
- Строка события — `{"event":"<вид>","data":{…}}`. События, на которые
  подписываются по панели, приходят с видом через точку и данными без поля
  `type`: `{"event":"pane.output_changed","data":{"pane_id":…,"revision":…}}`
  (проверено на живом сервере), `pane.agent_status_changed` несёт `pane_id`,
  `workspace_id`, `agent_status`, `agent`, `display_agent`. События жизненного
  цикла (`workspace_*`, `tab_*`, `pane_created`, `pane_closed`, `pane_exited`,
  `layout_updated` и другие) по схеме API приходят с видом через подчёркивание
  и данными с полем `type` того же вида: `pane_exited` и `pane_closed` несут
  `pane_id` и `workspace_id`, `pane_created` — запись `pane`. Клиент принимает
  оба написания вида.
- Идентификаторы бывают не только числовыми (в номере workspace и панели бывают буквы): клиент
  обращается с ними как со строками.

### Снимок

`session.snapshot` (CLI — `herdr api snapshot`): `result.snapshot` с полями
`workspaces`, `tabs`, `panes`, `agents`, `layouts`, `focused_workspace_id`,
`focused_tab_id`, `focused_pane_id`, `version`, `protocol`.

- Workspace: `workspace_id`, `parent_workspace_id`, `label`, `number`,
  `agent_status`, `active_tab_id`.
- Вкладка: `tab_id`, `workspace_id`, `label`, `number`.
- Панель: `pane_id`, `tab_id`, `workspace_id`, `foreground_process`, `cwd`,
  `agent`, `agent_status`, `display_agent`, `terminal_title`, `revision` и
  `agent_session`.
- `agent_session`: `kind` (`id` или `path`), `source`, `agent`, `value`.
  У Claude Code `value` — идентификатор сессии.
- Состояния агента: `idle`, `working`, `blocked`, `done`, `unknown`.

### Методы

- Чтение панели: `pane.read` с `pane_id`, `source` (`visible`, `recent`,
  `recent_unwrapped`, `detection`; в CLI `recent-unwrapped`), `format` (`text`
  или `ansi`), `lines`, `strip_ansi`. Ответ несёт `text`, `revision`, `truncated`.
- Отправка: `pane.send_text` (`pane_id`, `text`), `pane.send_keys` (`pane_id`,
  `keys`), `agent.prompt` (`target`, `text`, необязательное `wait`),
  `agent.send_keys` (`target`, `keys`). `agent.prompt` для агента в состоянии
  `blocked` возвращает ошибку `agent_blocked` и ничего не отправляет.
- Создание: `tab.create` (`workspace_id`, `cwd`, `label`, `focus`, `env`),
  `pane.split` (`direction`, `target_pane_id`, `workspace_id`, `cwd`, `focus`,
  `env`), `agent.start` (`pane_id`, `name`, `kind`, `args`, `timeout_ms`):
  панель должна стоять у приглашения оболочки; ответ приходит, когда агент
  обнаружен и готов к вводу.
- Подключение к терминалу агента — команда CLI `herdr agent attach <цель>`
  (двоичный протокол, не JSON API).

## Файлы Claude Code

### Транскрипт сессии

`~/.claude/projects/<каталог проекта>/<идентификатор сессии>.jsonl`: каталог
проекта — рабочий каталог сессии с заменой разделителей на дефисы. Связь
панели с транскриптом — `agent_session.value`. Каталог проекта сессии не равен
`cwd` панели, если в сессии меняли каталог, поэтому транскрипт ищется по
идентификатору среди каталогов `~/.claude/projects/`. Файл дописывается по
мере работы сессии: строка — одна запись JSON.

### Субагенты

В каталоге `~/.claude/projects/<проект>/<сессия>/subagents/` лежат пары
`agent-<id>.jsonl` (транскрипт субагента) и `agent-<id>.meta.json`.

Поля `meta.json`: `agentType`, `description`, `toolUseId` (вызов в родительском
транскрипте), `spawnDepth`, `model`, `parentAgentId` (только у вложенных,
`spawnDepth` больше 1), `finished`.

- Вложенные субагенты лежат в том же каталоге `subagents/` сессии-владельца;
  родитель определяется полем `parentAgentId`, у субагентов первого уровня оно
  отсутствует.
- У завершённого субагента `finished` равно `true`, время записи файла совпадает
  с последней строкой транскрипта.
- У работающего субагента поля `finished` нет: проверено на `meta.json`
  работающего субагента, поля были `agentType`, `isBuiltIn`, `description`,
  `toolUseId`, `spawnDepth`, `requestShape`, `requestNonInteractive`, `model`.
  Состояние «работает» — отсутствие `finished: true` при живом владельце.
- Рядом могут лежать посторонние файлы (`*.forked-skill.json`,
  `*.forked-skill.marker.json`): они не субагенты и разбором игнорируются.
- События хуков `SubagentStart` и `SubagentStop` — запасной источник на случай,
  если формат файлов изменится.

### Фоновые команды

- Запуск: в транскрипте владельца (сессии или субагента) запись вызова
  инструмента Bash с `run_in_background: true`; в `input` — `command` и
  `description`.
- Результат вызова содержит `toolUseResult.backgroundTaskId` и путь файла
  вывода `/tmp/claude-<uid>/<проект>/<сессия>/tasks/<id>.output`; файл
  дописывается по мере работы команды.
- Завершение: запись `queue-operation` с `operation: enqueue`, следом запись
  `user` с блоком `<task-notification>`: `task-id`, `tool-use-id`,
  `output-file`, `status`, в `summary` — код выхода.
- Записи при ошибке, остановке и для команды, пережившей сессию, а также
  задачи `Monitor` и workflow не проверены: [`open-questions/background-task-records.md`](open-questions/background-task-records.md).

### Оборванные узлы

Если владелец упал, отметки завершения у субагентов и фоновых команд нет.
Состояние «оборван» выводится из отсутствия отметки при событии herdr
`pane.exited` или `pane.closed` панели владельца; правило общее для субагентов
и фоновых команд.
