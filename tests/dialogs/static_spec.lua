-- Отсутствие таймеров и опроса в модулях диалогов и окна ввода, отсутствие обращений к
-- панели (`pane.send_keys`, `pane.send_text`, `pane.read`) по диалогам (agent-dialogs,
-- «Отсутствие таймеров и опроса», «Диалог в панели не затрагивается»).
local t = require("helpers.t")

local forbidden = {
  "defer_fn",
  "new_timer",
  "timer_start",
  "pane%.send_keys",
  "pane%.send_text",
  "pane%.read",
}

local function sources()
  local out = {}
  local dirs = { t.root .. "/lua/claudr/dialogs" }
  for _, dir in ipairs(dirs) do
    for _, f in ipairs(vim.fn.globpath(dir, "**/*.lua", false, true)) do
      out[#out + 1] = f
    end
  end
  out[#out + 1] = t.root .. "/lua/claudr/input.lua"
  return out
end

-- Код файла без комментариев.
local function code(path)
  local lines = {}
  for line in io.lines(path) do
    if not line:match("^%s*%-%-") then
      lines[#lines + 1] = (line:gsub("%s%-%-.*$", ""))
    end
  end
  return table.concat(lines, "\n")
end

describe("Отсутствие таймеров и опроса", function()
  it(
    "Нет таймеров и обращений к панели в модулях диалогов",
    function()
      local files = sources()
      t.ok(#files >= 8, "найдены модули диалогов")
      for _, path in ipairs(files) do
        local text = code(path)
        for _, word in ipairs(forbidden) do
          t.ok(not text:find(word), path .. ": найдено " .. word)
        end
      end
    end
  )
end)
