local commands = require("agents.commands")
local config = require("agents.config")
local picker = require("agents.picker")
local sessions = require("agents.sessions")
local target = require("agents.target")
local task_editor = require("agents.task_editor")
local util = require("agents.util")

local M = {}

local keymaps_installed = false

local function open_agent_picker(launch_opts)
  local cfg = config.get().picker
  local agents = config.list_agents()

  return picker.open({
    title = " Agents ",
    width = cfg.width,
    height = cfg.height,
    border = cfg.border,
    items = agents,
    empty_text = "No agents configured",
    format = function(agent)
      local command = agent.cmd or agent.command or agent.name
      local args = table.concat(agent.args or {}, " ")
      if args ~= "" then
        command = command .. " " .. args
      end
      return string.format("%-12s %s", agent.name, command)
    end,
    on_select = function(agent)
      M.launch(agent.name, launch_opts)
    end,
  })
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
    if #config.list_agents() == 0 then
      util.notify("No agents configured", vim.log.levels.WARN)
      return nil
    end

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

return M
