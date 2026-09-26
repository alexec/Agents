# 054 walk notes

One heading per [quickstart](../quickstart.md) step. Each says what was run, on what, and what was seen.

## 1. Unit and integration tests

2026-09-26, Phases 1–3: `swift test --filter 'PersonalDotAgentsTests|PersonalLayoutTests|PersonalHomeTests|DotAgentsTests'`
passes 41 of 41, three runs in a row. In one full-suite run under load, the 50 ms budget test
(`a100SkillReconcileIsQuick`) failed once. It is now `.flakyUnderLoad` and takes the best of
three. Main's own failures are in [baseline.md](baseline.md).

## 2. The runtimes see it: the probe against the app's own layout

2026-09-26, after Phase 3. `probe/run.sh setup` made the scratch home; then the built
`agentsd` (this branch, `build/DD`) ran with
`AGENTS_PERSONAL_HOME=/tmp/dotagents-probe/home --root /tmp/054-root` and laid it out at start:
`~/.claude/skills/heron-probe -> ../../.agents/skills/heron-probe`, recorded in
`personal-layout.json`. It exited by itself once idle.

| Runtime | HERON-7 | OSPREY-3 |
|---|---|---|
| Claude | x1 | — (US2 not built yet) |
| Codex | x1 | — |
| Grok | x1 | — |
| Cursor | x1 | — |
| Copilot | x1 | — |

`probe/run.sh clean` afterwards; nothing of the probe or its borrowed sign-ins was left.

## 3. Through the app itself (ACP, not the CLIs)

2026-09-26, the R1 open question: Claude **over ACP**, through `@agentclientprotocol/claude-agent-acp`
as the app starts it (`probe/run.sh acp claude`), offers `heron-probe` through the link. So the
adapter does load the user's `~/.claude/skills`. The other runtimes over ACP come with step 5.

## 4. Adoption and clashes

## 5. MCP servers and plugins reach each runtime

## 6. Settings ▸ Shared
