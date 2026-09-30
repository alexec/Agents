# Implementation Plan: Attention on the Home screen

**Feature**: 068-attention-widget | **Date**: 2026-09-29 | **Spec**: [spec.md](spec.md) | **Issue**: [#33](https://github.com/alexec/Agents/issues/33)
**Branch**: `agents/work-github-issue-33`, a worktree off main.

## Summary

A Home-screen widget on the iPhone and iPad app: a small one that shows how many sessions
need a person, and a medium one that shows the number and the newest few, each row naming
the project, the agent and what it is asking for. Tapping a row opens that conversation.

The widget never talks to the Mac. It reads one small JSON file that the app writes into the
pair's shared storage on the device — an app group the Remote already holds and nothing has
used yet — and the app asks the system to redraw it whenever the number changes, including
from the silent push that already wakes the app when a need is raised or answered while you
are away.

The number is the Mac's Dock badge number: the app's own grouping of each project, summed
over the live ones. One rule, three surfaces, so they cannot drift.

## Technical Context

- **Language**: Swift 6.2, SwiftUI. WidgetKit for the extension.
- **Dependencies**: none new. `AgentsKitCore` only, as the Remote and `RemoteNotify` have.
- **Storage**: `<app group>/attention-snapshot.json` — the device-local copy the widget
  reads. Not the daemon's store and not a cache of the work: it holds ids, names and counts.
- **Platforms**: iOS/iPadOS 27 only. The Mac app is untouched.
- **Testing**: Swift Testing against `AgentsModel`, which the package's tests already drive
  with fake state; a simulator run of the Remote with `-fake` for the widget's own look; the
  real build for signing.
- **Constraints**: the widget holds no connection, no key and no session (FR-014); the rule
  for "needs you" is not redefined (FR-019); a failure to read or write is silent (FR-018);
  the app group file is removed with the app (FR-015).

## Constitution Check

The constitution is an unfilled template. The plan follows AGENTS.md and the spec. Passes
before and after design.

## Decisions

### 1. Feed, never connect

A widget extension has no daemon link, no paired key and no reason to have one: it gets a
few seconds, often with no network, and a link that hangs is a widget that shows nothing.
So the extension reads a file and nothing else. The app is the only writer (FR-014).

### 2. Where the file goes, and who writes it

`group.com.alexecollins.agents`, which `Remote/Remote.entitlements` already carries and the
signed Remote already has in its profile, unused until now. The writer hooks, all of them on
`RemoteModel`, all of them ending in one `publishAttention()`:

- after `refreshEverything()`, so a fresh connection republishes what it just learned;
- after any notification that could change a count, in the `listen()` loop;
- on `scenePhase(.active)`, beside the `refreshAttention()` that already runs there;
- from `receivedPush`, when a need is raised or withdrawn — the silent push of 021 T079 is
  what makes the number move while the app is not in front (US3, FR-016).

Writing is debounced to one write per turn of the run loop: the notification loop delivers
several notifications for one change, and the file is a few hundred bytes.

### 3. The number is the badge's number

`AttentionSnapshot.make(model:)` sums `counts[.needsAttention]` and `counts[.blocked]` over
the live projects — the expression at `App/Sources/AppModel.swift:503`, in one place now
rather than two (FR-001, FR-019). A second copy of that rule would be the drift the codebase
has been written to avoid, so the widget gets the rule and not the number.

### 4. Rows are sessions, not questions

One agent asking twice is one session and one row (FR-005). The row's "what is wanted" is
the `Headline` the banner already builds for that need (`h3`), which is cut to its budget
before it is sealed; failing that the agent's own last report; failing that nothing, and the
view says what is true of the session instead of inventing a question (FR-007). Rows are
ordered newest first, so the thing that just asked is the first row and the one that has
been waiting longest is not the only row, and capped at four with the remainder said in
words (FR-006).

### 5. One link, one parser

`agents://attention` and `agents://agent/<uuid>`, built and parsed by `AttentionLink` in
Core — in Core because it is the one piece of this that can be tested without a widget, a
simulator or a device, and because the app and the extension must agree on it exactly.
`RemoteModel.open(_:)` already keeps a tap that arrives before the agents have landed
(`pendingOpen`, honoured at the end of `refreshEverything()`), so US2's cold launch is that
path, not a new one (FR-012).

### 6. No information is not zero

With no file the widget says it does not know yet and offers the app (FR-009). Showing `0`
would be a lie the person could not tell from a real zero. With a file, the age is shown
once it is more than a few minutes (FR-017), because the honest limit of a snapshot is that
it is as old as the app's last look.

## To build

1. `AttentionSnapshot`, `AttentionSnapshotSession`, `AttentionLink` in
   `AgentsKitCore/Widget/`. Pure value types, `Codable`, `Hashable`, `Sendable`.
   `AttentionSnapshot.make(model:at:limit:)` is the only place that reads an `AgentsModel`.
2. `AttentionSnapshotStore` beside them: write atomic, read returns nil for no file, both
   take a directory so the tests do not need an app group.
3. `AttentionSnapshotTests` in `Tests/Unit/`: the count rule (including a blocked session),
   one row per session with two needs, the cap and the count of rows not shown, what is
   wanted for a question and for a finished session, ordering by when the need was raised,
   round-trip through JSON, a missing file, and both link forms with a URL that is neither.
4. `RemoteWidget/` — the extension: the bundle, the two layouts, the provider, its
   `Info.plist` and its entitlements (the app group, and nothing else).
5. `project.yml`: the `RemoteWidget` app-extension target, embedded in the Remote's PlugIns
   the way `RemoteNotify` already is, compiling `Shared/UI/{Paper,StateTint,TypeScale}.swift`
   so the widget's colour and type scale are the app's.
6. `RemoteModel.publishAttention()` on the four hooks; `WidgetCenter.reloadTimelines` after a
   write that changed the file.
7. `Remote/Info.plist`: `CFBundleURLTypes` for the `agents` scheme. `RemoteApp`: `.onOpenURL`
   into `AttentionLink.parse`, and `model.openNeedsYou()` for the small widget's tap.

## Requirement coverage

| Requirement | Where |
|---|---|
| FR-001, FR-019 | `AttentionSnapshot.make`, summing the badge's rule over live projects |
| FR-002 … FR-004 | Two layouts; `Paper`, `StateTint`, `TypeScale` from `Shared/UI` |
| FR-005, FR-007 | Rows keyed by agent; `Need.headline.h3`, else the report, else nothing |
| FR-006 | The cap, and the remainder said in the medium header |
| FR-008, FR-009 | The empty states, distinguished by whether a file exists |
| FR-010 … FR-013 | `AttentionLink`, `.onOpenURL`, the existing `open(_:)`/`pendingOpen` path |
| FR-014 | The extension reads one file; no `AgentsKitCore` link, no keychain, no socket |
| FR-015 | An app group file, which the system removes with the app |
| FR-016 | The four hooks on `RemoteModel` |
| FR-017 | The age, shown once it matters |
| FR-018 | `try?` on both sides of the store, no error surfaced |
| SC-001, SC-002 | Both fall out of using one rule and one link; checked against a fake model |
| SC-006 | Nothing outside `Remote/`, `RemoteWidget/` and Core's `Widget/` changes |

## Complexity Tracking

No new service, dependency or protocol method. The one new idea is the snapshot file; it is
a value type, a store over a container URL, and one writer called from four places that
already exist. The extension is a second layout over data the app has already fetched.

Build the `RemoteWidget` target first: it is the only part of this that needs something
outside the repository (a signed App ID for a new bundle identifier, with the App Groups
capability), and finding that out first leaves the rest of the work undisturbed.
