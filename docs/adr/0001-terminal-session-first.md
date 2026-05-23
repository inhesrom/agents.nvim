# ADR 0001: Terminal Session First

## Status

Accepted

## Context

The first version of `agents.nvim` needs to make CLI coding agents usable from
Neovim without committing to provider-specific APIs, transcript formats, or
adapter contracts too early. Agents such as `codex`, `claude`, and local tools
already expose interactive terminal interfaces that users understand.

## Decision

V1 wraps configured CLI executables in managed floating terminal sessions.
Launching an agent captures a lightweight target, opens an editable task prompt,
then sends the final prompt through the terminal PTY using generic paste and
submit behavior.

The plugin does not implement provider APIs, native agent adapters, transcript
persistence, or restartable session history in V1.

## Consequences

- The plugin stays zero-config for users with supported CLIs on `PATH`.
- Custom agents can be added with only a command, args, and PTY send settings.
- The implementation works with any interactive terminal CLI that accepts pasted
  prompt text.
- V1 cannot inspect provider-specific state, stream structured events, or resume
  sessions after Neovim exits.
- Future native integrations can be added later against observed user workflows
  rather than guessed provider abstractions.
