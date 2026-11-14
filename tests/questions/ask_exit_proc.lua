-- Вспомогательный процесс «Neovim» для теста выхода во время ответа: задаёт вопрос по коду,
-- дожидается начала ответа (кадр init — сессия создана) и завершает Neovim, пока отвечающий
-- процесс ещё работает. Запуск: nvim --headless --clean -u NONE -l ask_exit_proc.lua <корень
-- плагина> <файл проекта>. Ожидание — по событию вывода процесса, без сна.
local root, file = arg[1], arg[2]
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

require("claudr").setup()
vim.cmd.edit(vim.fn.fnameescape(file))
vim.api.nvim_win_set_cursor(0, { 4, 4 })

local topic
require("claudr.questions").ask({
  question = "Что делает bar?",
  on_topic = function(tp)
    topic = tp
  end,
})
vim.wait(2 ^ 31 - 1, function()
  return topic ~= nil and topic.has_session
end)
io.stdout:write(topic.id, "\n")
io.stdout:flush()
vim.cmd("qa!")
