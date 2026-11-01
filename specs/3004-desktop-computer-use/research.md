# Research: Desktop control

What exists today, and why each decision in `plan.md` was made. Paths are from `main` at
`25bc8c60c`. `<settings>` is `<root>/settings`; `<root>` is
`~/Library/Application Support/Agents` on a Mac.

## What exists

### The screen lease, already reserved

| Thing | Where | What this plan does with it |
|---|---|---|
| `ResourceKindScreen` | `Go/wire/types_gen.go:7943-7948` (generated from `Packages/Wire/daemon.schema.json`); Swift mirror `Packages/AgentsKit/Sources/AgentsKitCore/Model/Lease.swift:66-71` | Reused as is (FR-002); no wire change. |
| The lease book | `Go/internal/agentsd/leases.go`: `leaseEntry`, `waiter`, `leaseBook`, persisted at `<root>/leases.json` | `leaseSnapshot()` (`leases.go:415-487`) already hardcodes a `"screen"` row (`:460-463`), so the resource already shows in `list_resources` and **Resources**, held or not. |
| Acquire/release/extend | `Go/internal/agentsd/leasecalls.go` (`leaseResource`, `releaseResource`, `listResources`, `resolveResource`) | New code calls the same internal grant/queue path (R4), not a second one. |
| Wait in line | `Go/internal/agentsd/leasewaits.go` (`linePattern`, `openLineWait`, `leaveLine`), event `lease.granted`, spec 042 | Reused as is: a second agent that calls the new tool while the lease is held waits exactly as it would for `lease_resource("screen")` (FR-002, Acceptance Scenario 4). |

### No automatic `browser` lease, and no real-input driving code today

`ResourceKindBrowser` and the `"browser:"`/`"simulator:"` prefixes (`leases.go:496`,
`Lease.swift:167-169`) are a naming convention only; nothing in this repo calls
`lease_resource` on an agent's behalf before Playwright drives a browser. The only existing
screen-reading code is `run-app`'s own walk driver:

| Thing | Where | What it does, and does not do |
|---|---|---|
| `ui.swift` | `.agents/skills/run-app/scripts/ui.swift` | `AXUIElementCreateApplication(pid)`, walks the AX tree, and acts **on the AX tree** (`kAXPressAction`, sets `kAXValueAttribute`/`kAXSelectedAttribute`/`AXDisclosing`) — never moves the real pointer or sends a real key event. Needs `AXIsProcessTrusted()` (line 116), checked against whatever process runs `swift ui.swift …` (a scratch, unsigned invocation; not a shipped binary; see R1). |
| `shot.sh` | `.agents/skills/run-app/scripts/shot.sh` | `screencapture -o -x -l <window id>`, captures one window without raising it (works behind the person's own window or on another Space). |
| `walk.py` | `.agents/skills/run-app/SKILL.md` | talks to an in-process debug socket a Debug build opens, not AX at all; only for this app's own scratch builds. |

No code in this repo calls `CGEventCreateMouseEvent`, `CGEventPost` or
`CGEventCreateKeyboardEvent` (checked across the whole tree). Real mouse and keyboard
synthesis (FR-001's "synthetic mouse, keyboard and key events") is new code for this
feature, not a reuse.

### How Go reaches CoreGraphics and IOKit today: a sibling helper, not cgo

`Go/internal/agentsd/machine_darwin.go:14-16`: "StartMachineWatch hears the Mac through
`agents-watch --machine`, beside this binary in Agents Host's Helpers: IOKit and
CoreGraphics are out of Go's reach without cgo." `agentsd` finds the helper via
`watchHelper()` (a sibling file in `Contents/Helpers`; `install_darwin.go:9`: "the app
carries beside this binary (Contents/Helpers → Contents/Resources/toolsets)"), starts it
with `exec.Command`, and reads a NUL-byte-delimited word stream off its stdout
(`machine_darwin.go:81-106`); the Swift side is `Host/AgentsWatch/Machine.swift`, a small
`Never`-returning loop reading `IORegisterForSystemPower` and polling
`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` and `IOHIDSystem`'s
`HIDIdleTime` every 10 seconds, writing words (`sleep`, `wake`, `away:locked`, `back:idle`,
…) that `machine.go:22,95-101` turns into the already-shipped events `mac.sleep`,
`mac.wake`, `person.away`, `person.back`. This is the exact shape for a second helper (R1).

### Locked-screen detection already exists

`screenIsLocked()` (`Host/AgentsWatch/Machine.swift:38-40`) and `d.personAway()` (returns
`"locked"`, `"idle"`, or `""`) are already wired end to end. FR-012's "Mac is locked"
placeholder reads `d.personAway() == "locked"`; no new detector.

### Live status today: the transcript's own running line, not a side channel

`Go/internal/agentsd/turns.go:1130-1183` (`live.Update`) turns ACP `ToolCall`/
`ToolCallUpdate` into a `wire.TranscriptEntryKind{ToolCall:…}` entry via `d.record`, and
`Go/internal/agentsd/lean.go:70-85` (`tellEntry`) pushes `wire.NotifyAgentEntry` only to
the clients currently "showing" that agent (`d.showers`). `Shared/UI/Chat/TranscriptRows.swift:275`
and `Web/src/views/chat/Rows.tsx:495-497` (`LiveLine`) already draw "a running turn's
latest step, in one line, until the turn has its outcome" from `turnLine()`
(`Web/src/model/turns.ts:82-83`). A separate `attention/turn` push
(`Packages/Wire/control.openrpc.json:47-50`, capability `liveactivity/1`,
`AttentionTurn{agentID, phase, endedAt}`) exists only for iOS's lock-screen Live Activity
(APNs), not for in-app live content.

### Policy refusal shape, and the nearest off-by-default precedent

`Go/internal/agentsd/policy.go:306` `policyRefusal(reason, rule, words string, until
*time.Time) error` is the organisation-policy refusal; `Shared/UI/OrgPolicyLine.swift:32-47`
(`OrgPolicyRefusalLine`) and its web twin draw `refusal.title` + `refusal.words`. It is
shaped for the **organisation** layer (`rule`, `layer`), not a standalone person-level
switch, and spec 2957 (the policy layers that would eventually hold this rule) has no code
yet (`Go/internal/policylayers` does not exist; `specs/2957-policy-layers/tasks.md` does not
exist either) — confirming the spec's own assumption that this switch is temporary and
stands alone for now. The nearest **off-by-default boolean that gates a tool call**, in
spirit, is the already-shipped "Agents may start sessions on my other machines without
asking" (`docs/reference/agent-tools.md`, `start_session`'s row, #2928): off by default, and
while off, the call still runs but asks first; here the switch must refuse outright
(FR-004), which is new.

### A runtime's own flag is already turned off the same way elsewhere

`docs/reference/runtimes.md:334`: Codex's `features.browser_use`, `computer_use`,
`image_generation` row, today "Measure: they may be tools that duplicate the app's."
`Go/internal/agentsd/runtimes.go` already merges a `features` map into `CODEX_CONFIG` per
launch (`toolPolicyEnv`, `withToolPolicy`) for other flags (`sleep_tool: false`,
`apps: false`); adding `"computer_use": false` there is the same mechanism FR-010 needs.

### "Needs your hands" and what is genuinely new

`ask_question`/`ask_secret` go through `Go/internal/agentsd/elicitations.go`
(`pendingElicitation`); `WorkOutcome.needsAPerson` and the three ways a turn ends
(`docs/reference/agent-tools.md`) are the existing "needs a person" shape the Edge Cases
section points at, and that part needs no new code. **Take Over has no precedent anywhere
in this repo** (checked across Go, Shared/UI, Web and docs): the pause-on-touch card,
Resume, and Take Over are new wire surface and new UI, not a rename of something that
exists.

## Decisions

### R1. The driver is a second sibling helper beside `agents-watch`, not the scratch `ui.swift`, and not inside Agents Host's own GUI process

- **Decision**: a new helper binary, `agents-drive`, built and shipped the way
  `agents-watch` is (an executable in `Contents/Helpers`, found by `watchHelper()`'s
  sibling-path logic, started by `agentsd` with `exec.Command` and a NUL-delimited
  stdin/stdout protocol: commands in (`screenshot`, `click <app> <label-or-x,y>`, `type
  <text>`, `key <name>`, `read <app>`), replies out (`ok`, a screenshot handed back once and
  not kept, `touch` the moment a real HID event that is not the helper's own arrives)). It
  runs only while the `screen` lease is held (R4), and exits the moment it is released.
- **Why**: Go cannot reach `ApplicationServices`/`CoreGraphics`/`IOKit` without cgo (the
  exact reason `agents-watch` exists, `machine_darwin.go:14-16`); the scratch `ui.swift` is
  an unsigned, ad hoc script invoked by `swift ui.swift …`, never carries a stable code
  identity for TCC to remember, and only ever touches the AX tree, never a real pointer or
  key (it is explicitly the thing `run-app`'s own skill doc keeps separate from "real
  trackpad gestures… and the `screen` lease"). Building this inside Agents Host's own GUI
  process would mean a crash or a slow AX call on the screen-driving path could affect the
  window that is also drawing the person's own chat.
- **Not chosen**: cgo inside `agentsd` (the project avoids cgo everywhere else for this exact
  reason); reusing `ui.swift` unchanged as the shipped tool (it cannot inject real HID
  events, and it is not a binary the Accessibility permission can be granted to once, by
  name, and keep).
- **Open risk, to confirm during the build (quickstart.md)**: whether macOS attributes the
  Accessibility grant to "Agents Host" (the "responsible process" for a bundled helper under
  `Contents/Helpers`) or to `agents-drive` by its own path, the way a loose `agents-watch`
  binary might be named today. `install_darwin.go:9`'s existing "Contents/Helpers →
  Contents/Resources/toolsets" packaging is the same shape `agents-watch` already ships
  under, so the same answer applies to both; if it turns out to name `agents-drive` on its
  own, FR-005's card names that binary instead of "Agents Host," and the docs page says so.

### R2. Real mouse and keyboard synthesis: `CGEvent`, tagged so the helper can tell its own input from the person's

- **Decision**: `agents-drive` posts input with `CGEventCreateMouseEvent`/
  `CGEventCreateKeyboardEvent` and `CGEventPost(.cghidEventTap, …)`, and marks every event it
  makes with `CGEventSetIntegerValueField(event, .eventSourceUserData,
  agentsDriveMarker)` before posting. A global, listen-only `CGEventTap` (tap point
  `.cghidEventTap`, which sees events after they are injected) filters out anything carrying
  that marker; everything else is the person's own touch (FR-007).
- **Why**: `CGEventTapCreate` is the only way to hear a mouse move or key press as it
  happens, within the "stops within the second" bound of SC-002; nothing already in this
  repo listens for real input (new code). Tagging, rather than disabling the tap while the
  helper acts, is needed because the tap must also catch the person's own input **during** a
  drawn-out agent action (that is the whole point of "pause on touch"), so it cannot simply
  be off while the helper works.
- **Not chosen**: `NSEvent.addGlobalMonitorForEvents` (Cocoa-level, coarser, and still needs
  the same marker to avoid hearing the helper's own events); polling mouse location
  (`CGEventGetLocation` on a timer) misses key presses and is not sub-second reliably.

### R3. The screenshot: `SCScreenshotManager.captureImage` of the main display, kept only in memory

- **Decided (US1's build, superseding this row's original choice): `ScreenCaptureKit`'s
  `SCScreenshotManager.captureImage`, not `CGWindowListCreateImage`, because Alex can
  overrule.** `CGWindowListCreateImage` is obsolete on this project's deployment target
  (macOS 27, `project.yml`'s `deploymentTarget.macOS`): Swift refuses to build it
  ("obsoleted in macOS 15.0 … Please use ScreenCaptureKit instead"), so the row below's
  original decision does not compile and could not have been walked. `captureImage` is
  itself a one-shot still (`SCScreenshotManager`, not `SCStream`), so the "built for a
  continuous video stream" reason for not choosing ScreenCaptureKit no longer holds either:
  there is no media server or running stream to hold open, one `await` per request.
- **Decision (original, for the shape kept)**: `agents-drive` makes the screenshot of the
  main display (Assumptions: single display), downscaled to a width that keeps each frame
  well under the size of an ordinary chat image, and hands it to `agentsd` once per request;
  `agentsd` forwards it to clients that are showing the session (R7) and never calls
  `d.record` with it, matching FR-016, and widening `shot.sh`'s existing "capture without
  raising anything" idea to the whole screen because the tool can act on any app, not one
  known window.
- **Why**: this is the full-display equivalent of what `shot.sh` already proves works
  without stealing focus; neither API raises or activates anything, and both give pixel
  data directly to the helper instead of a file `screencapture` would have to write and the
  Go side would have to delete. `captureImage` needs Screen Recording granted once, a
  second permission beside Accessibility (US2's gate names both).
- **Not chosen**: `screencapture` as a subprocess per frame (an extra process launch every
  few seconds, and a file on disk, however briefly, that FR-016 says must never exist).

### R4. Where the lease is taken: by the tool itself, not by the agent's own `lease_resource` call

- **Decision**: the new agent tool (`drive_screen`, R6) takes the `screen` lease itself,
  through the same internal grant/queue path `leaseResource` uses (`leasecalls.go`), on its
  first call in a turn, and releases it (through the same path `releaseResource` uses) when
  the agent stops calling it for longer than the turn, the turn stops, or the person takes
  over (FR-002, FR-008, FR-009). An agent does not call `lease_resource("screen")` itself
  first.
- **Why**: FR-002 says "the tool MUST take the lease," not "the agent MUST lease it first,"
  unlike `build` or `browser`, where the project already accepts the manual-discipline
  trade-off (AGENTS.md's own leasing rule). This tool can move the real pointer; making the
  safety property (nobody collides) depend on the agent remembering a separate call first is
  a weaker guarantee than the tool enforcing it as its own first step.
- **Not chosen**: the manual pattern (document "lease `screen` before `drive_screen`" in the
  briefing and leave it to the agent, as for `build`/`browser`): it is one more thing an
  agent can forget, for the one tool where forgetting means fighting the person for the
  mouse.
- **A second agent that calls `drive_screen` while the lease is held** gets exactly the
  existing "waiting in line" answer `lease_resource` gives (place in line, a wait for
  `lease.granted`), because it is the same internal queue (FR-002, Acceptance Scenario 4).

### R5. The off switch: its own small file and refusal, not `OrgPolicy` or spec 2957's unbuilt policy layers

- **Decision**: one new person-level setting, `<settings>/desktop-control.json`
  `{enabled: bool}` (absent or `false` is Off), read and written the way `sandbox.json`/
  `display.json` already are (`d.writeSetting`, `sandbox.go:244`'s pattern). A new small
  refusal type, `DesktopControlRefusal{reason: "off" | "accessibilityNotGranted", words}`,
  drawn by a new, small card (`Shared/UI/Chat/DesktopControlRefusalCard.swift` and its web
  twin) rather than `PolicyRefusal` (which carries organisation-specific fields, `rule` and
  `layer`, that do not apply to a lone person setting).
- **Why**: spec 2957's `Go/internal/policylayers` and `policy-yours.json` do not exist yet
  (confirmed above), exactly as the spec's own Assumptions say ("a single person-level
  setting until spec 2957's policy layers ship... read once, FR-012 there"); building this
  switch on top of unbuilt code is not possible, and reusing `OrgPolicy`'s shape for a rule
  that is never set by an organisation would mean carrying fields (`layer`, a rank against
  other layers) that mean nothing here.
- **Not chosen**: waiting for spec 2957 to ship first (it has no tasks yet, and this feature
  does not depend on it); folding the switch into `sandbox.json` or another existing file (a
  different concern, and FR-004's refusal needs its own words, naming its own rule, which a
  shared file would blur).
- **Who may change it**: the person's own clients only (Settings), never the agent socket
  role, an MCP tool, or a workflow — the same restriction `policy/setYours` already places on
  changing **your** policy layer (FR-004's own intent: an agent cannot turn on its own
  permission to drive the screen).
- **Decided (US2's build, amending this row's card): no `DesktopControlRefusalCard.swift`
  or web twin. The refusal's words reach the person as `drive_screen`'s own plain error
  text, not a dedicated card. Alex can overrule.** `drive_screen` is an app tool: a failed
  call's result crosses into the runtime over MCP's `tools/call`
  (`Go/internal/agentsd/apptools.go:449-452`), which keeps only `Error.Message` and drops
  `Error.Data` — the same boundary every other app tool's refusal already crosses (`Invalid`,
  `leaseRefused`, `notPermitted`; confirmed no app-tool refusal anywhere in this repo reaches
  a client as a dedicated card). `DesktopControlRefusal`'s `words` is still written as a
  clear, complete sentence naming the rule and where to fix it (FR-004, FR-005), so the
  runtime's own rendering of a failed tool call already satisfies both FRs; a Swift struct
  and card that decode `error.data` would be unreachable dead code, since no client ever
  sees that structured payload for a tool call this shape. `wire.DesktopControlRefusal`
  itself is kept (data-model.md's contract, and the Go handler's own test,
  `screensettings_test.go`), since it still documents the shape and reason cleanly on the Go
  side even though it crosses no further. A later story (the live tile, US4) already adds
  its own notifications (`desktopControl/liveFrame`, `desktopControl/stateChanged`)
  specifically because the ordinary tool pipeline cannot carry rich state (R7); if a visual
  card for this refusal is wanted later, it would ride a notification of that shape, not the
  tool call's own result.

### R6. One tool, `drive_screen`, with an action field — not one tool per verb

- **Decision**: a single app tool, `drive_screen`, added to `appToolCalls()`
  (`Go/internal/agentsd/leasewaits.go:60-92`) with its schema in `Go/wire/app-tools.json`
  (and the `Packages/Wire` mirror), params `{app, action: "screenshot" | "click" | "type" |
  "key" | "read", label?, x?, y?, text?, keyName?}`, one handler (a new file,
  `screencalls.go`, beside `leasecalls.go`), mirroring `ui.swift`'s own verbs (`find`/
  `press`, `set`, `dump`) for the AX-addressed actions, plus the new `click`-by-coordinate
  and real `type`/`key` actions R2 adds.
- **Why**: the spec's own words, "one screen, one lease, one watch path, one way to pause
  and take over" (Decisions table), argue for one capability and one refusal path rather
  than several; `lease_resource`/`release_resource`/`list_resources` are three tools because
  acquiring, releasing and listing are three different relationships to the lease, not
  several ways of acting once held.
- **Not chosen**: a tool per verb (`click_screen`, `type_screen`, …): several capability
  declarations, several refusal paths, and several rows in `docs/reference/agent-tools.md`
  for one feature.

### R7. The live tile: the narration rides the existing transcript line; the screenshot is a new, unrecorded push

- **Decision**: the narration ("Clicking Export in Preview") is `drive_screen`'s own ACP
  tool-call title, already carried end to end by the existing live-step pipeline
  (`live.Update` → `d.record` → `tellEntry`/`NotifyAgentEntry` → `TranscriptRows.swift`/
  `Rows.tsx`'s `turnLine()`) — no new wire type for the narration. The screenshot is a new
  notification, `desktopControl/liveFrame {agentID, image, capturedAt}` (or, while the
  screen is locked, `{agentID, locked: true, capturedAt}` and no `image`, FR-012), sent only
  to clients currently showing that agent (`d.showers`, the exact gate `tellEntry` already
  uses) and **never** passed to `d.record`, so it cannot end up in saved history (FR-016)
  even by accident.
- **Why**: FR-016 explicitly splits the two ("The narration line MUST be written to the
  turn's ordinary record... [the screenshot] MUST NOT"); riding one pipe for both would make
  that split one `if` away from a leak. The narration already works today for every other
  tool; only the part that must not be saved needs a new path.
- **Not chosen**: reusing `attention/turn`/`liveactivity/1` (built for APNs Live Activities,
  phase-keyed, not a per-frame image channel); a new transcript entry kind for the
  screenshot that is simply never read back (it would still write it to the record store
  first, which SC-005 rules out: "no screenshot... is ever found on disk or in a turn's
  saved history").

### R8. Capability: `host.desktop-control/1`, following the existing convention exactly

- **Decision**: `x-capability: host.desktop-control/1` on the new `desktopControl/*` daemon
  methods (`state`, `set`, `resume`, `takeOver`, `liveFrame`) in `daemon.openrpc.json`,
  alongside `host.policy/1` and `host.wire/1` (`Packages/Wire/daemon.openrpc.json:8-13`,
  `README.md:52`); `drive_screen` itself is offered only when the capability is declared,
  the same gate `offeredTools()` (`leasewaits.go:356-380`) already applies to every app
  tool. An older client that does not know it shows the session as an ordinary running
  turn (Edge Cases, "An older client," the same degrade path as spec 1748).
- **Why**: this is the repo's one existing way to say "a machine or client must be new
  enough" (`Go/internal/agentsd/capabilities.go:9-23`, `host/hello`); nothing new is needed
  to invent it.

### R9. Pause, Resume, Take Over: new wire surface, modelled on the existing permission/elicitation shape

- **Decision**: a small new state, `DesktopControlState{heldBy: agentID?, app,
  lastNarration, paused: bool}`, kept on the agent (one per session that holds the lease),
  pushed on change (`desktopControl/stateChanged`) the same way a permission request is
  pushed today (`wire.NotifyAgentPermission`, `turns.go:1328,1348`); `desktopControl/resume`
  and `desktopControl/takeOver` are new daemon methods any of the person's own clients may
  call. **Take Over** calls the same internal release path R4 uses. **Stop** (FR-009) needs
  no new method: the existing stop-turn path already cancels the in-flight tool call; it is
  extended to also release the `screen` lease and tell `agents-drive` to stop its current
  action, the same shape every other cancelled tool call already gets.
- **Why**: confirmed above, nothing like Take Over exists to rename; the shape (a pending
  state, pushed to every client, answered by one of a small fixed set of actions) is
  exactly `ask_question`/permission's shape, reused rather than invented twice.
- **Not chosen**: folding Resume/Take Over into the existing permission-answer method
  (`PermissionAnswer` has a fixed small set of answers already tied to tool-call risk, not
  to "a person touched the mouse"; stretching it would make that method's meaning less clear
  for every other tool that uses it).

### R10. Turning off a runtime's own `computer_use`

- **Decision**: `Go/internal/agentsd/runtimes.go`'s `toolPolicyEnv["codex"]["CODEX_CONFIG"]
  ["features"]` map gains `"computer_use": false`, beside the existing `sleep_tool`/`apps`
  entries, applied by the existing `withToolPolicy` on every launch. `docs/reference/
  runtimes.md`'s row (`:334`) is split: `computer_use` moves to its own row, "Superseded by
  the app's own desktop-control tool," naming this feature; `browser_use` and
  `image_generation` keep today's "Measure" row.
- **Why**: FR-010, and the exact mechanism already shipped for the same kind of per-feature
  Codex toggle.

### R11. Libraries before our own code

- **Decision**: platform libraries only — `ApplicationServices`/`AppKit` (AX, `CGEvent*`),
  `CoreGraphics` (`CGWindowListCreateImage`), `IOKit` (the same lock/idle facts `agents-watch`
  already reads) — all part of the macOS SDK, already linked by `Host/AgentsWatch` and the
  `run-app` scripts, no new dependency, no licence to record, no version to pin. No
  third-party library fits: this is OS-level input synthesis and screen reading, not a
  parser, protocol or format with a community library to prefer, and the project's own
  `run-app` walk driver already proves the platform APIs are sufficient.
- **Why**: AGENTS.md's "Libraries before our own code" rule asks this question first; the
  answer here is the same one `run-app`'s existing driver already gives.

## Sizes

A live frame, downscaled, is well under 1 MB; at the 2–5 s refresh of FR-011 that is under
1 MB/s to each showing client while the lease is held, and nothing is kept after release.
The screen lease, the pause state and the refusal are all tiny, in-memory records; no new
persisted store beyond the one `desktop-control.json` boolean.
