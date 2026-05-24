# agents.nvim

Launch CLI coding agents from Neovim in managed terminal sessions.

`agents.nvim` is zero-config and dependency-free. If `codex` or `claude` are on
your `PATH`, they are available automatically.

## Quick start

```lua
require("agents").setup()
```

Then run:

```vim
:Agents launch
```

Choose an agent, edit the generated task prompt, and press `<CR>` in normal mode
to submit it. The agent runs in a managed terminal window. Closing or hiding the
window does not stop the process.

## Local install script

For copy-based local testing with lazy.nvim:

```sh
./install-plugin.sh
```

The script copies this checkout into lazy's plugin directory under your Neovim
data directory. When `NVIM_DATA_DIR` is set, the target is
`$NVIM_DATA_DIR/lazy/agents.nvim`. To test against an isolated data directory:

```sh
NVIM_DATA_DIR=/tmp/nvim-data ./install-plugin.sh
```

Restart Neovim or reload your plugin manager, then run `:Agents launch`.

## Commands

- `:Agents launch [name]` launches a new agent session. Without `name`, it opens
  the agent picker.
- `:Agents sessions` opens the global session picker, sorted by most recent use.
- `:Agents hide` hides the current agent session window without stopping the job.
- `:Agents send` resends the stored task prompt to the current session.

## Lua API

```lua
local agents = require("agents")

agents.setup({
  -- Opt in; no keymaps are installed by default.
  default_keymaps = true,

  ui = {
    -- Session float size.
    width = 0.85,
    height = 0.85,

    -- Session split size when snapping. Values below 1 are fractions of the
    -- anchor editor window; values 1 or above are cells.
    snap = {
      width = 0.40,
      height = 0.35,
    },
  },

  agents = {
    -- Override a built-in, even when it is not auto-detected.
    codex = {
      cmd = "codex",
      args = {},
    },

    -- Disable a built-in.
    claude = false,

    -- Add any CLI agent.
    local_agent = {
      cmd = "my-agent",
      args = { "--interactive" },
      send = {
        -- Wait for terminal output to appear and settle before pasting.
        -- Use "delay" to preserve delay-only scheduling.
        ready = "output-idle",
        ready_idle_ms = 250,
        ready_timeout_ms = 3000,

        -- Applied after readiness.
        delay_ms = 80,
        bracketed_paste = true,
        submit = true,
      },
    },
  },
})

agents.launch("codex")
agents.sessions()
agents.hide()
agents.send()
```

Default keymaps are opt-in:

- `<leader>aa` opens `:Agents launch`
- `<leader>as` opens `:Agents sessions`

## Terminal-session-first model

Every launch creates a new in-memory agent session. The plugin captures the
current project root, file path, and cursor line or command range, then opens an
editable task prompt:

```text
Task:

Context:
File: path/to/file.lua
Range: lines 10-20
```

The edited prompt is pasted into the terminal PTY and submitted using generic
terminal input. By default, agents.nvim waits until the terminal has visible
output and that output has been idle for `send.ready_idle_ms` before pasting the
task. If no stable output appears before `send.ready_timeout_ms`, it sends
anyway. Set `send.ready = "delay"` to use delay-only behavior.

If a CLI drops early input or has unusual startup timing, `:Agents send` or
`require("agents").send(session_or_id?)` resends the stored task prompt to the
current or given running session.

Agent sessions reopen in their last placement. Press `i` in a session terminal's
normal mode to type into the terminal, or press `s` to enter snap mode. In snap
mode, press `h`, `l`, `j`, or `k` to move the same session buffer into a real
split on the left, right, bottom, or top of the last focused editor window.
Press `f` in snap mode to restore a centered float, or `q`/`<Esc>` to cancel
snap mode. Outside snap mode, `q`/`<Esc>` hides the current session window while
keeping the terminal job alive. While typing in terminal mode, use
`<C-\><C-n>` to return to cursor mode. Centered floats show mode-aware keybind
hints in their native float footer; snapped splits show a centered, muted
Session Hint Line attached to the bottom of the session pane. The snapped line
uses the `AgentsSessionHint` highlight, linked to `Comment` by default.

There are no provider APIs, adapters, transcript stores, or background services
in V1.

See `:help agents.nvim` and
`docs/adr/0001-terminal-session-first.md` for more detail.
