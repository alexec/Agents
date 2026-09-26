# 054 walk notes

One heading per [quickstart](../quickstart.md) step. Each says what was run, on what, and what was seen.

## 1. Unit and integration tests

2026-09-26, after Phases 4–6 and the merge of main 6f77c3c: the four suites pass 54 of 54. They
were three runs in a row before the merge and one after. The full suite was not run after this
merge.

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
| Claude | x1 | x1 |
| Codex | x1 | x1 |
| Grok | x1 | x1 |
| Cursor | x1 | — (no instructions file, as R1 found) |
| Copilot | x1 | x1 |

`probe/run.sh clean` afterwards; nothing of the probe or its borrowed sign-ins was left.

The OSPREY-3 column was filled after Phases 4–6, on main 6f77c3c merged in (`7a70f51`). A
scratch root has no Codex toolset of its own (Codex is only ever the app's copy, in
`<root>/tools`), so the daemon counts Codex as not installed and gives it no link. For the
walk, `/tmp/054-root/tools/codex` was a link to the real app's toolset, read-only, and then Codex
got `~/.codex/AGENTS.md -> ../.agents/AGENTS.md` and read OSPREY-3. (`XYZ-1` in Codex's answer
is the example word in the probe's own question.)

## 3. Through the app itself (ACP, not the CLIs)

2026-09-26, the R1 open question: Claude **over ACP**, through `@agentclientprotocol/claude-agent-acp`
as the app starts it (`probe/run.sh acp claude`), offers `heron-probe` through the link. So the
adapter does load the user's `~/.claude/skills`. The other runtimes over ACP come with step 5.

## 4. Adoption and clashes

2026-09-26, after Phases 4–6. The same built `agentsd` ran on a probe home with no
`~/.agents/AGENTS.md`, a real `~/.claude/CLAUDE.md` (KITE-1), and three real skills in
`~/.claude/skills`: `mine`, `heron-probe` (also in `~/.agents/skills`) and `synced` (with a
`.bucket-test` marker).

- First layout: `mine` moved to `~/.agents/skills/mine` (contents unchanged) and was linked back
  (`../../.agents/skills/mine`). `heron-probe` clashed, so both real copies stayed. `synced` was
  untouched. `CLAUDE.md` moved to `~/.agents/AGENTS.md` and was linked back.
- The `mine` link deleted, then a second layout: it was not put back.
- `~/.agents/skills/mine` removed, then a third layout: its record entry was dropped.
- A new real `~/.claude/skills/later`, then a fourth layout: `daemon.log` says
  `personal layout: moved .claude/skills/later into .agents/skills`, and the link back is there.

## 5. MCP servers and plugins reach each runtime

## 6. Settings ▸ Shared
