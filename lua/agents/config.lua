local M = {}

local defaults = {
  default_keymaps = false,
  keymaps = {
    launch = "<leader>aa",
    sessions = "<leader>as",
  },
  send = {
    delay_ms = 80,
    bracketed_paste = true,
    submit = true,
  },
  ui = {
    width = 0.85,
    height = 0.85,
    border = "rounded",
  },
  task_editor = {
    width = 0.70,
    height = 0.35,
    border = "rounded",
  },
  picker = {
    width = 0.75,
    height = 0.45,
    border = "rounded",
  },
}

local builtins = {
  codex = {
    name = "codex",
    label = "Codex",
    cmd = "codex",
    args = {},
    send = {
      delay_ms = 120,
      bracketed_paste = true,
      submit = true,
    },
  },
  claude = {
    name = "claude",
    label = "Claude",
    cmd = "claude",
    args = {},
    send = {
      delay_ms = 120,
      bracketed_paste = true,
      submit = true,
    },
  },
}

local state

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function sorted_pairs(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  local index = 0
  return function()
    index = index + 1
    local key = keys[index]
    if key then
      return key, tbl[key]
    end
  end
end

local function executable(cmd, executable_check)
  if not cmd or cmd == "" then
    return false
  end

  executable_check = executable_check or vim.fn.executable
  return executable_check(cmd) == 1
end

local function split_argv(value)
  if type(value) ~= "table" then
    return value, {}
  end

  local argv = deepcopy(value)
  local cmd = table.remove(argv, 1)
  return cmd, argv
end

local function is_array(tbl)
  if type(tbl) ~= "table" then
    return false
  end

  local count = 0
  for key in pairs(tbl) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end

  return count > 0
end

local function normalize_agent(name, spec, base, cfg)
  if spec == false then
    return nil, true
  end

  spec = spec or {}
  if type(spec) == "string" then
    spec = { cmd = spec }
  end

  if type(spec) ~= "table" then
    error("agent '" .. name .. "' must be a table, string, false, or nil")
  end

  if spec.enabled == false then
    return nil, true
  end

  local agent = deepcopy(base or {})
  agent.name = spec.name or name or agent.name
  agent.label = spec.label or agent.label or agent.name

  local command = spec.cmd or spec.command or spec.argv or agent.cmd or agent.command or agent.argv or agent.name
  local command_is_argv = type(command) == "table"
  local cmd, args_from_command = split_argv(command)

  agent.cmd = cmd
  agent.command = cmd
  agent.args = deepcopy(spec.args or (command_is_argv and args_from_command or agent.args) or {})

  if spec.argv and not spec.args then
    local argv_cmd, argv_args = split_argv(spec.argv)
    agent.cmd = argv_cmd
    agent.command = argv_cmd
    agent.args = argv_args
  end

  agent.cwd = spec.cwd or agent.cwd
  agent.env = spec.env or agent.env
  agent.send = vim.tbl_deep_extend("force", deepcopy(cfg.send), deepcopy(agent.send or {}), deepcopy(spec.send or {}))

  for key, value in pairs(spec) do
    if key ~= "cmd"
      and key ~= "command"
      and key ~= "argv"
      and key ~= "args"
      and key ~= "send"
      and key ~= "enabled"
    then
      agent[key] = deepcopy(value)
    end
  end

  return agent, false
end

local function apply_agent_specs(cfg, specs)
  if not specs then
    return
  end

  if is_array(specs) then
    for _, spec in ipairs(specs) do
      local name = spec.name
      if not name or name == "" then
        error("array agent specs require a name")
      end

      local agent, disabled = normalize_agent(name, spec, builtins[name], cfg)
      if disabled then
        cfg.agents[name] = nil
      else
        cfg.agents[name] = agent
      end
    end
    return
  end

  for name, spec in sorted_pairs(specs) do
    local agent, disabled = normalize_agent(name, spec, builtins[name], cfg)
    if disabled then
      cfg.agents[name] = nil
    else
      cfg.agents[name] = agent
    end
  end
end

function M.resolve(opts, executable_check)
  opts = deepcopy(opts or {})
  local agent_specs = opts.agents
  opts.agents = nil

  local cfg = vim.tbl_deep_extend("force", deepcopy(defaults), opts)
  cfg.agents = {}

  for name, builtin in sorted_pairs(builtins) do
    if executable(builtin.cmd, executable_check) then
      local agent = normalize_agent(name, {}, builtin, cfg)
      cfg.agents[name] = agent
    end
  end

  apply_agent_specs(cfg, agent_specs)

  return cfg
end

function M.setup(opts)
  state = M.resolve(opts)
  return state
end

function M.get()
  if not state then
    return M.setup({})
  end
  return state
end

function M.get_agent(name)
  return M.get().agents[name]
end

function M.list_agents()
  local agents = {}
  for _, agent in pairs(M.get().agents) do
    agents[#agents + 1] = agent
  end

  table.sort(agents, function(left, right)
    return left.name < right.name
  end)

  return agents
end

function M.builtins()
  return deepcopy(builtins)
end

function M.defaults()
  return deepcopy(defaults)
end

return M
