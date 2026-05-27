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

  local normal_footer = opts.footer or " <CR> select  q/<Esc> close "
  local insert_footer = opts.insert_footer or " INSERT  <Esc> normal "

  local winid = util.open_centered_float(bufnr, {
    width = opts.width or 0.75,
    height = opts.height or 0.45,
    border = opts.border or "rounded",
    title = opts.title,
    footer = normal_footer,
  })

  local function set_footer(footer)
    if not vim.api.nvim_win_is_valid(winid) then
      return
    end

    local win_config = vim.api.nvim_win_get_config(winid)
    if not win_config.footer then
      return
    end

    win_config.footer = footer
    win_config.footer_pos = "center"
    pcall(vim.api.nvim_win_set_config, winid, win_config)
  end

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

  local function refresh(cursor_line)
    if opts.items_provider then
      state.items = opts.items_provider()
    end

    render()

    if #state.items > 0 and vim.api.nvim_win_is_valid(winid) then
      local line = math.max(1, math.min(cursor_line or vim.api.nvim_win_get_cursor(winid)[1], #state.items))
      pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
    end
  end

  local function current_item()
    if #state.items == 0 then
      return nil
    end

    local line = vim.api.nvim_win_get_cursor(winid)[1]
    return state.items[line]
  end

  local function current_line()
    local line = vim.api.nvim_win_get_cursor(winid)[1]
    return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  end

  local function select()
    local item = current_item()
    if not item then
      return
    end

    local line_text = current_line()
    if opts.close_before_select == false then
      local result = opts.on_select(item, line_text)
      if result ~= false then
        close()
      end
      return
    end

    close()
    opts.on_select(item, line_text)
  end

  local function test()
    if not opts.on_test then
      return nil
    end

    local item = current_item()
    if not item then
      return nil
    end

    return opts.on_test(item, current_line())
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
      refresh()
    end
    return changed
  end

  local function start_insert()
    if #state.items == 0 then
      return
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  end

  local function add()
    if not opts.on_add then
      return
    end

    local cursor_line = opts.on_add()
    refresh(type(cursor_line) == "number" and cursor_line or nil)
    start_insert()
  end

  util.set_normal_keymap(bufnr, "<CR>", select, "Select")
  util.set_normal_keymap(bufnr, "q", close, "Close picker")
  util.set_normal_keymap(bufnr, "<Esc>", close, "Close picker")

  if opts.on_delete then
    util.set_normal_keymap(bufnr, "d", delete, "Delete")
  end

  if opts.on_test then
    util.set_normal_keymap(bufnr, "t", test, "Test")
  end

  if opts.on_add then
    util.set_normal_keymap(bufnr, "o", add, "Add")
  end

  if opts.editable then
    util.set_normal_keymap(bufnr, "i", function()
      start_insert()
    end, "Edit picker line")

    vim.keymap.set("i", "<CR>", "<Nop>", {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Use normal mode Enter to select",
    })

    local group = vim.api.nvim_create_augroup("agents_picker_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = group,
      buffer = bufnr,
      callback = function()
        set_footer(insert_footer)
      end,
    })
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = group,
      buffer = bufnr,
      callback = function()
        local cursor_line = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_cursor(winid)[1] or 1
        local item = current_item()
        local line_text = current_line()
        vim.bo[bufnr].modifiable = false
        set_footer(normal_footer)

        if opts.on_insert_leave and item then
          local refresh_cursor = opts.on_insert_leave(item, line_text, cursor_line)
          if refresh_cursor then
            refresh(type(refresh_cursor) == "number" and refresh_cursor or cursor_line)
          end
        end
      end,
    })
  end

  render()

  return {
    bufnr = bufnr,
    winid = winid,
    select = select,
    test = test,
    delete = delete,
    add = add,
    refresh = function(items)
      state.items = items or state.items
      render()
    end,
    close = close,
  }
end

return M
