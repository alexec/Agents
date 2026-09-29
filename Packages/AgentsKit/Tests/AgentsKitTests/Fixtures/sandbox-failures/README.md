# Sandbox failures (064)

Real text from runtimes whose command sandbox could not be set up, captured on 2026-09-29 by
`scripts/sandbox-probe.sh` (research R9 and R11). Each file is exactly what reached an ACP client,
ANSI colours included; paths under the probe's scratch folder are rewritten as `/fixture`.
Nothing here was written by hand.

| File | Runtime, version, host | How it was made | Where the app sees it |
| --- | --- | --- | --- |
| `claude-linux-missing-bwrap.txt` | Claude Code 2.1.282, adapter 0.81.2, the devbox (Debian, no bubblewrap) | `_meta.claudeCode.options.sandbox.enabled = true` | the `session/new` error's `data.details` |
| `claude-macos-nested-seatbelt.txt` | Claude Code 2.1.284, adapter 0.81.2, macOS | the same, with the runtime started inside an outer `sandbox-exec` | a Bash tool call's output; the turn goes on |
| `codex-macos-nested-seatbelt-reply.txt` | Codex 0.156.1, adapter 1.13.1, macOS, mode `agent` | the runtime started inside an outer `sandbox-exec` | the agent's reply only: no tool call is sent for a command whose sandbox failed |
| `codex-linux-bwrap-no-namespace.txt` | Codex 0.156.1, the devbox (Docker withholds user namespaces) | `codex sandbox -c sandbox_mode="workspace-write"`, Codex's own sandbox without a model | what the command returns to the model |
| `grok-macos-nested-seatbelt.txt` | Grok 1.0.44, macOS | `--sandbox workspace`, inside an outer `sandbox-exec` | stderr; the process exits before `initialize` is answered |
| `gemini-linux-no-container.txt` | Gemini CLI 0.61.0, the devbox (no Docker or Podman) | `GEMINI_SANDBOX=true` | stderr; exit 44 before `initialize` |

Two more failures have no text to keep:

- Gemini 0.61.0 on macOS with its sandbox on (`GEMINI_SANDBOX=true`, or `tools.sandbox` in the
  person's own settings) reads all of standard input before it relaunches itself inside
  `sandbox-exec`. Under ACP standard input is the conversation, so it never answers `initialize`.
- Antigravity 1.2.1's own sandbox exists only for business accounts whose admin turns it on; on a
  host that cannot run it, the server logs "run_command will execute UNSANDBOXED" and asks before
  each command instead.

Files starting `not-` are commands denied **inside** a working sandbox. They must never be read as a
sandbox that failed to start (FR-006, SC-004).
