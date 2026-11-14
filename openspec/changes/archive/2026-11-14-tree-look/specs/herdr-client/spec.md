## MODIFIED Requirements

### Requirement: Состав снимка
Клиент MUST читать `session.snapshot` и использовать из него workspace (`workspace_id`, `parent_workspace_id`, `label`, `number`, `agent_status`, `active_tab_id`, `tokens`), вкладки (`tab_id`, `workspace_id`, `label`, `number`, `agent_status`) и панели (`pane_id`, `tab_id`, `workspace_id`, `foreground_process`, `cwd`, `agent`, `display_agent`, `agent_status`, `terminal_title`, `revision`, `agent_session`). Состояния агента: `unknown`, `idle`, `working`, `blocked`, `done`.

#### Scenario: Сессия агента
- **WHEN** у панели `agent_session` содержит `kind`, `agent` и `value`
- **THEN** клиент отдаёт `value` как идентификатор сессии Claude Code для панели с `agent = "claude"`

#### Scenario: Неизвестное состояние
- **WHEN** сервер присылает состояние агента, которого клиент не знает
- **THEN** клиент передаёт его как есть, ошибки нет

#### Scenario: Токены workspace
- **WHEN** у workspace в снимке `tokens = {"symbol": "S1", "color": "#336699"}`
- **THEN** клиент отдаёт токены как таблицу строк, а при отсутствии поля — пустую таблицу

#### Scenario: Состояние вкладки
- **WHEN** у вкладки в снимке `agent_status = "working"`
- **THEN** клиент отдаёт его вместе с остальными полями вкладки

## ADDED Requirements

### Requirement: Значки состояний из конфигурации herdr
Клиент MUST читать из файла конфигурации herdr (`HERDR_CONFIG_PATH`, без неё — `config.toml` в каталоге конфигурации herdr) таблицу `ui.status_icons`: значки `idle`, `working`, `blocked`, `done`, `unknown` (строка или массив кадров) и `frame_interval_ms` (число или таблица по состояниям; по умолчанию 400, значение вне 50…5000 заменяется на 400). Остальные ключи MUST игнорироваться, как и вся конфигурация вне этой таблицы и `ui.status_indicators`.

#### Scenario: Кадры и период
- **WHEN** в конфигурации `working = ["a", "b"]`, `idle = "c"` и `frame_interval_ms = { working = 80 }`
- **THEN** клиент отдаёт для `working` кадры `a`, `b` с периодом 80 мс, для `idle` — один кадр `c` с периодом 400 мс

#### Scenario: Период вне диапазона
- **WHEN** `frame_interval_ms = 10`
- **THEN** период всех состояний 400 мс

#### Scenario: Посторонние ключи
- **WHEN** в таблице есть `frame_phase = "per_row"` и `frame_speed_spread`
- **THEN** клиент их игнорирует, ошибки нет

### Requirement: Встроенные значки herdr
Состояние без значка в `ui.status_icons` MUST получать встроенный значок herdr по `ui.status_indicators`: при `dots` (по умолчанию) `idle` — `○`, `unknown` — `·`, остальные — `●`; при `symbols` `idle` — `○`, `working` — `◐`, `blocked` — `×`, `done` — `✓`, `unknown` — `·`. Нет файла или он не разбирается — все значки встроенные, ошибка не показывается.

#### Scenario: Конфигурации нет
- **WHEN** файла конфигурации herdr нет
- **THEN** значки состояний — встроенные точки: `working` — `●`, `idle` — `○`, `unknown` — `·`

#### Scenario: Часть значков задана
- **WHEN** `status_indicators = "symbols"`, а в `ui.status_icons` задан только `working`
- **THEN** `working` — заданный значок, `blocked` — `×`

#### Scenario: Файл не разбирается
- **WHEN** файл конфигурации содержит синтаксис, который клиент не разбирает
- **THEN** используются встроенные значки, плагин работает

### Requirement: Обновление значков при смене конфигурации
Клиент MUST перечитывать конфигурацию herdr по уведомлению файловой системы (`vim.uv.new_fs_event` на каталоге файла, с учётом замены файла переименованием) и MUST уведомлять подписчиков, если значки изменились. Расписаний и опроса быть MUST NOT.

#### Scenario: Правка значков
- **WHEN** файл конфигурации переписан с другим значком `idle`
- **THEN** подписчики получают уведомление, дерево показывает новый значок без перезапуска Neovim

#### Scenario: Файл заменён переименованием
- **WHEN** редактор записывает конфигурацию во временный файл и переименовывает его
- **THEN** значки перечитываются

#### Scenario: Изменений нет
- **WHEN** конфигурация не менялась
- **THEN** файл не читается повторно
