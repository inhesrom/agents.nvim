local config = require("agents.config")

local M = {}

local created = false

local subcommands = { "launch", "sessions", "hide", "send" }

local function starts_with(value, prefix)
  return value:sub(1, #prefix) == prefix
end

local function matching(values, prefix)
  local result = {}
  for _, value in ipairs(values) do
    if starts_with(value, prefix or "") then
      result[#result + 1] = value
    end
  end
  return result
end

function M.dispatch(command_opts)
  local agents = require("agents")
  local fargs = command_opts.fargs or {}
  local subcommand = fargs[1] or "launch"

  if subcommand == "launch" then
    agents.launch(fargs[2], {
      range = command_opts.range,
      line1 = command_opts.line1,
      line2 = command_opts.line2,
    })
    return
  end

  if subcommand == "sessions" then
    agents.sessions()
    return
  end

  if subcommand == "hide" then
    agents.hide()
    return
  end

  if subcommand == "send" then
    agents.send()
    return
  end

  vim.notify("Unknown :Agents subcommand: " .. subcommand, vim.log.levels.ERROR, { title = "agents.nvim" })
end

function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  local ends_with_space = cmdline:sub(-1) == " "

  if #words <= 1 or (#words == 2 and not ends_with_space) then
    return matching(subcommands, arglead)
  end

  local subcommand = words[2]
  if subcommand == "launch" then
    local names = {}
    for _, agent in ipairs(config.list_agents()) do
      names[#names + 1] = agent.name
    end
    return matching(names, arglead)
  end

  return {}
end

function M.ensure()
  if created then
    return
  end

  vim.api.nvim_create_user_command("Agents", M.dispatch, {
    nargs = "*",
    range = true,
    complete = M.complete,
    desc = "Launch and manage CLI agent sessions",
  })

  created = true
end

return M
