local agents = require("agents")
local config = require("agents.config")
local target = require("agents.target")
local task_editor = require("agents.task_editor")
local sessions = require("agents.sessions")
local commands = require("agents.commands")
local util = require("agents.util")

local FLOAT_FOOTER = " normal: s snap  q/<Esc> hide "
local SESSION_HINT = "normal: s snap  q/<Esc> hide"
local SNAP_HINT = "snap: h left  j down  k up  l right  f float  q/<Esc> cancel"
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
  ok(value ~= SNAP_HINT, "window should not use the snap-mode session hint statusline")
end

local function centered_hint_line(text, width)
  local text_width = vim.fn.strdisplaywidth(text)
  local padding = math.max(0, math.floor((width - text_width) / 2))
  return string.rep(" ", padding) .. text, padding
end

local function session_hint_line_text(session)
  if not session or not vim.api.nvim_win_is_valid(session.hint_winid or -1) then
    return nil
  end

  local bufnr = vim.api.nvim_win_get_buf(session.hint_winid)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
  return lines[1] or ""
end

local function assert_session_hint_line(session, expected)
  ok(vim.api.nvim_win_is_valid(session.hint_winid or -1), "session should have a Session Hint Line window")
  ok(is_float(session.hint_winid), "Session Hint Line should be an attached floating window")
  local win_config = vim.api.nvim_win_get_config(session.hint_winid)
  eq(win_config.relative, "win")
  eq(win_config.win, session.winid)
  eq(win_config.border, "none")
  eq(win_config.focusable, false)

  local width = vim.api.nvim_win_get_width(session.winid)
  local expected_line, hint_start_col = centered_hint_line(expected, width)
  eq(session_hint_line_text(session), expected_line)
  eq(util.trim(expected_line), expected)

  local winhl = vim.api.nvim_get_option_value("winhighlight", { win = session.hint_winid, scope = "local" })
  ok(not winhl:find("StatusLine", 1, true), "Session Hint Line should not map its background to StatusLine")
  ok(winhl:find("Normal:Normal", 1, true), "Session Hint Line should map Normal to the pane background")
  ok(winhl:find("NormalFloat:Normal", 1, true), "Session Hint Line should map NormalFloat to the pane background")
  ok(winhl:find("EndOfBuffer:Normal", 1, true), "Session Hint Line should map EndOfBuffer to the pane background")

  local bufnr = vim.api.nvim_win_get_buf(session.hint_winid)
  local ns = vim.api.nvim_get_namespaces().agents_session_hint_line
  ok(ns, "Session Hint Line namespace should exist")
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  eq(#marks, 1)
  eq(marks[1][2], 0)
  eq(marks[1][3], hint_start_col)
  eq(marks[1][4].end_col, hint_start_col + #expected)
  eq(marks[1][4].hl_group, "AgentsSessionHint")
end

local function assert_no_session_hint_line(session, winid)
  if winid then
    ok(not vim.api.nvim_win_is_valid(winid), "old Session Hint Line window should be closed")
  end
  if session and session.hint_winid then
    ok(not vim.api.nvim_win_is_valid(session.hint_winid), "session should not keep a Session Hint Line window")
  end
end

local function feed_normal(keys)
  local leave_terminal = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
  vim.api.nvim_feedkeys(leave_terminal, "nx", false)
  vim.api.nvim_feedkeys(keys, "mx", false)
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
  assert_session_hint_line(session, SESSION_HINT)

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
    "Task:",
    "",
    "Context:",
    "File: lua/example.lua",
    "Range: lines 10-20",
  }, "\n"))

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
  assert_session_hint_line(session, SNAP_HINT)
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
  assert_session_hint_line(session, SNAP_HINT)

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
    assert_session_hint_line(session, SESSION_HINT)

    sessions._reset_for_test()
  end)
  vim.o.winborder = old_winborder
  if not success then
    error(err, 0)
  end
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
  assert_session_hint_line(session, SNAP_HINT)
  feed_normal("q")

  eq(session.placement, placement)
  ok(vim.api.nvim_win_is_valid(session.winid), "cancel should not hide the session")
  ok(not sessions._snap_mode_active_for_test(session), "snap mode should exit")
  assert_no_session_hint_statusline(session.winid)
  assert_session_hint_line(session, SESSION_HINT)

  sessions._reset_for_test()
end)

test("opens task editor and pickers in headless Neovim", function()
  local editor = task_editor.open({
    target = { path = "x.lua", start_line = 1, end_line = 1 },
    on_submit = function() end,
  })
  ok(vim.api.nvim_win_is_valid(editor.winid))
  assert_no_session_hint_statusline(editor.winid)
  editor.cancel()

  local picker = sessions.open_picker()
  ok(vim.api.nvim_win_is_valid(picker.winid))
  assert_no_session_hint_statusline(picker.winid)
  picker.close()
end)

test("agent picker preserves the invoking target", function()
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
  eq(lines[4], "File: lua/example.lua")
  eq(lines[5], "Range: line 4")
  vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
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
