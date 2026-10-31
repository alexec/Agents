# Feature Specification: Desktop control: an agent drives apps on the Mac, watched from another device

**Feature Branch**: `agents/3004-let-an-agent-drive-desktop` (spec only)

**Created**: 2026-10-30

**Status**: Draft. Nothing here is built yet.

**Milestone**: none yet (backlog, `competitor`). **Tier**: driving the screen is **one client** (the Mac; see Decisions). Watching and steering a session that is driving the screen is **Core** (all three clients).

**Input**: Issue #3004, and the competitor-check report behind it (Nuphos desktop v0.98.0 / iOS v0.21.0, Orca v1.4.245, Pragma www-v1.5.0, all 2026-10-30). Alex's only comment on the issue is "Needs a spec."

It touches the closed issue #843, "A built-in browser that the agent drives" (declined, 2026-10-12: "agents already have a good browser on the computer... an agent can drive a browser through the Playwright MCP server from the marketplace, and the browser lease keeps it to one agent at a time... Goal: none now"). It builds on the resource-lease system (`docs/explanation/leases.md`), which already reserves a `screen` resource ("the screen, mouse and keyboard... one agent at a time") that no shipped tool acquires today, and on the command-sandbox rule of the policy work (specs 998 and 2957).

## Why this feature exists

**Today, an agent can drive a browser and nothing else.** Issue #843 found that worth doing only through the Playwright MCP server from the marketplace, with the `browser` lease to keep one agent on it at a time; the app ships no first-party tool that clicks, types or reads pixels, and nothing an agent does to a GUI is shown on another device. The `screen` resource name is already reserved in the lease system, for exactly this, but nothing in the app ever asks for it: the only code that drives a Mac app's UI by its Accessibility tree is `run-app`'s own walk driver, built to verify this app's own scratch builds, not offered to agents or to other apps.

**The gap is everything with no API and no MCP server.** A native installer, Xcode's own UI, Preview, Blender, a settings pane — an agent that must get through one of these today has no tool for it. Three competitors closed that gap, in the same window, each with a fuller answer: Orca runs computer use in the background so the person keeps their own mouse; Nuphos streams the Mac's own screen to an iPhone so the person can watch and steer from there; Pragma reaches Windows as well as Mac. That repetition inside 24 hours is why the issue exists.

**Moving the real mouse and keyboard has no existing sandbox.** The browser pane is restricted to `http`/`https`/`about`/`file` schemes (`BrowserPolicy.swift`); shell commands sit behind the command-sandbox rule (`sandbox: required`, `docs/reference/policy.md`). Nothing bounds what an agent could click if it can click anything on the screen — a native app has no DOM, no URL scheme, no sandboxed process boundary to lean on. This spec's safety answer is not a new sandbox around *what* it can click (there isn't a clean one), but three things the app already leans on elsewhere: the lease that stops two actors colliding, an explicit off-by-default switch, and making every action watchable and instantly stoppable from any of the person's own devices. Agents Host still runs, and still drives the screen, as the person's own user — no elevated privilege, as for every other host capability.

## Decisions

| Question | Answer | Who, when |
|---|---|---|
| Which apps can an agent drive | **Any app on the Mac**, through the system Accessibility API and synthetic mouse/keyboard events — the same technique `run-app`'s walk driver already proves, offered for the first time as a tool of the `agents` server rather than a test-only script. No per-app integration. | Decided by Claude (#3004). Alex can overrule. |
| Does this replace the Playwright-MCP browser story (#843) | **No.** A browser is still best driven through Playwright: it reads the DOM instead of guessing from pixels. This tool is for everything Playwright cannot reach. | Decided by Claude. Alex can overrule. |
| Exclusive use, or background use like Orca's (the person keeps their own mouse while the agent drives a hidden session) | **Exclusive, for v1.** The agent holds the existing `screen` lease for as long as it drives the real screen, the same trade-off the project already lives with for `browser` and `simulator:` leases. A private, virtual display that lets the person keep working at the same time is real, but it is a new subsystem on its own; it is out of scope here and worth its own follow-up issue once this ships. | Decided by Claude. Alex can overrule. |
| The person's real screen, or a virtual one the agent gets to itself | **The person's real screen, for v1.** It needs no new display subsystem, and it means the person can always see, on the Mac itself, literally what the agent is doing — the strongest form of watchability. The cost is the exclusivity above. | Decided by Claude. Alex can overrule. |
| Who can watch, and from where | **All three clients** (Core): the Mac window, the Remote and the web page each show a live tile for a session that holds the `screen` lease, because "watch it work from another device" is the issue's own second half, not an afterthought. | Decided by Claude. Alex can overrule. |
| A video stream (H.264, as Nuphos ships) or periodic screenshots | **Periodic screenshots plus a one-line text narration, for v1.** No new media server or streaming pipeline; small, plain data in keeping with the project's local-first bias. Full-motion video is a possible later issue once this ships and is watched for real. | Decided by Claude. Alex can overrule. |
| A new policy rule, or reuse of an existing one | **A new rule, "desktop control,"** off by default, belonging in the policy layers (spec 2957) once that ships. Until then it is a single person-level switch (alongside the other settings spec 2957 is consolidating), carried into the policy layer later with no loss, the same way spec 2957 reads old settings into itself once (FR-012 there). | Decided by Claude. Alex can overrule. |
| Does driving the screen need a new macOS permission | **Yes: the Accessibility permission**, granted once to Agents Host in System Settings ▸ Privacy & Security ▸ Accessibility — the same permission `run-app`'s own driver needs today. No elevated or root privilege; this is why Agents Host can do this at all without breaking "Hosts never escalate." | Decided by Claude. Alex can overrule. |
| What happens when the person touches the real mouse or keyboard while the lease is held | **The agent's action pauses at once**, and every client offers Resume or Take Over, rather than the agent fighting the person for the pointer. | Decided by Claude. Alex can overrule. |
| What the live tile shows while the Mac is locked | **A "Mac is locked" placeholder and the text narration only — no screenshot pixels**, so a login field or lock-screen content is never captured or sent to another device. Desktop control itself keeps working while locked, exactly as `run-app`'s driver does today; only the picture is withheld. | Decided by Claude. Alex can overrule. |
| A runtime's own built-in computer-use feature (Codex's `computer_use`, `docs/reference/runtimes.md`, "Measure") | **Turned off, superseded by this tool.** One screen, one lease, one watch path, one way to pause and take over — not two unrelated implementations in the same session. | Decided by Claude. Alex can overrule. |
| Does a Remote or web client get to move the real mouse by remote control (as Nuphos's iOS app does) | **Not in this version.** Steering from another device is limited to Resume, Take Over, Stop and ordinary chat messages to the agent. Forwarding raw touch input from a phone into arbitrary Mac apps is its own project (input mapping, a different trust boundary) and is not needed to answer "watch it work and step in if it goes wrong." | Decided by Claude. Alex can overrule. |
| Where the screenshot is kept | **Nowhere.** It exists only for as long as the lease is held and is never written to the project or to the turn's saved history, in keeping with the project's "store data in the project, or not at all" default — there is no good place to keep a growing set of screen captures. The narration line is kept, as an ordinary turn step. | Decided by Claude. Alex can overrule. |

## Words

- **Desktop control**: the capability this spec adds — an agent reads and acts on the screen of any Mac app through the Accessibility API, not only a sandboxed browser pane.
- **Screen lease**: the resource named `screen` that the lease system has reserved since before this feature (`docs/explanation/leases.md`); holding it is what lets an agent drive the real screen, and it is what makes two agents, or the person and an agent, take turns rather than collide.
- **Live tile**: the view a paired client shows for a session that holds the screen lease: the latest screenshot (or the locked placeholder) and the current narration line.
- **Narration**: the one-line description of the action in progress ("Clicking Export in Preview"), written to the turn's ordinary record.
- **Take over**: releases the screen lease at once and hands input back to the person; the opposite of the agent holding it.
- **Pause on touch**: the automatic pause that happens the moment the person uses the real mouse or keyboard while the lease is held.

## Clarifications

### Session 2026-10-30 (the issue has no mock-up; decide and tell)

- Q: Does "watch it work from another device" mean the phone can also move the real mouse, the way Nuphos's iOS app does?
  → A: **No**, not in v1 (see Decisions). It watches, and it can Resume, Take Over, Stop, or send the agent a message — all of which already exist as controls on a running turn, extended to a session that holds the screen lease.
- Q: Must this reach Windows or Linux hosts, since Pragma's release added Windows in the same breath?
  → A: **No.** Every GUI client this project ships (the Mac window, the Remote, the web page) is a view onto a Mac; the Linux devbox (`.agents` server work) has no GUI session to drive. A GUI host on another OS is a precondition this issue does not have yet, and is its own later issue if one ever exists.
- Q: Could an agent hold both the `browser` lease (Playwright) and the `screen` lease in the same turn, for a task that spans a download in the browser and an edit in a native app?
  → A: **Yes, when both are free.** They are different resource names; nothing about this feature makes them mutually exclusive with each other, only each exclusive with itself (see Edge Cases).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent gets through an app with no API, and the person can stop it (Priority: P1)

Alex asks an agent to crop a screenshot in Preview — an app with no API and no MCP server. With desktop control on, the agent calls the new tool, takes the `screen` lease, and drives Preview through the Accessibility API: opening the file, dragging the crop handles, exporting. The chat records each step as an ordinary part of the turn. Partway through, Alex decides the crop is wrong and presses **Stop**. The agent's action stops, the lease is released, and the chat says the turn was stopped.

**Why this priority**: this is the whole first half of the issue. Without it, there is no new capability at all.

**Independent Test**: on a scratch set-up with desktop control on and Accessibility granted, give an agent a task reachable only by clicking a non-browser app. Confirm it completes using the new tool, the chat shows each step, and pressing Stop at any point halts it and frees the lease.

**Acceptance Scenarios**:

1. **Given** desktop control is on and Accessibility is granted, **When** the agent calls the desktop-control tool, **Then** it takes the `screen` lease, acts on the named app through the Accessibility API, and each action is recorded as an ordinary step of the turn.
2. **Given** the agent is driving the screen, **When** the person presses **Stop** on any client, **Then** the action stops, the `screen` lease is released, and the chat says the turn was stopped.
3. **Given** desktop control is **off** (the default), **When** an agent calls the tool, **Then** the call is refused with a card that names the desktop-control rule and where to turn it on.
4. **Given** another agent or the Accessibility walk driver already holds the `screen` lease, **When** a second agent calls the tool, **Then** it waits in line for the lease, as it would for `build` or `browser` today.

---

### User Story 2 - Turning it on, and the one-time Accessibility grant (Priority: P1)

Alex opens Settings and turns desktop control on for the first time. The next time an agent calls the tool, macOS itself asks whether Agents Host may use the Accessibility API. Alex approves it once, in System Settings. Every later call, on this Mac, needs no further prompt.

**Why this priority**: nothing in User Story 1 works without this, and it is the main new risk surface, so it must be explicit and visible rather than silently on.

**Independent Test**: on a fresh scratch install, confirm the switch defaults to off with a line explaining what it allows. Turn it on, trigger a desktop-control call, and confirm macOS's Accessibility prompt appears for Agents Host; until it is approved, confirm the call fails with a card naming where to grant it; after approval, confirm a second call succeeds with no further prompt.

**Acceptance Scenarios**:

1. **Given** a fresh install, **When** the person opens Settings, **Then** desktop control shows **Off**, with a line that says what it allows and that macOS will ask for the Accessibility permission on first use.
2. **Given** the person turns it on, **When** an agent first calls the tool, **Then** macOS's own Accessibility prompt appears for Agents Host, and until it is approved, every call fails with a card that tells the person where to grant it.
3. **Given** Accessibility is already granted, **When** a later agent calls the tool, **Then** it succeeds with no further system prompt, on that machine.

---

### User Story 3 - The person's own touch pauses the agent, never fights it (Priority: P2)

While an agent is driving Preview, Alex reaches for the real mouse to check something. The agent's current action stops at once. Every client showing that session offers **Resume** and **Take Over**. Alex taps **Take Over**; the screen lease is released and the chat says Alex took over.

**Why this priority**: without this, the one real new hazard — a person and an agent fighting over the same pointer — has no answer.

**Independent Test**: on a scratch set-up, start a desktop-control run, then move the real mouse or press a key. Confirm the action stops within the second and a card offers Resume/Take Over on every client; confirm each choice does what it says.

**Acceptance Scenarios**:

1. **Given** the agent holds the screen lease and is mid-action, **When** the person moves the real mouse or presses any real key, **Then** the current action stops at once and every client showing that session offers **Resume** and **Take Over**.
2. **Given** the paused card, **When** the person chooses **Take Over**, **Then** the screen lease is released at once and the chat says the person took over.
3. **Given** the paused card, **When** the person chooses **Resume**, **Then** the agent continues the action from where it paused.

---

### User Story 4 - Watching live from the Remote or the web page (Priority: P2)

Away from the Mac, Alex opens the session on the Remote. It shows a live tile: the latest screenshot and a narration line ("Dragging the crop handle in Preview"), refreshing every few seconds with no action needed. When the run later pauses (User Story 3) or finishes, Alex gets the same kind of notice as for any other turn that needs attention. Opening the same session on the web page shows the identical tile.

**Why this priority**: this is the issue's second half — standalone value even before the person does anything.

**Independent Test**: on the walk simulator (or a paired iPhone) and on the web page, open a session that holds the `screen` lease. Confirm the live tile appears with no setup step, the screenshot and narration refresh on their own, and a notice arrives when the run pauses or ends while the client is backgrounded.

**Acceptance Scenarios**:

1. **Given** a session holds the `screen` lease, **When** any paired client opens that session, **Then** it shows a live tile with the latest screenshot (or the locked placeholder) and the current narration line, refreshed within 2 seconds of each action and at least every 5 seconds while idle.
2. **Given** the Remote is backgrounded, **When** the run pauses (User Story 3) or ends, **Then** the person gets the same notice they get for any other turn needing attention.
3. **Given** the web page, **When** the person opens the same session, **Then** it shows the same live tile and the same Resume/Take Over/Stop controls.
4. **Given** the Mac's screen is locked, **When** any client opens the live tile, **Then** it shows the "Mac is locked" placeholder and the narration text only — no screenshot pixels — while the underlying action keeps running.

---

### Edge Cases

- **Two leases in one turn**: an agent downloads a file through a Playwright-driven browser, then holds the `screen` lease to open and edit it in a native app. The two leases are independent; nothing here makes holding both at once an error (see Clarifications).
- **The agent needs a login, a CAPTCHA or anything only a person can do**: the paused state looks like any other place an agent is stuck on something only the person can do — the same "needs your hands" pattern the project already uses, not a new one.
- **A multi-display Mac**: out of scope for v1; the tool and the live tile act on the main display only (see Assumptions).
- **The lease expires mid-action** (the project's lease lengths, `docs/explanation/leases.md`): the action in progress stops as it does for Stop, and the agent must take the lease again to continue, the same as any other lease's expiry today.
- **An older client**: one that does not know the live-tile capability shows the session as an ordinary running turn, with no tile, until it updates — the same degrade path other capability-gated features use (spec 1748).

## Requirements *(mandatory)*

### Functional Requirements

**Driving the screen**

- **FR-001**: The app MUST offer a first-party agent tool that reads and acts on the screen of any Mac app — not only the sandboxed browser pane, and not only through a third-party MCP server — using the system Accessibility API and synthetic mouse, keyboard and key events.
- **FR-002**: The tool MUST take the existing `screen` resource lease before any action, and release it when the agent's use ends, pauses for longer than the turn, or the turn stops, so it is never held by two agents at once and queues behind another holder exactly as `build`, `browser` and `simulator:` leases do today.
- **FR-003**: Agents Host MUST drive the screen as the person's own logged-in user, with no elevated or escalated privilege.
- **FR-004**: Desktop control MUST default to **Off** for every person and folder. While it is Off, a call to the tool MUST be refused, with a refusal that names the rule and where to turn it on.
- **FR-005**: Turning desktop control On MUST lead to macOS's own Accessibility permission prompt for Agents Host on the tool's first use, if not already granted. Until it is granted, a call MUST fail with a card that names where to grant it.
- **FR-006**: Desktop control MUST keep working while the Mac's screen is locked or asleep, as `run-app`'s existing Accessibility driver does today.

**Safety while driving**

- **FR-007**: The moment the person moves the real mouse or presses a real key while the `screen` lease is held, the agent's current action MUST stop, and every client showing that session MUST offer **Resume** and **Take Over**.
- **FR-008**: **Take Over** MUST release the `screen` lease at once and record in the chat that the person took over.
- **FR-009**: **Stop**, on any client, MUST stop the current desktop-control action and release the `screen` lease, exactly as Stop does for any other running turn.
- **FR-010**: A runtime's own built-in computer-use feature (for example Codex's `computer_use`) MUST NOT be passed through or run alongside this tool; the app MUST turn that feature off for the runtime, so one session has exactly one way an agent drives the screen.

**Watching and steering from another device**

- **FR-011**: Every client (the Mac window, the Remote, the web page) MUST show, for a session that holds the `screen` lease, a live tile with the latest screenshot and the current narration line, refreshed within 2 seconds of each action and at least every 5 seconds while idle.
- **FR-012**: While the Mac's screen is locked, the live tile MUST show a "Mac is locked" placeholder and the narration line only; it MUST NOT show a screenshot.
- **FR-013**: The live tile MUST be visible to every paired client of the person's, with no separate connection step beyond opening the session, consistent with how running-turn status is shown today.
- **FR-014**: Any client MUST be able to send **Resume**, **Take Over** or **Stop** from the live tile; none of the three MUST require being at the Mac.
- **FR-015**: The live tile MUST NOT accept raw mouse or keyboard input from a Remote or web client in this version; steering is limited to Resume, Take Over, Stop and ordinary chat messages to the agent.
- **FR-016**: The screenshot behind the live tile MUST be kept only for as long as the `screen` lease is held; it MUST NOT be written to the project or to the turn's saved history. The narration line MUST be written to the turn's ordinary record, so what the agent did is still visible after the lease is released.

### Key Entities

- **Desktop-control call**: one agent tool call, the app it drove, and the `screen` lease hold that backed it.
- **Screen lease**: the pre-existing `ResourceKindScreen` ("screen") lease, now actually taken by a shipped tool instead of only reserved.
- **Live tile**: the screenshot (or locked placeholder), the narration line, and when it was taken; held only for the current lease hold.
- **Desktop-control rule**: the off-by-default policy switch; a single person-level setting until the policy layers (spec 2957) ship, then one of that policy's rules.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person can watch an agent operate any native Mac app from a paired iPhone or the web page, with the live tile never more than 5 seconds stale, without being at the Mac.
- **SC-002**: Moving the real mouse or pressing a real key while the lease is held stops the agent's current action within 1 second, every time, in a test over 20 tries.
- **SC-003**: With desktop control Off, the default, 0 of the agent-tool and policy paths let an agent move the mouse or send a keystroke.
- **SC-004**: Pressing Stop or Take Over from any client ends the agent's hold of the `screen` lease: 0 cases, across the Mac window, the Remote and the web page, where the lease is still held a second later.
- **SC-005**: No screenshot taken for the live tile is ever found on disk or in a turn's saved history, in a review of every code path that creates one.

## Docs *(mandatory)*

- `docs/how-to/let-an-agent-drive-desktop-apps.md` — add: turning desktop control on, granting Accessibility, what the agent can and cannot do, and the Resume/Take Over/Stop controls.
- `docs/reference/agent-tools.md` — add: a row for the new desktop-control tool, in the same table as `show_file`, `ask_question` and the rest, naming the `screen` lease it takes and that the person is asked first only through the policy switch, not per call.
- `docs/reference/runtimes.md` — change: the `computer_use` row moves from "Measure" to "Superseded by the app's own desktop-control tool," naming this feature.
- `docs/explanation/leases.md` — change: the `screen` resource is now actually acquired by a shipped tool, not only reserved; add a line on Take Over as a way to end a lease early.
- `docs/reference/settings.md` — add: the desktop-control switch, off by default, and what turning it on asks of macOS.
- `docs/reference/feature-matrix.md` — change: the browser row's neighbour; add a line for desktop control once built, and update the "A browser the agent drives" line if the browser tool itself changes as a result of this work (it should not).
- `specs/071-web-remote/walks/parity.md` and the relevant per-screen file under `specs/071-web-remote/walks/parity/` — add: a row for the live tile and its controls, Tier **Core**.

## Assumptions

- **Single main display.** The tool and the live tile act on the Mac's main display; a second or external display is out of scope for v1.
- **The policy switch is temporary.** It lives as a single person-level setting until spec 2957's policy layers ship, at which point it becomes one of that policy's rules with no loss of the value the person set (the same "read once" pattern spec 2957 already uses for its own migration, FR-012 there).
- **No change to the browser story.** Issue #843 stays declined; Playwright through the MCP marketplace remains how an agent drives a browser. This feature does not touch that path, only extends coverage to everything outside it.
- **Remote input forwarding is a later issue, not a missing piece of this one.** Watching, pausing, taking over and stopping answer the issue's stated need ("watch it work... and steer"); literal remote mouse/keyboard control from a phone is a materially larger and separately scoped project.
- **No new account, no cloud dependency.** Desktop control works with no control plane and no sign-in, consistent with the project's local-first default; watching from another device uses whatever link already carries that device's view of a running session today.
