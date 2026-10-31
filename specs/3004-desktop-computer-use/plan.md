# Implementation Plan: Desktop control: an agent drives apps on the Mac, watched from another device

**Branch**: `agents/3004-let-agent-drive` (plan only) | **Date**: 2026-10-31 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/3004-desktop-computer-use/spec.md` (#3004),
merged by PR #3038 and deliberately left open for this stage.

## Summary

A new sibling helper, `agents-drive`, built the same way `agents-watch` already is
(research R1) — an executable beside `agentsd` in Agents Host's `Contents/Helpers`, found
and run by a small Go wrapper because Go cannot reach `ApplicationServices`,
`CoreGraphics` or `IOKit` without cgo. It drives any app through the Accessibility API for
AX-addressed actions and through tagged, injected `CGEvent`s for real mouse and keyboard
input (research R2), takes a screenshot with `CGWindowListCreateImage` (research R3), and
listens on a global `CGEventTap` for the person's own, untagged input so the running
action can pause the instant it is touched (research R2, FR-007).

One new agent tool, `drive_screen` (research R6), takes the existing `screen` resource
lease itself before its first action and releases it when the agent stops, the turn
stops, or the person takes over (research R4) — unlike `build` or `browser`, where the
project already accepts the agent remembering to lease first. A new, small person-level
setting, `<settings>/desktop-control.json`, gates the tool off by default (research R5);
a new capability, `host.desktop-control/1` (research R8), gates the tool, the daemon
methods and the three clients' live tile together, so an older machine or client degrades
to an ordinary running turn rather than a broken one.

The narration of each action rides the transcript's own existing live-step line (research
R7); the screenshot behind the live tile is a new, never-recorded push,
`desktopControl/liveFrame`, to whichever of the Mac, the Remote and the web page are
showing the session, replaced by a "Mac is locked" placeholder while the screen is locked
(`d.personAway() == "locked"`, already wired end to end). A new small state and two new
methods, `desktopControl/resume` and `desktopControl/takeOver` (research R9), carry the
pause-on-touch flow; **Stop** needs no new method, only a small extension to the existing
stop-turn path. Codex's own `computer_use` feature flag is turned off the same way other
per-feature Codex toggles already are (research R10).

## Technical Context

**Language/Version**: Go 1.24 (`agentsd`). Swift 6 (the new `agents-drive` helper, Agents
Host, the Mac window, the Remote, `Shared/UI`, `Packages/AgentsKit`). TypeScript (the web
page).

**Primary Dependencies**: none new. `ApplicationServices`/`AppKit` (the Accessibility API,
`CGEvent*`), `CoreGraphics` (`CGWindowListCreateImage`) and `IOKit` are all part of the
macOS SDK, already linked by `Host/AgentsWatch` and the `run-app` skill's scripts — no
licence to record, no version to pin (research R11).

**Storage**: plain files, no database. One new file, `<settings>/desktop-control.json`
(`{enabled: bool}`, research R5). No screenshot is ever written anywhere (FR-016); the
live tile is in-memory, per connection, only.

**Testing**:

- `Go/scripts/go.sh test ./internal/agentsd/...`: the new tool's lease take/release, the
  Off/not-granted refusals, the capability gate, the Codex `features` map change.
- `swift test`, filtered by `scripts/select-test-suites.sh`, for `agents-drive`'s own
  logic that can run without real Accessibility (command parsing, event tagging, the
  touch filter) and for the new Shared/UI cards and tile.
- Vitest: a new `Web/test/desktopControl.test.mjs` for the tile and the pause card.
- `scripts/go-changed.sh` before each push that changes `Go/`.
- Walks (quickstart.md): `run-app` on a scratch root (Mac and web) with Accessibility
  granted to the scratch build, the walk simulator for the Remote.

**Target Platform**: macOS 27 (driving and the Mac's own live tile); iOS and iPadOS 27,
and current browsers (watching and steering only — FR-015, no client but the Mac moves
the real pointer).

**Project Type**: distributed app addition: one new helper process, new daemon methods and
an agent tool, and a UI addition on three existing clients.

**Performance Goals**: the live tile within 2 s of an action and at least every 5 s while
idle (FR-011, SC-001). A real touch pauses the current action within 1 s, every time, over
20 tries (SC-002).

**Constraints**:

- Agents Host drives the screen as the person's own logged-in user; no elevated or
  escalated privilege (FR-003, "Hosts never escalate").
- Off by default for every person and folder (FR-004); no agent, MCP tool or workflow may
  turn it on (research R5).
- A screenshot is never written to the project, to `<root>`, or to a turn's saved history
  (FR-016, SC-005); only the narration is.
- Single main display for v1 (Assumptions); a second display is out of scope.
- No new media server or streaming pipeline: periodic stills, not video (spec Decisions).

**Scale/Scope**: one driving session at a time per Mac — the `screen` lease enforces this,
the same as `build`, `browser` and `simulator:` today. As many watching clients as the
person has paired; each gets its own `desktopControl/liveFrame` push while showing the
session.

## Constitution Check

*Before Phase 0, and again after Phase 1.*

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec 3004 (merged, #3038), this plan, then tasks. The build starts only after `/speckit-tasks`. |
| II. Capability-driven runtimes | A machine says `host.desktop-control/1` only once it carries `agents-drive` and the new daemon methods; `offeredTools()` withholds `drive_screen` from any machine or client that does not (research R8). Codex's own `computer_use` is turned off through its existing per-feature toggle (research R10), never passed through. |
| III. Scoped access and user control | The tool is off by default and only the person's own clients may turn it on (FR-004, research R5); it runs as the person's own user with no escalation (FR-003); the person's own touch pauses it at once and **Take Over** ends it, never fought (FR-007, FR-008). |
| IV. Work must be inspectable | Every action is an ordinary transcript step (research R7); the live tile shows exactly what is happening, or "Mac is locked" rather than a stale or misleading picture (FR-012); **Resources** shows the lease held, as for any other resource. |
| V. Docs and quality travel with the feature | The spec's Docs section lists every page; each slice updates its own pages and the parity row for the live tile (Core). Wire types come from `Packages/Wire` through `scripts/wire.sh gen`. |

No violation. Complexity Tracking is empty. After Phase 1: still no violation. The one new
moving part is the `agents-drive` helper process; research R1 says why `agentsd` cannot do
this itself, the same reason `agents-watch` already exists.

## Project Structure

### Documentation (this feature)

```text
specs/3004-desktop-computer-use/
├── spec.md
├── plan.md                              this file
├── research.md                          Phase 0
├── data-model.md                        Phase 1
├── contracts/desktop-control-api.md     Phase 1
├── quickstart.md                        Phase 1
├── checklists/requirements.md
└── tasks.md                             /speckit-tasks (not made by this plan)
```

### Source Code (repository root)

Areas from `.agents/areas` are in brackets.

```text
Packages/Wire/
├── daemon.schema.json        DesktopControlSettings, DesktopControlRefusal,
│                              DesktopControlState, LiveFrame (data-model.md)
├── daemon.openrpc.json        desktopControl/state|set|resume|takeOver, liveFrame;
│                              x-capability host.desktop-control/1                        [build]
└── app-tools.json             drive_screen (mirrors Go/wire/app-tools.json)               [build]
Go/wire/*_gen.go                generated from the above                                    [-]
Host/AgentsDrive/ (new)         agents-drive: AX actions, tagged CGEvent injection,
                                 CGWindowListCreateImage, the global CGEventTap touch
                                 filter, the NUL-delimited stdin/stdout protocol with
                                 agentsd (research R1, R2, R3)                              [machines]
Go/internal/agentsd/
├── screencalls.go (new)       drive_screen's handler: resolves/leases "screen" (reusing
│                               resolveResource/leaseResource's internals), starts/talks to
│                               agents-drive, returns the result or DesktopControlRefusal   [machines]
├── screensettings.go (new)    desktop-control.json: read, write, desktopControl/state|set;
│                               refuses the agent socket role, MCP tools, workflows         [machines]
├── screenpause.go (new)       DesktopControlState, desktopControl/resume|takeOver,
│                               desktopControl.paused|resumed|takenOver events              [machines]
├── leasewaits.go              appToolCalls() gains drive_screen; offeredTools() gates it   [machines]
├── turns.go, lean.go          Stop releases "screen" and tells agents-drive to stop;
│                               liveFrame pushed to d.showers, never to d.record            [machines]
├── runtimes.go                toolPolicyEnv["codex"]["CODEX_CONFIG"]["features"]
│                               gains "computer_use": false (research R10)                  [runtimes]
└── capabilities.go             declares host.desktop-control/1                             [machines]
Packages/AgentsKit/Sources/AgentsKitCore/Model/
└── DesktopControl*.swift (new) decode, words                                               [agent-tools]
Shared/UI/Chat/
├── DesktopControlRefusalCard.swift (new)   Off / Accessibility-not-granted                 [chat]
├── DesktopControlPauseCard.swift (new)     Resume, Take Over                               [chat]
└── DesktopControlTile.swift (new)          the live tile: frame or "Mac is locked" +
                                             narration                                       [chat]
App/Sources/Settings/            the desktop-control switch (Agent Runtimes or a new row)   [settings]
Remote/Sources/Chat/             the pause card, the tile (Shared/UI, Core)                  [chat]
Web/src/views/chat/
├── DesktopControlTile.tsx (new)                                                             [chat]
├── DesktopControlPauseCard.tsx (new)                                                        [chat]
└── Rows.tsx                     draws the tile beside the existing LiveLine                 [chat]
Web/src/views/settings/          the switch, web twin                                        [settings]
Web/src/model/desktopControl.ts (new)                                                        [chat]
Web/test/desktopControl.test.mjs (new)                                                       [chat]
docs/                            the pages of the spec's Docs section                        [docs, settings, runtimes]
specs/071-web-remote/walks/parity/chat-turns-and-turn-detail.md   the live tile row, Core     [docs]
```

**Structure Decision**: one new executable (`agents-drive`, beside the existing
`agents-watch`), no new daemon binary, no new client app. Each client draws the live tile
and the pause card in its own idiom (`Shared/UI/Chat` for the Mac and the Remote,
`Web/src/views/chat` for the web page), matching how `TranscriptRows.swift`/`Rows.tsx`
already draw a running turn's live line, rather than inventing a fourth code path.

## Slices for the build

Each slice is one lane, one area set, its own tests and its own walk. A slice starts only
when no open PR or running lane holds its areas (#873). Slices 2 and 3 change what clients
show, so each is a UI enhancement and waits for Alex's approval of its screenshots
(#2811); slice 1's refusal card is small and part of the same tool that ships in that
slice, so it travels with it rather than waiting on its own.

| Slice | What | Areas | Needs | Walk |
|---|---|---|---|---|
| **1. The tool, the lease, and Off by default** | `agents-drive` (screenshot, AX click/read, real type/key); `host.desktop-control/1`; `drive_screen` and its lease take/release (research R4, R6); `desktop-control.json`, the refusal card, the Settings switch (Mac + web); Stop releases the lease | machines, agent-tools, settings | none | `run-app` scratch root: Off refuses; On but not granted refuses; granted succeeds; a second agent queues; Stop frees the lease |
| **2. Pause on touch, Resume, Take Over** | the `CGEventTap` touch filter (research R2); `DesktopControlState`; `desktopControl/resume`, `desktopControl/takeOver`; the pause card (Mac, Remote via Shared/UI, web) | machines, chat | slice 1 | `run-app`: a real mouse move pauses within 1 s (20 tries, SC-002); Resume continues; Take Over frees the lease |
| **3. The live tile on Mac, Remote and web** | `desktopControl/liveFrame`; the locked placeholder; the tile (Shared/UI, web); parity row (Core) | machines, chat | slice 1 | `run-app` Mac + headless Chrome, walk simulator for the Remote: tile refreshes within bounds; locked placeholder shows no pixels; an older client (capability dropped) shows an ordinary turn |
| **4. Turn off Codex's own `computer_use`** | `toolPolicyEnv` gains the flag; `docs/reference/runtimes.md` row split | runtimes, docs | none | scratch Codex agent: `features.computer_use` is `false` in its launch config |

**Order**: 1 → 2 → 3 (2 and 3 both hold `chat`, so they go one after the other). Slice 4
holds no area either of the others does, and may run at any point alongside them. The
parity row goes with slice 3; the other docs pages go with the slice that ships what they
describe (slice 1: `agent-tools.md`, `leases.md`, `settings.md`; slice 3:
`let-an-agent-drive-desktop-apps.md`'s watching half; slice 4: `runtimes.md`).

**Parity line**: slice 3 is Core on all three clients in the same branch, so its own commit
needs no `remote:`/`web:` follow-up line; slice 1's Settings switch is Mac + web by
AGENTS.md's default rule (on neither the Core nor the Mac+web list by name, so it takes the
default), with the row in `parity/settings-and-project-settings.md` noting `remote: tier
mac+web`.

## Complexity Tracking

None.
