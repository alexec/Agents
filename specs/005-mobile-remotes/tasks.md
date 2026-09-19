---
description: "Task list for Remotes for iPhone and iPad"
---

# Tasks: Remotes for iPhone and iPad

**Input**: Design documents from `specs/005-mobile-remotes/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. The plan names the suites, and three properties here can only be held by tests —
that an envelope opens for its target and for nobody else, that the bridge sends a transcript entry
only to the device watching that agent, and that a question is never answered twice.

**Organization**: By user story, in the plan's phase order. The layout sits in Foundational rather
than in a story phase, deliberately: the plan gates every piece of machinery behind a settled layout,
which makes it a blocking prerequisite and not a deliverable of its own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1, US2, US3 — maps to the user stories in spec.md

## Path Conventions

Four shells around two libraries. New in this feature, from plan.md:

- `Packages/AgentsKit/Sources/AgentsKitCore/` — both platforms. Moved, not rewritten.
- `Packages/AgentsKit/Sources/AgentsKit/` — macOS only, depends on Core
- `Packages/AgentsKit/Tests/AgentsKitTests/` — `Unit/`, `Integration/`, `Fake/`
- `App/Sources/` — the Mac window
- `Daemon/Sources/` — the `agentsd` helper
- `Bridge/Sources/` — NEW. The app-like bundle that owns CloudKit on the Mac.
- `Remote/Sources/` — NEW. The iPhone and iPad app.

---

## Phase 1: Setup — the spike, and the ground

**Purpose**: Answer whether the feature can exist, and make the places new files land.

T001 to T004 are the spike from plan.md phase 0. They are first in importance and **not** a gate on
Phase 2: nothing in the layout depends on their answer, so they run beside it. If T002 fails, stop
and rewrite the spec — the feature becomes "the Mac app must be running", which is a different
feature.

- [ ] T001 Create the CloudKit container for team `6T4RVD5724` in the developer portal and record its identifier in `specs/005-mobile-remotes/research.md` under §2. Both apps must name it explicitly, because their bundle identifiers differ and neither may rely on the default.
- [ ] T002 **Spike, blocking the feature's premise.** Build a throwaway app-like bundle per Apple's "Signing a daemon with a restricted entitlement" — an application target with `NSPrincipalClass`, `NSMainStoryboardFile`, the storyboard and the delegate stripped, no App Sandbox, Hardened Runtime on — carrying `com.apple.developer.icloud-services: ["CloudKit"]` and `com.apple.developer.icloud-container-identifiers`. `posix_spawn` it from a test harness **with `POSIX_SPAWN_SETSID`, as `DaemonClient.spawnHelper()` does**, and confirm: `CKAccountStatus.available`, a custom zone created, one record written and read back, and a key stored in and fetched from the data protection keychain. Record the result in `research.md` §6. If any of it fails, stop.
- [ ] T003 [P] **Spike.** Build a throwaway scene-based iOS app (iOS 27 will not launch one without the UIScene lifecycle), register for remote notifications, create a `CKQuerySubscription`, and measure the interval from the Mac's record write to the banner appearing, ten times, on cellular. Record the worst case in `research.md` §5 — SC-001's five seconds is built on it.
- [ ] T004 [P] **Spike.** Write a record with three `desiredKeys` fields at exactly 100 characters and log what actually arrives in `CKQueryNotification.recordFields`. Record the measured byte budget in `research.md` §5 and in `data-model.md` under Headline. Everything in `Headline.swift` is sized to this measurement, not to the documentation's "may be truncated".
- [ ] T005 [P] Add `devices` to `StoreLocations` in `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`, returning `root.appendingPathComponent("devices.json")`, beside `projects.json`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Split the package so the phone can share the kit, stand up an iOS app that launches, and
**settle the layout on real devices before any machinery is written under it**.

**⚠️ CRITICAL**: No user story work begins until this phase is complete. The gate at T024 is the
point of this ordering: 004 built a project lead under a layout that then moved four times, and the
lead was deleted. See plan.md, Phasing.

### The package split

- [x] T006 Add `.iOS("27.0")` to `platforms` and declare a second target `AgentsKitCore` in `Packages/AgentsKit/Package.swift`, with `AgentsKit` depending on it and the test target depending on both.
- [x] T007 Move `JSONRPC/` whole — `JSONValue.swift`, `JSONRPCMessage.swift`, `JSONRPCError.swift`, `JSONRPCConnection.swift`, `LineTransport.swift` including `FDTransport` and `PairedTransport` — from `Packages/AgentsKit/Sources/AgentsKit/JSONRPC/` to `Packages/AgentsKit/Sources/AgentsKitCore/JSONRPC/`. A move, not a rewrite: every file imports only Foundation.
- [x] T008 Move `Model/` whole from `Packages/AgentsKit/Sources/AgentsKit/Model/` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/`.
- [x] T009 [P] Move `Daemon/DaemonAPI.swift`, `ACP/ACPTypes.swift`, `ACP/ContentBlock.swift`, `ACP/SessionUpdate.swift`, `ACP/ToolCallContent.swift`, `Runtimes/RuntimeAccount.swift` and `Runtimes/RuntimeCatalog.swift` into the matching directories under `Packages/AgentsKit/Sources/AgentsKitCore/`.
- [x] T010 Split `DaemonClient` in `Packages/AgentsKit/Sources/AgentsKit/Client/DaemonClient.swift`: move the actor to `Packages/AgentsKit/Sources/AgentsKitCore/Client/DaemonClient.swift` taking `any LineTransport` injected, and leave the socket-and-spawn half — `connectSocket(path:)`, `spawnHelper()`, `locateHelper()`, all of which use `posix_spawn` and `Bundle.main` — behind in `Packages/AgentsKit/Sources/AgentsKit/Client/SocketTransport.swift` as a `LineTransport` the Mac hands it.
- [x] T011 Lift the meaning of each notification out of `AppModel.received(_:_:)` in `App/Sources/AppModel.swift` into a new `AgentsModel` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`, so the phone applies `agent/changed`, `agent/entry`, `agent/permission`, `agent/usage`, `agent/plan`, `agent/elicitation` and `project/changed` with the same code the Mac does. `AppModel` keeps only what is about the window.
- [x] T012 Build both platforms and run `swift test --package-path Packages/AgentsKit` to confirm the split changed nothing: `xcodebuild -scheme Agents -destination 'platform=macOS' build` and a compile of `AgentsKitCore` for iOS.

### The iOS app, and something to drive it

- [~] T013 Add three targets to `project.yml`: `Remote` (application, `supportedDestinations: [iOS, iPadOS]`, sources `Remote/Sources`, dependency `package: AgentsKitCore`), `RemoteNotificationService` (app-extension, sources `Remote/Sources/NotificationService`), and `AgentsRemote` (the Mac bridge, an application target nested into `Agents.app/Contents/Helpers` by `copy: {destination: wrapper, subpath: Contents/Helpers}`, sources `Bridge/Sources`). Set `deploymentTarget` iOS `"27.0"`.
- [x] T014 Create `Remote/Sources/RemoteApp.swift` **scene-based from this commit** — `@main struct RemoteApp: App` with a `WindowGroup`, no `UIApplicationDelegate` lifecycle — because iOS 27 will not launch an app without the UIScene lifecycle, and nothing at all can be tested until it launches.
- [~] T015 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Fake/FakeDaemon.swift`: a `PairedTransport`-backed stand-in that answers `agents/list`, `projects/list`, `agents/transcript`, `permissions/pending` and `elicitations/pending` from canned data, and can be told to raise a permission request on demand. This is what drives the layout in T016 to T023 — no CloudKit, no crypto, no daemon.

### The layout, on real devices

Every screen in `contracts/ui.md`, driven by `FakeDaemon`. Built to match what 004 actually shipped —
two columns and a push — not the three columns its contract described.

- [x] T016 [P] Create `Remote/Sources/Projects/ProjectListView.swift`: live projects newest activity first, named by the same `ProjectNaming` the Mac uses, each row marking when one of its agents needs the user, a missing folder marked and dimmed but still selectable.
- [x] T017 Create `Remote/Sources/Projects/ProjectPageView.swift`: the project's name, then the prompt bar with this project's folder fixed, then the agents. The path is not repeated under the name; the one case where the folder is news is that it has gone. Mirrors `App/Sources/Projects/ProjectAgentsView.swift`, including its 144pt gutter so the page and a conversation are the same width.
- [x] T018 [P] Create `Remote/Sources/Projects/AgentCard.swift`: a card per agent as on the Mac, saying in "Completed" how it ended — finished, stopped, or the error.
- [x] T019 Group the agents in `ProjectPageView` under "Needs input", "Working", "Completed", in that order, omitting any empty group, using `AgentGroup(for:)` from `AgentsKitCore` — the same file the Mac uses, so the two cannot disagree. Below them, an "Archived (n)" disclosure showing ten at a time.
- [x] T020 Wire navigation in `Remote/Sources/RemoteApp.swift`: `NavigationSplitView` with the projects column and the project page, and the conversation as a **push inside a `NavigationStack`** with a back button — not a third column. On a wide iPad the projects column stays visible; on a phone or narrow iPad it collapses to a back destination.
- [x] T021 [P] Create `Remote/Sources/Chat/RemoteChatView.swift`: transcript with diffs, command output and files a tool call touched, laid out for the screen, with cost and context shown as reported and never estimated.
- [x] T022 [P] Create `Remote/Sources/Permission/PermissionSheet.swift`: the question in full — the command or the change — with the same choices the Mac offers and no fewer. An already-answered question says so and by which device, and puts the outcome where the buttons were.
- [x] T023 [P] Create `Remote/Sources/StaleBanner.swift`: one line at the top — "Last heard from your Mac 12 minutes ago" — with everything below it dimmed and marked stale, reading as information and not as an error (FR-035).
- [ ] T024 **Gate.** Build and run `Remote` on a real iPhone and a real iPad, not only the simulator, and walk every screen in `contracts/ui.md` side by side with the Mac. Iterate until the layout is settled. **Nothing in Phase 3 or later begins until it has stopped changing.**

**Checkpoint**: the kit is shared, an iOS app launches and is worth using, and the layout is settled.
User story work can begin.

---

> **Where this got to, 2026-09-19.** The package split, the iOS target and every screen
> in T016 to T023 are in and run on both simulators. Three tasks landed differently from
> how they were written, marked `[~]`:
>
> - **T011** — done. `AgentsModel` is in `AgentsKitCore/Client/` and both clients hold
>   one; `AppModel` forwards to it and keeps only what is about the window. Thirteen
>   tests in `Unit/AgentsModelTests.swift` hold the properties both of them now share.
>   It caught one real disagreement on the way in: the window standardised an agent's
>   `cwd` before matching it to a project and the remote did not, so a project whose
>   folder was written with a trailing slash would have looked empty on the phone while
>   its agents were plainly running.
> - **T013** — only the `Remote` target was added. `RemoteNotificationService` and the
>   `AgentsRemote` bridge have no sources yet, and an empty target is a build that
>   passes for no reason.
> - **T015** — the fake is `Remote/Sources/Preview/FakeDaemon.swift`, not a test file.
>   It has to be linked into the app to drive the app, and it is a `DaemonLink` rather
>   than a fake model, so `DaemonClient` and `RemoteModel` above it run unchanged when
>   the mailbox replaces it. T048 becomes one line.
>
> `Remote/Sources/RemoteModel.swift` carries a `#if DEBUG` `openFromLaunchArguments()`,
> because this machine has no Simulator window to tap. It goes when the layout does.
>
> T001 to T004 are untouched: they need a developer-portal container, a paired device
> and a cellular connection. T024 needs real hardware. All five are yours.


## Phase 3: User Story 1 — Answer the thing that is waiting, from anywhere (Priority: P1) 🎯 MVP

**Goal**: a phone buzzes on a train, names the project and the agent, takes the answer, and the agent
carries on.

**Independent Test**: with the phone on cellular and the Mac on a different network, provoke a
permission request, confirm the phone is notified within 5 seconds, answer from the phone, and confirm
the agent proceeds on the Mac.

### Tests for User Story 1

- [ ] T025 [P] [US1] Write `Unit/EnvelopeTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/`: a sealed envelope opens for its target; does **not** open for another device's key; does not open when `to`, `from` or `sequence` is edited, since all three are bound in as associated data; and a sequence gap is reported to the reader rather than repaired.
- [ ] T026 [P] [US1] Write `Unit/HeadlineTests.swift` asserting each of `h1`, `h2`, `h3` is truncated to the budget measured in T004 **before** sealing, and that a headline which will not fit degrades to the generic placeholder rather than being cut mid-sequence.
- [ ] T027 [P] [US1] Write `Integration/BridgeTests.swift` against `PairedTransport`: a question is forwarded to every approved device; a transcript entry is forwarded **only** to the device whose subscription says it is watching that agent (FR-037); nothing is ever sealed to a device without an approved record.
- [ ] T028 [P] [US1] Write `Integration/AnswerRaceTests.swift` firing two answers at one `permissionID` concurrently, 100 times: exactly one succeeds each time and the other gets `alreadyAnswered` (`-32013`), never `noSuchAgent` (SC-007).

### The envelope and the mailbox

- [ ] T029 [P] [US1] Create `DeviceKey` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/DeviceKey.swift`: a **P256** key pair — P256 and not Curve25519 because the Secure Enclave holds P256 and does not hold Curve25519 — stored in the device's own keychain with accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`ThisDeviceOnly` because a key that syncs cannot be revoked from one device; `AfterFirstUnlock` because the notification extension reads it while the phone is locked), in an access group shared by the app and its extension, Enclave-backed where available.
- [ ] T030 [P] [US1] Create `Device` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Device.swift` with the fields from data-model.md: `id: UUID`, `publicKey: Data`, `name: String`, `kind: Kind` (`iPhone`, `iPad`, `unknown`), `announcedAt: Date`, `approvedAt: Date?` (nil means waiting), `lastSeenAt: Date?`, `wants: Notify` (three flags `needsInput`, `finished`, `failed`, all defaulting to on), and `unknownFields: [String: JSONValue]` kept and rewritten as `Agent` and `Project` do. Derived `isApproved` is `approvedAt != nil`.
- [ ] T031 [US1] Create `Envelope` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Envelope.swift`: `to: UUID`, `from: UUID`, `sequence: Int` all plaintext, and `sealed: Data` using HPKE with the P256 suite to the target's public key, **binding `to`, `from` and `sequence` in as associated data**. What is inside is one JSON-RPC line. An envelope that does not open is dropped and logged, never guessed at and never partly applied (depends on T029, T030).
- [ ] T032 [P] [US1] Create `Headline` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Headline.swift`: three fields sealed separately — `h1` the project name, `h2` the agent name, `h3` a short action such as "wants to run `git push`" — each truncated to the budget measured in T004 before sealing, since `desiredKeys` takes at most 3 keys of about 100 characters.
- [ ] T033 [US1] Create the `Mailbox` protocol in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Mailbox.swift` — write, fetch since a sequence, delete, sweep — with a `FakeMailbox` beside it in `Packages/AgentsKit/Tests/AgentsKitTests/Fake/`, because a test suite that needs an iCloud account is a test suite that does not run.
- [ ] T034 [US1] Implement `CloudKitMailbox` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/CloudKitMailbox.swift` against the record shape in `contracts/mailbox.md`: record type `Message` in a custom zone of the private database, with plaintext `to`, `from`, `kind` (`event`/`request`/`response`), `seq`, `createdAt`, and our own ciphertext in `sealed`, `h1`, `h2`, `h3`. **No plaintext field may name a project, agent, folder, tool or command.** Honour `CKErrorRetryAfterKey` on every operation without exception; never exceed 400 records per operation or the 1 MB record ceiling (depends on T031, T033).
- [ ] T035 [US1] Implement `MailboxTransport` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/MailboxTransport.swift` as a third `LineTransport` beside `FDTransport` and `PairedTransport`, so `JSONRPCConnection` and `DaemonClient` work across it unchanged (depends on T034).

### The daemon's three small changes

- [ ] T036 [P] [US1] Create `DeviceStore` in `Packages/AgentsKit/Sources/AgentsKit/Store/DeviceStore.swift`: reads and writes the whole JSON array at `locations.devices` using `StoreCoding`'s encoder and decoder. A missing or unreadable file is an empty list, never an error (depends on T005, T030).
- [ ] T037 [US1] Create `DaemonCore+Devices.swift` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/` with `devices/list`, `devices/announce`, `devices/approve` and `devices/revoke` per `contracts/daemon-api.md`. `devices/announce` returns the existing record when the same `id` announces twice with the same key, and fails `notSupported` when the `id` exists with a **different** `publicKey` — a key never changes under an identity. `devices/revoke` deletes the record, because deletion is what makes the device unable to read anything rather than a flag somebody must remember to check (depends on T036).
- [ ] T038 [US1] Add the four cases to the switch in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, and broadcast `device/changed` — `{ device }` on announce, approve and last-seen, `{ id, gone: true }` on revoke (depends on T037).
- [ ] T039 [US1] Add `alreadyAnswered = -32013` and `noSuchDevice = -32014` to `DaemonAPI.Failure` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, continuing the block that 004 leaves at `-32012`.
- [ ] T040 [US1] Add `answeredBy: String?` to `DaemonAPI.AnswerRequest` and `DaemonAPI.AnswerElicitationRequest`, and to `PermissionNotification`, all in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, all **optional on read** so a client built before this change still answers and a daemon built before it still accepts.
- [ ] T041 [US1] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:390` `answerPermission`, throw `alreadyAnswered` instead of `noSuchAgent` when `pendingPermissions.removeValue` returns nil — keeping the message "That question has already been answered." — and carry `answeredBy` into the `request: nil` withdrawal broadcast. Make the same change to `answerElicitation` in `DaemonCore+Serving.swift:20` (depends on T039, T040).

### The bridge

- [ ] T042 [US1] Create `Bridge/Sources/main.swift`: connect to `agentsd` over the existing Unix socket using `DaemonClient` with `SocketTransport` — an ordinary client, so the daemon gains no listener and no network code — and exit when no device is approved.
- [ ] T043 [US1] Create `Bridge/Sources/Subscription.swift` holding, per device, what it is watching: `device`, `watching: UUID?`, `since: Int`. In memory, never stored — if the bridge restarts the remote says again (depends on T042).
- [ ] T044 [US1] Create `Bridge/Sources/BridgeCore.swift`: forward state changes and questions to every approved device always, and transcript entries only to the device watching that agent; seal each with `Envelope`; write transcript in coalesced chunks of roughly one record per second of output or on a semantic boundary, **never one per token**, because one record per token would exhaust CloudKit's ~40 requests a second in seconds (depends on T035, T043).
- [ ] T045 [US1] Create `Bridge/Sources/Poller.swift`: poll the mailbox every second while any agent is `waitingOnUser`, holding an `NSProcessInfo.beginActivity` assertion for exactly that window and releasing it on answer or timeout; poll rarely otherwise and let the Mac sleep. The Mac does not use push: macOS will not launch a stopped application to deliver one, and there is a live unresolved CloudKit push-delivery regression on macOS (research §10) (depends on T044).
- [ ] T046 [US1] Spawn the bridge from `agentsd` with `posix_spawn`, the way the app spawns `agentsd`, when at least one device is approved or waiting — **no `SMAppService` and no login item**, per research §7. Add the spawn to `Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift`.
- [ ] T047 [US1] Add `Bridge/Bridge.entitlements` with `com.apple.developer.icloud-services: ["CloudKit"]`, `com.apple.developer.icloud-container-identifiers` naming the container from T001, and the keychain access group. Embed the provisioning profile in the nested bundle (depends on T002).

### The phone

- [ ] T048 [US1] Point `Remote`'s model in `Remote/Sources/RemoteModel.swift` at a real `DaemonClient` over `MailboxTransport` in place of `FakeDaemon`, so the layout settled in Phase 2 is now driven by the Mac (depends on T035, T044).
- [ ] T049 [US1] Create the device's `CKQuerySubscription` in `Remote/Sources/Pairing/Subscribe.swift`: `firesOnRecordCreation`, predicate `to == <this device>`, `alertBody` set to a generic placeholder — **not optional**, because a notification with no alert, sound or badge is sent at lower priority and SC-001 cannot rest on one — `shouldSendMutableContent = true`, and `desiredKeys = ["h1", "h2", "h3"]`.
- [ ] T050 [US1] Create `Remote/Sources/NotificationService/NotificationService.swift`: decrypt `h1`, `h2`, `h3` with the device's key and rewrite the banner to name the project and the agent. **No network I/O and no CloudKit**, which is what keeps it inside a memory ceiling of roughly 20 MB. Implement `serviceExtensionTimeWillExpire` and always deliver something; on any failure deliver the placeholder rather than nothing (depends on T029, T032).
- [ ] T051 [US1] Add `Remote/Remote.entitlements` with the same iCloud services and container as T047, the shared keychain access group, and `aps-environment`.
- [ ] T052 [US1] Answer a permission from the phone in `Remote/Sources/Permission/PermissionSheet.swift` with `answeredBy` set to the device's name, and on receiving a withdrawal with `answeredBy` set, replace the question's buttons with what became of it and who answered — never a second answer (FR-032) (depends on T022, T041).
- [ ] T053 [US1] Hard-code approval of the first announcing device in `DaemonCore+Devices.swift`, with a `// TODO(T060)` comment, so US1 is testable before the pairing UI exists. This is the one place US1 knowingly leaves a gap for US3 to close.

**Checkpoint**: a phone on cellular is notified within 5 seconds, names the project and the agent, and
the answer reaches the Mac. This is the feature; everything after it is reach and comfort.

---

## Phase 4: User Story 2 — Keep working from the iPad (Priority: P2)

**Goal**: the iPad becomes a second desk — read what an agent did, start another, answer two
permissions without getting up.

**Independent Test**: on an iPad away from the Mac's network, select a project, read a transcript
including a diff and command output, start a new agent in that project, prompt it, and stop it.

- [ ] T054 [P] [US2] Page the transcript in `Remote/Sources/Chat/RemoteChatView.swift` using the `before` and `limit` that `DaemonAPI.TranscriptRequest` already carries — no new method is added — opening at the end of the conversation and fetching backwards as the user scrolls (FR-037).
- [ ] T055 [P] [US2] Tell the bridge what this device is watching as the selected agent changes, from `Remote/Sources/RemoteModel.swift` into `Bridge/Sources/Subscription.swift`, so transcript for every other agent stays off the connection (depends on T043).
- [ ] T056 [US2] Start an agent from the project page's prompt bar in `Remote/Sources/Projects/ProjectPageView.swift` via `agents/start` with the project's folder already set, choosing from the runtimes the Mac has via `agents/options`, and land in the new agent's conversation.
- [ ] T057 [P] [US2] Stop a running agent, and archive and unarchive an agent, from the conversation's toolbar in `Remote/Sources/Chat/RemoteChatView.swift` via `agents/stop`, `agents/archive` and `agents/unarchive`.
- [ ] T058 [P] [US2] Add attachments to a prompt from the photo library and Files in `Remote/Sources/Chat/`, refused before sending when the runtime cannot take them — the same refusal the Mac gives, for the same reason.
- [ ] T059 [P] [US2] Answer an elicitation form from the phone in `Remote/Sources/Elicitation/`, via `elicitations/answer` with `answeredBy` set (FR-028).
- [ ] T060 [US2] Follow a project being archived on the Mac while the remote is looking at it, in `Remote/Sources/RemoteModel.swift`: move the selection rather than leaving an empty pane (spec US2 scenario 7).

**Checkpoint**: an iPad away from the Mac's network is a place to do work, not only to watch it.

---

## Phase 5: User Story 3 — Pair a device, and take it back (Priority: P3)

**Goal**: add a device once, at the Mac. Remove it when it is lost, and it can read nothing.

**Independent Test**: pair a device at the Mac and confirm it connects; revoke it and confirm it can
no longer connect or read anything, including with its app open at the time.

- [ ] T061 [P] [US3] Write `Integration/RevocationTests.swift`: after revoking, nothing is sealed to that device, every record addressed to it is deleted, and a connection attempt is refused.
- [ ] T062 [US3] Create `Remote/Sources/Pairing/FirstRunView.swift`: what this is, that it needs the same Apple Account with iCloud Drive on, and one button. Then "Waiting for you to approve this on your Mac." Check `CKAccountStatus` first and say plainly which of the two is missing rather than failing (research §6).
- [ ] T063 [US3] Announce the device into the mailbox on first run from `Remote/Sources/Pairing/Announce.swift` — `id`, `name`, `kind`, `publicKey` — and have the bridge call `devices/announce` when an unknown device appears (depends on T037, T042).
- [ ] T064 [US3] Replace the hard-coded approval from T053 with a real question in `App/Sources/Devices/ApprovalAlert.swift`: "Alex's iPhone would like to connect", with **Approve** and **Deny**. Nothing is sealed to a device before this.
- [ ] T065 [P] [US3] Create `App/Sources/Devices/DeviceListView.swift` in the Mac's settings: each device by name, its kind, when it was paired, when it last connected, which notifications it wants, and **Revoke** — saying plainly that the device will no longer be able to read anything.
- [ ] T066 [US3] On revoke, delete the record in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Devices.swift` and have `Bridge/Sources/BridgeCore.swift` empty that device's mailbox at once, so a revoked device holds nothing readable and receives nothing new. Revoking and denying are the same act (depends on T037, T065).
- [ ] T067 [P] [US3] Let each device turn `finished` and `failed` notifications off independently in `Remote/Sources/Settings/`, persisted to its `Device.wants` on the Mac (FR-016).

**Checkpoint**: all three stories work. Pairing is something a user can hold, and revoking is real.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T068 [P] Sweep the mailbox: a reader deletes what it has opened, a writer deletes anything older than seven days. CloudKit has no record expiry we can set, and an undrained mailbox is both a privacy leak and a charge against the user's own iCloud quota.
- [ ] T069 [P] Handle `CKErrorUserDidResetEncryptedDataKey` and a missing zone by recreating the zone and re-announcing. No agent data is at risk, because none of it lives there.
- [ ] T070 [P] Accessibility pass on `Remote/Sources/`: group headings are headings, a row needing the user says so in its label and not only with a dot, and the permission sheet's choices never truncate under Dynamic Type — a permission the user cannot read in full is one they cannot answer.
- [ ] T071 Answer `ITSAppUsesNonExemptEncryption` deliberately in `App/Resources/Info.plist` and the new targets' plists. It is currently `false` and that is no longer true. This is an export-compliance declaration to get right before submission, not a default to leave standing.
- [ ] T072 [P] Update `README.md`: what the remotes are, that they need the same Apple Account with iCloud Drive on, and the two designed behaviours a user would otherwise file as faults — **after a reboot the Mac app must be opened once**, and **a sleeping Mac does not answer**.
- [ ] T073 Confirm FR-038: with no device paired, `pgrep -fl AgentsRemote` is empty, no CloudKit call is made, and the Mac app behaves exactly as it does today. The feature is inert until it is asked for.
- [ ] T074 Run every check in `specs/005-mobile-remotes/quickstart.md`, including the privacy one — inspect `Message` records in CloudKit Console while a conversation is in flight and confirm no plaintext field names a project, agent, folder, tool or command (SC-009).
- [ ] T075 Decide FR-004. Either build the direct local connection as a fourth `LineTransport` over `NWListener` and Bonjour, reusing the device key pairs, or amend FR-004 and the tighter half of SC-006 out of `spec.md`. Do not leave it stated and unmet.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: T001 first. T002 to T004 are the spike — first in importance, not a gate on Phase 2, because nothing in the layout depends on their answer. **If T002 fails, stop and rewrite the spec.**
- **Phase 2 (Foundational)**: depends on T005. Blocks every user story. The gate is T024.
- **Phase 3 (US1)**: depends on Phase 2 complete **and T002 passing**.
- **Phase 4 (US2)**: depends on Phase 3 — it needs a real connection to work against.
- **Phase 5 (US3)**: depends on Phase 3 (it replaces T053). Independent of Phase 4.
- **Phase 6 (Polish)**: depends on the stories being done.

### Within Phase 2

T006 → T007, T008, T009 (the moves) → T010, T011 → T012. T013 to T015 run alongside the moves.
T016 to T023 need T013 to T015, then T024 gates everything.

### Within User Story 1

Tests (T025 to T028) before the code they cover. Then the envelope (T029 to T032) → the mailbox
(T033 to T035) → the daemon (T036 to T041) → the bridge (T042 to T047) → the phone (T048 to T053).
The daemon block and the envelope block are independent of each other and can run together.

### Parallel Opportunities

- T003, T004 and T005 alongside T002.
- T007, T008, T009 are three separate directory moves.
- T016, T018, T021, T022, T023 are five separate view files.
- T025 to T028 are four separate test files.
- T029, T030, T032, T036 touch four different files.
- Phase 4 is almost entirely parallel: T054, T055, T057, T058, T059 are separate files.
- Phase 6: T068, T069, T070, T072 are independent.

---

## Parallel Example: the layout in Phase 2

```bash
# Once T013–T015 are done, five views can be written at once:
Task: "ProjectListView in Remote/Sources/Projects/ProjectListView.swift"
Task: "AgentCard in Remote/Sources/Projects/AgentCard.swift"
Task: "RemoteChatView in Remote/Sources/Chat/RemoteChatView.swift"
Task: "PermissionSheet in Remote/Sources/Permission/PermissionSheet.swift"
Task: "StaleBanner in Remote/Sources/StaleBanner.swift"
```

## Parallel Example: User Story 1 tests

```bash
Task: "Unit/EnvelopeTests.swift"
Task: "Unit/HeadlineTests.swift"
Task: "Integration/BridgeTests.swift"
Task: "Integration/AnswerRaceTests.swift"
```

---

## Implementation Strategy

### MVP (User Story 1)

1. Phase 1 — and if T002 fails, stop. The feature as specified does not exist.
2. Phase 2 — split the kit, then **settle the layout on real devices**. Do not shorten this.
3. Phase 3 — the machinery, under a layout that has stopped moving.
4. **STOP and VALIDATE**: phone on cellular, Mac elsewhere, permission answered from a train.

That is a shippable feature on its own. Pairing is hard-coded (T053) and the iPad is readable but not
yet a desk — both are honest limitations, neither is a broken promise.

### Incremental delivery

1. Setup + Foundational → an iOS app worth using, driven by a fake.
2. + US1 → the feature. Ship it.
3. + US2 → the iPad becomes a place to work.
4. + US3 → pairing and revoking become real; remove the hard-coded approval.
5. + Polish → the sweep, the declaration, the README, and the FR-004 decision.

### Why the layout comes first

004 specified, planned and built a project lead — MCP tools, four guards, a held permission flow —
alongside a new layout. The layout then changed four times, each change made the lead mean something
slightly different, and it was removed entirely. All of that work was written, tested and deleted.

The machinery under this feature is worse: an entitlement, a container, a crypto envelope and a push
extension are not things to rework because a screen moved. T024 is the gate that stops that
happening twice.

---

## Notes

- [P] tasks = different files, no dependencies.
- Commit after each task or logical group.
- T002 is the only task that can end the feature. Do it early and believe the answer.
- T053 is a deliberate gap, closed by T064. It is the only one.
