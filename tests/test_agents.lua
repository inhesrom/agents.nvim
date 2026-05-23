local agents = require("agents")
local config = require("agents.config")
local target = require("agents.target")
local task_editor = require("agents.task_editor")
local sessions = require("agents.sessions")
local commands = require("agents.commands")

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

test("auto-registers built-ins found on PATH", function()
  local cfg = config.resolve({}, function(cmd)
    return cmd == "codex" and 1 or 0
  end)

  ok(cfg.agents.codex, "codex should be registered")
  eq(cfg.agents.claude, nil, "claude should not be registered")
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

  agents.launch = function(name, opts)
    calls[#calls + 1] = { "launch", name, opts.line1, opts.line2 }
  end
  agents.sessions = function()
    calls[#calls + 1] = { "sessions" }
  end
  agents.hide = function()
    calls[#calls + 1] = { "hide" }
  end

  commands.dispatch({ fargs = { "launch", "alpha" }, range = 2, line1 = 3, line2 = 5 })
  commands.dispatch({ fargs = { "sessions" } })
  commands.dispatch({ fargs = { "hide" } })

  agents.launch = old_launch
  agents.sessions = old_sessions
  agents.hide = old_hide

  eq(calls, {
    { "launch", "alpha", 3, 5 },
    { "sessions" },
    { "hide" },
  })
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

test("opens task editor and pickers in headless Neovim", function()
  local editor = task_editor.open({
    target = { path = "x.lua", start_line = 1, end_line = 1 },
    on_submit = function() end,
  })
  ok(vim.api.nvim_win_is_valid(editor.winid))
  editor.cancel()

  local picker = sessions.open_picker()
  ok(vim.api.nvim_win_is_valid(picker.winid))
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
