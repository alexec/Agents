# Tasks: One ~/.agents Shared by Every Agent

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/personal-shared.md](contracts/personal-shared.md),
[contracts/mcp-bridge.md](contracts/mcp-bridge.md), [quickstart.md](quickstart.md),
[look/](look/README.md) (approved by Alex, 2026-09-26)

**Tests**: Included. The quickstart names each property, and this repo tests every daemon
behaviour. Write each test before the code that makes it pass. Every layout test uses a
temporary home passed in directly; none reads `$HOME` (SC-006). Integration tests follow
`Pkg/Tests/AgentsKitTests/Integration/LeaseTests.swift`: `FakeACPAgent` + `FakeLauncher`, a
temporary root, and a bound app token.

**Where**: Everything runs in the worktree `.agents/worktrees/consider-how-might-have` on
branch `agents/consider-how-might-have`. Never edit the shared checkout. `Pkg/` means
`Packages/AgentsKit/`, `Src/` means `Pkg/Sources/AgentsKit/`, `Core/` means
`Pkg/Sources/AgentsKitCore/`, and `Tests/` means `Pkg/Tests/AgentsKitTests/`.

**Rules this feature must keep**:
- The real home is laid out only on the standard root, or on the home `AGENTS_PERSONAL_HOME`
  names. A scratch root or a test never touches `$HOME` (R4, FR-015).
- Never write inside, move or remove anything another tool manages: `~/.claude/skills/synced`,
  any folder with a `.bucket-*` or `.sync-manifest.json`, `~/.cursor/skills-cursor`, and
  `~/.agents/.skill-lock.json` (FR-007).
- No value from `mcp.json` goes into a log, event, the store, anything sent to the phone or a
  server, or the `personal/shared` result. Env and header values show up nowhere; only their
  names (FR-023).
- No runtime's own MCP config is written (FR-018). The only writes outside `~/.agents` are the
  links in the rule table, Gemini extension links, and Codex's own `codex plugin add/remove`
  (R12).
- Every step is its own attempt. A failure is logged and never stops the agent (FR-012).
- The bridge binds `127.0.0.1` only and answers only a route's bearer (contracts/mcp-bridge.md).
- The Shared tab matches the approved frames in `look/`, minus the "Last start" line (R13).

**Order**: Stories 1 and 2 (skills, instructions) come first, then 3 and 4, which protect what
is already there. The bridge spike comes before Story 6's build, because the bridge is the risky
part (plan, "Prove the risky part first"). Story 6 (MCP) comes before Story 7 (plugins), since
Grok's plugin servers ride on Story 6's merge. Story 5 (the tab) is last: it reads everything the
others produce. The look gate has passed, so no screenshot gate stands before the tab's views.

---

## Phase 1: Setup

- [X] T001 Merge `main` into `agents/consider-how-might-have` in the worktree. Confirm it with `git merge-base --is-ancestor main HEAD`, since a branch can move under a merge. Build both schemes (`xcodebuild … -skipPackagePluginValidation`, one after the other) and run `swift test` in `Pkg/` once, recording the failures already on `main` in `specs/054-user-dotagents/walk/baseline.md`.
- [X] T002 [P] Create the empty folders and files named in plan.md: `Src/MCP/`, `App/Sources/Settings/Shared/`, and `specs/054-user-dotagents/walk/README.md` with a heading for each quickstart step. *(Git keeps no empty folder, so `Src/MCP/` and `App/Sources/Settings/Shared/` come with their first files, in T020 and T042.)*

---

## Phase 2: Foundational (blocks every story)

- [X] T003 Add `AGENTS_PERSONAL_HOME` to `Src/Store/StoreLocations.swift`: `personalHome: URL?` is the named home, or the real home only when the root is the standard root, else nil (R4). Add `personalLayout` (`<root>/personal-layout.json`).
- [X] T004 [P] Test T003 in `Tests/Unit/PersonalHomeTests.swift`: a scratch root without the variable → nil; with it → that folder; the standard root → `FileManager.homeDirectoryForCurrentUser`.
- [X] T005 Make `DotAgents`'s helpers `place`, `attempt`, `exists`, `isDirectory`, `json(at:)`, `encoded` and `writeGeminiManifest` `internal` (not private) in `Src/Projects/DotAgents.swift` and `Src/Projects/DotAgents+Plugins.swift`. No change of behaviour, and the existing `DotAgentsTests` stay green. *(Done 2026-09-26: they were already internal, with nothing `private`, so no edit was needed.)*
- [X] T006 Create `Src/Projects/PersonalDotAgents.swift` with the rule table from data-model.md `RuntimeLinkRule`:
  - `runtimeID`;
  - `configFolder`;
  - `readsSharedSkills`: "true for Codex, Grok, Cursor, Copilot";
  - `skillsFolder`: `.claude/skills` for Claude only;
  - `instructionsFile`: `.claude/CLAUDE.md`, `.codex/AGENTS.md`, `.grok/AGENTS.md`, `.copilot/copilot-instructions.md`, and "nil for Cursor";
  - `adopts`: "true for Claude only";
  - `takesStdioServers`: "false for Copilot only";
  - `pluginHandover`: `sessionMeta` (Claude), `sessionMetaWithServers` (Grok), `codexMarketplace` (Codex), `extensionLink` (Gemini), `none` (Cursor, Copilot).

  Gemini has no instructions or skills rule until R14. A runtime counts as installed only when `RuntimeDiscovery.locate` finds it, never because its folder exists.
- [X] T007 Add the placed-links record to `Src/Projects/PersonalDotAgents.swift`, per data-model.md `PlacedLinks`:
  - Fields: `home`, `links` (path → destination) and `codexPlugins` (plugin → fingerprint).
  - Loading it with a different `home` resets it.
  - Missing or unreadable reads as empty; writes are atomic.
- [X] T008 Create `Src/Daemon/DaemonCore+PersonalLayout.swift`:
  - `reconcileHome()` runs every per-runtime step on the actor, each in its own `attempt`, and does nothing when `personalHome` is nil.
  - Call it once in `Src/Daemon/Daemon.swift` at start, and in `freshSession` and the pick-up path in `Src/Daemon/DaemonCore+Commands.swift`, beside `layOutOnce(cwd)` (FR-010).

**Checkpoint**: a daemon on a scratch root starts and makes sessions exactly as before, with no file touched in any home.

---

## Phase 3: User Story 1: A skill in ~/.agents reaches every agent (P1) 🎯 MVP

**Goal**: a skill folder in `~/.agents/skills` is offered by the next agent on every runtime.
**Independent test**: quickstart step 2 (probe HERON-7 x1 on all five runtimes against the built layout).

### Tests for User Story 1

- [X] T009 [P] [US1] In `Tests/PersonalDotAgentsTests.swift`, test US1 scenarios 1, 2 and 4 on a temporary home:
  - with Claude installed, a Claude link `~/.claude/skills/<name> -> ../../.agents/skills/<name>` is made and it is relative (FR-013);
  - `~/.claude/skills/synced` with a `.bucket-x` file is byte-for-byte unchanged;
  - no link is made for Codex, Grok, Cursor or Copilot;
  - no link is made for a runtime that is not installed (use a discovery stub).
- [X] T010 [P] [US1] In `Tests/Integration/PersonalLayoutTests.swift`, test US1 scenario 3 with a daemon on a temporary root and `AGENTS_PERSONAL_HOME`: a skill added after the daemon starts is linked before the next `agents/start` makes its session. Also test SC-006: the same daemon with no `AGENTS_PERSONAL_HOME` leaves a sentinel home untouched.
- [X] T011 [P] [US1] In `Tests/PersonalDotAgentsTests.swift`, test SC-005: a reconcile of 100 skills on a warm home finishes in under 50 ms.

### Implementation for User Story 1

- [X] T012 [US1] In `Src/Projects/PersonalDotAgents.swift`, make the skill-link step: create `~/.agents/skills` and `~/.agents/personas` when they are missing (FR-001), then apply data-model.md's reconcile table for each skill and each installed runtime with a `skillsFolder`. Skip managed names (FR-007), and skip a `skillsFolder` that is itself a link (spec, Edge Cases).
- [X] T013 [US1] Wire the step into `reconcileHome()` in `Src/Daemon/DaemonCore+PersonalLayout.swift`, so T009 to T011 pass.

**Checkpoint**: quickstart step 2's HERON-7 row holds for all five runtimes.

---

## Phase 4: User Story 2: Instructions written once apply everywhere (P1)

**Goal**: `~/.agents/AGENTS.md` is every runtime's personal instructions.
**Independent test**: quickstart step 2 (OSPREY-3 x1 on all but Cursor).

- [X] T014 [P] [US2] In `Tests/PersonalDotAgentsTests.swift`, test US2 scenarios 1 to 3: the Claude, Codex, Grok and Copilot instruction links exist and are relative; Cursor gets none; with no instructions anywhere, a short `~/.agents/AGENTS.md` saying what it is for is written, and the links point at it.
- [X] T015 [US2] In `Src/Projects/PersonalDotAgents.swift`, make the instructions step: follow the same table, with `AGENTS.md` as the target, for every installed runtime that has an `instructionsFile`. Wire it into `reconcileHome()`.

---

## Phase 5: User Story 3: What the person already has moves in, and nothing is lost (P2)

**Goal**: Claude's real skills and `CLAUDE.md` are adopted into `~/.agents` and linked back.
**Independent test**: quickstart step 4.

- [X] T016 [P] [US3] In `Tests/PersonalDotAgentsTests.swift`, test US3 scenarios 1 to 4:
  - move and link back only when the name is free, with contents byte-for-byte unchanged (a hash before and after);
  - a clash leaves both copies exactly as they are;
  - only the first real instructions file found moves, in the order Claude, Codex, Copilot, Grok (FR-006).
- [X] T017 [US3] In `Src/Projects/PersonalDotAgents.swift`, make the adopt step, run before the link steps: for each real folder in `~/.claude/skills` that is not managed, move it with `FileManager.moveItem` when `~/.agents/skills/<name>` is free. Then move the first real instructions file when `~/.agents/AGENTS.md` is missing. A failed move leaves the original where it was (spec, Edge Cases).

---

## Phase 6: User Story 4: The app stays out of the way of other tools and of the person (P2)

**Goal**: links the app placed and the person removed stay removed; dangling links into `~/.agents/skills` go; nothing else changes.
**Independent test**: quickstart step 4, second half.

- [X] T018 [P] [US4] In `Tests/PersonalDotAgentsTests.swift`, test US4 scenarios 1 to 4:
  - a link the `skills` installer made is left alone;
  - a link the app placed that the person deleted is not placed again (FR-009);
  - a skill removed from `~/.agents/skills` has its dangling links removed, including ones the installer made, and no other link (FR-008);
  - a second reconcile changes nothing: compare `lstat` and `mtime` of every entry (FR-011, SC-004).
- [X] T019 [US4] In `Src/Projects/PersonalDotAgents.swift`, make the record use and the dangling-link sweep (R5, R7):
  - record each link placed;
  - never place a recorded path that is gone from disk;
  - drop a record entry once its skill is gone;
  - in every folder the app links into, remove only links that resolve inside `~/.agents/skills/` to nothing.

---

## Phase 7: Bridge spike (before Story 6)

**Goal**: prove Copilot takes an http server from the bridge and calls a tool through it before the bridge is built properly.

- [ ] T020 Spike `Src/MCP/MCPBridge.swift` at its barest:
  - `NWListener` on `127.0.0.1:0`;
  - one hard-coded route that runs the app's own `agentsd mcp <token>` helper;
  - POST → stdin, stdout line → the matching response.

  On a scratch root, start a real Copilot agent whose session's `agents` server is swapped for the route. Ask it to call `finish_turn`. Record in `specs/054-user-dotagents/walk/README.md` whether the turn ends with an outcome. Then do the same for `probe/mcp-server.py heron-mcp`'s tool, reading `mcp.log`. If Copilot refuses the route, stop and ask Alex before going on.

---

## Phase 8: User Story 6: MCP servers set up once reach every agent (P1)

**Goal**: every server in `~/.agents/mcp.json` reaches every agent the app starts, on every runtime, Copilot included through the bridge.
**Independent test**: quickstart step 5, MCP half.

### Tests for User Story 6

- [ ] T021 [P] [US6] In `Tests/Unit/PersonalMCPTests.swift`, test parsing per data-model.md `PersonalMCPServer`:
  - stdio "when `command` is present; else `type` (`http` default, or `sse`)";
  - an entry "with neither `command` nor `url`", or a file that is not JSON, is a problem `{message, line?}`;
  - a problem's message never contains a value from the file (a sentinel string in `env`, `headers`, `args` and `url`);
  - a missing file means no servers and no problem.
- [ ] T022 [P] [US6] In `Tests/Unit/SessionServersTests.swift`, test R10 with a stubbed handshake:
  - the order is app's own → chosen → personal → Grok plugin servers;
  - of two servers with one name, the first is kept and the later one is dropped as `nameTaken` (FR-020);
  - an sse server is dropped for a handshake with `sse: false` (`transportNotAdvertised`, FR-019), and an http server for one without http;
  - a problem file drops only the personal servers;
  - for a runtime with `takesStdioServers == false`, every stdio server comes back as `.http` with an `Authorization` header, and the rest are unchanged.
- [ ] T023 [P] [US6] In `Tests/Integration/PersonalMCPIntegrationTests.swift`, test with `FakeACPAgent` on a temporary root with `AGENTS_PERSONAL_HOME`. `FakeACPAgent` records `session/new`/`session/load` params.
  - A new agent's `session/new` carries the personal server.
  - Edit `mcp.json`, stop the agent and pick it up again: the `session/load` carries the edit.
  - `Agent.mcpServers` in the store never contains a personal server.
  - A draft made before `mcp.json` changed is not used (R10).
  - With a sentinel secret in `mcp.json`, the sentinel appears nowhere in `daemon.log`, the store folder, the event log, or anything a phone-role connection receives (FR-023).
  - A broken `mcp.json` still starts the agent (Story 6 scenario 4).

### Implementation for User Story 6

- [ ] T024 [US6] Create `Src/Projects/PersonalDotAgents+MCP.swift`: `personalServers(home:) -> Result<[MCPServer], MCPFileProblem>`, read fresh on every call, with no cache (R10). Keep an `mcpStamp(home:)` (modification date + size) for drafts.
- [ ] T025 [US6] Create `Src/Daemon/DaemonCore+SessionServers.swift`: `sessionServers(runtimeID:chosen:token:managesAgents:cwd:capabilities:)` per R10 steps 1 to 4. Log each drop by name and reason only. Bridge swapping calls `MCPBridge.route(for:token:cwd:)`, which comes in T029; until then, leave stdio as it is.
- [ ] T026 [US6] In `Src/Daemon/DaemonCore+Commands.swift`, replace the two hand-built `mcpServers + [appServer(...)]` lists with `sessionServers(...)`: `freshSession` (about line 405, using the handshake it has just received) and the pick-up path (about line 802). Store the `mcpStamp` on the draft, and treat a mismatch as unusable in `startAgent`'s draft check (about line 243). The workflow start path in `DaemonCore+Workflows.swift` goes through `freshSession` and needs nothing extra.

### The bridge, built

- [ ] T027 [P] [US6] In `Tests/MCPBridgeTests.swift`, test against a fixture stdio server `Tests/Fixtures/mcp/echo-server.py` (echoes `tools/call` arguments; sleeps when asked) every row of contracts/mcp-bridge.md's HTTP table, using `URLSession` against the listener:
  - 200 with a matching `id`, and 202 for a notification;
  - the same 404 for an unknown route, a wrong bearer and an ended route;
  - 405 on GET, 411 on a chunked body, 413 over 16 MiB;
  - two overlapping calls answered out of order;
  - ending a route sends SIGTERM to its process (checked by pid) and fails a waiting call with -32000;
  - a server that exits fails waiting calls, and the next POST starts it again;
  - a server-sent notification is dropped and a server-sent request is answered -32601;
  - no command, arg, env or body appears in `daemon.log`.
- [ ] T028 [US6] Build `Src/MCP/MCPBridge.swift` out from the spike to contracts/mcp-bridge.md:
  - an actor with lazy `NWListener` start and keep-alive HTTP/1.1 parsing (`Content-Length` bodies only);
  - routes keyed by route id, each holding a key, an app token, the server, the folder and a process;
  - the process starts on first POST, with a stdout reader that matches ids;
  - SIGTERM, then SIGKILL after 2 s;
  - `endRoutes(for token:)` and `stopAll()`.

  Wrap it in `#if canImport(Network)` so the Linux gate still builds.
- [ ] T029 [US6] Wire the bridge in:
  - `sessionServers` swaps stdio servers for `bridge.route(...)` when the rule says `takesStdioServers == false`;
  - `dropAppTokens` in `Src/Daemon/DaemonCore+AppTools.swift` calls `bridge.endRoutes(for:)`;
  - a let-go draft ends its routes;
  - `Src/Daemon/Daemon.swift` calls `stopAll()` at exit.

  Extend T022 and T023 to cover Copilot: a Copilot session's `agents` server is http.
- [ ] T030 [US6] Run quickstart step 5's MCP half live on a scratch root with the R9 probe home. Record in `walk/README.md` which runtimes logged `tools/list` for `heron-mcp` and `egret-mcp`, including Copilot through the bridge, and that `finish_turn` works on a Copilot agent.

**Checkpoint**: SC-007 holds for Claude, Codex, Grok, Cursor and Copilot.

---

## Phase 9: User Story 7: Plugins installed once reach every agent (P2)

**Goal**: a plugin in `~/.agents/plugins` is loaded by Claude, Grok, Codex and Gemini, as R12 settles.
**Independent test**: quickstart step 5, plugin half.

### Tests for User Story 7

- [ ] T031 [P] [US7] In `Tests/PersonalPluginsTests.swift`, test:
  - Claude's `_meta.claudeCode.options.plugins` lists the project's plugins, then the personal ones, merged with the tool policy's `disallowedTools` (use `DaemonCore.merging`);
  - Grok's `_meta.pluginDirs` likewise, and a plugin's `.mcp.json` servers appear in Grok's `sessionServers` and no other runtime's;
  - the Gemini link `~/.gemini/extensions/<name>` is relative, is recorded, and is not put back once deleted; its dangling link is removed when the plugin goes; `gemini-extension.json` is written once when missing and never overwritten.
- [ ] T032 [P] [US7] In `Tests/PersonalPluginsTests.swift`, test Codex with a fake `codex` script on `PATH` that logs its arguments:
  - `~/.agents/plugins/marketplace.json` is written with the marker, `name: agents-personal`, and sources `./.agents/plugins/<name>`;
  - an index the person wrote themselves is never touched;
  - an unchanged fingerprint → no `plugin add`; a touched file → `plugin add <name>@agents-personal`; a removed plugin → `plugin remove` and its record entry dropped;
  - a failing `codex` is logged and does not stop the session (FR-012).

### Implementation for User Story 7

- [ ] T033 [US7] Create `Src/Projects/PersonalDotAgents+Plugins.swift`:
  - `personalPluginFolders(home:)`;
  - `pluginInfo(_:)` per data-model.md `PluginInfo`, with contents counts for `skills`, `commands`, `agents`, `hooks` and `mcpServers`;
  - `pluginServers(_:)`, read from `.mcp.json`;
  - `fingerprint(_:)`: relative path, size and modification date of each file, hashed.
- [ ] T034 [US7] Extend `sessionMeta(runtimeID:cwd:)` in `Src/Daemon/DaemonCore+Projects.swift` to add personal plugin folders after the project's own, for Claude and Grok, and pass Grok's plugin servers into `sessionServers` (R12).
- [ ] T035 [US7] Add the Codex step to `Src/Daemon/DaemonCore+PersonalLayout.swift`:
  - write the index;
  - diff fingerprints against `codexPlugins`;
  - run the toolset's `codex` binary with `HOME` set to the personal home (`plugin add` / `plugin remove`), off the actor, with a `terminationHandler`, never `waitUntilExit`;
  - record the new fingerprint on success.

  It runs at daemon start and before a Codex session only.
- [ ] T036 [US7] Add the Gemini extension-link step to `Src/Projects/PersonalDotAgents+Plugins.swift`, recorded like skill links, only when Gemini is installed.
- [ ] T037 [US7] Run quickstart step 5's plugin half live on the probe home. Record in `walk/README.md` that `plover-mcp` logged for Claude, Codex (after the app's own add) and Grok, and that touching a plugin file makes the next Codex start add it again while a second unchanged start does not.

---

## Phase 10: User Story 5: The person can see what every agent shares (P3)

**Goal**: the Settings ▸ Shared tab from the approved wireframes, read-only, over `personal/shared`.
**Independent test**: quickstart step 6.

### Tests for User Story 5

- [ ] T038 [P] [US5] In `Tests/PersonalSnapshotTests.swift`, test the snapshot against a temporary home with each kind of thing in it. Check every rule in contracts/personal-shared.md:
  - `reach` keys cover installed runtimes only;
  - a skill clash names both paths;
  - a plugin's skills have `source: {plugin}`;
  - `runtimeOnly` and `ownCopy` come from name-only reads of `~/.claude.json`, `~/.codex/config.toml` (`[mcp_servers.<name>]` lines), `~/.cursor/mcp.json`, `~/.copilot/mcp-config.json` and `~/.gemini/settings.json`;
  - Copilot stdio servers read "through the bridge";
  - `otherFiles` kinds are `persona`, `git`, `managed` and `unused`;
  - `needsALook` holds each clash, left-out and problem;
  - a sentinel secret in env, headers, args (`--token=…` and a long token) and the URL query appears nowhere in the encoded result;
  - `laidOut: false` with everything else empty when there is no personal home.
- [ ] T039 [P] [US5] In `Tests/Integration/PersonalSharedMethodTests.swift`, test that `personal/shared` answers a window connection and refuses a phone-role connection, as `runtimes/list` does.

### Implementation for User Story 5

- [ ] T040 [US5] Add `personal/shared` and the `SharedSnapshot` types (`Reach` as an enum with `gets`, `ownCopy`, `leftOut`, `noWay`, `unchecked`) to `Core/Daemon/DaemonAPI.swift`, and route the method in the daemon's dispatch for the Mac window role only.
- [ ] T041 [US5] Create `Src/Projects/PersonalDotAgents+Snapshot.swift`: build the snapshot from the rule table, the discovery results, the record, `mcp.json`, the plugin info and the name scans of runtime configs, as R13 describes. It never holds or returns a value from `mcp.json`.
- [ ] T042 [US5] Create `App/Sources/Settings/Shared/SharedSettingsView.swift`: the sidebar (Overview; In ~/.agents: Instructions, Skills, MCP servers, Plugins, Other files, with counts and ⚠) and the page area. It fetches on appear and on `NSApplication.didBecomeActiveNotification`, and shows the "off for this copy" state when `laidOut` is false. Add `Tab("Shared", systemImage: "square.on.square")` after Agents in `App/Sources/AgentsApp.swift`. Keep the modifier chain on `ContentView()` identical (see memory: a changed chain renames the saved window).
- [ ] T043 [P] [US5] Create `App/Sources/Settings/Shared/ReachDots.swift`: six dots in catalog order with the states gets, no (struck through) and unchecked (dashed). The row carries one accessibility label only, never a label over child texts (stacked labels crash AppKit).
- [ ] T044 [P] [US5] Create `App/Sources/Settings/Shared/SharedOverviewPage.swift` (frame A): the grid of kinds × runtimes, the legend, and Needs a look rows that open their page.
- [ ] T045 [P] [US5] Create `App/Sources/Settings/Shared/SharedSkillsPage.swift` (frame B): a filter, Yours then From plugins, and a detail with the SKILL.md preview, how Claude gets it, Reveal in Finder, and Edit SKILL.md (`NSWorkspace.open`).
- [ ] T046 [P] [US5] Create `App/Sources/Settings/Shared/SharedServersPage.swift` (frames C and D): Yours, From the app, and Only in one agent's own config, with reach per runtime in the detail and env names masked as `••••••`. The problem banner shows with Edit mcp.json. There is no "Last start" line (R13).
- [ ] T047 [P] [US5] Create `App/Sources/Settings/Shared/SharedPluginsPage.swift` (frame E): rows with content chips, and a detail with the file tree and "How each gets it", including Codex's last-added time.
- [ ] T048 [P] [US5] Create `App/Sources/Settings/Shared/SharedInstructionsPage.swift` (frame F) and `App/Sources/Settings/Shared/SharedOtherFilesPage.swift` (frame G), plus the empty state (frame H) in `SharedSettingsView.swift`.
- [ ] T049 [US5] Walk quickstart step 6 with the run-app skill on a scratch copy with `AGENTS_PERSONAL_HOME`. Screenshot each page and the broken-`mcp.json` state into `specs/054-user-dotagents/walk/`, and compare each with its frame in `look/`. Drive the window by pid with AX, and only when Alex is idle (memory), leasing the screen for the shots.

---

## Phase 11: Polish and proof

- [ ] T050 [P] Gemini (R14): once Alex's Gemini key is in Settings, run `probe/run.sh acp gemini` for MCP and plugins, and `probe/run.sh gemini` for skills and instructions. Add its rules to the rule table and research R14, or record that it is still unprobed. Ask Alex for the key rather than looking for it.
- [ ] T051 [P] Write `docs/how-to/share-skills-across-agents.md` (skills, AGENTS.md, `mcp.json`, plugins, what moves the first time, opting a skill out) and update `docs/explanation/projects-hosts-worktrees.md`, `docs/reference/runtimes.md` (per runtime: skills, instructions, MCP transports, plugins, the bridge) and `docs/reference/settings.md` (the Shared tab). Run `scripts/docs-check.py`.
- [ ] T052 Run the full quickstart (steps 1–6) and record the results in `walk/README.md`. Run `swift test` six times, and compare the failures with T001's baseline before blaming this branch.
- [ ] T053 Build both schemes and the Linux gate. Confirm `MCPBridge` is compiled out of the Linux build. Check that no `/tmp/dotagents-probe`, scratch root or borrowed sign-in is left behind (`probe/run.sh clean`).
- [ ] T055 [P] Antigravity (049, branch `agents/speckit-specify-support-antigravity`), once it is merged:
  - Its agents already get `mcp.json` servers through `sessionServers`, since R10 goes by the handshake (049 measured `mcpCapabilities {http, sse}`). Prove it with `probe/acp.py` using 049's command line.
  - 049's D7 gives it a home of the app's own (`GEMINI_HOME=<root>/runtimes/antigravity/home`), so links in `~` never reach it. Probe where it reads skills, instructions and plugins under that home, and add an Antigravity rule to the table that places links **inside the app's own home**, not `~/.gemini`.
  - Add its column to the Shared tab's reach.
- [ ] T054 Update `specs/054-user-dotagents/tasks.md` ticks and the memory note. Do not merge: merging is Alex's call.

---

## Dependencies

- Phase 1 → Phase 2 → everything else.
- US1 (Phase 3) → US2 (Phase 4) → US3 (Phase 5) → US4 (Phase 6): they share `PersonalDotAgents.swift` and `reconcileHome()`, so they run one after another.
- Bridge spike (Phase 7) → US6 (Phase 8). US6 can start after Phase 2; it does not need US1–US4.
- US7 (Phase 9) needs US6's `sessionServers` (T025) for Grok's plugin servers, and US4's record (T019) for Gemini links.
- US5 (Phase 10) needs US1–US4, US6 and US7, since it reports on all of them. T038 to T041 can start once T025 and T033 exist.
- Phase 11 comes last. T050 waits on Alex's key and can happen whenever that arrives.

## Parallel opportunities

- Within each story, the tests marked [P] can be written together.
- US6's bridge tests (T027) and parse tests (T021) are independent of the skill phases, so a second agent could take Phases 7–8 while one does Phases 3–6. Both touch `DaemonCore+Commands.swift` only in T008 and T026, so merge T008 first.
- The six page views (T043 to T048) are separate files and can be built in parallel once T042 exists.

## Implementation strategy

1. **MVP = Phases 1–3**: skills reach every agent, the core of the feature. Stop and prove it with quickstart step 2.
2. Add US2, US3 and US4: the shared copy becomes real on day one and never fights anyone.
3. Spike the bridge, then add US6. Copilot getting the app's own tools is a visible win on its own.
4. Add US7.
5. Add US5, then polish.

Commit at each checkpoint with the phase in the message.
