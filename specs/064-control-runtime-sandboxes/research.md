# Research: Control runtime sandboxes

Checked on this Mac on 2026-09-28 unless marked. "Parses" means the binary accepted the flag with `--version`. It does not prove the ACP server honours it; R9 covers that.

## R1. Where a per-agent choice enters a launch

- **Decision**: bind a TaskLocal `LaunchSandbox` around `launcher.launch` in `freshSession`, `liveSession` and `options()`. `ProcessSessionLauncher.launch` appends the catalog's arguments and environment after `ToolPolicy` and `RuntimePolicyFiles`. Codex and Claude use the session instead, through the mode and `_meta` respectively (R2, R7).
- **Rationale**:
  - `SessionLauncher.launch(runtime:path:cwd:)` has no agent parameter.
  - `LentEnvironment` already carries per-launch values this way.
  - There is one process per agent, and every turn ends with `releaseRuntime`, so the next spawn is where a change takes effect (FR-012).
- **Alternatives considered**:
  - A new `launch` parameter: touches three callers and every test fake.
  - Per-agent config files: `RuntimePolicyFiles` writes fixed paths under `<root>/runtimes/`, shared by every agent on a runtime.
  - Editing the runtime's home config: forbidden. It changes the person's own CLI and every other agent.

## R2. Codex

- **Decision**: express the sandbox only through Codex's advertised mode:
  - Off = `agent-full-access` (**Full access**).
  - On = `read-only` (**Ask for approval**) when leaving Full access; otherwise the current `read-only` or `agent` mode.
  - Under **As configured by runtime**, the effective state is read from the mode.
- **Rationale**:
  - The adapter (`@agentclientprotocol/codex-acp`) advertises `read-only`, `agent` and `agent-full-access`. See the captured handshake in `specs/052-quota-fallback/walk/real-runtimes/codex-handshake.json`.
  - Full access is Codex's documented `danger-full-access` sandbox with approvals off. The coupling in FR-005 is the vendor's, not ours.
  - Keeping one control means the mode menu and the sandbox state cannot disagree (FR-005a).
- **Alternatives considered**:
  - `-c sandbox_mode=...`: the Codex toolset shim does not forward arguments, and adding `forwardsArguments` changes the toolset id.
  - Adding `sandbox_mode` to `CODEX_CONFIG`: the mode menu would still say Ask for approval while commands ran unsandboxed.
- **Open, for the probe**: capture Codex's own error text when its sandbox cannot start. The likely host is the Linux devbox container, where bubblewrap and landlock need namespaces that Docker withholds. Save the text as `Fixtures/sandbox-failures/codex-*.txt` and derive the patterns from it, not from guesses.

## R3. Grok

- **Decision**: Off = `--sandbox off`; On = `--sandbox workspace`. Both go before `agent stdio`, next to the existing `--permission-mode default`.
- **Rationale**:
  - Grok 1.0.41 documents `--sandbox <PROFILE>` (env `GROK_SANDBOX`) with profiles `off`, `workspace`, `devbox`, `read-only` and `strict` (`~/.grok/docs/user-guide/05-configuration.md`).
  - CLI flags come first in its precedence.
  - `requirements.toml`/MDM clamps config layers. Whether it also clamps the flag is part of the probe.
  - The flag parses.
- **Alternatives considered**:
  - `GROK_SANDBOX` env: equivalent, but the flag is explicit in the process list and in tests.
  - The `GROK_CONFIG_PATH` overlay: it sits below requirements and is shared per daemon.

## R4. Cursor

- **Decision**: Off = `--sandbox disabled`; On = `--sandbox enabled`, before `acp`.
- **Rationale**: Cursor 2026.09.26 help says "Explicitly enable or disable sandbox mode (overrides config)", and the flag parses.
- **Alternatives considered**: the `/sandbox` setting, which is persistent and belongs to the person's own Cursor.

## R5. Copilot

- **Decision**: Off = `--no-sandbox`; On = `--sandbox`. Offered only after the probe. A startup warning that sandboxing is forced by policy marks Off **Unavailable (policy)**.
- **Rationale**:
  - Copilot 1.0.89-5 describes command sandboxing as experimental and disabled by default (`copilot help sandbox`).
  - It says a managed policy with `allowBypass: false` makes sandboxing mandatory, and that a host which cannot run it fails every sandboxed command with a startup warning.
  - Both flags parse but are not listed in `--help`. The probe must show that `--sandbox` works without `--experimental` under `--acp`. If not, On stays unoffered and only Off is actionable.
- **Alternatives considered**:
  - `/sandbox disable`: a slash command that is only registered with experimental features on, and applies to one session only.
  - `sandbox.enabled` in `settings.json`: the person's own config.

## R6. Gemini

- **Decision**: Off = `GEMINI_SANDBOX=false`; On = `GEMINI_SANDBOX=true`. The control covers Gemini's process sandbox (`tools.sandbox`) only, and the Settings text says so.
- **Rationale**:
  - The pinned Gemini CLI resolves its sandbox from the `--sandbox` flag, then `GEMINI_SANDBOX`, then settings.
  - Environment reaches the process whichever shim runs it.
  - Agents already launches it without `--sandbox`.
- **Two layers**:
  - `security.toolSandboxing` is a separate tool sandbox. The probe checks whether `false` there matters for the pinned version. If it does, document the layer as not controlled rather than writing the person's settings.
  - The existing `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` file is the lowest-precedence layer, so it cannot force either value.
- **Alternatives considered**:
  - `--sandbox` / `--sandbox=false` arguments: the shim forwards them, so this remains the fallback if the env is ignored.
  - System defaults: too weak.

## R7. Claude

- **Decision**: offer only **As configured by runtime** (shown as **Runtime controlled**) until the probe proves a route.
- **Rationale**:
  - Claude Code's Bash sandbox is off unless the person's settings enable it.
  - The candidate route is `_meta.claudeCode.options`, which `claude-agent-acp` 0.84 passes into the Agent SDK options, carrying `sandbox` settings. That is untested.
  - The Claude shim does not forward arguments, so `--settings` is not available.
- **Alternatives considered**: writing the project's `.claude/settings.local.json`. That changes files in the person's project and every other Claude session there.

## R8. Antigravity

- **Decision**: always **Unavailable**, with the reason from FR-013.
- **Rationale**:
  - Agents runs `agy_acp_server` 1.2.1, not the Antigravity CLI or IDE.
  - Neither the ACP registry entry nor the pinned manifest lists a sandbox setting.
  - `AGY_ACP_DISABLE_WORKSPACE_TRUST=1` concerns workspace trust.
  - The status changes only after a probe on a new pinned version, or a Google statement about the server.

## R9. Capability and probes

- **Decision**:
  - A choice is actionable only when `SandboxCatalog` supports it and a stored probe for the installed runtime version on this host confirms it.
  - Probes run once per version per host: on the first Settings visit after an install or update, or on demand from the row.
  - Results are stored in `sandbox-settings.json` under `probes`.
  - A version change invalidates the result. A saved Off then shows **Unavailable**, and agents start **As configured** until the probe passes again.
- **Probe**: start the runtime on a scratch folder with the choice, run one harmless command that reads outside the folder (`ls /`, and on Linux `cat /etc/hostname`), and compare On with Off:
  - On must be blocked or confined, and Off must succeed.
  - A policy-forced sandbox, a rejected flag, or no difference between the two marks the choice unconfirmed.
- **Rationale**: FR-002 and FR-008 forbid claiming Off without evidence for the exact integration. A flag that merely parses does not count.
- **Alternatives considered**:
  - Trust the vendor docs: rejected by FR-002.
  - Probe at every launch: slow, and it spends model turns.

## R10. Helper cap (decided by Alex, 2026-09-28)

- **Decision**: a helper's sandbox is never looser than its caller's. If the caller's effective sandbox is On, a runtime default of Off does not apply to the helper. It starts **As configured**, or, for Codex, is refused Full access by the existing `ModeLooseness` cap. Its effective state gives the reason. FR-011 is amended to match.
- **Alternatives considered**: letting the default win, which matches FR-011 as first written but lets a sandboxed agent create an unsandboxed one.

## R11. Recognising a sandbox startup failure

- **Decision**: per-runtime patterns in `SandboxCatalog`, taken from real failure text captured during the probes (R2 onwards). They are matched against the handshake error, the turn error text and the last 8 KB of stderr, before sign-in, limit and generic handling.
- **Rationale**:
  - Today stderr is only logged, and a handshake failure becomes `runtimeWillNotStart`.
  - A command denied inside a working sandbox arrives as a tool result, not as a turn failure, so it cannot match (FR-006, SC-004).
- **Alternatives considered**: JetBrains `SessionFailure` categories. No runtime reports a sandbox category.

## R12. Recovery re-send

- **Decision**: `agents/continueWithoutSandbox` sets the override, then re-sends the last user prompt with `beginTurn(recorded: false)`, like Pool's `retry` and `sendAgain`. If tool calls completed during the failed turn, it sends a short continuation instead.
- **Rationale**:
  - The in-memory `lastPrompts` does not survive a daemon restart; the transcript does.
  - Re-sending a prompt after actions have run could repeat them without the person knowing (spec edge case).

All unknowns in the Technical Context are resolved or assigned to the R9 probe gate.
