---
description: "Tasks for 068, Attention on the Home screen"
---

# Tasks: Attention on the Home screen

**Input**: `specs/068-attention-widget/`: spec.md, plan.md, checklists/requirements.md (Issue #33)

**Tests**: requested (plan, Technical Context): unit tests against a fake `AgentsModel` in `Tests/Unit/`, and the widget itself looked at on a simulator with the Remote run `-fake`.

**Paths**: `Core` = `Packages/AgentsKit/Sources/AgentsKitCore`, `Tests` = `Packages/AgentsKit/Tests/AgentsKitTests`.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [x] T001 Create the branch `agents/attention-widget` in the worktree `.agents/worktrees/attention-widget` off main, with this spec folder, with this spec folder
- [x] T002 `RemoteWidget/` target in `project.yml` (app-extension, `com.apple.widgetkit-extension`, embedded in the Remote's PlugIns), its `Info.plist` and an entitlements file carrying the app group; `xcodegen generate`; build it for the device to settle signing before anything is written (plan, Complexity Tracking). The target, the plist and the entitlement are in and build for the simulator; the device build is T023, and it is the one thing outside this repository
- [x] T003 `RemoteWidget/Sources/AttentionWidget.swift`: the bundle and one empty placeholder layout, so T002's build is of the target itself and not of what comes after

**Checkpoint**: a signed widget extension the app carries.

---

## Phase 2: Foundational (what the widget is shown, and where it comes from)

**Purpose**: US1 needs a number and rows; US2 needs a link. Both are pure and both are testable before a view exists.

- [x] T004 [P] `AttentionSnapshot`, `AttentionSnapshotSession`, `AttentionLink` in `Core/Widget/`: `Codable`, `Hashable`, `Sendable`; `widgetKind`, the row limit, `AttentionLink.url` and `AttentionLink.parse`
- [x] T005 `AttentionSnapshot.make(model:at:limit:)` in `Core/Widget/`: the count summed over live projects (FR-001), one row per session with `Need.headline.h3` or the agent's report or nothing (FR-005, FR-007), newest need first, capped, with the total beyond the cap carried on the snapshot
- [x] T006 `AttentionSnapshotStore in `Core/Widget/`: `write` atomic, `read` nil for a file that is not there, a directory parameter so no app group is needed by the tests (FR-018)
- [x] T007 [P] `Tests/Unit/AttentionSnapshotTests.swift`: the count rule, two needs from one agent as one row, a finished-unread session with no need, the cap and what is left over, ordering by `raisedAt`, JSON round-trip, a missing file, and both link forms with a URL that is neither (SC-001, SC-005)

**Checkpoint**: the number and the rows exist, and are proved by tests alone.

---

## Phase 3: User Story 1 — See what is waiting without opening the app (P1) 🎯 MVP

**Goal**: a small widget with the number, a medium one with the number and the rows.

**Independent Test**: the app run `-fake` with waiting agents, the widget on a simulator Home screen: the small one shows the count, the medium one shows the rows, and the same count the project's row shows.

- [x] T008 [US1] `AttentionProvider` in `RemoteWidget/Sources/`: reads the snapshot, one entry per layout, the next refresh a quarter of an hour out, and no entry when there is no file
- [x] T009 [US1] The small layout: the number in `StateTint.attention` when it is not zero, a line saying what it is, and the "does not know yet" state (FR-003, FR-009)
- [x] T010 [US1] The medium layout: the number, the newest rows within the limit, the remainder counted in the header, `Link` on each row (FR-004, FR-006)
- [x] T011 [US1] The age, shown once the snapshot is more than a few minutes old (FR-017)
- [x] T012 [US1] `RemoteModel.publishAttention()`: write the snapshot and reload the timelines only when what the last write said has changed (FR-016, FR-018)
- [x] T013 [US1] The four hooks: after `refreshEverything()`, in the `listen()` loop, on `scenePhase(.active)`, from `receivedPush` (FR-016, SC-003)

**Checkpoint**: the number on the Home screen, and it moves when the app learns something.

---

## Phase 4: User Story 2 — Tap it and be in the conversation (P1)

**Goal**: a tap opens the conversation, in its project, however cold the launch.

**Independent Test**: with the app not running, tap a row; the app opens on that conversation. Then `-agent` nothing, no — the real path: kill the app, tap, and look.

- [x] T014 [US2] `CFBundleURLTypes` for the `agents` scheme in `Remote/Info.plist`, and `AttentionLink.url` as the only URL either side builds
- [x] T015 [US2] The body's tap: the first project with somebody waiting, or the projects page (FR-010), in `RemoteModel`
- [x] T016 [US2] `.onOpenURL` in `RemoteApp`, into `openNeedsYou()` or `open(_:)`; a URL that parses to nothing does nothing (FR-011)
- [x] T017 [US2] A session that has gone since the widget was drawn: the app shows what it can rather than an empty chat (FR-013)

**Checkpoint**: a tap lands in the conversation, and the cold launch works.

---

## Phase 5: Docs and verification

- [x] T018 `docs/how-to/see-what-needs-you-from-your-home-screen.md` and its nav entry; a short section in `docs/explanation/phone-and-ipad.md`; `scripts/docs.sh check`
- [x] T019 `swift test --package-path Packages/AgentsKit` green
- [ ] T020 A simulator run of the Remote `-fake` with the widget on the Home screen: small, medium, nothing waiting, and no file at all — screenshotted each (US1, US2, FR-009). Not done: no simulator device exists on this Mac, and the touch injection needed to put a widget on a Home screen is not installed, so T022 is what will see it drawn
- [x] T021 `xcodebuild -scheme Remote -destination 'platform=macOS' build` for the Mac app, to prove nothing there moved (SC-006)
- [ ] T022 Ship to the phone and iPad, and add the widget by hand on one of them. Blocked on T023

---

## Not done, and why

- [ ] T023 Register `com.alexecollins.agents.remote.widget` as an App ID with the App
  Groups capability, so the extension can be signed for a device. Automatic signing
  reports `No Accounts` from a shell, and falls back to a wildcard profile that has no
  App Groups. Everything builds for the simulator without it; nothing on a device does.

## Notes

- [US3] has no phase of its own: it is T013's `receivedPush` hook and T011's age, and it is verified in T020 and T022.
- T002 comes before everything on purpose. It is the only task that can be blocked by something outside this repository.
- T019: the new suite is green (13 tests). The full run also reports failures, in the
  daemon-integration suites, and they are not new: the same suites fail on `main`, and
  which of them fail changes from run to run. They are the flaky tests
  `scripts/flaky-tests.sh` knows about.
