local M = {}

function M.trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.basename(path)
  if not path or path == "" then
    return ""
  end
  return vim.fn.fnamemodify(path, ":t")
end

function M.centered_float_config(opts)
  opts = opts or {}

  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width_opt = opts.width or 0.85
  local height_opt = opts.height or 0.85

  local width = width_opt < 1 and math.floor(columns * width_opt) or width_opt
  local height = height_opt < 1 and math.floor(lines * height_opt) or height_opt

  width = math.max(20, math.min(width, columns - 4))
  height = math.max(5, math.min(height, lines - 4))

  local config = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2),
    col = math.floor((columns - width) / 2),
    style = "minimal",
    border = opts.border or "rounded",
  }

  if opts.title then
    config.title = opts.title
    config.title_pos = opts.title_pos or "center"
  end

  if opts.footer and vim.fn.has("nvim-0.12") == 1 then
    config.footer = opts.footer
    config.footer_pos = opts.footer_pos or "center"
  end

  return config
end

function M.open_centered_float(bufnr, opts)
  local config = M.centered_float_config(opts)
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, config)

  if not ok and config.footer then
    config.footer = nil
    config.footer_pos = nil
    ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, config)
  end

  if not ok then
    error(winid)
  end

  return winid
end

function M.set_normal_keymap(bufnr, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = desc,
  })
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "agents.nvim" })
end

return M
