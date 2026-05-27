local util = require("agents.util")

local M = {}

local test_path

local function json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end

  return vim.fn.json_encode(value)
end

local function json_decode(value)
  if vim.json and vim.json.decode then
    return vim.json.decode(value)
  end

  return vim.fn.json_decode(value)
end

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end

  local list_check = vim.islist or vim.tbl_islist
  if list_check then
    return list_check(value)
  end

  local count = 0
  local max = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    max = math.max(max, key)
  end

  return count == max
end

local function default_path()
  return vim.fn.stdpath("data") .. "/agents.nvim/launch_commands.json"
end

function M.path()
  return test_path or default_path()
end

function M.normalize(commands, opts)
  opts = opts or {}
  local configured_commands = opts.configured_commands or {}
  local validate = opts.validate
  local normalized = {}
  local seen = {}
  local changed = false

  for _, value in ipairs(commands or {}) do
    if type(value) ~= "string" then
      changed = true
    else
      local command = util.trim(value)
      local valid = command ~= ""

      if valid and validate then
        valid = validate(command) == true
      end

      if valid and not configured_commands[command] and not seen[command] then
        normalized[#normalized + 1] = command
        seen[command] = true
        if command ~= value then
          changed = true
        end
      else
        changed = true
      end
    end
  end

  return normalized, changed
end

function M.load(opts)
  local path = M.path()
  if vim.fn.filereadable(path) == 0 then
    return {}
  end

  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    util.notify("Could not read Launch Commands: " .. tostring(lines), vim.log.levels.WARN)
    return {}
  end

  local ok_decode, decoded = pcall(json_decode, table.concat(lines, "\n"))
  if not ok_decode or not is_list(decoded) then
    util.notify("Could not parse Launch Commands: " .. path, vim.log.levels.WARN)
    return {}
  end

  local normalized, changed = M.normalize(decoded, opts)
  if changed then
    M.save(normalized)
  end

  return normalized
end

function M.save(commands)
  local path = M.path()
  local dir = vim.fn.fnamemodify(path, ":h")

  if dir ~= "" then
    local ok_mkdir, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
    if not ok_mkdir then
      util.notify("Could not create Launch Command directory: " .. tostring(mkdir_err), vim.log.levels.ERROR)
      return false
    end
  end

  local ok_encode, encoded = pcall(json_encode, commands or {})
  if not ok_encode then
    util.notify("Could not encode Launch Commands: " .. tostring(encoded), vim.log.levels.ERROR)
    return false
  end

  local ok_write, write_err = pcall(vim.fn.writefile, { encoded }, path)
  if not ok_write then
    util.notify("Could not write Launch Commands: " .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end

  return true
end

function M._set_path_for_test(path)
  test_path = path
end

function M._reset_for_test()
  test_path = nil
end

return M
