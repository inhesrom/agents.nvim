local config = require("agents.config")
local picker = require("agents.picker")
local target_mod = require("agents.target")
local util = require("agents.util")

local M = {}

local sessions = {}
local next_id = 1
local uv = vim.uv or vim.loop
local READY_POLL_MS = 50

local function now()
  return uv.hrtime()
end

local function now_ms()
  return math.floor(now() / 1000000)
end

local function touch(session)
  session.updated_at = now()
end

local function session_title(session)
  return string.format(" %s #%d ", session.agent.label or session.agent.name, session.id)
end

local function argv_for(agent)
  local argv = { agent.cmd or agent.command or agent.name }
  for _, arg in ipairs(agent.args or {}) do
    argv[#argv + 1] = arg
  end
  return argv
end

local function is_win_valid(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function is_buf_valid(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_visible(session)
  return is_win_valid(session.winid)
end

local function install_buffer_maps(session)
  util.set_normal_keymap(session.bufnr, "q", function()
    M.hide(session)
  end, "Hide agent session")
  util.set_normal_keymap(session.bufnr, "<Esc>", function()
    M.hide(session)
  end, "Hide agent session")
end

local function attach_winclosed(session, winid)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      if session.winid == winid then
        session.winid = nil
        touch(session)
      end
    end,
  })
end

local function format_task_input(prompt, send)
  send = send or {}
  local text = prompt or ""

  if send.bracketed_paste ~= false then
    text = "\027[200~" .. text .. "\027[201~"
  end

  if send.submit == nil or send.submit == true or send.submit == "enter" then
    text = text .. "\r"
  elseif send.submit == "newline" then
    text = text .. "\n"
  end

  return text
end

local function send_task_now(session, prompt)
  if session.deleted or session.status ~= "running" or not session.job_id then
    return false
  end

  local ok = pcall(vim.fn.chansend, session.job_id, format_task_input(prompt, session.agent.send))
  if ok then
    touch(session)
  end

  return ok
end

local function send_task_after_delay(session, prompt)
  local send = session.agent.send or {}
  local delay_ms = send.delay_ms or 0

  vim.defer_fn(function()
    send_task_now(session, prompt)
  end, delay_ms)
end

local function visible_buffer_text(bufnr)
  if not is_buf_valid(bufnr) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  if text:find("%S") then
    return text
  end

  return nil
end

local function send_task_when_output_idle(session, prompt)
  local send = session.agent.send or {}
  local idle_ms = send.ready_idle_ms or 250
  local timeout_ms = send.ready_timeout_ms or 3000
  local started_ms = now_ms()
  local last_text = nil
  local last_change_ms = started_ms
  local sent = false

  local function finish()
    if sent then
      return
    end

    sent = true
    send_task_after_delay(session, prompt)
  end

  local function poll()
    if sent or session.deleted or session.status ~= "running" or not session.job_id then
      return
    end

    local current_ms = now_ms()
    local text = visible_buffer_text(session.bufnr)

    if text then
      if text ~= last_text then
        last_text = text
        last_change_ms = current_ms
      elseif current_ms - last_change_ms >= idle_ms then
        finish()
        return
      end
    end

    if current_ms - started_ms >= timeout_ms then
      finish()
      return
    end

    vim.defer_fn(poll, READY_POLL_MS)
  end

  poll()
end

local function send_task(session, prompt)
  local send = session.agent.send or {}
  if send.ready == "delay" then
    send_task_after_delay(session, prompt)
    return
  end

  send_task_when_output_idle(session, prompt)
end

local function on_exit(session, code)
  if session.deleted then
    return
  end

  session.status = "exited"
  session.exit_code = code
  touch(session)

  if not is_visible(session) then
    util.notify(string.format("%s exited with code %d", session_title(session):gsub("^%s+", ""):gsub("%s+$", ""), code))
  end
end

local function open_window(session)
  if is_visible(session) then
    vim.api.nvim_set_current_win(session.winid)
    touch(session)
    return session.winid
  end

  if not is_buf_valid(session.bufnr) then
    session.bufnr = vim.api.nvim_create_buf(false, true)
  end

  local cfg = config.get().ui
  local winid = util.open_centered_float(session.bufnr, {
    width = cfg.width,
    height = cfg.height,
    border = cfg.border,
    title = session_title(session),
    footer = " normal: q/<Esc> hide ",
  })

  session.winid = winid
  attach_winclosed(session, winid)
  touch(session)
  return winid
end

local function start_job(session, prompt)
  vim.api.nvim_set_current_win(session.winid)

  local ok, job_id = pcall(vim.fn.jobstart, argv_for(session.agent), {
    term = true,
    cwd = session.agent.cwd or session.root,
    env = session.agent.env,
    on_exit = function(_, code)
      vim.schedule(function()
        on_exit(session, code)
      end)
    end,
  })

  if not ok or not job_id or job_id <= 0 then
    session.status = "exited"
    session.exit_code = -1
    util.notify("Failed to start agent: " .. (session.agent.cmd or session.agent.name), vim.log.levels.ERROR)
    return false
  end

  session.job_id = job_id
  session.status = "running"
  install_buffer_maps(session)
  send_task(session, prompt)
  return true
end

function M.start(agent, prompt, target, description)
  local id = next_id
  next_id = next_id + 1

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false

  local session = {
    id = id,
    agent = agent,
    agent_name = agent.name,
    bufnr = bufnr,
    root = target.root,
    target = target,
    task_prompt = prompt,
    description = description,
    status = "starting",
    created_at = now(),
    updated_at = now(),
  }

  sessions[id] = session
  open_window(session)
  start_job(session, prompt)

  return session
end

function M.show(session)
  if type(session) == "number" then
    session = sessions[session]
  end

  if not session then
    return nil
  end

  open_window(session)
  return session
end

function M.hide(session)
  if type(session) == "number" then
    session = sessions[session]
  end

  if not session then
    session = M.current()
  end

  if not session or not is_visible(session) then
    return false
  end

  local winid = session.winid
  session.winid = nil
  touch(session)

  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end

  return true
end

function M.send(session)
  if type(session) == "number" then
    session = sessions[session]
  end

  if not session then
    session = M.current()
  end

  if not session then
    util.notify("No current agent session to send to", vim.log.levels.WARN)
    return false
  end

  if session.task_prompt == nil then
    util.notify(string.format("Agent session #%d has no stored task to send", session.id), vim.log.levels.WARN)
    return false
  end

  if session.status ~= "running" or not session.job_id then
    util.notify(string.format("Agent session #%d is not running", session.id), vim.log.levels.WARN)
    return false
  end

  return send_task_now(session, session.task_prompt)
end

function M.current()
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()

  for _, session in pairs(sessions) do
    if session.winid == current_win or session.bufnr == current_buf then
      return session
    end
  end

  return nil
end

function M.list()
  local result = {}
  for _, session in pairs(sessions) do
    result[#result + 1] = session
  end

  table.sort(result, function(left, right)
    return left.updated_at > right.updated_at
  end)

  return result
end

function M.delete(session, opts)
  opts = opts or {}
  if type(session) == "number" then
    session = sessions[session]
  end

  if not session then
    return false
  end

  local live = session.status ~= "exited"

  if live and opts.confirm ~= false then
    local choice = vim.fn.confirm(
      string.format("Stop %s session #%d?", session.agent_name, session.id),
      "&Stop\n&Cancel",
      2
    )
    if choice ~= 1 then
      return false
    end
  end

  session.deleted = true

  if live and session.job_id then
    pcall(vim.fn.jobstop, session.job_id)
  end

  if is_visible(session) then
    pcall(vim.api.nvim_win_close, session.winid, true)
  end

  if is_buf_valid(session.bufnr) then
    pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
  end

  sessions[session.id] = nil
  return true
end

local function session_line(session)
  local status = session.status
  if status == "running" then
    status = "live"
  end

  local target = session.target and target_mod.label(session.target) or ""
  local root = session.root and util.basename(session.root) or ""

  return string.format(
    "%-10s %-7s %-36s %-28s %s",
    session.agent_name,
    status,
    session.description or "",
    target,
    root
  )
end

function M.open_picker()
  local cfg = config.get().picker
  return picker.open({
    title = " Agent Sessions ",
    width = cfg.width,
    height = cfg.height,
    border = cfg.border,
    items = M.list(),
    items_provider = M.list,
    empty_text = "No agent sessions",
    footer = " <CR> show  d delete  q/<Esc> close ",
    format = session_line,
    on_select = function(session)
      M.show(session)
    end,
    on_delete = function(session)
      return M.delete(session, { confirm = true })
    end,
  })
end

function M._reset_for_test()
  for _, session in pairs(sessions) do
    session.deleted = true
    if session.job_id then
      pcall(vim.fn.jobstop, session.job_id)
    end
    if is_visible(session) then
      pcall(vim.api.nvim_win_close, session.winid, true)
    end
    if is_buf_valid(session.bufnr) then
      pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
    end
  end

  sessions = {}
  next_id = 1
end

function M._record_for_test(fields)
  local id = next_id
  next_id = next_id + 1

  local session = vim.tbl_extend("force", {
    id = id,
    agent = { name = fields.agent_name or "test", label = fields.agent_name or "test" },
    agent_name = fields.agent_name or "test",
    status = fields.status or "exited",
    description = fields.description or "",
    target = fields.target,
    root = fields.root,
    created_at = now(),
    updated_at = now(),
  }, fields or {})

  sessions[id] = session
  return session
end

M._format_task_input_for_test = format_task_input

return M
