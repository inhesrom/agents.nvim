local config = require("agents.config")
local picker = require("agents.picker")
local target_mod = require("agents.target")
local util = require("agents.util")

local M = {}

local sessions = {}
local next_id = 1
local uv = vim.uv or vim.loop
local READY_POLL_MS = 50
local SESSION_HINT = "NORMAL  [i] terminal  [s] snap  [q/Esc] hide"
local TERMINAL_HINT = "TERMINAL  [Ctrl+\\ then Ctrl+N] cursor"
local SNAP_HINT = "SNAP  [h/j/k/l] move  [f] float  [q/Esc] cancel"
local FLOAT_FOOTER = " " .. SESSION_HINT .. " "
local TERMINAL_FOOTER = " " .. TERMINAL_HINT .. " "
local SNAP_FOOTER = " " .. SNAP_HINT .. " "
local snap_modes = {}
local last_editor_win

local enter_snap_mode
local exit_snap_mode
local snap_to

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

local function is_session_buffer(bufnr)
  for _, session in pairs(sessions) do
    if (session.bufnr == bufnr or session.hint_bufnr == bufnr) and not session.deleted then
      return true
    end
  end

  return false
end

local function session_for_buffer(bufnr)
  for _, session in pairs(sessions) do
    if session.bufnr == bufnr and not session.deleted then
      return session
    end
  end

  return nil
end

local function is_floating_win(winid)
  local ok, win_config = pcall(vim.api.nvim_win_get_config, winid)
  return ok and win_config.relative ~= ""
end

local function format_session_hint_winbar(hint)
  return "%#AgentsSessionHint#%=" .. tostring(hint):gsub("%%", "%%%%") .. "%="
end

local function set_session_winbar(winid, hint)
  if not is_win_valid(winid) or is_floating_win(winid) then
    return false
  end

  return pcall(vim.api.nvim_win_call, winid, function()
    pcall(vim.cmd, "setlocal statusline<")
    vim.wo.winbar = format_session_hint_winbar(hint)
  end)
end

local function clear_session_chrome(winid)
  if not is_win_valid(winid) or is_floating_win(winid) then
    return
  end

  pcall(vim.api.nvim_win_call, winid, function()
    vim.cmd("setlocal statusline<")
    pcall(vim.cmd, "setlocal winbar<")
  end)
end

local function define_highlights()
  vim.api.nvim_set_hl(0, "AgentsSessionHint", { default = true, link = "Comment" })
end

local function close_session_hint_line(session)
  if not session then
    return
  end

  local winid = session.hint_winid
  session.hint_winid = nil

  if is_win_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end

  if is_buf_valid(session.hint_bufnr) then
    pcall(vim.api.nvim_buf_delete, session.hint_bufnr, { force = true })
  end
  session.hint_bufnr = nil
end

local function set_float_footer(winid, hint)
  if not is_win_valid(winid) or not is_floating_win(winid) then
    return
  end

  local ok, win_config = pcall(vim.api.nvim_win_get_config, winid)
  if not ok then
    return
  end

  if hint == SNAP_HINT then
    win_config.footer = SNAP_FOOTER
  elseif hint == TERMINAL_HINT then
    win_config.footer = TERMINAL_FOOTER
  else
    win_config.footer = FLOAT_FOOTER
  end
  win_config.footer_pos = "center"
  pcall(vim.api.nvim_win_set_config, winid, win_config)
end

local function visible_hint_for_session(session)
  if not session then
    return SESSION_HINT
  end

  if snap_modes[session.id] then
    return SNAP_HINT
  end

  local ok, mode = pcall(vim.api.nvim_get_mode)
  if ok and mode.mode == "t" and is_win_valid(session.winid) and vim.api.nvim_get_current_win() == session.winid then
    return TERMINAL_HINT
  end

  return SESSION_HINT
end

local function set_session_hint(session, hint)
  if not session then
    return
  end

  if is_floating_win(session.winid) then
    close_session_hint_line(session)
    set_float_footer(session.winid, hint)
    return
  end

  close_session_hint_line(session)
  set_session_winbar(session.winid, hint)
end

local function refresh_visible_session_hints()
  for _, session in pairs(sessions) do
    if is_visible(session) then
      set_session_hint(session, visible_hint_for_session(session))
    end
  end
end

local function is_editor_win(winid)
  if not is_win_valid(winid) or is_floating_win(winid) then
    return false
  end

  local ok, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
  if not ok or is_session_buffer(bufnr) then
    return false
  end

  return true
end

local function remember_editor_win(winid)
  if is_editor_win(winid) then
    last_editor_win = winid
  end
end

local function current_or_last_editor_win()
  local current_win = vim.api.nvim_get_current_win()
  if is_editor_win(current_win) then
    last_editor_win = current_win
    return current_win
  end

  if is_editor_win(last_editor_win) then
    return last_editor_win
  end

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if is_editor_win(winid) then
      last_editor_win = winid
      return winid
    end
  end

  return nil
end

local function install_hide_maps(session)
  util.set_normal_keymap(session.bufnr, "q", function()
    if snap_modes[session.id] then
      exit_snap_mode(session)
      return
    end

    M.hide(session)
  end, "Hide agent session")
  util.set_normal_keymap(session.bufnr, "<Esc>", function()
    if snap_modes[session.id] then
      exit_snap_mode(session)
      return
    end

    M.hide(session)
  end, "Hide agent session")
end

local function install_buffer_maps(session)
  install_hide_maps(session)
  util.set_normal_keymap(session.bufnr, "s", function()
    enter_snap_mode(session)
  end, "Snap agent session")
end

local function remove_snap_choice_maps(session)
  for _, lhs in ipairs({ "h", "j", "k", "l", "f" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = session.bufnr })
  end
end

exit_snap_mode = function(session)
  if not session then
    return
  end

  snap_modes[session.id] = nil

  if is_buf_valid(session.bufnr) then
    remove_snap_choice_maps(session)
    install_hide_maps(session)
  end

  set_session_hint(session, visible_hint_for_session(session))
end

enter_snap_mode = function(session)
  if not session or not is_buf_valid(session.bufnr) then
    return false
  end

  snap_modes[session.id] = true

  util.set_normal_keymap(session.bufnr, "h", function()
    snap_to(session, "left")
  end, "Snap agent session left")
  util.set_normal_keymap(session.bufnr, "j", function()
    snap_to(session, "down")
  end, "Snap agent session down")
  util.set_normal_keymap(session.bufnr, "k", function()
    snap_to(session, "up")
  end, "Snap agent session up")
  util.set_normal_keymap(session.bufnr, "l", function()
    snap_to(session, "right")
  end, "Snap agent session right")
  util.set_normal_keymap(session.bufnr, "f", function()
    snap_to(session, "float")
  end, "Float agent session")
  util.set_normal_keymap(session.bufnr, "q", function()
    exit_snap_mode(session)
  end, "Cancel agent snap")
  util.set_normal_keymap(session.bufnr, "<Esc>", function()
    exit_snap_mode(session)
  end, "Cancel agent snap")

  set_session_hint(session, SNAP_HINT)
  return true
end

local function attach_winclosed(session, winid)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      if session.winid == winid then
        close_session_hint_line(session)
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

local function ensure_session_buffer(session)
  if is_buf_valid(session.bufnr) then
    return
  end

  session.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[session.bufnr].bufhidden = "hide"
  vim.bo[session.bufnr].swapfile = false
  install_buffer_maps(session)
end

local function replace_session_window_with_anchor(session, winid)
  if not is_win_valid(winid) then
    return false
  end

  clear_session_chrome(winid)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false

  local ok = pcall(vim.api.nvim_win_set_buf, winid, bufnr)
  if not ok then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return false
  end

  session.winid = nil
  remember_editor_win(winid)
  return true
end

local function close_session_window(session)
  local winid = session.winid
  if not is_win_valid(winid) then
    session.winid = nil
    return true
  end

  close_session_hint_line(session)
  clear_session_chrome(winid)

  session.winid = nil
  local ok = pcall(vim.api.nvim_win_close, winid, true)
  if not ok and is_win_valid(winid) then
    if replace_session_window_with_anchor(session, winid) then
      return true
    end

    session.winid = winid
    set_session_hint(session, visible_hint_for_session(session))
    return false
  end

  return true
end

local function split_size(value, available)
  value = value or 0.40
  local size = value < 1 and math.floor(available * value) or value
  local maximum = math.max(1, available - 1)

  return math.max(1, math.min(math.floor(size), maximum))
end

local function open_split(session, direction)
  local anchor = current_or_last_editor_win()
  if not anchor then
    return nil
  end

  local split_commands = {
    left = "leftabove vertical split",
    right = "rightbelow vertical split",
    up = "leftabove split",
    down = "rightbelow split",
  }
  local command = split_commands[direction]
  if not command then
    return nil
  end

  local anchor_width = vim.api.nvim_win_get_width(anchor)
  local anchor_height = vim.api.nvim_win_get_height(anchor)
  local snap_cfg = config.get().ui.snap or {}

  local ok = pcall(vim.api.nvim_set_current_win, anchor)
  if not ok then
    return nil
  end

  ok = pcall(vim.cmd, command)
  if not ok then
    return nil
  end

  local winid = vim.api.nvim_get_current_win()
  ok = pcall(vim.api.nvim_win_set_buf, winid, session.bufnr)
  if not ok then
    pcall(vim.api.nvim_win_close, winid, true)
    return nil
  end

  if direction == "left" or direction == "right" then
    pcall(vim.api.nvim_win_set_width, winid, split_size(snap_cfg.width, anchor_width))
  else
    pcall(vim.api.nvim_win_set_height, winid, split_size(snap_cfg.height, anchor_height))
  end

  pcall(vim.api.nvim_set_current_win, winid)
  return winid
end

local function open_float(session)
  local cfg = config.get().ui
  return util.open_centered_float(session.bufnr, {
    width = cfg.width,
    height = cfg.height,
    border = cfg.border,
    title = session_title(session),
    footer = FLOAT_FOOTER,
  })
end

local function open_window(session, opts)
  opts = opts or {}

  if is_visible(session) and not opts.force_reopen then
    set_session_hint(session, visible_hint_for_session(session))
    vim.api.nvim_set_current_win(session.winid)
    touch(session)
    return session.winid
  end

  remember_editor_win(vim.api.nvim_get_current_win())
  ensure_session_buffer(session)

  if opts.force_reopen and not close_session_window(session) then
    vim.api.nvim_set_current_win(session.winid)
    touch(session)
    return session.winid
  end

  local placement = session.placement or { kind = "float" }
  local winid
  if placement.kind == "split" then
    winid = open_split(session, placement.direction)
  end

  if not winid then
    winid = open_float(session)
  end

  session.winid = winid
  attach_winclosed(session, winid)
  set_session_hint(session, visible_hint_for_session(session))
  touch(session)
  return winid
end

snap_to = function(session, direction)
  if not session then
    return false
  end

  exit_snap_mode(session)

  if direction == "float" then
    session.placement = { kind = "float" }
  else
    session.placement = { kind = "split", direction = direction }
  end

  return open_window(session, { force_reopen = true }) ~= nil
end

local anchor_group = vim.api.nvim_create_augroup("agents_session_anchor", { clear = true })
vim.api.nvim_create_autocmd("WinEnter", {
  group = anchor_group,
  desc = "Track the editor window used for Agent Session splits",
  callback = function()
    remember_editor_win(vim.api.nvim_get_current_win())
  end,
})
remember_editor_win(vim.api.nvim_get_current_win())

local chrome_group = vim.api.nvim_create_augroup("agents_session_chrome", { clear = true })
define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = chrome_group,
  desc = "Define Agent Session hint highlights",
  callback = define_highlights,
})
vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = chrome_group,
  desc = "Refresh Agent Session hints when session windows resize",
  callback = refresh_visible_session_hints,
})
vim.api.nvim_create_autocmd({ "TermEnter", "TermLeave" }, {
  group = chrome_group,
  desc = "Refresh Agent Session hints when terminal mode changes",
  callback = function(args)
    local session = session_for_buffer(args.buf)
    if session and is_visible(session) then
      set_session_hint(session, visible_hint_for_session(session))
    end
  end,
})

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
    placement = { kind = "float" },
    created_at = now(),
    updated_at = now(),
  }

  sessions[id] = session
  install_buffer_maps(session)
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

  local closed = close_session_window(session)
  if closed then
    touch(session)
  end

  return closed
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
  snap_modes[session.id] = nil

  if live and session.job_id then
    pcall(vim.fn.jobstop, session.job_id)
  end

  if is_visible(session) then
    close_session_window(session)
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
    snap_modes[session.id] = nil
    if session.job_id then
      pcall(vim.fn.jobstop, session.job_id)
    end
    if is_visible(session) then
      close_session_window(session)
    end
    if is_buf_valid(session.bufnr) then
      pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
    end
  end

  sessions = {}
  snap_modes = {}
  next_id = 1
  remember_editor_win(vim.api.nvim_get_current_win())
end

function M._record_for_test(fields)
  fields = fields or {}
  local id = next_id
  next_id = next_id + 1

  local session = vim.tbl_extend("force", {
    id = id,
    agent = { name = fields.agent_name or "test", label = fields.agent_name or "test" },
    agent_name = fields.agent_name or "test",
    status = fields.status or "exited",
    description = fields.description or "",
    placement = { kind = "float" },
    target = fields.target,
    root = fields.root,
    created_at = now(),
    updated_at = now(),
  }, fields)

  sessions[id] = session
  if is_buf_valid(session.bufnr) then
    install_buffer_maps(session)
  end
  return session
end

M._format_task_input_for_test = format_task_input
M._snap_for_test = snap_to
M._enter_snap_mode_for_test = enter_snap_mode
M._snap_mode_active_for_test = function(session)
  return session and snap_modes[session.id] or false
end
M._remember_editor_for_test = remember_editor_win

return M
