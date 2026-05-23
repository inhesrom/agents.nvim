# agents.nvim

Launch CLI coding agents from Neovim in managed floating terminal sessions.

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
to submit it. The agent runs in a floating terminal. Closing or hiding the float
does not stop the process.

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
- `:Agents hide` hides the current agent float without stopping the job.
- `:Agents send` resends the stored task prompt to the current session.

## Lua API

```lua
local agents = require("agents")

agents.setup({
  -- Opt in; no keymaps are installed by default.
  default_keymaps = true,

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

There are no provider APIs, adapters, transcript stores, or background services
in V1.

See `:help agents.nvim` and
`docs/adr/0001-terminal-session-first.md` for more detail.
