local commands = require("agents.commands")
local config = require("agents.config")
local launch_commands = require("agents.launch_commands")
local picker = require("agents.picker")
local sessions = require("agents.sessions")
local target = require("agents.target")
local task_editor = require("agents.task_editor")
local util = require("agents.util")

local M = {}

local keymaps_installed = false

local SMOKE_TEST_TIMEOUT_MS = 1000

local function quote_argv_part(value)
  value = tostring(value or "")
  if value == "" then
    return "''"
  end

  if not value:find("[%s'\"\\]") then
    return value
  end

  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function argv_for_agent(agent)
  local argv = { agent.cmd or agent.command or agent.name }
  for _, arg in ipairs(agent.args or {}) do
    argv[#argv + 1] = arg
  end

  return argv
end

local function format_command(agent)
  local parts = {}
  for index, part in ipairs(argv_for_agent(agent)) do
    parts[index] = quote_argv_part(part)
  end

  return table.concat(parts, " ")
end

local function split_command_line(line)
  line = util.trim(line)
  if line == "" then
    return {}
  end

  local argv = {}
  local current = {}
  local quoted
  local escaped = false
  local started = false

  for index = 1, #line do
    local char = line:sub(index, index)

    if escaped then
      current[#current + 1] = char
      escaped = false
      started = true
    elseif char == "\\" then
      escaped = true
      started = true
    elseif quoted then
      if char == quoted then
        quoted = nil
      else
        current[#current + 1] = char
      end
      started = true
    elseif char == "'" or char == '"' then
      quoted = char
      started = true
    elseif char:match("%s") then
      if started then
        argv[#argv + 1] = table.concat(current)
        current = {}
        started = false
      end
    else
      current[#current + 1] = char
      started = true
    end
  end

  if escaped then
    current[#current + 1] = "\\"
  end

  if quoted then
    return nil, "Unclosed quote in agent command"
  end

  if started then
    argv[#argv + 1] = table.concat(current)
  end

  return argv
end

local function copy_agent_with_argv(agent, argv)
  if #argv == 0 then
    return agent
  end

  local copy = vim.deepcopy(agent)
  copy.cmd = argv[1]
  copy.command = argv[1]
  copy.args = {}

  for index = 2, #argv do
    copy.args[#copy.args + 1] = argv[index]
  end

  return copy
end

local function argv_args(argv)
  local args = {}
  for index = 2, #argv do
    args[#args + 1] = argv[index]
  end

  return args
end

local function agent_from_picker_line(default_agent, line)
  line = util.trim(line or "")
  if line == "" then
    return nil, "Edited agent line is empty"
  end

  local argv, err = split_command_line(line)
  if not argv then
    return nil, err
  end

  if #argv == 0 then
    return default_agent
  end

  if argv[1]:sub(1, 1) == "-" then
    local base_argv = { default_agent.cmd or default_agent.command or default_agent.name }
    for _, arg in ipairs(default_agent.args or {}) do
      base_argv[#base_argv + 1] = arg
    end
    for _, arg in ipairs(argv) do
      base_argv[#base_argv + 1] = arg
    end
    argv = base_argv
  end

  return copy_agent_with_argv(default_agent, argv)
end

local function full_command_argv(line)
  line = util.trim(line or "")
  if line == "" then
    return nil, "Launch Command is empty"
  end

  local argv, err = split_command_line(line)
  if not argv then
    return nil, err
  end

  if #argv == 0 or argv[1]:sub(1, 1) == "-" then
    return nil, "Launch Command must start with a command"
  end

  return argv
end

local function is_valid_launch_command(line)
  return full_command_argv(line) ~= nil
end

local function configured_command_map(agents)
  local commands_by_line = {}
  for _, agent in ipairs(agents) do
    commands_by_line[format_command(agent)] = true
  end

  return commands_by_line
end

local function matching_agent_for_argv(argv, agents)
  local command = argv[1]
  for _, agent in ipairs(agents) do
    if command == agent.name or command == agent.cmd or command == agent.command then
      return agent
    end
  end

  return nil
end

local function agent_from_launch_command_line(line, agents)
  local argv, err = full_command_argv(line)
  if not argv then
    return nil, err
  end

  local matching_agent = matching_agent_for_argv(argv, agents)
  if matching_agent then
    return copy_agent_with_argv(matching_agent, argv)
  end

  local cfg = config.get()
  return {
    name = argv[1],
    label = argv[1],
    cmd = argv[1],
    command = argv[1],
    args = argv_args(argv),
    send = vim.deepcopy(cfg.send),
  }
end

local function agent_from_picker_row(row, line, agents)
  if row.kind == "agent" then
    return agent_from_picker_line(row.agent, line)
  end

  return agent_from_launch_command_line(line, agents)
end

local function launch_command_rows(commands_to_load)
  local rows = {}
  for _, command in ipairs(commands_to_load) do
    rows[#rows + 1] = {
      kind = "launch_command",
      command = command,
      persisted = true,
    }
  end

  return rows
end

local function launch_command_strings(rows, configured_commands)
  local commands_to_save = {}
  local seen = {}

  for _, row in ipairs(rows) do
    if row.kind == "launch_command" then
      local command = util.trim(row.command or "")
      if command ~= ""
        and is_valid_launch_command(command)
        and not configured_commands[command]
        and not seen[command]
      then
        commands_to_save[#commands_to_save + 1] = command
        seen[command] = true
      end
    end
  end

  return commands_to_save
end

local function persist_launch_command_rows(rows, configured_commands)
  local commands_to_save = launch_command_strings(rows, configured_commands)
  local command_set = {}
  for _, command in ipairs(commands_to_save) do
    command_set[command] = true
  end

  local filtered_rows = {}
  for _, row in ipairs(rows) do
    if row.kind == "launch_command" then
      local command = util.trim(row.command or "")
      if command_set[command] then
        row.command = command
        row.persisted = true
        filtered_rows[#filtered_rows + 1] = row
        command_set[command] = nil
      elseif command ~= "" and not is_valid_launch_command(command) then
        row.persisted = false
        filtered_rows[#filtered_rows + 1] = row
      end
    end
  end

  launch_commands.save(commands_to_save)
  return filtered_rows
end

local function smoke_test_agent(agent, launch_opts)
  local argv = argv_for_agent(agent)
  local root = launch_opts.target and launch_opts.target.root or vim.fn.getcwd()
  local scratch_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch_bufnr].bufhidden = "wipe"
  vim.bo[scratch_bufnr].swapfile = false

  local function cleanup()
    if vim.api.nvim_buf_is_valid(scratch_bufnr) then
      pcall(vim.api.nvim_buf_delete, scratch_bufnr, { force = true })
    end
  end

  local ok_start, job_id = pcall(vim.api.nvim_buf_call, scratch_bufnr, function()
    return vim.fn.jobstart(argv, {
      term = true,
      cwd = agent.cwd or root,
      env = agent.env,
    })
  end)

  if not ok_start or not job_id or job_id <= 0 then
    cleanup()
    util.notify("Launch Command test failed: could not start " .. tostring(argv[1]), vim.log.levels.ERROR)
    return false
  end

  local status = vim.fn.jobwait({ job_id }, SMOKE_TEST_TIMEOUT_MS)[1]
  if status == -1 then
    pcall(vim.fn.jobstop, job_id)
    cleanup()
    util.notify("Launch Command test passed: command stayed running")
    return true
  end

  if status == 0 then
    cleanup()
    util.notify("Launch Command test passed: command exited 0")
    return true
  end

  cleanup()
  util.notify("Launch Command test failed: command exited " .. tostring(status), vim.log.levels.ERROR)
  return false
end

local function submit_launch(agent, launch_opts)
  local captured_target = launch_opts.target or target.capture(launch_opts)
  local prompt = task_editor.skeleton(captured_target)

  task_editor.open({
    target = captured_target,
    prompt = prompt,
    config = config.get().task_editor,
    on_submit = function(edited_prompt)
      local description = task_editor.description_from_prompt(edited_prompt, captured_target)
      sessions.start(agent, edited_prompt, captured_target, description)
    end,
  })
end

local function open_agent_picker(launch_opts)
  local cfg = config.get().picker
  local agents = config.list_agents()
  local configured_commands = configured_command_map(agents)
  local saved_commands = launch_commands.load({
    configured_commands = configured_commands,
    validate = is_valid_launch_command,
  })
  local launch_rows = launch_command_rows(saved_commands)

  local function build_rows()
    local rows = {}
    for _, agent in ipairs(agents) do
      rows[#rows + 1] = {
        kind = "agent",
        agent = agent,
      }
    end

    for _, row in ipairs(launch_rows) do
      rows[#rows + 1] = row
    end

    return rows
  end

  local function replace_launch_rows(rows)
    launch_rows = rows
  end

  return picker.open({
    title = " Agents ",
    width = cfg.width,
    height = cfg.height,
    border = cfg.border,
    items = build_rows(),
    items_provider = build_rows,
    empty_text = "No agents or Launch Commands",
    editable = true,
    close_before_select = false,
    footer = " <CR> launch  i edit CLI cmd  o add CLI cmd  t test  d delete  q/<Esc> close ",
    insert_footer = " INSERT edit CLI cmd  <Esc> normal ",
    format = function(row)
      if row.kind == "agent" then
        return format_command(row.agent)
      end

      return row.command or ""
    end,
    on_select = function(row, line)
      local selected_agent, err = agent_from_picker_row(row, line, agents)
      if not selected_agent then
        util.notify(err, vim.log.levels.ERROR)
        return false
      end

      submit_launch(selected_agent, launch_opts)
    end,
    on_insert_leave = function(row, line, row_index)
      if row.kind ~= "launch_command" then
        return false
      end

      local command = util.trim(line or "")
      if command == "" then
        for index, launch_row in ipairs(launch_rows) do
          if launch_row == row then
            table.remove(launch_rows, index)
            if row.persisted then
              replace_launch_rows(persist_launch_command_rows(launch_rows, configured_commands))
            end
            return math.min(row_index, #agents + #launch_rows)
          end
        end

        return false
      end

      row.command = command
      local _, err = full_command_argv(command)
      if err then
        row.persisted = false
        util.notify(err, vim.log.levels.ERROR)
        return true
      end

      replace_launch_rows(persist_launch_command_rows(launch_rows, configured_commands))
      return row_index
    end,
    on_add = function()
      launch_rows[#launch_rows + 1] = {
        kind = "launch_command",
        command = "",
        persisted = false,
      }
      return #agents + #launch_rows
    end,
    on_delete = function(row)
      if row.kind ~= "launch_command" then
        return false
      end

      for index, launch_row in ipairs(launch_rows) do
        if launch_row == row then
          table.remove(launch_rows, index)
          replace_launch_rows(persist_launch_command_rows(launch_rows, configured_commands))
          return true
        end
      end

      return false
    end,
    on_test = function(row, line)
      local selected_agent, err = agent_from_picker_row(row, line, agents)
      if not selected_agent then
        util.notify(err, vim.log.levels.ERROR)
        return false
      end

      return smoke_test_agent(selected_agent, launch_opts)
    end,
  })
end

local function install_keymaps()
  if keymaps_installed then
    return
  end

  local cfg = config.get()
  vim.keymap.set("n", cfg.keymaps.launch, function()
    M.launch()
  end, { desc = "Launch agent" })
  vim.keymap.set("n", cfg.keymaps.sessions, function()
    M.sessions()
  end, { desc = "Agent sessions" })

  keymaps_installed = true
end

function M.setup(opts)
  local cfg = config.setup(opts or {})
  commands.ensure()

  if cfg.default_keymaps then
    install_keymaps()
  end

  return cfg
end

function M.launch(name, launch_opts)
  config.get()
  launch_opts = launch_opts or {}

  if not name or name == "" then
    launch_opts = vim.tbl_extend("force", launch_opts, {
      target = launch_opts.target or target.capture(launch_opts),
    })
    return open_agent_picker(launch_opts)
  end

  local agent = config.get_agent(name)
  if not agent then
    util.notify("Unknown agent: " .. name, vim.log.levels.ERROR)
    return nil
  end

  submit_launch(agent, launch_opts)
  return nil
end

function M.sessions()
  return sessions.open_picker()
end

function M.hide()
  if not sessions.hide() then
    util.notify("No current agent session to hide", vim.log.levels.WARN)
  end
end

function M.send(session)
  return sessions.send(session)
end

M._config = config
M._sessions = sessions
M._target = target
M._task_editor = task_editor
M._commands = commands
M._launch_commands = launch_commands

return M
