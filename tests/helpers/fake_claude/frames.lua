-- Кадры потока `claude -p --output-format stream-json --verbose --include-partial-messages`
-- в форме, наблюдавшейся на Claude Code 2.1.325 (spec-checks.md, п. 11). Модуль используется
-- поддельным `claude` и не зависит от кода плагина.
local M = {}

local NIL = vim.NIL

local MODELS = {
  sonnet = "claude-sonnet-5-5",
  haiku = "claude-haiku-5-5",
  opus = "claude-opus-5-5",
}

--- Создаёт контекст кадров: session_id, cwd, model, счётчики идентификаторов.
function M.context(opts)
  local model = opts.model or "sonnet"
  return {
    session_id = opts.session_id,
    cwd = opts.cwd,
    model = MODELS[model] or model,
    tools = opts.tools or { "Read", "Grep", "Glob" },
    mcp = opts.mcp or false,
    pid = vim.uv.os_getpid(),
    n = 0,
    msg = 0,
  }
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
end
M.now = now

local function uuid(ctx)
  ctx.n = ctx.n + 1
  return string.format("%08x-0000-4000-a000-%012x", ctx.pid, ctx.n)
end
M.uuid = uuid

local function usage(output_tokens)
  return {
    input_tokens = 2,
    cache_creation_input_tokens = 222,
    cache_read_input_tokens = 39420,
    cache_creation = { ephemeral_5m_input_tokens = 0, ephemeral_1h_input_tokens = 222 },
    output_tokens = output_tokens,
    service_tier = "standard",
    inference_geo = "global",
    speed = "standard",
  }
end

local function next_message_id(ctx)
  ctx.msg = ctx.msg + 1
  return string.format("msg_01Fixture%017d", ctx.pid % 100000 * 100 + ctx.msg)
end

local function stream_event(ctx, msg_id, event, extra)
  local f = {
    type = "stream_event",
    event = event,
    session_id = ctx.session_id,
    parent_tool_use_id = NIL,
    uuid = uuid(ctx),
  }
  for k, v in pairs(extra or {}) do
    f[k] = v
  end
  f.api_message_id = msg_id
  return f
end

local function message_body(ctx, msg_id, content, out_tokens)
  return {
    model = ctx.model,
    id = msg_id,
    type = "message",
    role = "assistant",
    content = content,
    container = NIL,
    stop_reason = NIL,
    stop_sequence = NIL,
    stop_details = NIL,
    usage = usage(out_tokens),
    input_transformations = {},
    diagnostics = NIL,
    context_management = NIL,
  }
end

local function assistant_record(ctx, msg_id, content, extra)
  local f = {
    type = "assistant",
    message = message_body(ctx, msg_id, content, 2),
    parent_tool_use_id = NIL,
    session_id = ctx.session_id,
    uuid = uuid(ctx),
    timestamp = now(),
    request_id = "req_01Fixture" .. msg_id:sub(-12),
  }
  for k, v in pairs(extra or {}) do
    f[k] = v
  end
  return f
end

local function message_delta(ctx, msg_id, stop_reason, out_tokens)
  return stream_event(ctx, msg_id, {
    type = "message_delta",
    delta = {
      stop_reason = stop_reason,
      stop_sequence = NIL,
      stop_details = NIL,
      container = NIL,
    },
    usage = {
      input_tokens = 2,
      cache_creation_input_tokens = 222,
      cache_read_input_tokens = 39420,
      output_tokens = out_tokens,
      output_tokens_details = { thinking_tokens = 0 },
    },
    context_management = { applied_edits = {} },
  })
end

--- Событие `system/init`.
function M.init(ctx)
  return {
    type = "system",
    subtype = "init",
    cwd = ctx.cwd,
    session_id = ctx.session_id,
    tools = ctx.tools,
    mcp_servers = ctx.mcp and { { name = "mcp", status = "connected", source = "dynamic" } } or {},
    model = ctx.model,
    permissionMode = "default",
    slash_commands = {},
    apiKeySource = "none",
    claude_code_version = "2.1.325",
    output_style = "default",
    agents = {},
    skills = {},
    plugins = {},
    uuid = uuid(ctx),
  }
end

--- `system/status` перед очередным сообщением модели.
function M.status(ctx)
  return {
    type = "system",
    subtype = "status",
    status = "requesting",
    session_id = ctx.session_id,
    uuid = uuid(ctx),
  }
end

--- Сообщение модели с текстом: список кадров; `parts` — приращения `text_delta`.
function M.text_message(ctx, parts)
  local id = next_message_id(ctx)
  local full = table.concat(parts)
  local out = {}
  table.insert(
    out,
    stream_event(
      ctx,
      id,
      { type = "message_start", message = message_body(ctx, id, {}, 2) },
      { ttft_ms = 900, thinking_display = "updates" }
    )
  )
  table.insert(
    out,
    stream_event(ctx, id, {
      type = "content_block_start",
      index = 0,
      content_block = { type = "text", text = "" },
    })
  )
  for _, part in ipairs(parts) do
    table.insert(
      out,
      stream_event(ctx, id, {
        type = "content_block_delta",
        index = 0,
        delta = { type = "text_delta", text = part },
      })
    )
  end
  table.insert(out, assistant_record(ctx, id, { { type = "text", text = full } }))
  table.insert(out, stream_event(ctx, id, { type = "content_block_stop", index = 0 }))
  table.insert(out, message_delta(ctx, id, "end_turn", 26))
  table.insert(out, stream_event(ctx, id, { type = "message_stop" }))
  return out
end

--- Сообщение модели с вызовом инструмента и результатом вызова (запись `user`).
function M.tool_message(ctx, name, input, result_text)
  local id = next_message_id(ctx)
  local tool_id = string.format("toolu_01Fixture%015d", ctx.n + 1)
  local json = vim.json.encode(input)
  local cut = math.max(1, math.floor(#json / 2))
  local out = {}
  table.insert(
    out,
    stream_event(
      ctx,
      id,
      { type = "message_start", message = message_body(ctx, id, {}, 2) },
      { ttft_ms = 915, thinking_display = "updates" }
    )
  )
  table.insert(
    out,
    stream_event(ctx, id, {
      type = "content_block_start",
      index = 0,
      content_block = {
        type = "tool_use",
        id = tool_id,
        name = name,
        input = vim.empty_dict(),
        caller = { type = "direct" },
      },
    })
  )
  for _, piece in ipairs({ "", json:sub(1, cut), json:sub(cut + 1) }) do
    table.insert(
      out,
      stream_event(ctx, id, {
        type = "content_block_delta",
        index = 0,
        delta = { type = "input_json_delta", partial_json = piece },
      })
    )
  end
  table.insert(
    out,
    assistant_record(ctx, id, {
      {
        type = "tool_use",
        id = tool_id,
        name = name,
        input = input,
        caller = { type = "direct" },
      },
    }, { wire_tool_inputs = { [tool_id] = input } })
  )
  table.insert(out, stream_event(ctx, id, { type = "content_block_stop", index = 0 }))
  table.insert(out, {
    type = "user",
    message = {
      role = "user",
      content = {
        {
          tool_use_id = tool_id,
          type = "tool_result",
          content = { { type = "text", text = result_text } },
        },
      },
    },
    parent_tool_use_id = NIL,
    session_id = ctx.session_id,
    uuid = uuid(ctx),
    timestamp = now(),
    tool_use_result = { { type = "text", text = result_text } },
    tool_result_meta = {
      {
        id = tool_id,
        permission_decision = { decision = "accept", source = "config", reason_type = "mode" },
      },
    },
  })
  table.insert(out, message_delta(ctx, id, "tool_use", 120))
  table.insert(out, stream_event(ctx, id, { type = "message_stop" }))
  return out
end

--- Служебное событие лимитов, приходящее между сообщениями.
function M.rate_limit(ctx)
  return {
    type = "rate_limit_event",
    rate_limit_info = {
      status = "allowed",
      resetsAt = 1794643200,
      rateLimitType = "five_hour",
      isUsingOverage = false,
    },
    uuid = uuid(ctx),
    session_id = ctx.session_id,
  }
end

--- Итоговая запись `result`.
function M.result(ctx, text, opts)
  opts = opts or {}
  return {
    type = "result",
    subtype = opts.is_error and "error_during_execution" or "success",
    is_error = opts.is_error or false,
    api_error_status = NIL,
    duration_ms = 1506,
    duration_api_ms = 1343,
    num_turns = 1,
    result = text,
    stop_reason = "end_turn",
    session_id = ctx.session_id,
    total_cost_usd = 0.00631563,
    usage = {
      input_tokens = 6,
      cache_creation_input_tokens = 25682,
      cache_read_input_tokens = 93085,
      output_tokens = 178,
      service_tier = "standard",
    },
    modelUsage = {
      [ctx.model] = { inputTokens = 6, outputTokens = 178, costUSD = 0.00615685 },
    },
    permission_denials = {},
    terminal_reason = "completed",
    uuid = uuid(ctx),
  }
end

return M
