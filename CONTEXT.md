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

An **Agent Session** is one managed terminal buffer, floating window state, job
handle, captured target, status, and description. Sessions are in-memory only.
Hiding a session closes its float but keeps the terminal job alive. Exited
sessions remain in the session picker until deleted.

## Task

A **Task** is the prompt text submitted to the agent terminal. V1 pre-fills a
small editable skeleton with a blank task area and context metadata. The first
non-empty task line becomes the session description.

## Target

A **Target** is the editor location captured at launch time: project root,
project-relative file path, and either a cursor line or selected/ranged line
span. V1 does not paste source file contents by default.
