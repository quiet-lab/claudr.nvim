## MODIFIED Requirements

### Requirement: Субагенты сессии
Субагенты сессии MUST определяться по парам `agent-<id>.jsonl` и `agent-<id>.meta.json` в каталоге `subagents/` каталога сессии. Из `meta.json` модуль MUST читать `agentType`, `description`, `toolUseId`, `spawnDepth`, `parentAgentId`, `model` и `finished`; без `description` — брать описание из вызова `Agent` с идентификатором `toolUseId`. Задание субагента MUST быть первой непустой строкой первой записи транскрипта вида `user`. Посторонние файлы и подкаталоги MUST игнорироваться.

#### Scenario: Пара файлов
- **WHEN** в `subagents/` лежат `agent-a1.jsonl` и `agent-a1.meta.json`
- **THEN** модуль возвращает субагента `a1` с полями из `meta.json`

#### Scenario: Посторонний файл
- **WHEN** в `subagents/` лежит файл `agent-a1.forked-skill.json` или `agent-a1.forked-skill.marker.json`
- **THEN** он не даёт субагента

#### Scenario: Каталог workflow
- **WHEN** в `subagents/` есть каталог `workflows/` с вложенными каталогами и журналами
- **THEN** он игнорируется, субагентов не добавляет

#### Scenario: Описание из вызова и задание
- **WHEN** у субагента в `meta.json` нет `description`, `toolUseId` указывает на вызов `Agent` с описанием `D`, а первая запись транскрипта — запись пользователя с текстом `\n  Проверить ветку\n…`
- **THEN** модуль возвращает описание `D` и задание `Проверить ветку`
