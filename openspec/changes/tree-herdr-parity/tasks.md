## 1. Значки и кадры

- [x] 1.1 Чтение `frame_phase` и `frame_speed_spread` в `lua/claudr/herdr/icons.lua` (D45), тесты `tests/herdr/icons_spec.lua`.
- [x] 1.2 Часы строки, как `status_frames.rs`: начальное значение, коэффициент, сдвиг; таймер на ближайшую границу с окном 2 мс; метка переставляется только при смене кадра (D45), тесты `tests/tree/frames_spec.lua` со сверкой с расчётом herdr.

## 2. Подписи и состав

- [x] 2.1 Единственная вкладка не показывается строкой в режиме `herdr`, `focus` на неё ставит курсор на workspace (D46), тесты `tests/tree/view_spec.lua`, `tests/tree/icons_spec.lua`.
- [x] 2.2 Подпись вкладки по правилу herdr (D46), тесты `tests/tree/icons_spec.lua`.
- [x] 2.3 Описание субагента из вызова `Agent` и задание из транскрипта (D47), тесты `tests/data/subagents_spec.lua`, `tests/tree/model_spec.lua`.

## 3. Документы и проверки

- [x] 3.1 `docs/tree.md`: состав, подписи вкладок и субагентов, анимация `per_row`, значки из основного шрифта Neovide (D48).
- [x] 3.2 Полный прогон `tests/run.sh -j 8`, живая проверка без окна на рабочем сервере.
- [ ] 3.3 Проверка вида пользователем в Neovide и в Neovim внутри herdr.
