local target_mod = require("agents.target")
local util = require("agents.util")

local M = {}

local function split_lines(text)
  text = text or ""
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

function M.skeleton(target)
  return table.concat({
    "File: " .. (target.path or "[No Name]"),
    "Range: " .. target_mod.range_label(target),
    "Task: ",
  }, "\n")
end

local function initial_cursor(lines)
  for index = #lines, 1, -1 do
    local _, task_end = lines[index]:find("^%s*Task:")
    if task_end then
      return { index, task_end }
    end
  end

  return { #lines, 0 }
end

function M.description_from_prompt(prompt, target)
  local lines = split_lines(prompt)
  local task_seen = false

  for _, line in ipairs(lines) do
    local after_task = line:match("^%s*Task:%s*(.*)$")
    if after_task ~= nil then
      task_seen = true
      local inline = util.trim(after_task)
      if inline ~= "" then
        return inline
      end
    elseif task_seen then
      if line:match("^%s*Context:%s*$") then
        break
      end

      local trimmed = util.trim(line)
      if trimmed ~= "" then
        return trimmed
      end
    end
  end

  return target_mod.label(target)
end

function M.open(opts)
  opts = opts or {}
  local prompt = opts.prompt or M.skeleton(opts.target)
  local lines = split_lines(prompt)
  local cfg = opts.config or {}

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "agents-task"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local winid = util.open_centered_float(bufnr, {
    width = cfg.width or 0.70,
    height = cfg.height or 0.35,
    border = cfg.border or "rounded",
    title = " Agent Task ",
    footer = " <CR> submit  q/<Esc> cancel ",
  })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true

    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end

  local function submit()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    close()
    if opts.on_submit then
      opts.on_submit(table.concat(current_lines, "\n"))
    end
  end

  local function cancel()
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  util.set_normal_keymap(bufnr, "<CR>", submit, "Submit agent task")
  util.set_normal_keymap(bufnr, "q", cancel, "Cancel agent task")
  util.set_normal_keymap(bufnr, "<Esc>", cancel, "Cancel agent task")

  vim.api.nvim_win_set_cursor(winid, initial_cursor(lines))

  return {
    bufnr = bufnr,
    winid = winid,
    submit = submit,
    cancel = cancel,
  }
end

return M
