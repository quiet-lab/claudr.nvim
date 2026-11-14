## MODIFIED Requirements

### Requirement: Состояние панели с агентом
Узел панели с агентом MUST показывать состояние `agent_status` из herdr (`unknown`, `idle`, `working`, `blocked`) и MUST менять его по событию `pane.agent_status_changed`. Неизвестное значение MUST показываться как есть. Узел дополнительно MUST показывать число ждущих запросов (`agent-dialogs`, «Перечень ждущих запросов»).

#### Scenario: Агент ждёт ответа
- **WHEN** приходит `pane.agent_status_changed` с `agent_status = blocked`
- **THEN** узел панели показывает состояние `blocked`

#### Scenario: Агент вышел
- **WHEN** агент завершил работу, и панель вернулась к оболочке (`agent_status = unknown`, `agent` не задан)
- **THEN** узел панели показывается как панель с командой, без субагентов и фоновых команд

#### Scenario: Ждущие запросы
- **WHEN** у панели с агентом в `blocked` ждут два запроса диалога
- **THEN** узел панели показывает состояние `blocked` и число ждущих запросов — два
