local util = require("agents.util")

local M = {}

local uv = vim.uv or vim.loop

local function normalize_path(path)
  if not path or path == "" then
    return ""
  end

  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(path)
  end

  return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

local function dirname(path)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end
  return vim.fn.fnamemodify(path, ":h")
end

local function has_git_marker(path)
  local git_path = path .. "/.git"
  local stat = uv.fs_stat(git_path)
  return stat ~= nil
end

local function find_git_root(start)
  if vim.fs and vim.fs.root then
    local root = vim.fs.root(start, ".git")
    if root then
      return normalize_path(root)
    end
  end

  local current = normalize_path(start)
  while current and current ~= "" do
    if has_git_marker(current) then
      return current
    end

    local parent = dirname(current)
    if not parent or parent == current then
      break
    end
    current = parent
  end

  return nil
end

local function relpath(root, path)
  if not path or path == "" then
    return "[No Name]"
  end

  root = normalize_path(root)
  path = normalize_path(path)

  if vim.fs and vim.fs.relpath then
    local ok, result = pcall(vim.fs.relpath, root, path)
    if ok and result then
      return result
    end
  end

  if path == root then
    return util.basename(path)
  end

  local prefix = root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end

  return vim.fn.fnamemodify(path, ":.")
end

function M.project_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cwd = normalize_path(vim.fn.getcwd())

  local start = cwd
  if name and name ~= "" then
    start = dirname(normalize_path(name))
  end

  return find_git_root(start) or cwd
end

local function visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end

  local cursor = vim.fn.getpos(".")[2]
  local visual = vim.fn.getpos("v")[2]
  if cursor == 0 or visual == 0 then
    return nil
  end

  return math.min(cursor, visual), math.max(cursor, visual)
end

function M.capture(opts)
  opts = opts or {}

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local root = M.project_root(bufnr)
  local absolute_path = vim.api.nvim_buf_get_name(bufnr)
  local path = relpath(root, absolute_path)

  local start_line
  local end_line

  if opts.range and opts.range > 0 then
    start_line = opts.line1
    end_line = opts.line2
  else
    start_line, end_line = visual_range()
  end

  if not start_line then
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  return {
    root = root,
    absolute_path = absolute_path,
    path = path,
    start_line = start_line,
    end_line = end_line,
  }
end

function M.range_label(target)
  if target.start_line == target.end_line then
    return "line " .. target.start_line
  end

  return "lines " .. target.start_line .. "-" .. target.end_line
end

function M.label(target)
  if not target then
    return ""
  end

  return (target.path or "[No Name]") .. ":" .. M.range_label(target)
end

return M
