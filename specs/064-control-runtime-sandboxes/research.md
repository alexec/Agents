# Research: Control runtime sandboxes

First checked on this Mac on 2026-09-28, when "parses" meant only that a binary accepted a flag.
**Redone on 2026-09-29 (#40)**: every route below was run under ACP, on the version the app runs
today, with `scripts/sandbox-probe.sh`, on this Mac and on the devbox. The probe opens a real
conversation in a scratch project and asks for one command that writes a file outside the project
and reaches the network; the verdict is read from the disk. Where a runtime could not take a turn,
macOS's `sandbox_check()` said whether the kernel had its process in a sandbox. The measured table
is R9; R2–R8 give each runtime's decision.

## R1. Where a per-agent choice enters a launch

- **Decision**: bind a TaskLocal `LaunchSandbox` around `launcher.launch` in `freshSession`,
  `liveSession` and `options()`. `ProcessSessionLauncher.launch` appends the catalog's arguments and
  environment after `ToolPolicy` and `RuntimePolicyFiles`. Claude's choice goes in the session's
  `_meta.claudeCode.options.sandbox`, next to the app's `disallowedTools` and `plugins`; Codex's is its
  mode (R2).
- **Rationale**:
  - `SessionLauncher.launch(runtime:path:cwd:)` has no agent parameter.
  - `LentEnvironment` already carries per-launch values this way.
  - There is one process per agent, and every turn ends with `releaseRuntime`, so the next spawn is
    where a change takes effect (FR-012).
- **Alternatives considered**:
  - A new `launch` parameter: touches three callers and every test fake.
  - Per-agent config files: `RuntimePolicyFiles` writes fixed paths under `<root>/runtimes/`, shared
    by every agent on a runtime.
  - Editing the runtime's home config: forbidden. It changes the person's own CLI and every other
    agent.

## R2. Codex — Off and On confirmed

- **Decision**: express the sandbox only through Codex's advertised mode:
  - Off = `agent-full-access` (**Full access**).
  - On = `read-only` (**Ask for approval**) when leaving Full access; otherwise the current
    `read-only` or `agent` mode.
  - Under **As configured by runtime**, the effective state is read from the mode.
- **Measured** (Codex 0.156.1, adapter 1.13.1, macOS): in `agent`, the outside write failed with
  "Operation not permitted" and `curl` could not resolve a host; in `agent-full-access`, both worked.
- **Rationale**: Full access is Codex's documented `danger-full-access` sandbox with approvals off;
  the coupling in FR-005 is the vendor's. One control means the mode menu and the sandbox state
  cannot disagree (FR-005a).
- **Alternatives considered**: `-c sandbox_mode=…` (the shim forwards no arguments) and
  `sandbox_mode` in `CODEX_CONFIG` (the menu would say Ask for approval while commands ran
  unsandboxed).
- **Failure**: see R11. Codex's sandbox fails per command, never at start.

## R3. Grok — Off and On confirmed without a turn

- **Decision**: Off = `--sandbox off`; On = `--sandbox workspace`, before `agent stdio`, next to
  `--permission-mode default`.
- **Measured** (Grok 1.0.44, macOS): with `--sandbox workspace` the kernel reports the `grok` process
  itself sandboxed from the start of the conversation; with `--sandbox off`, or no flag, it is not.
  Grok's Build balance was spent, so no turn was run; the sandbox is applied to the whole process at
  startup (its docs, "How It Works"), so the kernel's answer is the one that matters.
- **Picking a conversation back up**: Grok's docs say resuming a session under a different profile
  is refused. That is its terminal's `--resume`. Under ACP, `session/load` of a conversation opened
  with `workspace` succeeded in a process started with `off`, and the reverse. So a change applies
  from the agent's next turn, like the other runtimes, and **Continue without sandbox** can keep the
  conversation.
- **A non-`off` profile also refuses Grok's shared leader process**, which 067's FR-014 wants off for
  its own reasons. The two do not conflict.
- **Alternatives considered**: `GROK_SANDBOX` (equivalent, less visible) and the `GROK_CONFIG_PATH`
  overlay (below requirements, shared per daemon).

## R4. Cursor — no route under ACP

- **Decision**: no control. Cursor shows **Runtime controlled**: "Cursor's own sandbox setting
  decides. The app cannot change it."
- **Measured** (Cursor 2026.09.26, its bundled code): `--sandbox <mode>` is a top-level option, read
  only by the terminal CLI (`sandboxOverride`). `cursor-agent acp` builds its session without it, so
  under ACP the sandbox is `sandbox.mode` in Cursor's own `cli-config.json`, else disabled. #41 found
  the same. Cursor's plan was spent ("Upgrade your plan to continue"), so no turn was run.
- **Rejected**: writing `sandbox.mode` into Cursor's config: its folder also holds its sign-in, and
  it is the person's.

## R5. Copilot — not yet proven

- **Decision**: no control until measured; **Runtime controlled**: "Copilot's own sandbox setting
  decides." The candidate routes are `--no-sandbox` (Off) and `--sandbox` (On), both of which parse.
- **Measured** (Copilot 1.0.89-5): its monthly quota was spent, so no turn ran. Its sandbox is per
  command (`sandbox-exec` through MXC), so, unlike Grok's, the kernel cannot show it without a
  command. Copilot says its sandbox is experimental and off by default, and that a managed policy
  with `allowBypass: false` forces it on.
- **Follow-up**: rerun `scripts/sandbox-probe.sh copilot {none,on,off}` once the quota resets
  (2026-10-01). If Off and On are confirmed, the catalog gains the two arguments and nothing else
  changes.

## R6. Gemini — Off confirmed; On breaks under ACP

- **Decision**: Off = `GEMINI_SANDBOX=false`. **On is not offered.**
- **Measured** (Gemini CLI 0.61.0):
  - `GEMINI_SANDBOX` is read before the person's `tools.sandbox` and the `--sandbox` flag
    (`getSandboxCommand`), so `false` turns the process sandbox off whatever their settings say.
    With it, Gemini started normally under ACP.
  - With the sandbox on, on macOS, Gemini reads **all of standard input** before relaunching itself
    inside `sandbox-exec` (it expects a piped prompt). Under ACP standard input is the conversation,
    so Gemini never answers `initialize`. This also happens today to anyone whose own Gemini
    settings turn its sandbox on.
  - On Linux without Docker or Podman, it exits at once with code 44: "GEMINI_SANDBOX is true but
    failed to determine command for sandbox; install docker or podman or specify command in
    GEMINI_SANDBOX".
- **Second layer**: `security.toolSandboxing` (default false) sandboxes single tools instead of the
  process. In 0.61.0's code it is enabled from the same sandbox setting (`getSandboxEnabled()`), so
  `GEMINI_SANDBOX=false` should cover it too; read, not measured.
- **Consequence for As configured**: a Gemini agent whose person has its sandbox on never starts.
  The app recognises a Gemini start that times out with no answer to `initialize` as a probable
  sandbox hang and offers Off (R11).

## R7. Claude — Off and On confirmed

- **Decision**: Off = `_meta.claudeCode.options.sandbox = {"enabled": false}`; On =
  `{"enabled": true}`. The adapter hands `sandbox` to the Agent SDK, which gives it to Claude Code as
  flag settings: above the person's user and project settings, below managed settings.
- **Measured** (Claude Code 2.1.284, adapter 0.81.2, macOS): with On, the outside write failed with
  "Operation not permitted" and the network request came to the client as a permission question
  (`example.com`); with Off or unset, both worked. On the devbox (no bubblewrap) On failed at
  `session/new`: "Sandbox required but unavailable … bubblewrap (bwrap) not installed, socat not
  installed".
- **Rebuilds on change**: `sandbox` is one of the adapter's `OPTION_REBUILDS_SESSION` keys, so a
  changed value on `session/load` restarts Claude Code with it: the next turn applies it.
- **Alternatives considered**: `--settings` (the shim forwards no arguments); writing the project's
  `.claude/settings.local.json` (the person's files).

## R8. Antigravity — no route; a sandbox only an admin controls

- **Decision**: no control. Antigravity shows **No sandbox** for a personal account and **Set by
  your organisation** for a business one: "Antigravity sandboxes commands only when a business
  account's admin turns on Sandbox mode. The app cannot change it."
- **Measured** (`agy_acp_server` 1.2.1, its bundled `terminal_sandbox.py`): the OS sandbox
  ("exebox": Seatbelt on macOS, user namespaces on Linux) is driven solely by the `sandboxModeEnabled`
  admin control, fetched for entitled `oauth-business` sessions. There is no flag, environment
  variable, ACP option or `_meta` key for it. Without admin controls, commands run unsandboxed after
  the usual permission question. On a host that cannot sandbox, the server logs "run_command will
  execute UNSANDBOXED" and falls back to asking before each command, so it never fails to start.
- A third-party `antigravity-acp` 1.2.0 (shubzkothekar) has a `sandbox` session option; it wraps the
  `agy` CLI and is not Google's server.
- `AGY_ACP_DISABLE_WORKSPACE_TRUST=1` concerns workspace trust, not the sandbox.

## R8a. OpenCode — no sandbox

- **Decision**: no control; **No sandbox**: "OpenCode has no command sandbox. It asks before
  commands, as set in Settings."
- **Measured** (OpenCode 1.18.33): no sandbox in its code or docs; its system prompt tells the model
  "The operating environment is not in a sandbox". Its `permission.external_directory` asks before
  touching files outside the project, which is a permission, not a sandbox, and is already the
  app's through `OPENCODE_CONFIG_CONTENT`.

## R9. What was measured (2026-09-29)

| Runtime | Version | Off | On | As configured today | Startup failure seen |
| --- | --- | --- | --- | --- | --- |
| Claude | 2.1.284, adapter 0.81.2 | `sandbox.enabled=false`: wrote outside, network ok (Mac) | `true`: write denied, network asked (Mac); failed at `session/new` without bwrap (devbox) | off unless the person's settings | yes, both hosts |
| Codex | 0.156.1, adapter 1.13.1 | Full access: wrote, network ok (Mac) | Ask / Approve: write and network denied (Mac) | the mode | yes, per command, both hosts |
| Grok | 1.0.44 | `--sandbox off`: process unsandboxed (kernel) | `--sandbox workspace`: process sandboxed (kernel) | off unless the person's config | yes, refuses to start (Mac) |
| Gemini | 0.61.0 | `GEMINI_SANDBOX=false`: starts, no relaunch | hangs under ACP (Mac); exit 44 without Docker (devbox) | off unless the person's settings | yes, both hosts |
| Cursor | 2026.09.26 | none under ACP | none under ACP | its own `sandbox.mode`, else off | not reachable (plan spent) |
| Copilot | 1.0.89-5 | `--no-sandbox`, unproven | `--sandbox`, unproven | off unless its own settings or policy | not reachable (quota spent) |
| Antigravity | 1.2.1 | none | none | off; business admin only | never fails: falls back to asking |
| OpenCode | 1.18.33 | none | none | no sandbox | — |

The runtimes the devbox has no copy of (Grok, Copilot, Cursor; Antigravity is Mac only) were not run
on Linux. Their Linux routes are the same arguments, and Grok's Linux sandbox is Landlock, which
the devbox kernel (6.8) has.

- **Decision**: **no probe inside the app.** The catalog records, per runtime, the routes above and
  the version they were measured on; `scripts/sandbox-probe.sh` re-measures them, as
  `scripts/acp-handshake.sh` does for options, whenever a pinned runtime moves or a self-updating one
  changes its sandbox. A choice the catalog does not have is not offered (FR-002).
- **Rationale**: the first plan ran a probe per runtime version per host from Settings. Three of
  eight runtimes could not take a turn today because their allowance was spent, so an in-app probe
  would leave their rows Unavailable for reasons unrelated to sandboxing, and every probe spends a
  turn. The routes are a vendor's flag, environment variable or ACP option; a later version that
  stops honouring one surfaces as a failure the app already recognises (R11), or a change the
  script notices.
- **Alternatives considered**: the in-app probe of 2026-09-28 (above); trusting docs alone
  (rejected by FR-002, and wrong twice here: Cursor's flag and Grok's resume refusal).

## R10. Helper cap (decided by Alex, 2026-09-28)

- **Decision**: a helper's sandbox is never looser than its caller's. If the caller's effective
  sandbox is On, a runtime default of Off does not apply to the helper. It starts **As configured**,
  or, for Codex, is refused Full access by the existing `ModeLooseness` cap. Its effective state gives
  the reason. FR-011 is amended to match.

## R11. Recognising a sandbox that failed to start

Failures arrive in three shapes (fixtures in
`Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/sandbox-failures/`):

| Shape | Runtimes | Where the text is |
| --- | --- | --- |
| The runtime will not start | Grok (refuses to start), Gemini on Linux (exit 44), Claude on Linux (`session/new` error) | stderr, or the handshake or `session/new` error |
| A command fails, the turn goes on | Claude on macOS (a tool call's output: `sandbox_apply: Operation not permitted`, exit 71), Codex on both (`sandbox_apply…`; `bwrap: No permissions to create a new namespace`) | the tool call's output; for Codex only the agent's reply, because codex-acp sends no tool call for a command whose sandbox failed |
| The runtime hangs | Gemini on macOS with its sandbox on | nothing: `initialize` is never answered |

- **Decision**: per-runtime patterns in `SandboxCatalog`, taken from these fixtures:
  - matched against the handshake and `session/new` error, the turn error, the last 8 KB of stderr,
    completed tool calls' output, and, for Codex only, the turn's reply text;
  - checked before sign-in, limit and generic handling;
  - a Gemini start with no answer to `initialize` within the handshake timeout counts as a sandbox
    hang, since that is the one known cause and the recovery (Off) is harmless if wrong.
- **What never matches**: a command denied inside a working sandbox says "Operation not permitted"
  about the command's own target (`not-*` fixtures). The patterns name the sandbox's own setup
  (`sandbox_apply`, `bwrap: No permissions`, "Sandbox required but unavailable", "could not apply
  the … sandbox profile", "failed to determine command for sandbox"), never a bare "Operation not
  permitted".

## R12. Recovery re-send

- **Decision**: `agents/continueWithoutSandbox` sets the override, then re-sends the last user prompt
  with `beginTurn(recorded: false)`, like Pool's `retry` and `sendAgain`. If tool calls completed
  during the failed turn, it sends a short continuation instead.
- **Rationale**: the in-memory `lastPrompts` does not survive a daemon restart; the transcript does.
  Re-sending a prompt after actions have run could repeat them without the person knowing.

## Decisions (Alex, 2026-09-29)

On the redone research, Alex chose:

1. **Measured routes only.** Claude, Codex and Grok get **As configured by runtime / On / Off**;
   Gemini gets **As configured by runtime / Off**. Cursor, Copilot, Antigravity and OpenCode show
   their state and one line of why, with no control. Copilot gains On and Off in a follow-up once
   its quota resets and the probe passes.
2. **No in-app probe** (R9).
3. **A sandbox that fails mid-turn shows its card when the turn ends**, and the agent stops there;
   the turn is not cut off (R11).
4. **Gemini keeps As configured by runtime**; a start that never answers is recognised as its
   sandbox hanging, and **Continue without sandbox** sets that agent to Off (R6).
