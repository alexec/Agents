---
description: "Task list for Notifications, Where The Person Actually Is"
---

# Tasks: Notifications, Where The Person Actually Is

**Input**: Design documents from `/specs/021-notifications/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/daemon-api.md](./contracts/daemon-api.md), [contracts/routing.md](./contracts/routing.md), [quickstart.md](./quickstart.md)

**Tests**: Included, and concentrated where they are worth something. `Routing.decide` is a pure, total function from presence and a need to a surface, which means the whole of the routing ladder, the settling pause and the re-alert interval can be exhausted in unit tests with no phone in the room — and that one suite is the most valuable thing in this list, because a rung that falls through is a need the person never hears about, which is the failure this feature exists to prevent. Two integration suites carry the claims a pure test cannot: that a need's identity survives the same agent asking twice, and that a need answered on one connection is withdrawn on every other. The device slices are **walked, not asserted** — `quickstart.md` is the test plan for those, and no amount of faking proves a banner arrived on a locked phone.

**Organization**: Grouped by user story, but in **build order rather than priority order**. The reason is in the next section, and it is not a matter of taste.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US5)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/Attention/` — **new**. The need, presence, and the ladder. Pure: no clock of its own, no I/O, no platform, no `import SwiftUI`. Linked by `agentsd` and both apps.
- `Packages/AgentsKit/Sources/AgentsKitCore/Remote/` — 005's unbuilt substrate, built here (Slice C).
- `Packages/AgentsKit/Sources/AgentsKit/{Daemon,Store}/` — the one place that decides (FR-012), and the one process that writes.
- `App/Sources/` and `Remote/Sources/` — surfaces. They report and they display; they decide nothing.
- `RemoteNotify/Sources/` — **new target**. A notification service extension, because that is what an extension has to be.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration,Live}/` — Swift Testing. Neither app has a test target, so anything to be tested lives here.

---

## The decision this list is written on

**The phases run US1(A) → US3 → US4 → US2 → US5 → US1(C), not P1 → P2 → P3.** Three reasons, each from a finding rather than from convenience:

1. **The link that ships today cannot deliver a notification in the only case that matters.** Research §1: the 005 bridge is a TCP connection held by a foreground app, and the person we are trying to reach is by definition not looking at a foreground app. So US1 — the P1, the whole of the value — cannot be finished until Slice C exists. Pretending otherwise by putting it first would mean a Phase 3 that cannot be checked off.

2. **US5 is built first and valued last.** The spec says so in its own priority note: nothing can be delivered to a device the Mac does not trust. US5 is P3 because pairing is worth nothing on its own, but every device rung depends on it. Putting it at its priority position would leave US1's completion depending on a phase after it.

3. **US2 needs two real devices in the room, and the ladder must be right before they are picked up.** Slice B exists to walk the iPad-versus-iPhone routing on hardware — the only way to know it is right — and it is worth doing over the existing LAN bridge *before* a line of CloudKit is written, because discovering the ladder is wrong after building the substrate is the expensive order.

**Phase 8 completes US1, and Phase 7 opens with the only task that can fail in a way that stops the feature.** T056 is 005's T002 spike: if a nested app-like bundle cannot reach the CloudKit private database, the architecture collapses to "the Mac app must be running", which is the premise gone. Stop and re-plan there; do not work around it.

The spec was amended before this list was written — FR-005(b), FR-007, FR-010 and SC-003 — per the three amendments `plan.md` asked for. The tasks below are against the amended text. In particular **there is no Mac fallback**: when nothing can be reached the need waits, and the next surface to connect is told through `attention/pending`.

---

## Phase 1: Setup

**Purpose**: The four numbers, the two failure codes, and the empty suites — so that nothing in Phase 2 has to invent a threshold inline or reach for a literal.

- [X] T001 Create `Packages/AgentsKit/Sources/AgentsKitCore/Attention/AttentionThresholds.swift`: a `public struct AttentionThresholds: Hashable, Sendable` with `macIdle: TimeInterval = 120`, `deviceStaleness: TimeInterval = 600`, `settlingPause: TimeInterval = 20`, `reAlertInterval: TimeInterval = 300`, a memberwise `public init` defaulting to those, and `public static let standard = AttentionThresholds()`. The doc comment must say why they live together — data-model.md's "so they move together or not at all" — and must cite the requirement each serves (FR-007, FR-008, FR-014, FR-018) and research §9 for the figure. **No caller may write a literal duration**; every test names its own thresholds and none of them sleeps
- [X] T002 [P] Add `noSuchNeed = -32021` and `notASurface = -32022` to `DaemonAPI.Failure` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, continuing the block 013 left at `-32020`. Leave `alreadyAnswered` (`-32019`) and `noSuchDevice` (`-32020`) exactly as they are — both are already declared for device work that was never built, and this feature reuses them unchanged rather than redefining either
- [X] T003 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/RoutingTests.swift` with `import Foundation`, `import Testing`, `@testable import AgentsKitCore` and an empty `@Suite("The ladder") struct RoutingTests {}`. Its doc comment must state the claim the suite carries: `decide` is total over its inputs, and a case that fell through would be a need the person never hears about
- [X] T004 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/NeedTests.swift` with the same imports and an empty `@Suite("What wants a person") struct NeedTests {}`, whose doc comment names the claim: the same agent asking twice is two needs, and answering the first must not clear the second
- [X] T005 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AttentionTests.swift` with `import Foundation`, `import Testing`, `@testable import AgentsKit`, `@testable import AgentsKitCore` and an empty `@Suite("Attention", .timeLimit(.minutes(1))) struct AttentionTests {}`, copying the temporary-root and `FakeLauncher` scaffolding from `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ElicitationTests.swift` verbatim
- [X] T006 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Support/FakeSurface.swift`: a test double holding a `DaemonClient` connection that calls `presence/report` on demand and records every `attention/changed` it receives, in order, with the values it carried. It must record **all** notifications, not only the ones naming it — the losers withdrawing is the behaviour under test in Phase 5, and a fake that filtered would hide it

**Checkpoint**: Nothing behaves differently. The numbers and the codes exist in one place each.

---

## Phase 2: Foundational — the nouns, and the ladder

**Purpose**: Everything that decides. Pure, in `AgentsKitCore`, testable with no phone and no window.

**⚠️ CRITICAL**: No user story phase can begin until this phase is complete.

- [X] T007 Create `Packages/AgentsKit/Sources/AgentsKitCore/Attention/Surface.swift`: `public enum Surface: Hashable, Sendable, Codable { case mac; case device(UUID) }`. `Codable` as a **tagged object** (`{"mac": {}}` / `{"device": "<uuid>"}`), not a bare string, so a third case later is additive rather than a re-parse. Two cases and no third
- [X] T008 [P] Create `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Headline.swift`: `public struct Headline: Hashable, Sendable, Codable` with exactly three fields — `h1` the project's folder name, `h2` the agent's title, `h3` what is wanted in a few words. There is no fourth, because `desiredKeys` carries at most three keys of about 100 characters each (research §11). Add `init(truncatingTo budget: Int)` that truncates each field **before** anything seals it, and a `static let placeholder` the type degrades to when a headline will not fit — a headline cut mid-ciphertext is worse than a generic one. Built in Core so the Mac banner and the phone banner say the same words about the same agent, which is the rule `AgentState.startingLabel` exists to defend
- [X] T009 Create `Packages/AgentsKit/Sources/AgentsKitCore/Attention/Need.swift`: `public enum NeedID: Hashable, Sendable, Codable { case permission(UUID); case elicitation(UUID); case report(UUID, Date) }` and `public struct Need: Hashable, Sendable, Codable` with `id: NeedID`, `agentID: UUID`, `folder: URL`, `kind: Kind` (`permission`, `elicitation`, `report`), `raisedAt: Date`, `headline: Headline`. The case is part of the identity, so a permission and an elicitation issued the same UUID by different code paths are different needs. `raisedAt` never moves — a need that is re-routed is the same need. The doc comment must say, and FR-001 requires, that `Need` is built from the existing `needsAPerson` rule and from the pending dictionaries the daemon already keeps: **there is no new detection anywhere and there must never be a second definition**
- [X] T010 [P] Create `Packages/AgentsKit/Sources/AgentsKitCore/Attention/Presence.swift`: `public struct Presence: Hashable, Sendable` with `surface: Surface`, `watching: UUID?`, `active: Bool`, `heardAt: Date`; and the three derived properties, each taking `now` and `thresholds` as parameters rather than reading a clock — `isRecent` (`now - heardAt < deviceStaleness`), `isHere` (`active && now - heardAt < macIdle`), `isWatching(_ agentID: UUID)` (`active && watching == agentID`). The doc comment must record that `heardAt` is stamped by the daemon's own clock and never by the sender, and why: a device with a fast clock must not win every race
- [X] T011 [P] Create `Packages/AgentsKit/Sources/AgentsKitCore/Attention/Delivery.swift`: `public struct Delivery: Hashable, Sendable` with `needID: NeedID`, `to: Surface?`, `alertedAt: Date`, `alertCount: Int`. Its doc comment must state the invariant that makes FR-003 checkable — one `Delivery` per outstanding `Need`, destroyed when the need is met, nothing outliving what it belongs to — and that changing `to` is a **move** that does not touch `alertedAt` unless the re-alert interval has passed, which is the whole of FR-018 in one place
- [X] T012 Create `Packages/AgentsKit/Sources/AgentsKitCore/Attention/Routing.swift` implementing `contracts/routing.md` exactly: `public enum Routing { public static func decide(need:presences:devices:delivery:thresholds:now:) -> Decision }` and `public struct Decision: Hashable, Sendable { var to: Surface?; var alert: Bool; var wait: Bool }`. The six rungs in order, first match wins, nothing below a matched rung consulted: (0) already met → not outstanding; (1) **any** presence `active && watching == need.agentID` → `to = nil`; (2) `presences[.mac]` exists, `active`, `now - heardAt < macIdle` → `.mac`; (3) the approved, `mayNotify`, most recent `.device` with `now - heardAt < deviceStaleness`; (4) the most recently used approved iPhone that may notify; (5) nowhere → `to = nil`. Rung 1 is deliberately **any** surface and not the one that would otherwise win — watching on the iPad silences the phone, because the rule is about the conversation being watched and not about which machine watches it. Pure: no clock of its own, no I/O, no platform
- [X] T013 In `Routing.swift`, implement the settling pause: `wait` is true, and nothing is delivered, when **all** of — rung 2 matched, the person is not watching this conversation, and `now - need.raisedAt < settlingPause`. Never when the person is away: rungs 3, 4 and 5 deliver immediately (FR-013), because a person who is not at the Mac is not about to look at it. The caller re-decides when the pause elapses
- [X] T014 In `Routing.swift`, implement `alert` separately from `to`, per the contract: `alert = delivery == nil || (delivery.to != to && now - delivery.alertedAt >= reAlertInterval)`. A move inside the interval still moves the notification — `to` changes, the old surface withdraws, the new one shows it — but shows it **silently**. Implement ties explicitly rather than leaning on `max(by:)`'s stability, which is neither guaranteed nor readable: later `heardAt` wins, and on an exact tie the iPhone, because that is the default the person asked for
- [X] T015 [P] Fill `Packages/AgentsKit/Tests/AgentsKitTests/Unit/RoutingTests.swift`: exhaust all six rungs with an injected `now` and named thresholds, the way `AgentGroupTests` exhausts `AgentState`. At minimum — each rung reached; rung 1 reached from a *device* while the Mac is active (US3 scenario 3); rung 3 skipping a device with `mayNotify == false` and rung 4 skipping it too; rung 4 refusing a device whose `kind` is `unknown` as the iPhone default; rung 5 when every device is stale. Then the pause: `wait` true inside it at the Mac, false outside it, false while away however recent the need. Then `alert`: true on first decision, false on a move inside `reAlertInterval`, true on a move after it, and **ten moves inside five minutes producing at most two alerts**, which is SC-006 asserted rather than hoped for
- [X] T016 [P] Fill `Packages/AgentsKit/Tests/AgentsKitTests/Unit/NeedTests.swift`: two permissions on the same agent are two `NeedID`s; a permission and an elicitation carrying the same UUID are two `NeedID`s; two reports on the same agent at different timestamps are two needs and at the same timestamp are one; `raisedAt` is unchanged across a re-decide; `Headline` truncation happens before sealing and degrades to the placeholder rather than cutting mid-field; `Surface` round-trips through `Codable` as a tagged object
- [X] T017 Add to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, per `contracts/daemon-api.md`: the `presence/report` method and its params (`watching: UUID?`, `active: Bool`, `mayNotify: Bool?` — **and no timestamp field, which is a contract term and not an omission**), the `attention/pending` method returning `{ needs: [Need], deliveries: [NeedID: Surface] }`, and the `attention/changed` notification carrying `{ needID, need: Need?, to: Surface?, alert: Bool }`. Every new field optional on read, so a client built before this change works against a daemon built after it and the reverse. **No existing method gains a required parameter**; `agent/permission`, `agent/elicitation` and `agent/changed` are untouched
- [X] T018 In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonServer.swift`, give a connection an **identity** — `.mac`, or `.device(UUID)` for a connection the bridge opened on behalf of a device — as a field on the connection. The surface for `presence/report` is taken from the connection and **never from the parameters**; a connection with no identity gets `notASurface`. `DaemonServer.broadcast` itself is unchanged: this is a field on the connection, not a change to the fan-out
- [X] T019 Create `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Attention.swift`: the dictionaries `presences: [Surface: Presence]` and `deliveries: [NeedID: Delivery]`, held in memory and **never written to disk**; `needs()` deriving the outstanding needs from `Agent.needsAPerson` and `pendingPermissions`/`pendingElicitations` with no new detection; and `reconsider()`, the one function that runs the ladder for every outstanding need and broadcasts `attention/changed` for each whose `Decision` differs from its `Delivery`. FR-012 lives here: **no surface may decide for itself whether it is the right one to alert**
- [X] T020 In `DaemonCore+Attention.swift`, implement `presence/report`: replace this surface's record (a reconnecting surface replaces its own, it does not add one), stamp `heardAt` with the daemon's clock, then `reconsider()`. Implement the disconnect path — a disconnected surface's record is **deleted, not aged out**, because gone is more truthful than stale and it is the difference between the Mac rung failing fast and the person waiting 120 s for a banner nobody can show
- [X] T021 In `DaemonCore+Attention.swift`, implement `attention/pending`, beside `permissions/pending` and `elicitations/pending` and for the same reason: a surface that was not listening is put right rather than left guessing. This is also what makes the amended FR-010 true — when nothing can be reached the need waits in the record, and the next surface to connect learns of it here
- [X] T022 Wire `presence/report` and `attention/pending` into `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift` alongside the existing methods
- [X] T023 Call `reconsider()` from the places a need can begin or end: the permission and elicitation paths and `move()` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`, and the answer paths in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`. Answering a question, stopping an agent and archiving one each end a need; a turn ending with a report that says it is stuck **begins** one. A clean finish, a stop and a death begin nothing (FR-002)
- [X] T024 Add a settling-pause timer to `DaemonCore+Attention.swift`: when a `Decision` comes back with `wait == true`, schedule a single re-decide at `need.raisedAt + settlingPause` rather than polling, and cancel it if the need is met first. **Nothing is delivered for a need that has already been met** (FR-015) — the check is rung 0 and it runs again when the timer fires
- [X] T025 In `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`, hold the needs and deliveries the client has been told about, apply `attention/changed` and prime from `attention/pending` on connect. The model stores the fact; it does not post anything

**Checkpoint**: The daemon decides correctly and says so on the wire. Nothing shows a banner yet. `swift test --package-path Packages/AgentsKit` passes, and the ladder is exhausted.

---

## Phase 3: User Story 1 (Slice A) — a banner while you are in another app (Priority: P1) 🎯 MVP

**Goal**: An agent that needs you reaches you while you are at the Mac and looking at something else. Real value on its own, with no new target, no entitlement, no device and no account.

**Independent Test**: Quickstart A2. Start an agent that will ask permission, switch to another app, and confirm a banner names the project, the agent and what is wanted, and that clicking it opens that conversation with the question in front of you.

**What it does not do**: reach you when you are away from the Mac. That is Phase 8, and it is the reason this phase is labelled Slice A rather than "US1".

- [ ] T026 [P] [US1] Create `App/Sources/Notifications/PresenceReporter.swift`: reports `presence/report` when the app becomes or resigns active, when the selected conversation changes, and when input is seen after a quiet spell. **A report is sent on a change, not on a timer** — a surface already `active` with the same `watching` sends nothing, so typing does not send one per keystroke
- [ ] T027 [US1] Create `App/Sources/Notifications/MacNotifier.swift`: requests authorisation, posts a `UNNotificationRequest` whose identifier is the need's id, and withdraws with `removeDeliveredNotifications(withIdentifiers:)`. It applies the idempotent rule from the contract and nothing else — `to == me and not showing it → show it, with sound iff alert`; `to != me and showing it → withdraw`; `need == nil and showing it → withdraw`; otherwise nothing. It **decides nothing**; that is FR-012 expressed as a file boundary rather than as a comment
- [ ] T028 [US1] Build the banner's three lines in `MacNotifier` from `Need.headline` alone — `h1` the project, `h2` the agent, `h3` what is wanted — never from anything the Mac recomputes locally. An empty or enormous project or agent name must still identify which agent it is, **truncated rather than blank** (spec edge case)
- [ ] T029 [US1] Handle the notification response in `MacNotifier`: opening it selects that agent's conversation with the question in front of the person and answerable there (FR-019). It must not answer anything itself
- [ ] T030 [US1] Wire `PresenceReporter` and `MacNotifier` into `App/Sources/AppModel.swift` against the model it already has. Swiping a banner away must **not** mark the need met — there is no "dismissed" in the lifecycle; the agent is still blocked and the project row still says so, and conflating the two would be the app lying about the work
- [ ] T031 [US1] Ask for notification permission at a point where the person can see why (FR-024) — the first time a need would be delivered to the Mac, not on first launch with no context
- [ ] T032 [P] [US1] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AttentionTests.swift`: with a `FakeSurface` reporting itself active-but-not-watching, provoking a permission produces exactly one `attention/changed` with `to == .mac` and `alert == true`, after the settling pause and not before it
- [ ] T033 [P] [US1] Add to `AttentionTests.swift`: an agent that finishes cleanly, one that is stopped, and one whose process dies each produce **no** `attention/changed` at all (FR-002, US1 scenarios 5 and 6); an agent whose turn ends with a report saying it is stuck, partly done or needs an answer produces one that says which (US1 scenario 2)
- [ ] T034 [US1] Walk quickstart A2, A5 and A6 by hand and record the result in `quickstart.md`

**Checkpoint**: US1 is delivered for a person who is at the Mac. US1 scenarios 1–2 and 5–6 hold; scenarios 3–4 wait for Phase 6 and Phase 8.

---

## Phase 4: User Story 3 — silence while the person is already looking (Priority: P2)

**Goal**: The question appears in front of the person who is watching. Nothing buzzes, and there is nothing to dismiss afterwards.

**Independent Test**: Quickstart A3. Open an agent's conversation, leave it frontmost, provoke a permission request, confirm nothing is delivered anywhere.

**Why here**: this is the most common way a notification system becomes noise, because the moment an agent needs a person is very often the moment the person is watching it. It is pure, it is Slice A, and it costs one rung that already exists.

- [ ] T035 [US3] Confirm and, where it is missing, complete the `watching` half of `App/Sources/Notifications/PresenceReporter.swift`: which conversation is on screen, and whether the window is frontmost. "Watching" is all three of — showing that conversation, in front of the person, interacted with recently (FR-006) — and a window left frontmost on a locked Mac satisfies none of them
- [ ] T036 [P] [US3] Add to `AttentionTests.swift`: a surface reporting `watching == agentID` and `active` produces **zero** `attention/changed` with a non-nil `to` for that agent, on any surface (US3 scenario 1, SC-004)
- [ ] T037 [P] [US3] Add to `AttentionTests.swift`: a surface watching a **different** agent is notified normally (US3 scenario 2), and a *device* surface watching the conversation silences it even while the Mac is active (US3 scenario 3) — the rung-1 "any surface" rule, asserted at the daemon rather than only in `RoutingTests`
- [ ] T038 [P] [US3] Add to `AttentionTests.swift`: with the Mac reporting `active` but not watching, delivery waits out the settling pause and is **cancelled** if the person begins watching or the need is met inside it (FR-014, US3 scenario 4); with the Mac reporting inactive or absent, delivery is immediate with no pause (FR-013, US3 scenario 5)
- [ ] T039 [US3] Walk quickstart A3 by hand, ten trials, and record the result. Any banner is a failure, not a flake

**Checkpoint**: SC-004 holds. The app is silent about what you are already reading.

---

## Phase 5: User Story 4 (Mac half) — answered once, gone everywhere (Priority: P3)

**Goal**: A need met anywhere is withdrawn everywhere, and no stale notification ever asks about a question settled twenty hours ago.

**Independent Test**: Quickstart A4. Provoke a need, answer it, confirm the banner goes on its own.

**Why here**: it is Slice A, it is pure apart from the withdrawal call, and stale notifications are how the person learns that a notification is not evidence of anything. Its device half — a silent push waking a backgrounded phone — is Phase 8.

- [ ] T040 [US4] In `DaemonCore+Attention.swift`, broadcast `attention/changed` with `need == nil` when a need is met — answered anywhere, or the agent stopped or archived (FR-016). Broadcast to **every** connection and not only to `to`: that is what lets the losers withdraw, and it is why FR-016 needs no second message. A withdrawal names only the need's id, which identifies nothing about the work
- [ ] T041 [US4] Implement the move in `DaemonCore+Attention.swift`: when a need is outstanding and the person changes surface, one `attention/changed` with the new `to` — not a withdrawal and a delivery that could cross (FR-017). The whole resolved fact, in one notification, per need
- [ ] T042 [P] [US4] Add to `AttentionTests.swift`: a need answered on connection A produces `need == nil` on connections B and C within the same broadcast; a need whose agent is stopped or archived does the same (US4 scenarios 1–3)
- [ ] T043 [P] [US4] Add to `AttentionTests.swift`: two needs outstanding on the same agent, answering one leaves the other outstanding and showing (spec edge case: several agents at once, and the same agent asking twice)
- [ ] T044 [P] [US4] Add to `AttentionTests.swift`: a need met **before** the ladder delivers produces no `attention/changed` with a non-nil `to` at all — nothing arrives rather than arriving and being withdrawn a second later (FR-015, spec edge case)
- [ ] T045 [US4] Add a foreground sweep to `App/Sources/Notifications/MacNotifier.swift`: on becoming active, remove any delivered notification whose need the daemon no longer lists in `attention/pending`. This is the backstop that makes SC-009 survivable — research §8's "the worst case is a stale banner until the person picks the device up, at which point it is gone before they have read it"
- [ ] T046 [US4] Walk quickstart A4 by hand and record the result

**Checkpoint**: Slice A is complete and shippable. Everything in the spec except the device rungs has been proven, most of it in unit tests.

---

## Phase 6: User Story 2 — it goes to the screen you are looking at (Priority: P2)

**Goal**: The iPad shows it while you are holding the iPad; the phone shows it when you are not. Walked on real hardware over the existing LAN bridge, before a line of CloudKit is written.

**Independent Test**: Quickstart B1–B3. Both devices paired, Mac locked. Use the iPad, provoke a need, confirm only the iPad is notified. Put it down, use the phone, provoke another, confirm only the phone.

**⚠️ Needs a real iPhone and a real iPad.** This phase is the gate on the routing being right. It is **not** the shipping path: research §1 is honest that a LAN notification does not arrive while the app is backgrounded, which is quickstart B4 and is exactly what Phase 8 exists to fix.

- [ ] T047 [P] [US2] Create `Remote/Sources/Notifications/PresenceReporter.swift`: reports `presence/report` on `scenePhase` changes and on selection changes. `active` on a device means **foreground and unlocked** — a phone in a pocket with the app foregrounded is not a place a person is looking
- [ ] T048 [US2] Create `Remote/Sources/Notifications/DeviceNotifier.swift`: the same two jobs as `MacNotifier` and the same idempotent rule, on iOS. It shows and withdraws a **local** notification when `attention/changed` names it; it decides nothing
- [ ] T049 [US2] Ask for notification permission on the device where the person can see why (FR-024), and report the resulting authorisation status as `mayNotify` on every `presence/report` (FR-023)
- [ ] T050 [US2] Wire both into `Remote/Sources/RemoteModel.swift`, and prime from `attention/pending` on connect so a remote that was not listening is put right
- [ ] T051 [US2] Give the existing bridge connection a device identity so `presence/report` from a remote resolves to `.device(UUID)` rather than `notASurface` (T018's other half). Until Phase 7 stores real devices, the identity may come from the remote's existing handshake — but it must come from the **connection**, never from the report's parameters
- [ ] T052 [P] [US2] Add to `AttentionTests.swift`, with two fake device surfaces: the most recently used wins (US2 scenarios 1–2); neither recent enough falls to the iPhone (US2 scenario 3); only one paired means that device whatever it is (US2 scenario 5); a device not heard from past `deviceStaleness` is not a candidate (spec edge case)
- [ ] T053 [P] [US2] Add to `AttentionTests.swift`: the Mac active but behind another app beats both devices (US2 scenario 4, rung 2 above rung 3); and — against the **amended** FR-010 — no Mac connected and no device reachable delivers nowhere, leaves the need outstanding, and hands it to the next surface to call `attention/pending` (US2 scenario 6)
- [ ] T054 [P] [US2] Add to `AttentionTests.swift`: two device reports arriving within the same instant resolve by the daemon's `heardAt` and not by anything either device claimed; on an exact tie the iPhone wins (spec edge cases)
- [ ] T055 [US2] Walk quickstart B1, B2 and B3 on real hardware: three trials per rung, any wrong surface is a failure and not a flake (SC-002). Record the result, and record B4 — what the LAN cannot do — as the known limitation it is

**Checkpoint**: The routing is right, proven where it has to be proven. US2 is complete. US1 still cannot reach a pocket.

---

## Phase 7: User Story 5 — a device that can be told, and taken back (Priority: P3)

**Goal**: 005's substrate, built. Pairing, the sealed channel, the mailbox, and revocation that actually deafens.

**Independent Test**: Quickstart C5. Pair a device, confirm it is notified, revoke it at the Mac, provoke another need, confirm it receives nothing at all — including nothing that can be read.

**⚠️ T056 is a gate.** If a nested app-like bundle cannot reach the CloudKit private database, **stop and re-plan**. The remaining shapes are "the Mac app must be running" — the feature's premise gone — and "the daemon gains the entitlement", which breaks the standing rule that `agentsd` gains no network code. There is no third option identified, and this is said before the work starts rather than after.

- [ ] T056 [US5] **The gate.** Run 005's T002 spike: make `agents-bridge` an app-like bundle in `project.yml` (`type: application` with the principal class, storyboard and delegate stripped, per Apple DTS), give it `com.apple.developer.icloud-services` with an embedded provisioning profile under team `6T4RVD5724`, and prove from that nested bundle that it can read and write a record in the CloudKit **private** database. Record the outcome in `research.md` §7 either way. **DTS recommended this wrapper but had not tested it with CloudKit** — that risk is inherited whole from 005 and this task is where it is settled
- [ ] T057 [US5] Create the CloudKit container (005's T001) and record its identifier in `quickstart.md`'s prerequisites
- [ ] T058 [P] [US5] Create `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Device.swift`: 005's record, with `id: UUID`, `publicKey: Data`, `name: String`, `kind: Kind` (`iPhone`, `iPad`, `unknown`), `announcedAt: Date`, `approvedAt: Date?`, `lastSeenAt: Date?`, `mayNotify: Bool?`, `unknownFields: [String: JSONValue]` kept and written back as `Agent` and `Project` do. **`wants` is deliberately not built** — Out of Scope says every approved device is eligible for everything — and `unknownFields` is what keeps a record written by a future build that has it from being damaged by this one. The doc comment must say that `kind` stops being decorative here: FR-009 makes the iPhone the default, so a device reporting `unknown` cannot be the default, and that is worth knowing before somebody simplifies it away
- [ ] T059 [P] [US5] Create `Packages/AgentsKit/Sources/AgentsKitCore/Remote/DeviceKey.swift`: P256, Secure-Enclave-backed where available, with the private key in the **device's** keychain — which is the device's, not ours, and is why this does not break the rule about storing nothing outside the daemon's root
- [ ] T060 [P] [US5] Create `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Envelope.swift`: HPKE seal to a device's public key, with `Headline` sealed inside. Nothing legible goes to a device that is not `to` (FR-022)
- [ ] T061 [US5] Create `Packages/AgentsKit/Sources/AgentsKit/Store/DeviceStore.swift` and add `devices` to `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`: `devices.json` under the daemon's root, beside `projects.json`, written whole on change. **The daemon is the only writer**; the bridge reads nothing from the store and is handed what to send
- [ ] T062 [US5] Create `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Devices.swift` with `devices/list`, `devices/announce`, `devices/approve`, `devices/revoke`, and the `device/changed` notification (`{ device }` on announce, approve and last-seen; `{ id, gone: true }` on revoke). `announce` returns the existing record when the same id announces again with the same key and fails `notSupported` when the id exists with a **different** public key — a key never changes under an identity, and a device that wants a new key is a new device
- [ ] T063 [US5] Implement revoke as **deletion**, not a flag: the record goes and that device's mailbox is emptied, so anything already waiting for it is discarded unread (FR-021). Deletion is what makes a device unable to read anything rather than a flag somebody must remember to check
- [ ] T064 [US5] Wire the four methods into `DaemonCore+Dispatch.swift`, and make `Routing` consult the real `DeviceStore` rather than whatever stand-in Phase 6 used
- [ ] T065 [P] [US5] Create `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Mailbox.swift`: the protocol, plus a fake for tests
- [ ] T066 [US5] Create `Packages/AgentsKit/Sources/AgentsKitCore/Remote/CloudKitMailbox.swift`: the real one, in the private database, with `CKSubscription.NotificationInfo.collapseIDKey` set to a **stable id per need** so a stale banner is overwritten by the next one for the same need rather than stacking (research §8)
- [ ] T067 [US5] Create `Packages/AgentsKit/Sources/AgentsKitCore/Remote/MailboxTransport.swift`: the third `LineTransport`, beside the existing two, so the bridge carries `attention/changed` to a device that is not on the LAN
- [ ] T068 [US5] Add the `RemoteNotify` notification service extension target to `project.yml` and create `RemoteNotify/Sources/NotificationService.swift`: it decrypts the envelope and assembles the banner's three words **on the device**, which is what a notification service extension is for. Sending the words in plaintext is FR-022 gone; fetching them after the person taps means a banner that says "An agent needs you" every time, which the quickstart already names as a failure
- [ ] T069 [US5] Add the App Group shared between `Remote` and `RemoteNotify` in `project.yml`, plus `aps-environment` and the iCloud entitlements on both
- [ ] T070 [P] [US5] Create `Remote/Sources/Devices/PairingView.swift`: announce this device, show that it is waiting for approval, and say plainly what it is waiting for
- [ ] T071 [P] [US5] Create `App/Sources/Settings/DevicesPane.swift`: the paired devices, each with its name, kind and **whether it is able to show notifications** (FR-023) — a device that has not been permitted says so here rather than appearing to work — and approve and revoke
- [ ] T072 [P] [US5] Add to `AttentionTests.swift` against the fake mailbox: an unpaired device is sent nothing; a device that has announced and not been approved is sent nothing; a revoked device is sent nothing and its mailbox is empty (US5 scenarios 1–3, SC-007)
- [ ] T073 [P] [US5] Add a unit test in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` asserting that what a mailbox carries is ciphertext: the project name, the agent name and the headline do **not** appear in the bytes (FR-022, US5 scenario 4). Assert the property directly against a constructed envelope — do not reach for a running system
- [ ] T074 [US5] Walk quickstart C3, C5 and C6 on real hardware and record the results, checking C5 against the CloudKit dashboard as well as against the device

**Checkpoint**: A device can be told, and taken back. US5 is complete.

---

## Phase 8: User Story 1 (Slice C) — reaching a pocket on a train (Priority: P1)

**Goal**: The P1 finished. The phone buzzes on cellular with the Mac locked on another network, and answering there lets the agent carry on.

**Independent Test**: Quickstart C2. Phone on cellular, Mac locked elsewhere, provoke a permission request, confirm the phone is notified within 5 seconds with a banner that names the project, the agent and what is wanted, and that answering from the phone lets the agent proceed.

**Depends on Phase 7.** Nothing here can be delivered to a device the Mac does not trust.

- [ ] T075 [US1] Route `attention/changed` for a `.device` surface through `MailboxTransport` when that device has no live LAN connection, so a backgrounded or absent device is reached by push rather than by a socket nobody is holding. This is research §1's finding made real: the link 005 shipped cannot carry a notification in the only case that matters
- [ ] T076 [US1] Seal the `Headline` per device with `Envelope` before it leaves the Mac, truncating to the budget T004 of 005 measured, and degrading to the placeholder rather than cutting mid-ciphertext
- [ ] T077 [US1] Make opening a pushed notification take the person to that agent's conversation in the Remote app, with what is wanted in front of them and **answerable there** with the same choices the Mac offers (FR-019, US1 scenario 3)
- [ ] T078 [US1] Make an answer from a device reach the Mac and end the need, so the Mac shows the question answered rather than still pending (US1 scenario 4). Reuse `alreadyAnswered` (`-32019`) for a question answered twice rather than inventing a second code
- [ ] T079 [US1] Implement withdrawal on a backgrounded device: a silent push (`shouldSendContentAvailable`) waking the app to call `removeDeliveredNotifications(withIdentifiers:)`, plus the foreground sweep from T045 ported to `Remote/Sources/Notifications/DeviceNotifier.swift`. Document in the source that the push half is **best effort** — a silent push is low priority, coalesced one-deep, and not delivered at all to a force-quit app — which is exactly why SC-003 was amended and why the sweep is not optional
- [ ] T080 [US1] Walk quickstart C1, C2 and C4 on real hardware. C2 is ten trials on cellular with the Mac locked, taking the **worst** for SC-001, not the median
- [ ] T081 [US1] Record in `quickstart.md`'s "the thing to remember after a reboot" that nothing starts by itself: no daemon, no bridge and no notifications until the Mac app has been opened once. That is 005 §7's decision — no login item, nothing installed — and it is a cost, not an oversight

**Checkpoint**: The feature is whole. US1 scenarios 1–6 all hold.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T082 [P] Update `README.md` with what the daemon now decides and what it now stores: presence held in memory and never written, `devices.json` beside `projects.json`, and the rule that no surface decides for itself whether to alert
- [ ] T083 [P] Add a `ConsistencyTests` entry asserting that `AgentsKitCore/Attention/` contains no `import SwiftUI` and no platform import, so the ladder cannot quietly acquire a dependency that stops it being linkable by `agentsd`
- [ ] T084 [P] Add a source-scan test asserting that nothing outside `Routing.swift` computes a destination surface — FR-012 is a rule about where a decision lives, and the only honest way to assert it is to look at the source, the way 018's scans do. Prove the scan bites before trusting it: a regex matching nothing is a green test protecting nothing
- [ ] T085 [P] Add a source-scan test asserting that no file outside `AttentionThresholds.swift` writes one of the four durations as a literal
- [ ] T086 Measure SC-006 and SC-008 as `quickstart.md` describes: ten moves inside five minutes for the first, and two days of ordinary use with notifications off against two with them on for the second. Record both
- [ ] T087 Keep a week's log for SC-009 — every banner received, read against whether the need still stood when it was read — and record the result
- [ ] T088 Run `swift test --package-path Packages/AgentsKit`, then `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build` and `xcodebuild -scheme Remote -destination 'generic/platform=iOS' -skipPackagePluginValidation build` **sequentially**, and fix what breaks. `-skipPackagePluginValidation` is needed because SwiftTerm ships a build-tool plug-in, and without it the build fails silently

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies
- **Phase 2 (Foundational)**: needs Phase 1 — **blocks every story phase**
- **Phase 3 (US1 Slice A)**, **Phase 4 (US3)**, **Phase 5 (US4 Mac half)**: need Phase 2. Together they are Slice A, and Slice A ships on its own
- **Phase 6 (US2)**: needs Phase 2; needs two real devices; does **not** need Phase 7
- **Phase 7 (US5)**: needs Phase 2, and is **gated on T056**
- **Phase 8 (US1 Slice C)**: needs Phase 7, and completes the P1
- **Phase 9 (Polish)**: needs whichever slices are being shipped

### Story dependencies

- **US1** spans Phase 3 and Phase 8. Its Mac half is independent; its device half depends on US5
- **US2** depends only on the foundation, which is why it can be walked before any of the substrate exists
- **US3**, **US4** depend only on the foundation
- **US5** depends only on the foundation, and everything device-shaped depends on it

### Parallel opportunities

- T002–T006 all parallel
- T008, T010, T011 parallel after T007; T015 and T016 parallel after T014
- T026 parallel with T027–T029, which are the same file and are not
- Every test task marked [P] within a phase
- Phase 6 and Phase 7 can run in parallel by two people, since neither touches the other's files — but Phase 6 first if there is only one, because a wrong ladder discovered after the substrate is the expensive order

---

## Implementation Strategy

### MVP (Slice A — Phases 1–5)

Everything needing no new infrastructure: no target, no entitlement, no device, no account, no portal. Delivers a real thing — an agent that needs you reaches you while you are in another app — and proves every rule in the spec except the device rungs, most of it in unit tests. **Stop and validate here.**

### Then Slice B (Phase 6)

Walk the routing on an iPhone and an iPad over the LAN. This is the gate on the ladder being right, and it costs nothing but two devices and an afternoon. It is not shippable as the feature, and quickstart B4 says why in the open.

### Then Slice C (Phases 7–8)

The substrate. Largest by far, and the only part that can fail in a way that stops the feature. **T056 first, and if it fails, stop.**

---

## Notes

- Presence is never written to disk, and after a restart the person's whereabouts are unknown until a surface says otherwise — at which point the iPhone default carries the load. That is the design, not a gap
- There is no "dismissed". A banner swiped away is a banner gone, not a need met
- The two apps must say the same words about the same agent: build the headline once, in Core
- Commit after each task or logical group. Stop at any checkpoint to validate a slice on its own
