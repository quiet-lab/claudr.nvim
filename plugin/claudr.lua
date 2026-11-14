-- Загрузка плагина: только регистрация команды `:Claudr`. Подкоманды появляются после
-- `require("claudr").setup()`, как принято в плагинах Neovim: плагин без вызова `setup`
-- ничего не запускает и не подключается к herdr.
if vim.g.loaded_claudr then
  return
end
vim.g.loaded_claudr = 1

require("claudr.commands").define()
