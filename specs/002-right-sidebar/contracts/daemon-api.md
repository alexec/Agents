# Contract: what the app asks the daemon about shells

Extends `specs/001-agent-daemon-ui/contracts/daemon-api.md`. Same transport: line-delimited
JSON-RPC 2.0 over the Unix socket. Only additions are listed.

Three of the four panes add nothing here. The files pane reads the disk in the app's own process, the
browser loads pages in the app, and the artifacts pane filters a transcript the app already receives.
Only the shell needs the daemon, because only the shell has to outlive the window.

## New calls

| Method | Params | Result |
|---|---|---|
| `shell.attach` | `agentID`, `rows`, `cols` | The shell's state, and the tail of its scrollback as raw bytes for the client to replay. Starts the shell if the agent has none |
| `shell.detach` | `agentID` | Nothing. Stops the output going to this connection. Never kills |
| `shell.input` | `agentID`, `bytes` (base64) | Nothing. Written to the pty as sent |
| `shell.resize` | `agentID`, `rows`, `cols` | Nothing. `TIOCSWINSZ`, and the kernel sends `SIGWINCH` |
| `shell.signal` | `agentID`, `signal` | Nothing. For the pane's own interrupt affordance; `^C` typed into the pane goes through `shell.input` and the line discipline, as in any terminal |
| `shell.restart` | `agentID` | The new shell's state. Only valid when the shell is not `live` (FR-024) |

## New notifications

| Notification | Carries |
|---|---|
| `shell.output` | `agentID`, the new bytes (base64) |
| `shell.stateChanged` | `agentID`, the new `ShellState`, with the reason when there is one |

## Rules

- **One shell per agent.** `shell.attach` from a second window returns the same shell, and both
  connections receive `shell.output` (FR-023). The identifier is the agent's; there is no shell id,
  because there is never a choice of shell.
- **Attach starts, detach does not stop.** A shell begins on the first attach and ends only by
  exiting, being killed, or being reaped. Closing a window, or quitting the app, detaches every
  window and kills nothing (FR-026, SC-010).
- **Detach is per connection.** The daemon tracks which connections are attached to which agent's
  shell, and drops them when the socket closes, so a crashed app does not leave a subscriber behind.
- **Output is bytes, not text.** The pty produces bytes, which may split a UTF-8 sequence or an
  escape sequence at any boundary. They are carried base64 and reassembled by the client's emulator,
  which holds partial sequences across chunks. Nothing decodes them to a `String` on the way
  through, and the daemon never parses them at all.
- **The screen is rebuilt on attach, not sent.** The daemon parses nothing. A window that attaches to
  a shell that has been printing for an hour gets the capped tail of its bytes and replays them into
  its own emulator, which gives the same screen as having watched all along (SC-006). Replaying a
  buffer emitted at a different width does not always reproduce the wrapping, which affects
  scrollback after a resize while detached, not the live screen.
- **These are the user's shells.** They are `shell.*`, separate from 003's `terminal.*`, which are
  the agent's. The two share the pty code and nothing else: different owners, different identifier
  spaces, different lifetimes. Nothing sent to `shell.input` reaches the agent (FR-025).
- **A busy shell is work.** While a child of the shell is running, the daemon counts it in the work
  it is holding and will not shut down under it (FR-027).
- **An idle shell is let go.** No running child and no input for long enough, and the shell is
  reaped, becoming `released` with the reason. The pane says so; it does not draw a dead screen as
  though it were live (FR-028).
- **A shell that dies with the daemon is marked, not forgotten.** Shells are not persisted. On the
  next attach after a daemon restart there is no shell, and the pane is told the previous one is
  gone and why, rather than being handed a new one silently (FR-029).
- **The daemon kills its shells before it exits**, so no pty is orphaned.

## Errors

| Code | When |
|---|---|
| `-32005` `noSuchAgent` | Already defined in 001. Reused |
| `-32004` `folderGone` | Already defined in 001. The shell cannot start because the agent's folder is not there |
| `-32010` `shellWillNotStart` | The user's login shell is missing or would not exec (FR-024) |
| `-32011` `shellNotLive` | `shell.restart` on a shell that is still running |

## What is deliberately absent

- No `shell.kill`. Ending a shell is `exit` typed into it, or the idle rule. A button that kills a
  build the user started is not something this feature needs.
- No shell history, anywhere. What the user typed is not agent history and is not written down
  (the spec's assumption). The scrollback is a live buffer, not a record.
- No second shell per agent. One column, one shell. If that turns out to be wrong it is a later
  feature, and the contract would gain a shell id rather than change shape.
