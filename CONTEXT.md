# agents.nvim Context

This document defines the canonical language for V1.

## Agent

An **Agent** is a configured CLI executable that can be launched in an
interactive terminal. Built-in agents are `codex` and `claude` when those
executables are available on `PATH`. Users can override built-ins, disable them,
or add custom agents in `setup({ agents = ... })`.

## Launch

A **Launch** is the user action that creates a new Agent Session. Launching
starts with an agent choice, captures the current target, opens the editable task
prompt, then starts the terminal job after the prompt is submitted.

## Agent Session

An **Agent Session** is one managed terminal buffer, window placement state, job
handle, captured target, status, and description. Sessions are in-memory only.
Placement can be a centered float or a real editor split. **Snap** changes a
visible Agent Session between float and split placement without changing its
terminal buffer or job. Hiding a session closes its current visible window but
keeps the terminal job alive. Exited sessions remain in the session picker until
deleted.

## Session Hint Line

A **Session Hint Line** is the compact, mode-aware keybinding hint shown on a
visible Agent Session. It may render as a float footer or in the snapped session
winbar, but user-facing language should not call it a status bar.

## Task

A **Task** is the prompt text submitted to the agent terminal. V1 pre-fills a
small editable skeleton with a blank task area and context metadata. The first
non-empty task line becomes the session description.

## Target

A **Target** is the editor location captured at launch time: project root,
project-relative file path, and either a cursor line or selected/ranged line
span. V1 does not paste source file contents by default.
