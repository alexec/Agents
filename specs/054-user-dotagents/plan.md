# Implementation Plan: One ~/.agents Shared by Every Agent

**Branch**: `agents/consider-how-might-have` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/054-user-dotagents/spec.md`

## Summary

`~/.agents` becomes the one real copy of the person's instructions, skills, MCP servers and
plugins, and every agent the app starts gets them on every runtime that can take them.

- **Skills and instructions** (unchanged from the first plan, research R1–R7). Only Claude
  needs skill links; Claude, Codex, Grok and Copilot each get an instructions link; the daemon
  reconciles at start and before each session, adopts Claude's real files, and remembers what
  it placed.
- **MCP servers** (R9, R10). `~/.agents/mcp.json` is read before every `session/new` and
  `session/load` and merged into `mcpServers` in one daemon function, which also applies the
  name order and the transport filter. No runtime's config is written, and personal servers are
  never stored on the agent.
- **The Copilot bridge** (R11, Alex's call). Copilot refuses stdio servers from the client, so
  `agentsd` serves each one to it over loopback http and runs the process itself. This also
  gives Copilot agents the app's own tools for the first time.
- **Plugins** (R12). Claude and Grok get them in session `_meta` (Grok also gets their servers
  in `mcpServers`), and Gemini gets an extension link. Codex gets an index the app writes, and
  `codex plugin add` runs again whenever a plugin changes (Alex's call). Cursor, and Copilot over
  ACP, cannot be reached.
- **Settings ▸ Shared** (R13, [look/](look/README.md)). A read-only tab over one daemon snapshot,
  `personal/shared`, with an overview grid, a page per kind, reach per runtime, and clashes with
  runtimes' own configs. Its look gate is the wireframes, which Alex approves before any view
  code.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as the rest of AgentsKit and the app

**Primary Dependencies**: Foundation, and Network.framework (`NWListener`) for the bridge; no new packages

**Storage**: `<root>/personal-layout.json` (placed links, R5; Codex plugin fingerprints, R12);
the layout itself is files and symlinks in the home. `mcp.json` is read, never written, and
personal servers are never stored.

**Testing**: `swift test` in `Packages/AgentsKit`, against temporary homes; the quickstart walk on
a scratch root with `AGENTS_PERSONAL_HOME`

**Target Platform**: macOS app and its `agentsd`. The Linux `agentsd` is later (R8). The bridge
is `#if canImport(Network)`, so the Linux gate still builds.

**Project Type**: desktop app + daemon (existing)

**Performance Goals**: reconcile adds < 50 ms to a session start with 100 skills (SC-005).
Reading `mcp.json` and walking the plugin folders fit in the same budget. A Codex plugin add
(about 1 s) happens only when a fingerprint changed. A bridge route adds one loopback hop per
call.

**Constraints**: never reach the real home from a scratch root or a test (R4, FR-015); never
write inside managed folders (FR-007); every step its own attempt (FR-012); no `mcp.json` value
in any log, event, store, phone message or read model (FR-023); the bridge binds loopback only
and answers only a route's bearer

**Scale/Scope**: tens to low hundreds of skills; six runtimes

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so it sets no gates. The
project's own standing rules, from memory and earlier specs, are checked instead:

| Rule | How this plan keeps it |
|---|---|
| Settle the UX before building depth | The Shared tab's wireframes ([look/](look/README.md)) are approved by Alex before any view code (gate before US5's tasks); R13 lists what the frames drew that the build drops ("Last start") |
| Prove the risky part first | The bridge is spiked before its build: a real Copilot agent calls `finish_turn` and a probe tool through a bare bridge (R11) |
| Secrets stay put | FR-023 is covered by a test that runs the log, store and `personal/shared` against an `mcp.json` holding a sentinel value |
| Never touch the real home from tests or scratch | R4: home laid out only on the standard root or an explicit `AGENTS_PERSONAL_HOME`; tests inject the home |
| Never hand Alex a walk you could run | quickstart's walk is run by the implementer on a scratch root, with the probe's sign-in borrowing |
| Main checkout is only main | all work in this worktree |

Re-checked after Phase 1 (second pass, with MCP, plugins, the bridge and the tab): no violations.

## Project Structure

### Documentation (this feature)

```text
specs/054-user-dotagents/
├── proposal.md          # the first write-up, with Alex's decisions
├── spec.md
├── plan.md              # this file
├── research.md          # the probe and the decisions it drove
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── personal-shared.md
│   └── mcp-bridge.md
├── look/                # the Settings ▸ Shared wireframes (the look gate)
├── probe/               # run.sh, ask.txt (R1); acp.py, mcp-server.py (R9): rerunnable
└── tasks.md             # /speckit-tasks
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKit/Projects/
├── DotAgents.swift                   # shared helpers (place, attempt, exists) made internal, reused
├── PersonalDotAgents.swift           # NEW: rule table (R1, R9, R12), adopt, reconcile, skill links
├── PersonalDotAgents+MCP.swift       # NEW: read mcp.json → [MCPServer] or a problem (never logs values)
├── PersonalDotAgents+Plugins.swift   # NEW: plugin folders, info, Claude/Grok meta, Grok servers,
│                                     #      Codex index + fingerprints, Gemini extension links
└── PersonalDotAgents+Snapshot.swift  # NEW: the personal/shared read model, runtime-config name scan

Packages/AgentsKit/Sources/AgentsKit/MCP/
└── MCPBridge.swift                   # NEW: NWListener, routes, per-route stdio process (R11)

Packages/AgentsKit/Sources/AgentsKit/Daemon/
├── DaemonCore+PersonalLayout.swift   # NEW: which home (R4), record I/O, reconcile hooks, Codex add/remove
├── DaemonCore+SessionServers.swift   # NEW: sessionServers(...) (R10), bridge swap, drop log
├── DaemonCore+Commands.swift         # freshSession and pick-up call sessionServers; draft mcp.json stamp
├── DaemonCore+Projects.swift         # sessionMeta merges personal plugins after the project's
├── DaemonCore+AppTools.swift         # dropAppTokens also ends the token's bridge routes
└── Daemon.swift                      # reconcile once at start; bridge stopped at exit

Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift
                                      # personalLayout file; AGENTS_PERSONAL_HOME resolution
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift
                                      # personal/shared method + SharedSnapshot types

App/Sources/AgentsApp.swift           # Tab("Shared", …) beside Agents
App/Sources/Settings/Shared/          # NEW (after the look gate)
├── SharedSettingsView.swift          # sidebar + page, refresh on appear and on activation
├── SharedOverviewPage.swift          # grid + Needs a look
├── SharedSkillsPage.swift
├── SharedServersPage.swift           # incl. the mcp.json problem banner
├── SharedPluginsPage.swift
├── SharedInstructionsPage.swift
├── SharedOtherFilesPage.swift
└── ReachDots.swift                   # the six runtime dots, one accessibility element per row

Packages/AgentsKit/Tests/AgentsKitTests/
├── PersonalDotAgentsTests.swift      # NEW: US1–US4 on a temp home
├── PersonalMCPTests.swift            # NEW: parse, problem, no values in errors
├── SessionServersTests.swift         # NEW: order, drops, capability filter, bridge swap, drafts
├── MCPBridgeTests.swift              # NEW: fixture stdio server; 404/405/411; overlap; teardown
├── PersonalPluginsTests.swift        # NEW: meta, Grok servers, Codex fingerprints (fake codex), Gemini links
├── PersonalSnapshotTests.swift       # NEW: reach, clashes from runtime configs, secrets masked
└── Integration/PersonalLayoutTests.swift  # NEW: daemon start + session start; scratch root leaves home alone

docs/how-to/share-skills-across-agents.md   # NEW (skills, instructions, mcp.json, plugins)
docs/explanation/projects-hosts-worktrees.md
docs/reference/runtimes.md                  # per runtime: skills, instructions, MCP transports, plugins, the bridge
docs/reference/settings.md                  # the Shared tab
```

**Structure Decision**: a sibling of `DotAgents`, not a mode of it. The project layout runs
once per folder and replaces `.claude/skills` with one link. The home layout runs every time,
links per skill, and keeps a record, so the two share helpers but not an entry point. The home
guard in `DotAgents.apply(to:)` stays, which keeps FR-014 true by construction. The bridge is its
own actor under `MCP/`, owned by `DaemonCore`, which knows nothing about personal layouts: it
bridges whatever stdio servers `sessionServers` hands it, the app's own included.

## Phases

- **Phase 0 (done):** [research.md](research.md). R1–R8 cover skills and instructions; R9 is the
  ACP probe for MCP and plugins; R10–R14 cover the design that follows from it. Gemini is left
  to a task (R14).
- **Phase 1 (done):** [data-model.md](data-model.md),
  [contracts/personal-shared.md](contracts/personal-shared.md),
  [contracts/mcp-bridge.md](contracts/mcp-bridge.md), [quickstart.md](quickstart.md). The spec's
  FR-016, FR-018, FR-021 and FR-024 and User Story 5 were updated for Alex's two decisions and the tab.
- **Phase 2:** `/speckit-tasks`. Expected order:
  1. setup: merge main;
  2. foundational: the home (R4), the record, the rule table;
  3. US1 and US2, skills and instructions;
  4. US3 and US4, adopt, the record and dangling links;
  5. **bridge spike** (Copilot calls `finish_turn` through a bare bridge);
  6. US6, MCP: `mcp.json`, `sessionServers` at both session points, drafts, FR-023 test;
  7. the bridge build and wiring;
  8. US7, plugins: meta, Grok servers, Codex index and re-add, Gemini links;
  9. the `personal/shared` snapshot;
  10. **look gate** (Alex approves the wireframes);
  11. US5, the Shared tab;
  12. the Gemini probe when a key is in (R14);
  13. docs;
  14. the quickstart walk.

## Complexity Tracking

None.
