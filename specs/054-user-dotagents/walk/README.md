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

### The bridge spike (T020)

2026-09-26, the built `agentsd` (this branch, `build/DD`) on scratch root `/tmp/run-054b`, a real
Copilot agent (`copilot --acp`, as the app starts it), with `bridged(...)` wired into both places
a session is made.

- **The app's own tools.** Copilot was given `agents` as an http route on the bridge, listed its
  tools and called `finish_turn`. The first run showed a gap the spike was for: the daemon
  refused the call (`refused a token call from pid …: not started by that agent's runtime`),
  because the helper is now the daemon's child, not Copilot's. A helper the bridge started for
  the token's own route now counts too (`tokenRefusal` → `isBridged`): the bridge starts it only
  for a request carrying that route's bearer, which only the runtime was sent. Second run: the
  turn ended with `workReported {outcome: done}` and no refusal.
- **A chosen stdio server.** `probe/mcp-server.py heron-mcp`, given as the agent's stdio server,
  went through its own route. `mcp.log`: `initialize`, `notifications/initialized`, `tools/list`,
  `tools/call`, all from the bridge's child, and the model answered HERON-MCP-9.
- Both routes ended, and their processes with them, when the agent's turn settled and its token
  was dropped. Nothing but route ids, server names and pids is in `daemon.log`.

Copilot accepts the route, so Phase 8 goes on as planned.

### MCP servers from `~/.agents/mcp.json` (T030)

2026-09-26, after Phase 8 (69a926b), the built `agentsd` on scratch root `/tmp/run-054c` with
`AGENTS_PERSONAL_HOME=/tmp/dotagents-probe/home`. That home's `~/.agents/mcp.json` held
`heron-mcp` (stdio, `probe/mcp-server.py`) and `egret-mcp` (http, the same script with
`--http 8799`). `tools/codex` was a read-only link to the real app's toolset, as in step 2.
There was one agent per runtime, started over the socket as the window starts them, each asked
to call both probe tools and then `finish_turn`.

| Runtime | `heron-mcp` (stdio) | `egret-mcp` (http) | `finish_turn` |
|---|---|---|---|
| Claude | tools/list, tools/call | tools/list, tools/call | done |
| Codex | tools/list, tools/call | tools/list, tools/call | done |
| Grok | tools/list, tools/call | tools/list, tools/call | done |
| Cursor | tools/list, tools/call | tools/list, tools/call | done |
| Copilot | through the bridge: tools/list, tools/call | tools/list, tools/call | done, through the bridge |

`mcp.log` counted 5 `initialize`, 5 `tools/list` and 5 `tools/call` for each server. Every agent's
report named HERON-MCP-9 and EGRET-MCP-9. `daemon.log` shows Copilot's two routes (`agents`,
`heron-mcp`) made, started and ended with the session. Only names and route ids are logged.

**Broken file.** With a comma removed from `mcp.json`, a Cursor agent still started and finished
(`done`). `daemon.log`: `personal servers: left out, mcp.json is not valid JSON. (line 1)`.
Nothing reached `mcp.log`, and no value from the file is in `daemon.log`.

Gemini was not walked: it still has no sign-in here (R14, T050). Plugins are the other half of
this step, and come with Phase 9. Afterwards `/tmp/run-054b`, `/tmp/run-054c` and
`/tmp/dotagents-probe` were removed.

### Plugins from `~/.agents/plugins` (T037)

2026-09-26, after Phase 9 (2f708ec). `probe/run.sh setup` made the probe home, then
`~/.agents/plugins/heron-plugin` was added by hand: a manifest, the `plover-skill` skill, and
`.mcp.json` with `plover-mcp` (stdio). No marketplace or links were made by hand, so everything
else was the app's. Codex has to read the home the app adds the plugin into, so the built
`agentsd` ran with `HOME` and `AGENTS_PERSONAL_HOME` both set to the probe home, and with sign-ins
borrowed as the probe's `acp` mode does. It ran on scratch root `/tmp/run-054d`, with
`tools/codex` a read-only link to the real toolset. One agent at a time was asked to call
`plover_mcp_word`.

| Runtime | How it got the plugin | `plover-mcp` in `mcp.log` | Answer |
|---|---|---|---|
| Claude | `_meta.claudeCode.options.plugins` | started, tools/list, tools/call | PLOVER-MCP-9 |
| Grok | `_meta.pluginDirs`, and its server in `mcpServers` | started, tools/list, tools/call | PLOVER-MCP-9 |
| Codex | `~/.agents/plugins/marketplace.json` (`agents-personal`, the app's marker) and the app's own `codex plugin add` at daemon start | started, tools/list, tools/call | PLOVER-MCP-9 |

Codex's copy landed in `~/.codex/plugins/cache/agents-personal`.

**Re-adding on a change.** The daemon started with an unchanged plugin. Then `touch` on
`skills/plover-skill/SKILL.md` and a Codex start gave `codex plugin add heron-plugin: added`
before the session. A second Codex start, with nothing changed, ran no add: the count in
`daemon.log` stayed the same. An earlier `touch` also made the daemon's own start add it
again, as it should.

Afterwards `probe/run.sh clean` was run and `/tmp/run-054d` removed.

## 6. Settings ▸ Shared
