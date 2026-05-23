local util = require("agents.util")

local M = {}

local function empty_line(opts)
  return opts.empty_text or "No items"
end

function M.open(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = opts.filetype or "agents-picker"

  local state = {
    items = opts.items or {},
  }

  local winid = util.open_centered_float(bufnr, {
    width = opts.width or 0.75,
    height = opts.height or 0.45,
    border = opts.border or "rounded",
    title = opts.title,
    footer = opts.footer or " <CR> select  q/<Esc> close ",
  })

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end

  local function render()
    local lines = {}

    if #state.items == 0 then
      lines = { empty_line(opts) }
    else
      for index, item in ipairs(state.items) do
        lines[index] = opts.format(item, index)
      end
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
  end

  local function current_item()
    if #state.items == 0 then
      return nil
    end

    local line = vim.api.nvim_win_get_cursor(winid)[1]
    return state.items[line]
  end

  local function select()
    local item = current_item()
    if not item then
      return
    end

    close()
    opts.on_select(item)
  end

  local function delete()
    if not opts.on_delete then
      return
    end

    local item = current_item()
    if not item then
      return
    end

    local changed = opts.on_delete(item)
    if changed then
      state.items = opts.items_provider and opts.items_provider() or state.items
      render()
    end
  end

  util.set_normal_keymap(bufnr, "<CR>", select, "Select")
  util.set_normal_keymap(bufnr, "q", close, "Close picker")
  util.set_normal_keymap(bufnr, "<Esc>", close, "Close picker")

  if opts.on_delete then
    util.set_normal_keymap(bufnr, "d", delete, "Delete")
  end

  render()

  return {
    bufnr = bufnr,
    winid = winid,
    select = select,
    delete = delete,
    refresh = function(items)
      state.items = items or state.items
      render()
    end,
    close = close,
  }
end

return M
