## MODIFIED Requirements

### Requirement: Значки состояний из конфигурации herdr
Клиент MUST читать из файла конфигурации herdr (`HERDR_CONFIG_PATH`, без неё — `config.toml` в каталоге конфигурации herdr) таблицу `ui.status_icons`: значки `idle`, `working`, `blocked`, `done`, `unknown` (строка или массив кадров), `frame_interval_ms` (число или таблица по состояниям; по умолчанию 400, вне 50…5000 — 400), `frame_phase` (`per_row` или `synced`, по умолчанию `synced`) и `frame_speed_spread` (число или таблица по состояниям, 0…0.5, иначе 0). Остальное MUST игнорироваться.

#### Scenario: Кадры и период
- **WHEN** в конфигурации `working = ["a", "b"]`, `idle = "c"` и `frame_interval_ms = { working = 80 }`
- **THEN** клиент отдаёт для `working` кадры `a`, `b` с периодом 80 мс, для `idle` — один кадр `c` с периодом 400 мс

#### Scenario: Период вне диапазона
- **WHEN** `frame_interval_ms = 10`
- **THEN** период всех состояний 400 мс

#### Scenario: Посторонние ключи
- **WHEN** в таблице есть ключ, которого клиент не читает (например, `frame_style = "x"`)
- **THEN** клиент его игнорирует, ошибки нет

#### Scenario: Фаза и разброс
- **WHEN** в таблице `frame_phase = "per_row"` и `frame_speed_spread = { working = 0.10 }`
- **THEN** клиент отдаёт для всех состояний признак `per_row`, для `working` — разброс 0.10, для остальных — 0

#### Scenario: Разброс вне диапазона
- **WHEN** `frame_phase = "per_row"`, `frame_speed_spread = { working = 20 }`
- **THEN** разброс `working` — 0, ошибки нет
