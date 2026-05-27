local agents = require("agents")
local config = require("agents.config")
local target = require("agents.target")
local task_editor = require("agents.task_editor")
local sessions = require("agents.sessions")
local commands = require("agents.commands")
local util = require("agents.util")
local launch_commands = require("agents.launch_commands")

local FLOAT_FOOTER = " NORMAL  [i] terminal  [s] snap  [q/Esc] hide "
local SESSION_HINT = "NORMAL  [i] terminal  [s] snap  [q/Esc] hide"
local TERMINAL_HINT = "TERMINAL  [Ctrl+\\ then Ctrl+N] cursor"
local TERMINAL_FOOTER = " " .. TERMINAL_HINT .. " "
local SNAP_HINT = "SNAP  [h/j/k/l] move  [f] float  [q/Esc] cancel"
local SNAP_FOOTER = " " .. SNAP_HINT .. " "

local tests = {}

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual), 2)
  end
end

local function ok(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function temp_project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/lua", "p")
  local file = root .. "/lua/example.lua"
  vim.fn.writefile({ "one", "two", "three", "four", "five" }, file)
  return root, file
end

local function write_script(lines)
  local script = vim.fn.tempname() .. ".sh"
  vim.fn.writefile(lines, script)
  vim.fn.setfperm(script, "rwx------")
  return script
end

local function basic_target()
  return {
    root = vim.fn.getcwd(),
    path = "x.lua",
    start_line = 1,
    end_line = 1,
  }
end

local function wait_for_file(path, timeout_ms)
  ok(vim.wait(timeout_ms or 2000, function()
    return vim.fn.filereadable(path) == 1
  end), "expected file to be written: " .. path)

  return table.concat(vim.fn.readfile(path), "\n")
end

local function read_json_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function with_launch_command_store(initial_commands, fn)
  local path = vim.fn.tempname()
  if initial_commands then
    vim.fn.writefile({ vim.json.encode(initial_commands) }, path)
  end

  launch_commands._set_path_for_test(path)
  local success, err = pcall(fn, path)
  launch_commands._reset_for_test()
  pcall(vim.fn.delete, path)

  if not success then
    error(err, 0)
  end
end

local function set_picker_line_and_leave_insert(active_picker, line, text)
  vim.bo[active_picker.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(active_picker.bufnr, line - 1, line, false, { text })
  vim.api.nvim_set_current_win(active_picker.winid)
  vim.api.nvim_win_set_cursor(active_picker.winid, { line, 0 })
  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = active_picker.bufnr })
end

local function capture_notifications(fn)
  local notifications = {}
  local old_notify = vim.notify
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end

  local success, err = pcall(fn, notifications)
  vim.notify = old_notify
  if not success then
    error(err, 0)
  end

  return notifications
end

local function reset_editor_window()
  pcall(vim.cmd, "stopinsert")
  sessions._reset_for_test()

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local win_config = vim.api.nvim_win_get_config(winid)
    if win_config.relative ~= "" then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end

  vim.cmd("silent! only")
  vim.cmd("enew")
  local winid = vim.api.nvim_get_current_win()
  sessions._remember_editor_for_test(winid)
  return winid
end

local function is_float(winid)
  local win_config = vim.api.nvim_win_get_config(winid)
  return win_config.relative ~= ""
end

local function window_statusline(winid)
  return vim.api.nvim_get_option_value("statusline", { win = winid, scope = "local" })
end

local function window_winbar(winid)
  return vim.api.nvim_get_option_value("winbar", { win = winid, scope = "local" })
end

local function session_hint_winbar(hint)
  return "%#AgentsSessionHint#%=" .. tostring(hint):gsub("%%", "%%%%") .. "%="
end

local function footer_text(footer)
  if type(footer) == "string" then
    return footer
  end

  if type(footer) ~= "table" then
    return nil
  end

  if type(footer[1]) == "string" then
    return footer[1]
  end

  if type(footer[1]) == "table" then
    return footer[1][1]
  end

  return nil
end

local function float_footer(winid)
  return footer_text(vim.api.nvim_win_get_config(winid).footer)
end

local function has_float_footer_api()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok_open, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
    relative = "editor",
    width = 20,
    height = 5,
    row = 0,
    col = 0,
    style = "minimal",
    footer = " footer ",
  })

  local supported = ok_open and footer_text(vim.api.nvim_win_get_config(winid).footer) == " footer "
  if ok_open then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  return supported
end

local function assert_float_footer(winid, expected)
  if has_float_footer_api() then
    eq(float_footer(winid), expected)
  end
end

local function assert_no_session_hint_statusline(winid)
  local value = window_statusline(winid)
  ok(value ~= SESSION_HINT, "window should not use the normal session hint statusline")
  ok(value ~= TERMINAL_HINT, "window should not use the terminal-mode session hint statusline")
  ok(value ~= SNAP_HINT, "window should not use the snap-mode session hint statusline")
end

local function assert_no_session_hint_winbar(winid)
  local value = window_winbar(winid)
  ok(value ~= session_hint_winbar(SESSION_HINT), "window should not use the normal session hint winbar")
  ok(value ~= session_hint_winbar(TERMINAL_HINT), "window should not use the terminal-mode session hint winbar")
  ok(value ~= session_hint_winbar(SNAP_HINT), "window should not use the snap-mode session hint winbar")
  ok(not value:find(SESSION_HINT, 1, true), "window winbar should not contain the normal session hint")
  ok(not value:find(TERMINAL_HINT, 1, true), "window winbar should not contain the terminal-mode session hint")
  ok(not value:find(SNAP_HINT, 1, true), "window winbar should not contain the snap-mode session hint")
end

local function assert_no_session_hint_line(session, winid)
  if winid then
    ok(not vim.api.nvim_win_is_valid(winid), "old Session Hint Line window should be closed")
  end
  if session then
    eq(session.hint_winid, nil, "session should not keep a Session Hint Line window")
    eq(session.hint_bufnr, nil, "session should not keep a Session Hint Line buffer")
  end
end

local function assert_session_hint_winbar(session, expected)
  assert_no_session_hint_statusline(session.winid)
  assert_no_session_hint_line(session)
  eq(window_winbar(session.winid), session_hint_winbar(expected))
end

local function feed_normal(keys)
  local leave_terminal = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
  vim.api.nvim_feedkeys(leave_terminal, "nx", false)
  vim.api.nvim_feedkeys(keys, "mx", false)
end

local function with_mode(mode, fn)
  local old_get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    local current = old_get_mode()
    current.mode = mode
    return current
  end

  local success, err = pcall(fn)
  vim.api.nvim_get_mode = old_get_mode
  if not success then
    error(err, 0)
  end
end

local function exec_terminal_mode_autocmd(session, event, mode)
  vim.api.nvim_set_current_win(session.winid)
  with_mode(mode, function()
    vim.api.nvim_exec_autocmds(event, { buffer = session.bufnr })
  end)
end

local function start_sleep_session()
  local editor_win = reset_editor_window()
  local session = sessions.start({
    name = "sh",
    label = "sh",
    cmd = "sh",
    args = { "-c", "sleep 30" },
    send = { ready = "delay", delay_ms = 0, bracketed_paste = false, submit = false },
  }, "", basic_target(), "snap test")

  ok(session.job_id and session.job_id > 0, "session job should start")
  return session, editor_win
end

local function assert_split_direction(session, editor_win, direction)
  ok(vim.api.nvim_win_is_valid(session.winid), "session window should be valid")
  ok(vim.api.nvim_win_is_valid(editor_win), "editor anchor should be valid")
  ok(not is_float(session.winid), "session should be in a real split")
  eq(vim.api.nvim_win_get_buf(session.winid), session.bufnr)
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, SESSION_HINT)

  local session_pos = vim.api.nvim_win_get_position(session.winid)
  local editor_pos = vim.api.nvim_win_get_position(editor_win)
  if direction == "left" then
    ok(session_pos[2] < editor_pos[2], "session split should be left of editor")
  elseif direction == "right" then
    ok(session_pos[2] > editor_pos[2], "session split should be right of editor")
  elseif direction == "up" then
    ok(session_pos[1] < editor_pos[1], "session split should be above editor")
  elseif direction == "down" then
    ok(session_pos[1] > editor_pos[1], "session split should be below editor")
  end
end

test("auto-registers built-ins found on PATH", function()
  local cfg = config.resolve({}, function(cmd)
    return cmd == "codex" and 1 or 0
  end)

  ok(cfg.agents.codex, "codex should be registered")
  eq(cfg.agents.claude, nil, "claude should not be registered")
  eq(cfg.agents.codex.send.ready, "output-idle")
end)

test("applies explicit agent overrides and disables", function()
  local cfg = config.resolve({
    agents = {
      codex = { cmd = "/tmp/codex", args = { "--fast" } },
      claude = false,
      custom = { cmd = "custom-agent" },
      disabled = { cmd = "disabled-agent", enabled = false },
    },
  }, function()
    return 0
  end)

  eq(cfg.agents.codex.cmd, "/tmp/codex")
  eq(cfg.agents.codex.args, { "--fast" })
  eq(cfg.agents.claude, nil)
  eq(cfg.agents.custom.cmd, "custom-agent")
  eq(cfg.agents.disabled, nil)
  eq(cfg.send.ready, "output-idle")
  eq(cfg.send.ready_idle_ms, 250)
  eq(cfg.send.ready_timeout_ms, 3000)
end)

test("applies default and overridden snap config", function()
  local cfg = config.resolve({}, function()
    return 0
  end)

  eq(cfg.ui.snap.width, 0.40)
  eq(cfg.ui.snap.height, 0.35)

  cfg = config.resolve({
    ui = {
      snap = {
        width = 48,
        height = 12,
      },
    },
  }, function()
    return 0
  end)

  eq(cfg.ui.snap.width, 48)
  eq(cfg.ui.snap.height, 12)
end)

test("applies top-level send readiness to built-ins", function()
  local cfg = config.resolve({
    send = {
      ready = "delay",
      ready_idle_ms = 10,
      ready_timeout_ms = 20,
    },
    agents = {
      codex = { cmd = "/tmp/codex" },
    },
  }, function()
    return 0
  end)

  eq(cfg.agents.codex.send.ready, "delay")
  eq(cfg.agents.codex.send.ready_idle_ms, 10)
  eq(cfg.agents.codex.send.ready_timeout_ms, 20)
  eq(cfg.agents.codex.send.delay_ms, 120)
end)

test("completes commands and launch agent names", function()
  agents.setup({
    agents = {
      alpha = { cmd = "alpha" },
      beta = { cmd = "beta" },
    },
  })

  eq(commands.complete("la", "Agents la"), { "launch" })
  eq(commands.complete("a", "Agents launch a"), { "alpha" })
end)

test("dispatches subcommands", function()
  local calls = {}
  local old_launch = agents.launch
  local old_sessions = agents.sessions
  local old_hide = agents.hide
  local old_send = agents.send

  agents.launch = function(name, opts)
    calls[#calls + 1] = { "launch", name, opts.line1, opts.line2 }
  end
  agents.sessions = function()
    calls[#calls + 1] = { "sessions" }
  end
  agents.hide = function()
    calls[#calls + 1] = { "hide" }
  end
  agents.send = function()
    calls[#calls + 1] = { "send" }
  end

  commands.dispatch({ fargs = { "launch", "alpha" }, range = 2, line1 = 3, line2 = 5 })
  commands.dispatch({ fargs = { "sessions" } })
  commands.dispatch({ fargs = { "hide" } })
  commands.dispatch({ fargs = { "send" } })

  agents.launch = old_launch
  agents.sessions = old_sessions
  agents.hide = old_hide
  agents.send = old_send

  eq(calls, {
    { "launch", "alpha", 3, 5 },
    { "sessions" },
    { "hide" },
    { "send" },
  })
end)

test("formats terminal task input", function()
  eq(sessions._format_task_input_for_test("hello", {}), "\027[200~hello\027[201~\r")
  eq(sessions._format_task_input_for_test("hello", { bracketed_paste = false }), "hello\r")
  eq(sessions._format_task_input_for_test("hello", { bracketed_paste = false, submit = true }), "hello\r")
  eq(sessions._format_task_input_for_test("hello", { bracketed_paste = false, submit = "newline" }), "hello\n")
  eq(sessions._format_task_input_for_test("hello", { bracketed_paste = false, submit = false }), "hello")
end)

test("captures git root and cursor target", function()
  local root, file = temp_project()
  vim.cmd.edit(file)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })

  local captured = target.capture()
  eq(captured.root, root)
  eq(captured.path, "lua/example.lua")
  eq(captured.start_line, 3)
  eq(captured.end_line, 3)
end)

test("captures command range target", function()
  local root, file = temp_project()
  vim.cmd.edit(file)

  local captured = target.capture({ range = 2, line1 = 2, line2 = 4 })
  eq(captured.root, root)
  eq(captured.path, "lua/example.lua")
  eq(captured.start_line, 2)
  eq(captured.end_line, 4)
end)

test("builds task skeleton and extracts description", function()
  local captured = {
    path = "lua/example.lua",
    start_line = 10,
    end_line = 20,
  }

  eq(task_editor.skeleton(captured), table.concat({
    "File: lua/example.lua",
    "Range: lines 10-20",
    "Task: ",
  }, "\n"))

  eq(task_editor.description_from_prompt("File: x\nRange: line 1\nTask: Fix the parser", captured), "Fix the parser")
  eq(task_editor.description_from_prompt("File: x\nRange: line 1\nTask:\nFix the parser", captured), "Fix the parser")
  eq(task_editor.description_from_prompt("Task:\nFix the parser\n\nContext:\nFile: x", captured), "Fix the parser")
  eq(task_editor.description_from_prompt("Task:\n\nContext:\nFile: x", captured), "lua/example.lua:lines 10-20")
end)

test("orders sessions by recency and deletes exited sessions", function()
  sessions._reset_for_test()
  local older = sessions._record_for_test({ agent_name = "a", description = "older" })
  vim.wait(2)
  local newer = sessions._record_for_test({ agent_name = "b", description = "newer" })

  local list = sessions.list()
  eq(list[1].id, newer.id)
  eq(list[2].id, older.id)

  ok(sessions.delete(older, { confirm = false }))
  eq(#sessions.list(), 1)
end)

test("delay readiness preserves delay-only scheduling", function()
  sessions._reset_for_test()
  local capture = vim.fn.tempname()
  local script = write_script({
    "#!/usr/bin/env bash",
    "capture=\"$1\"",
    "if IFS= read -r -t 1 line; then",
    "  printf '%s\\n' \"$line\" > \"$capture\"",
    "else",
    "  printf '__NO_INPUT__\\n' > \"$capture\"",
    "fi",
  })

  sessions.start({
    name = "fake",
    label = "fake",
    cmd = "bash",
    args = { script, capture },
    send = {
      ready = "delay",
      delay_ms = 0,
      bracketed_paste = false,
      submit = true,
    },
  }, "delay prompt", basic_target(), "delay prompt")

  eq(wait_for_file(capture, 1500), "delay prompt")
  sessions._reset_for_test()
end)

test("output-idle readiness waits for terminal UI before sending", function()
  sessions._reset_for_test()
  local prompt = "ready prompt"
  local script = write_script({
    "#!/usr/bin/env bash",
    "capture=\"$1\"",
    "if IFS= read -r -t 0.2 early; then",
    "  :",
    "fi",
    "printf 'READY FRAME\\n'",
    "if IFS= read -r -t 1 line; then",
    "  printf '%s\\n' \"$line\" > \"$capture\"",
    "else",
    "  printf '__NO_INPUT__\\n' > \"$capture\"",
    "fi",
  })

  local early_capture = vim.fn.tempname()
  sessions.start({
    name = "fake",
    label = "fake",
    cmd = "bash",
    args = { script, early_capture },
    send = {
      ready = "delay",
      delay_ms = 0,
      bracketed_paste = false,
      submit = true,
    },
  }, prompt, basic_target(), prompt)

  eq(wait_for_file(early_capture, 2000), "__NO_INPUT__")
  sessions._reset_for_test()

  local ready_capture = vim.fn.tempname()
  sessions.start({
    name = "fake",
    label = "fake",
    cmd = "bash",
    args = { script, ready_capture },
    send = {
      ready = "output-idle",
      ready_idle_ms = 50,
      ready_timeout_ms = 1000,
      delay_ms = 0,
      bracketed_paste = false,
      submit = true,
    },
  }, prompt, basic_target(), prompt)

  eq(wait_for_file(ready_capture, 2000), prompt)
  sessions._reset_for_test()
end)

test("manual send resends stored task immediately", function()
  sessions._reset_for_test()
  local capture = vim.fn.tempname()
  local script = write_script({
    "#!/usr/bin/env bash",
    "capture=\"$1\"",
    "if IFS= read -r -t 1 line; then",
    "  printf '%s\\n' \"$line\" > \"$capture\"",
    "else",
    "  printf '__NO_INPUT__\\n' > \"$capture\"",
    "fi",
  })

  local session = sessions.start({
    name = "fake",
    label = "fake",
    cmd = "bash",
    args = { script, capture },
    send = {
      ready = "delay",
      delay_ms = 10000,
      bracketed_paste = false,
      submit = true,
    },
  }, "manual prompt", basic_target(), "manual prompt")

  ok(agents.send(session.id), "manual send should succeed")
  eq(wait_for_file(capture, 1500), "manual prompt")
  sessions._reset_for_test()
end)

test("manual send notifies when unavailable", function()
  sessions._reset_for_test()
  local notifications = {}
  local old_notify = vim.notify
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end

  ok(not agents.send(), "send without current session should fail")

  local session = sessions._record_for_test({
    agent_name = "fake",
    status = "running",
    job_id = 123,
    task_prompt = nil,
  })
  ok(not agents.send(session), "send without stored task should fail")

  vim.notify = old_notify
  eq(notifications[1].message, "No current agent session to send to")
  eq(notifications[2].message, "Agent session #" .. session.id .. " has no stored task to send")
  sessions._reset_for_test()
end)

test("snaps from float to each split direction without replacing buffer or job", function()
  local session, editor_win = start_sleep_session()
  local bufnr = session.bufnr
  local job_id = session.job_id

  local cases = {
    { direction = "left" },
    { direction = "right" },
    { direction = "down" },
    { direction = "up" },
  }

  for _, case in ipairs(cases) do
    ok(sessions._snap_for_test(session, "float"), "float restore should succeed")
    ok(is_float(session.winid), "session should be floating before split snap")
    ok(sessions._snap_for_test(session, case.direction), "split snap should succeed")
    eq(session.bufnr, bufnr)
    eq(session.job_id, job_id)
    eq(session.placement, { kind = "split", direction = case.direction })
    assert_split_direction(session, editor_win, case.direction)
  end

  sessions._reset_for_test()
end)

test("new centered session floats show the normal hint footer when supported", function()
  local session = start_sleep_session()

  ok(is_float(session.winid), "session should open as a centered float")
  assert_float_footer(session.winid, FLOAT_FOOTER)

  sessions._reset_for_test()
end)

test("centered session float footer tracks terminal mode when supported", function()
  local session = start_sleep_session()

  ok(is_float(session.winid), "session should open as a centered float")
  assert_float_footer(session.winid, FLOAT_FOOTER)

  exec_terminal_mode_autocmd(session, "TermEnter", "t")
  assert_float_footer(session.winid, TERMINAL_FOOTER)

  exec_terminal_mode_autocmd(session, "TermLeave", "nt")
  assert_float_footer(session.winid, FLOAT_FOOTER)

  sessions._reset_for_test()
end)

test("snap mode updates centered float footers when supported", function()
  local session = start_sleep_session()

  vim.api.nvim_set_current_win(session.winid)
  ok(sessions._enter_snap_mode_for_test(session), "snap mode should start")
  assert_float_footer(session.winid, SNAP_FOOTER)

  feed_normal("q")
  ok(not sessions._snap_mode_active_for_test(session), "snap mode should exit")
  assert_float_footer(session.winid, FLOAT_FOOTER)

  sessions._reset_for_test()
end)

test("defines the default Session Hint Line highlight", function()
  local highlight = vim.api.nvim_get_hl(0, { name = "AgentsSessionHint", link = true })
  eq(highlight.link, "Comment")
end)

test("snap mode f restores a centered float", function()
  local session = start_sleep_session()
  ok(sessions._snap_for_test(session, "left"))
  ok(not is_float(session.winid), "session should start snapped")

  vim.api.nvim_set_current_win(session.winid)
  feed_normal("s")
  ok(sessions._snap_mode_active_for_test(session), "snap mode should be active")
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, SNAP_HINT)
  local session_hint_win = session.hint_winid
  feed_normal("f")

  ok(is_float(session.winid), "session should return to a float")
  eq(session.placement, { kind = "float" })
  assert_no_session_hint_line(session, session_hint_win)
  assert_float_footer(session.winid, FLOAT_FOOTER)

  local win_config = vim.api.nvim_win_get_config(session.winid)
  local ui = config.get().ui
  local expected = util.centered_float_config({
    width = ui.width,
    height = ui.height,
    border = ui.border,
  })
  eq(win_config.row, expected.row)
  eq(win_config.col, expected.col)

  sessions._reset_for_test()
end)

test("entering snap mode does not echo the snap hint", function()
  local session = start_sleep_session()
  ok(sessions._snap_for_test(session, "left"))

  local old_echo = vim.api.nvim_echo
  local echoes = {}
  local success, err = pcall(function()
    vim.api.nvim_echo = function(chunks, history, opts)
      echoes[#echoes + 1] = { chunks = chunks, history = history, opts = opts }
    end

    ok(sessions._enter_snap_mode_for_test(session), "snap mode should start")
  end)

  vim.api.nvim_echo = old_echo
  if not success then
    error(err, 0)
  end

  eq(#echoes, 0)
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, SNAP_HINT)

  sessions._reset_for_test()
end)

test("snapped Session Hint Line remains visible when statuslines are disabled", function()
  local old_laststatus = vim.o.laststatus
  vim.o.laststatus = 0
  local success, err = pcall(function()
    local session, editor_win = start_sleep_session()

    ok(sessions._snap_for_test(session, "right"))
    assert_split_direction(session, editor_win, "right")

    sessions._reset_for_test()
  end)
  vim.o.laststatus = old_laststatus
  if not success then
    error(err, 0)
  end
end)

test("snapped Session Hint Line ignores global winborder", function()
  local ok_winborder, old_winborder = pcall(function()
    return vim.o.winborder
  end)
  if not ok_winborder then
    return
  end

  vim.o.winborder = "rounded"
  local success, err = pcall(function()
    local session = start_sleep_session()

    ok(sessions._snap_for_test(session, "right"))
    assert_session_hint_winbar(session, SESSION_HINT)

    sessions._reset_for_test()
  end)
  vim.o.winborder = old_winborder
  if not success then
    error(err, 0)
  end
end)

test("snapped Session Hint Line tracks terminal mode", function()
  local session = start_sleep_session()

  ok(sessions._snap_for_test(session, "right"))
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, SESSION_HINT)

  exec_terminal_mode_autocmd(session, "TermEnter", "t")
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, TERMINAL_HINT)

  exec_terminal_mode_autocmd(session, "TermLeave", "nt")
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, SESSION_HINT)

  sessions._reset_for_test()
end)

test("hide and show restore remembered split placement", function()
  local session, editor_win = start_sleep_session()
  local bufnr = session.bufnr
  local job_id = session.job_id

  ok(sessions._snap_for_test(session, "right"))
  assert_split_direction(session, editor_win, "right")
  ok(sessions.hide(session), "hide should close the visible split")
  eq(session.winid, nil)

  ok(sessions.show(session), "show should restore the session")
  eq(session.bufnr, bufnr)
  eq(session.job_id, job_id)
  eq(session.placement, { kind = "split", direction = "right" })
  assert_split_direction(session, editor_win, "right")

  sessions._reset_for_test()
end)

test("floating a snapped session works when it is the only normal window", function()
  local session = start_sleep_session()
  local bufnr = session.bufnr
  local job_id = session.job_id

  ok(sessions._snap_for_test(session, "left"))
  local split_win = session.winid
  local session_hint_win = session.hint_winid
  vim.api.nvim_set_current_win(session.winid)
  vim.cmd("silent! only")

  ok(sessions._snap_for_test(session, "float"))
  ok(vim.api.nvim_win_is_valid(split_win), "old split window should be reused as an anchor")
  assert_no_session_hint_line(session, session_hint_win)
  assert_no_session_hint_statusline(split_win)
  assert_no_session_hint_winbar(split_win)
  ok(is_float(session.winid), "session should restore to a float")
  eq(session.placement, { kind = "float" })
  eq(session.bufnr, bufnr)
  eq(session.job_id, job_id)
  assert_float_footer(session.winid, FLOAT_FOOTER)

  sessions._reset_for_test()
end)

test("exited sessions can be snapped", function()
  local editor_win = reset_editor_window()
  local session = sessions.start({
    name = "sh",
    label = "sh",
    cmd = "sh",
    args = { "-c", "exit 0" },
    send = { ready = "delay", delay_ms = 0, bracketed_paste = false, submit = false },
  }, "", basic_target(), "exited snap")

  ok(vim.wait(1000, function()
    return session.status == "exited"
  end), "session should exit")

  ok(sessions._snap_for_test(session, "down"))
  eq(session.status, "exited")
  assert_split_direction(session, editor_win, "down")

  sessions._reset_for_test()
end)

test("picker buffers do not receive snap mappings", function()
  reset_editor_window()
  local picker = sessions.open_picker()
  local maps = vim.api.nvim_buf_get_keymap(picker.bufnr, "n")

  for _, map in ipairs(maps) do
    ok(map.lhs ~= "s", "picker should not map snap entry")
    ok(map.lhs ~= "h", "picker should not map snap left")
    ok(map.lhs ~= "j", "picker should not map snap down")
    ok(map.lhs ~= "k", "picker should not map snap up")
    ok(map.lhs ~= "l", "picker should not map snap right")
    ok(map.lhs ~= "f", "picker should not map float snap")
  end

  picker.close()
end)

test("snap-mode cancel leaves placement unchanged", function()
  local session = start_sleep_session()
  ok(sessions._snap_for_test(session, "left"))
  local placement = vim.deepcopy(session.placement)

  vim.api.nvim_set_current_win(session.winid)
  ok(sessions._enter_snap_mode_for_test(session), "snap mode should start")
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, SNAP_HINT)
  feed_normal("q")

  eq(session.placement, placement)
  ok(vim.api.nvim_win_is_valid(session.winid), "cancel should not hide the session")
  ok(not sessions._snap_mode_active_for_test(session), "snap mode should exit")
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_winbar(session, SESSION_HINT)

  sessions._reset_for_test()
end)

test("opens task editor and pickers in headless Neovim", function()
  local editor = task_editor.open({
    target = { path = "x.lua", start_line = 1, end_line = 1 },
    on_submit = function() end,
  })
  ok(vim.api.nvim_win_is_valid(editor.winid))
  assert_no_session_hint_statusline(editor.winid)
  eq(vim.api.nvim_win_get_cursor(editor.winid), { 3, 5 })
  editor.cancel()

  local picker = sessions.open_picker()
  ok(vim.api.nvim_win_is_valid(picker.winid))
  assert_no_session_hint_statusline(picker.winid)
  picker.close()
end)

test("agent picker preserves the invoking target", function()
  with_launch_command_store(nil, function()
    sessions._reset_for_test()
    agents.setup({
      agents = {
        ztest = { cmd = "sh" },
      },
    })

    local _, file = temp_project()
    vim.cmd.edit(file)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    local agent_picker = agents.launch()
    ok(agent_picker and vim.api.nvim_win_is_valid(agent_picker.winid))
    agent_picker.select()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    eq(lines[1], "File: lua/example.lua")
    eq(lines[2], "Range: line 4")
    eq(lines[3], "Task: ")
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
  end)
end)

test("agent picker can edit a one-shot startup command", function()
  with_launch_command_store(nil, function()
    sessions._reset_for_test()
    agents.setup({
      agents = {
        alpha = { cmd = "alpha", args = { "--base" } },
        beta = { cmd = "beta" },
      },
    })

    local started = {}
    local old_task_open = task_editor.open
    local old_sessions_start = sessions.start

    task_editor.open = function(opts)
      opts.on_submit("Task: edited")
      return { bufnr = 0, winid = 0 }
    end

    sessions.start = function(agent)
      started[#started + 1] = agent
    end

    local function restore()
      task_editor.open = old_task_open
      sessions.start = old_sessions_start
    end

    local success, err = pcall(function()
      local agent_picker = agents.launch(nil, { target = basic_target() })
      ok(agent_picker and vim.api.nvim_win_is_valid(agent_picker.winid))
      assert_float_footer(
        agent_picker.winid,
        " <CR> launch  i edit CLI cmd  o add CLI cmd  t test  d delete  q/<Esc> close "
      )
      local lines = vim.api.nvim_buf_get_lines(agent_picker.bufnr, 0, 2, false)
      eq(lines[1], "alpha --base")
      eq(lines[2], "beta")
      local maps = vim.api.nvim_buf_get_keymap(agent_picker.bufnr, "n")
      local has_edit_map = false
      for _, map in ipairs(maps) do
        if map.lhs == "i" then
          has_edit_map = true
        end
      end
      ok(has_edit_map, "agent picker should map i to edit the startup command")

      vim.api.nvim_set_current_win(agent_picker.winid)
      vim.api.nvim_exec_autocmds("InsertEnter", { buffer = agent_picker.bufnr })
      assert_float_footer(agent_picker.winid, " INSERT edit CLI cmd  <Esc> normal ")
      vim.api.nvim_exec_autocmds("InsertLeave", { buffer = agent_picker.bufnr })
      assert_float_footer(
        agent_picker.winid,
        " <CR> launch  i edit CLI cmd  o add CLI cmd  t test  d delete  q/<Esc> close "
      )

      agent_picker.select()

      eq(started[1].name, "alpha")
      eq(started[1].cmd, "alpha")
      eq(started[1].args, { "--base" })

      agent_picker = agents.launch(nil, { target = basic_target() })
      vim.bo[agent_picker.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(agent_picker.bufnr, 0, 1, false, { 'beta --model "gpt 5"' })
      vim.bo[agent_picker.bufnr].modifiable = false
      agent_picker.select()

      eq(started[2].name, "alpha")
      eq(started[2].cmd, "beta")
      eq(started[2].args, { "--model", "gpt 5" })

      agent_picker = agents.launch(nil, { target = basic_target() })
      vim.bo[agent_picker.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(agent_picker.bufnr, 0, 1, false, { "--extra" })
      vim.bo[agent_picker.bufnr].modifiable = false
      agent_picker.select()

      eq(started[3].name, "alpha")
      eq(started[3].cmd, "alpha")
      eq(started[3].args, { "--base", "--extra" })
    end)

    restore()
    if not success then
      error(err, 0)
    end

    sessions._reset_for_test()
  end)
end)

test("launch picker persists added Launch Commands and reloads them", function()
  with_launch_command_store(nil, function(path)
    agents.setup({
      agents = {
        alpha = { cmd = "alpha" },
        beta = { cmd = "beta" },
        claude = false,
        codex = false,
      },
    })

    local active_picker = agents.launch(nil, { target = basic_target() })
    ok(active_picker and vim.api.nvim_win_is_valid(active_picker.winid))

    local maps = vim.api.nvim_buf_get_keymap(active_picker.bufnr, "n")
    local mapped = {}
    for _, map in ipairs(maps) do
      mapped[map.lhs] = true
    end
    ok(mapped.o, "launch picker should map o to add a Launch Command")
    ok(mapped.t, "launch picker should map t to smoke-test a row")
    ok(mapped.d, "launch picker should map d to delete Launch Commands")

    active_picker.add()
    local lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines[1], "alpha")
    eq(lines[2], "beta")
    eq(lines[3], "")

    set_picker_line_and_leave_insert(active_picker, 3, "sh -c 'exit 0'")
    eq(read_json_file(path), { "sh -c 'exit 0'" })
    active_picker.close()

    active_picker = agents.launch(nil, { target = basic_target() })
    lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines[1], "alpha")
    eq(lines[2], "beta")
    eq(lines[3], "sh -c 'exit 0'")
    active_picker.close()
  end)
end)

test("blank and unparsable Launch Command edits are not persisted", function()
  with_launch_command_store(nil, function(path)
    agents.setup({
      agents = {
        alpha = { cmd = "alpha" },
        claude = false,
        codex = false,
      },
    })

    local active_picker = agents.launch(nil, { target = basic_target() })
    active_picker.add()
    set_picker_line_and_leave_insert(active_picker, 2, "")
    local lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines, { "alpha" })
    eq(read_json_file(path), nil)

    active_picker.add()
    local notifications = capture_notifications(function()
      set_picker_line_and_leave_insert(active_picker, 2, 'sh -c "unterminated')
    end)

    lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines, { "alpha", 'sh -c "unterminated' })
    eq(read_json_file(path), nil)
    eq(notifications[1].message, "Unclosed quote in agent command")
    active_picker.close()
  end)
end)

test("malformed Launch Command storage notifies and continues empty", function()
  with_launch_command_store(nil, function(path)
    vim.fn.writefile({ "{not json" }, path)
    agents.setup({
      agents = {
        alpha = { cmd = "alpha" },
        claude = false,
        codex = false,
      },
    })

    local active_picker
    local notifications = capture_notifications(function()
      active_picker = agents.launch(nil, { target = basic_target() })
    end)

    local lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines, { "alpha" })
    ok(notifications[1].message:find("Could not parse Launch Commands", 1, true))
    active_picker.close()
  end)
end)

test("Launch Commands delete and storage normalization keep only unique non-agent commands", function()
  with_launch_command_store({ "alpha --base", "sh -c 'exit 0'", "sh -c 'exit 0'" }, function(path)
    agents.setup({
      agents = {
        alpha = { cmd = "alpha", args = { "--base" } },
        claude = false,
        codex = false,
      },
    })

    local active_picker = agents.launch(nil, { target = basic_target() })
    local lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines, { "alpha --base", "sh -c 'exit 0'" })
    eq(read_json_file(path), { "sh -c 'exit 0'" })

    vim.api.nvim_set_current_win(active_picker.winid)
    vim.api.nvim_win_set_cursor(active_picker.winid, { 1, 0 })
    ok(not active_picker.delete(), "configured Agent rows should not be deletable")
    lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines, { "alpha --base", "sh -c 'exit 0'" })

    vim.api.nvim_win_set_cursor(active_picker.winid, { 2, 0 })
    ok(active_picker.delete(), "Launch Command rows should delete immediately")
    lines = vim.api.nvim_buf_get_lines(active_picker.bufnr, 0, -1, false)
    eq(lines, { "alpha --base" })
    eq(read_json_file(path), {})
    active_picker.close()
  end)
end)

test("saved Launch Commands launch full commands and inherit matching Agent settings", function()
  with_launch_command_store({ 'alpha --child "two words"', 'tool --flag "quoted value"' }, function()
    sessions._reset_for_test()
    agents.setup({
      send = {
        ready = "delay",
        delay_ms = 7,
        bracketed_paste = false,
        submit = false,
      },
      agents = {
        alpha = {
          cmd = "alpha",
          args = { "--base" },
          cwd = "/tmp/alpha-root",
          env = { ALPHA = "1" },
          send = {
            delay_ms = 42,
            submit = true,
          },
        },
        claude = false,
        codex = false,
      },
    })

    local started = {}
    local old_task_open = task_editor.open
    local old_sessions_start = sessions.start

    task_editor.open = function(opts)
      opts.on_submit("Task: saved")
      return { bufnr = 0, winid = 0 }
    end
    sessions.start = function(agent)
      started[#started + 1] = agent
    end

    local function restore()
      task_editor.open = old_task_open
      sessions.start = old_sessions_start
    end

    local success, err = pcall(function()
      local active_picker = agents.launch(nil, { target = basic_target() })
      vim.api.nvim_set_current_win(active_picker.winid)
      vim.api.nvim_win_set_cursor(active_picker.winid, { 2, 0 })
      active_picker.select()

      eq(started[1].name, "alpha")
      eq(started[1].cmd, "alpha")
      eq(started[1].args, { "--child", "two words" })
      eq(started[1].cwd, "/tmp/alpha-root")
      eq(started[1].env, { ALPHA = "1" })
      eq(started[1].send.delay_ms, 42)
      eq(started[1].send.submit, true)

      active_picker = agents.launch(nil, { target = basic_target() })
      vim.api.nvim_set_current_win(active_picker.winid)
      vim.api.nvim_win_set_cursor(active_picker.winid, { 3, 0 })
      active_picker.select()

      eq(started[2].name, "tool")
      eq(started[2].cmd, "tool")
      eq(started[2].args, { "--flag", "quoted value" })
      eq(started[2].send.delay_ms, 7)
      eq(started[2].send.submit, false)
    end)

    restore()
    if not success then
      error(err, 0)
    end

    sessions._reset_for_test()
  end)
end)

test("command completion remains scoped to configured Agent names", function()
  with_launch_command_store({ "tool --from-store" }, function()
    agents.setup({
      agents = {
        alpha = { cmd = "alpha" },
        claude = false,
        codex = false,
      },
    })

    eq(commands.complete("t", "Agents launch t"), {})
    eq(commands.complete("a", "Agents launch a"), { "alpha" })
  end)
end)

test("Launch Command smoke tests report pass and failure without opening sessions", function()
  with_launch_command_store({
    "sh -c 'printf ok'",
    "sh -c 'sleep 5'",
    "sh -c 'test -t 0'",
    "sh -c 'exit 9'",
    "missing-agents-nvim-bin",
  }, function()
    agents.setup({
      agents = {
        alpha = { cmd = "sh", args = { "-c", "exit 0" } },
        claude = false,
        codex = false,
      },
    })

    local old_task_open = task_editor.open
    local old_sessions_start = sessions.start
    task_editor.open = function()
      error("smoke test should not open the task editor")
    end
    sessions.start = function()
      error("smoke test should not start an Agent Session")
    end

    local function restore()
      task_editor.open = old_task_open
      sessions.start = old_sessions_start
    end

    local success, err = pcall(function()
      local active_picker = agents.launch(nil, { target = basic_target() })
      local function assert_picker_current()
        ok(vim.api.nvim_win_is_valid(active_picker.winid), "picker window should remain valid")
        ok(vim.api.nvim_buf_is_valid(active_picker.bufnr), "picker buffer should remain valid")
        eq(vim.api.nvim_get_current_win(), active_picker.winid, "picker window should remain current")
        eq(vim.api.nvim_win_get_buf(active_picker.winid), active_picker.bufnr, "picker buffer should remain visible")
      end

      local notifications = capture_notifications(function(items)
        vim.api.nvim_set_current_win(active_picker.winid)

        vim.api.nvim_win_set_cursor(active_picker.winid, { 1, 0 })
        ok(active_picker.test(), "configured Agent smoke test should pass")
        assert_picker_current()

        vim.api.nvim_win_set_cursor(active_picker.winid, { 2, 0 })
        ok(active_picker.test(), "quick exit 0 should pass")
        assert_picker_current()

        vim.api.nvim_win_set_cursor(active_picker.winid, { 3, 0 })
        ok(active_picker.test(), "long-running command should pass")
        assert_picker_current()

        vim.api.nvim_win_set_cursor(active_picker.winid, { 4, 0 })
        ok(active_picker.test(), "TTY-sensitive command should pass")
        assert_picker_current()

        vim.api.nvim_win_set_cursor(active_picker.winid, { 5, 0 })
        ok(not active_picker.test(), "nonzero command should fail")
        assert_picker_current()

        vim.api.nvim_win_set_cursor(active_picker.winid, { 6, 0 })
        ok(not active_picker.test(), "missing executable should fail")
        assert_picker_current()

        active_picker.add()
        set_picker_line_and_leave_insert(active_picker, 7, 'sh -c "unterminated')
        vim.api.nvim_win_set_cursor(active_picker.winid, { 7, 0 })
        ok(not active_picker.test(), "parse error should fail")
        assert_picker_current()

        ok(#items >= 7, "smoke tests should report notifications")
      end)

      ok(notifications[1].message:find("passed", 1, true), "Agent smoke test should report pass")
      ok(notifications[2].message:find("passed", 1, true), "quick command should report pass")
      ok(notifications[3].message:find("passed", 1, true), "long command should report pass")
      ok(notifications[4].message:find("passed", 1, true), "TTY-sensitive command should report pass")
      ok(notifications[5].message:find("failed", 1, true), "nonzero command should report failure")
      ok(notifications[6].message:find("failed", 1, true), "missing executable should report failure")
      ok(notifications[#notifications].message:find("Unclosed quote", 1, true), "parse error should be reported")
      active_picker.close()
    end)

    restore()
    if not success then
      error(err, 0)
    end
  end)
end)

test("notifies when a hidden session exits", function()
  sessions._reset_for_test()

  local notifications = {}
  local old_notify = vim.notify
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end

  local session = sessions.start({
    name = "sh",
    label = "sh",
    cmd = "sh",
    args = { "-c", "sleep 0.05" },
    send = { delay_ms = 0, bracketed_paste = false, submit = false },
  }, "", {
    root = vim.fn.getcwd(),
    path = "x.lua",
    start_line = 1,
    end_line = 1,
  }, "short job")

  ok(session.job_id and session.job_id > 0, "session job should start")
  ok(sessions.hide(session), "session should hide")
  ok(vim.wait(1000, function()
    return session.status == "exited" and #notifications > 0
  end), "hidden session exit notification should arrive")

  vim.notify = old_notify
  sessions._reset_for_test()
end)

local failures = {}
for _, entry in ipairs(tests) do
  local success, err = pcall(entry.fn)
  if success then
    print("ok - " .. entry.name)
  else
    failures[#failures + 1] = entry.name .. "\n" .. err
    print("not ok - " .. entry.name)
    print(err)
  end
end

if #failures > 0 then
  error(table.concat(failures, "\n\n"))
end

print(string.format("%d tests passed", #tests))
