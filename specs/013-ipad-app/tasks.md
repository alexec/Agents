---

description: "Task list for the iPad Remote"
---

# Tasks: The iPad Remote

**Input**: Design documents from `/specs/013-ipad-app/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Included. Not by TDD dogma — plan.md's Technical Context names the pure things worth
testing (the `Escalation` derivation, the category round trip, the envelope, the answer race),
and this repo already runs `swift test --package-path Packages/AgentsKit`. Tests are written
where the thing under test is a function; what cannot be faked is measured on device and
recorded, not asserted.

**Organization**: by user story, with one deliberate deviation from the template — see below.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1–US4, mapping to spec.md's user stories
- Exact file paths in every description

## Two tracks, and a deviation from the template

The template says Foundational blocks **all** user stories. Here it does not, and that is the
central sequencing decision in plan.md:

- **Track A** — Phase 2 Foundational, then US1 and US4. The unbuilt half of feature 005: the
  spikes, device keys, the envelope, the mailbox, the bridge as a real process, pairing.
- **Track B** — **US2 (Phase 5) depends only on Phase 1** and runs over the direct link that
  already works on the same Wi-Fi. It does not wait for Phase 2 and it is not blocked by the
  CloudKit spike that could sink Track A.

Two people can run the two tracks at once. One person should start Phase 2's spikes, and while
they are pending, work Phase 5.

**Inherited numbering warning**: tasks marked *(005 Txxx)* are carried from
`specs/005-mobile-remotes/tasks.md`. Re-read them there for detail — but **never paste their
error numbers**. `-32013` and `-32014` are taken; see research §7.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: the things every later phase needs to exist first.

- [ ] T001 Create the CloudKit container for team `6T4RVD5724` in the developer portal and record its identifier in `specs/013-ipad-app/research.md` under a new §10. Both the bridge and the Remote app must name it explicitly, because their bundle identifiers differ and neither may rely on the default. *(005 T001)*
- [ ] T002 Add the `RemoteNotificationService` app extension target to `project.yml`: `supportedDestinations: [iOS]`, sources `Remote/Sources/NotificationService`, embedded in the `Remote` target, depending on `AgentsKitCore` only. Regenerate with `xcodegen generate` and confirm the extension appears inside the app bundle.
- [ ] T003 Add the app group `group.com.alexecollins.agents` to `project.yml` for both the `Remote` target and the new extension target, and the shared keychain access group for both. These are what let the extension and the app reach the same `OutstandingQuestion` (contracts/notification-actions.md).
- [ ] T004 [P] Create `Remote/Remote.entitlements` with `com.apple.developer.icloud-services: ["CloudKit"]`, `com.apple.developer.icloud-container-identifiers` naming T001's container, `aps-environment`, the app group and the keychain access group. Wire it via `CODE_SIGN_ENTITLEMENTS` in `project.yml`, not via an `entitlements:` key — see the comment in `project.yml` explaining why XcodeGen must not own the file. *(005 T051)*
- [ ] T005 [P] Create `Bridge/Bridge.entitlements` with the same iCloud services and container as T004, plus the keychain access group. No `aps-environment` — the Mac polls, it is not pushed to (005 research §10). *(005 T047)*
- [X] T006 [P] Add `alreadyAnswered = -32019` and `noSuchDevice = -32020` (the numbers this task proposed were taken by feature 010's `dayLimitReached = -32018`; picked by reading the file, as the task says to) to `DaemonAPI.Failure` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`. **Not** 005's `-32013`/`-32014`, which are `projectHasLiveAgents` and `noSuchWorkflow`. Pick by reading the file: it already contains a collision at `-32010`. *(research §7)*
- [X] T007 [P] Add `devices` to `StoreLocations` in `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`, returning `root.appendingPathComponent("devices.json")`, beside `projects.json`. *(005 T005)*

**Checkpoint**: both targets build, `xcodebuild -scheme Remote -destination 'generic/platform=iOS' build` passes. Track B can begin.

---

## Phase 2: Foundational (Blocking Prerequisites for Track A)

**Purpose**: everything US1 and US4 stand on. **Does not block US2 (Phase 5).**

**⚠️ The four spikes come first and any of them can end or reshape the feature.** Do not build
on top of an unanswered one.

### Spikes

- [ ] T008 **Spike, blocking the feature's premise.** Build a throwaway app-like bundle per Apple's "Signing a daemon with a restricted entitlement" — an application target with `NSPrincipalClass`, `NSMainStoryboardFile`, the storyboard and the delegate stripped, no App Sandbox, Hardened Runtime on — carrying T001's container. `posix_spawn` it from a test harness **with `POSIX_SPAWN_SETSID`, as `DaemonClient.spawnHelper()` does**, and confirm `CKAccountStatus.available`, a custom zone created, one record written and read back, and a key stored in and fetched from the data protection keychain. Record the result in `specs/013-ipad-app/research.md` §10. **If it fails, stop and re-spec.** *(005 T002)*
- [ ] T009 [P] **Spike.** In a throwaway scene-based iOS app, register for remote notifications, create a `CKQuerySubscription`, and measure the interval from the Mac's record write to the banner appearing, ten times, on cellular. Record the worst case in `specs/013-ipad-app/research.md` §10 — SC-001's five seconds rests on it. *(005 T003)*
- [ ] T010 [P] **Spike.** Write a record with three `desiredKeys` fields at exactly 100 characters and log what actually arrives in `CKQueryNotification.recordFields`. Record the measured byte budget in `research.md` §10 and in `data-model.md` under `Headline`. Everything in `Headline.swift` is sized to this measurement, not to the documentation's "may be truncated". *(005 T004)*
- [ ] T011 **Spike, new to 013, blocking FR-008.** On a real iPad on cellular, answer the three questions in `research.md` §3: does a non-`foreground` `UNNotificationAction` handler run when the app is merely backgrounded; does it run after a force-quit from the app switcher; and can a sealed mailbox write complete inside the handler's budget from cold, ten times. Record all three in `research.md` §3, replacing the **Unverified** marker. **If the force-quit answer is no, add the stated limit to `spec.md` FR-008 before building US1.**

### Keys, envelopes and the mailbox

- [ ] T012 [P] Create `DeviceKey` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/DeviceKey.swift`: a **P256** key pair — P256 and not Curve25519 because the Secure Enclave holds P256 — stored in the device's keychain with accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`ThisDeviceOnly` because a key that syncs cannot be revoked from one device; `AfterFirstUnlock` because the extension reads it while the iPad is locked), in the access group from T003, Enclave-backed where available. *(005 T029)*
- [ ] T013 [P] Create `Device` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Device.swift` with the fields from `specs/005-mobile-remotes/data-model.md`: `id: UUID`, `publicKey: Data`, `name: String`, `kind: Kind` (`iPhone`, `iPad`, `unknown`), `announcedAt: Date`, `approvedAt: Date?` (nil means waiting), `lastSeenAt: Date?`, `wants: Notify` (three flags `needsInput`, `finished`, `failed`, all defaulting to on), and `unknownFields: [String: JSONValue]` kept and rewritten as `Agent` and `Project` do. Derived `isApproved` is `approvedAt != nil`. *(005 T030)*
- [ ] T014 [P] Write `Unit/EnvelopeTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/`: a sealed envelope opens for its target; does **not** open for another device's key; does not open when `to`, `from` or `sequence` is edited, since all three are bound in as associated data; and a sequence gap is reported to the reader rather than repaired. *(005 T025)*
- [ ] T015 Create `Envelope` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Envelope.swift`: `to: UUID`, `from: UUID`, `sequence: Int` all plaintext, and `sealed: Data` using HPKE with the P256 suite to the target's public key, **binding `to`, `from` and `sequence` in as associated data**. Inside is one JSON-RPC line. An envelope that does not open is dropped and logged, never guessed at and never partly applied. Depends on T012, T013, T014. *(005 T031)*
- [ ] T016 [P] Write `Unit/HeadlineTests.swift` asserting each of `h1`, `h2`, `h3` is truncated to T010's measured budget **before** sealing, and that a headline which will not fit degrades to the generic placeholder rather than being cut mid-sequence. *(005 T026)*
- [ ] T017 Create `Headline` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Headline.swift`: three fields sealed separately — `h1` the project name, `h2` the agent name, `h3` a short action such as "wants to run `git push`" — each truncated to T010's budget before sealing. Depends on T010, T016. *(005 T032)*
- [ ] T018 Create the `Mailbox` protocol in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Mailbox.swift` — write, fetch since a sequence, delete, sweep — with a `FakeMailbox` beside it in `Packages/AgentsKit/Tests/AgentsKitTests/Fake/`, because a test suite that needs an iCloud account is a test suite that does not run. *(005 T033)*
- [ ] T019 Implement `CloudKitMailbox` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/CloudKitMailbox.swift` against `specs/005-mobile-remotes/contracts/mailbox.md`: record type `Message` in a custom zone of the private database, plaintext `to`, `from`, `kind` (`event`/`request`/`response`), `seq`, `createdAt`, and our ciphertext in `sealed`, `h1`, `h2`, `h3`. **No plaintext field may name a project, agent, folder, tool or command.** Honour `CKErrorRetryAfterKey` on every operation; never exceed 400 records per operation or the 1 MB record ceiling. Depends on T015, T018. *(005 T034)*
- [ ] T020 Implement `MailboxTransport` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/MailboxTransport.swift` as a third `LineTransport` beside `FDTransport` and `PairedTransport`, so `JSONRPCConnection` and `DaemonClient` work across it unchanged. Depends on T019. *(005 T035)*
- [ ] T021 Create `LinkChooser` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/LinkChooser.swift` per `specs/005-mobile-remotes/contracts/transport.md`: start the direct browse and the mailbox **at once** rather than trying direct and falling back — a Bonjour browse on a network with no Mac does not fail, it stays quiet — take whichever answers, hand over without losing an action in flight, and expose which link is live. On an iPad this is load-bearing rather than a refinement (research §9). Depends on T020.
- [ ] T022 [P] Write `Unit/NetworkLinkTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/`: a browser and a listener on the loopback interface find each other, a line written one end arrives whole at the other, and two lines in one write arrive as two. No CloudKit and no second device. *(005 T024i)*

### The daemon's side

- [ ] T023 Create `DeviceStore` in `Packages/AgentsKit/Sources/AgentsKit/Store/DeviceStore.swift`: reads and writes the whole JSON array at `locations.devices` using `StoreCoding`'s encoder and decoder. A missing or unreadable file is an empty list, never an error. Depends on T007, T013. *(005 T036)*
- [ ] T024 Create `DaemonCore+Devices.swift` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/` with `devices/list`, `devices/announce`, `devices/approve` and `devices/revoke` per `specs/005-mobile-remotes/contracts/daemon-api.md`. `devices/announce` returns the existing record when the same `id` announces twice with the same key, and fails `notSupported` when the `id` exists with a **different** `publicKey` — a key never changes under an identity. `devices/revoke` **deletes** the record, because deletion is what makes a device unable to read anything, rather than a flag somebody must remember to check. Depends on T023. *(005 T037)*
- [ ] T025 Add the four `devices/*` cases to the switch in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, and broadcast `device/changed` — `{ device }` on announce, approve and last-seen, `{ id, gone: true }` on revoke. Depends on T024. *(005 T038)*
- [ ] T026 Add `answeredBy: String?` to `DaemonAPI.AnswerRequest`, `DaemonAPI.AnswerElicitationRequest` and `PermissionNotification` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, all **optional on read** so a client built before this change still answers and a daemon built before it still accepts. *(005 T040)*
- [ ] T027 [P] Write `Integration/AnswerRaceTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/` firing two answers at one `permissionID` concurrently, 100 times: exactly one succeeds each time and the other gets `alreadyAnswered` (`-32018`), never `noSuchAgent` (SC-004). *(005 T028)*
- [ ] T028 In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` `answerPermission`, throw `alreadyAnswered` instead of `noSuchAgent` when `pendingPermissions.removeValue` returns nil — keeping the message "That question has already been answered." — and carry `answeredBy` into the `request: nil` withdrawal broadcast. Make the same change to `answerElicitation` in `DaemonCore+Serving.swift`. Depends on T006, T026, T027. *(005 T041)*

### The bridge, made real

- [ ] T029 Create `Bridge/Sources/Subscription.swift` holding, per device, what it is watching: `device`, `watching: UUID?`, `since: Int`. In memory, never stored — if the bridge restarts the remote says again. *(005 T043)*
- [ ] T030 [P] Write `Integration/BridgeTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/` against `PairedTransport`: a question is forwarded to every approved device; a transcript entry is forwarded **only** to the device whose subscription says it is watching that agent (FR-024); nothing is ever sealed to a device without an approved record. *(005 T027)*
- [ ] T031 Create `Bridge/Sources/BridgeCore.swift`: forward state changes and questions to every approved device always, transcript entries only to the device watching that agent; seal each with `Envelope`; write transcript in coalesced chunks of roughly one record per second of output or on a semantic boundary, **never one per token**, which would exhaust CloudKit's ~40 requests a second in seconds. Depends on T020, T029, T030. *(005 T044)*
- [ ] T032 Create `Bridge/Sources/Poller.swift`: poll the mailbox every second while any agent is `waitingOnUser`, holding an `NSProcessInfo.beginActivity` assertion for exactly that window and releasing it on answer or timeout; poll rarely otherwise and let the Mac sleep. The Mac does not use push — macOS will not launch a stopped application to deliver one. Depends on T031. *(005 T045)*
- [ ] T033 Spawn the bridge from `agentsd` with `posix_spawn`, the way the app spawns `agentsd`, when at least one device is approved or waiting — **no `SMAppService` and no login item**. Add the spawn to `Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift`, and stop starting it by hand. Depends on T008, T032. *(005 T046, T024h)*

### Closing 005's security debt — all three block ship

- [ ] T034 **Debt, blocking ship.** Seal every payload on the direct link in `Bridge/Sources/main.swift` with `Envelope`, exactly as the mailbox does, so FR-006 and SC-011 hold on the home network too. A home network is not a trusted network (005 FR-004c). Depends on T015. *(005 T024e)*
- [ ] T035 **Debt, blocking ship.** Refuse an unpaired device at accept in `Bridge/Sources/main.swift`, checked against `DeviceStore`, and say how to pair rather than dropping the connection silently. Depends on T023. *(005 T024f)*
- [ ] T036 **Debt, blocking ship.** Drop an open connection in `Bridge/Sources/main.swift` when its device is revoked — re-checked on `device/changed`, not only at accept — so revocation "within seconds even for a device connected at the time" holds on the one link that holds a connection open (SC-010). Depends on T025, T035. *(005 T024g)*
- [ ] T037 Hard-code approval of the first announcing device in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Devices.swift`, with a `// TODO(T070)` comment, so US1 is testable before the pairing UI exists. This is the one place Track A knowingly leaves a gap for US4 to close. Depends on T024. *(005 T053)*

**Checkpoint**: an iPad can reach the Mac over both links, sealed, refused if unpaired. Nothing is notified yet.

---

## Phase 3: User Story 1 - Being asked, and answering from where you are (Priority: P1) 🎯 MVP

**Goal**: an agent stops on the Mac; the iPad buzzes; the answer happens on the notification.

**Independent Test**: iPad locked, app not running, on cellular, Mac on an unrelated network. Provoke a permission request. The banner names the project, agent and what is wanted; pressing **Allow once** resumes the agent on the Mac without the app opening. (quickstart A1, A2)

**Depends on**: Phase 2 complete, including T011's answer.

### The model, and its tests

- [ ] T038 [P] [US1] Write `Unit/EscalationTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/` for the derivation table in `data-model.md`: `{allowOnce, rejectOnce}` → `.allowDeny`; `{allowOnce, allowAlways, rejectOnce}` → `.allowAlwaysDeny`; all four → `.full`; **any** option with `kind == .unknown` → `.openOnly` with an **empty** option map; any other set → `.openOnly`. Plus the two invariants: the map never holds an `optionID` the request did not offer, and an `.openOnly` result offers no `optionID` at all.
- [ ] T039 [US1] Create `Escalation` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Escalation.swift` with the fields in `data-model.md` — `permissionID: UUID`, `agentID: UUID`, `projectFolder: URL`, `category: Category`, `options: [PermissionOption.Kind: String]` (**never containing `.unknown`**), `askedAt: Date`, `expiresAt: Date` — and the `Category` enum with raw values `perm.allowDeny`, `perm.allowAlwaysDeny`, `perm.full`, `perm.openOnly`. An `ElicitationRequest` projects to `.openOnly` with an empty map. Depends on T038.
- [ ] T040 [P] [US1] Write `Unit/ActionCategoryTests.swift` asserting the `Kind` → action identifier → `Kind` round trip is total and lossless for the four real kinds, that `.unknown` never reaches it, and that every category in `contracts/notification-actions.md` is registered with exactly the actions and flags that table gives.
- [ ] T041 [US1] Create `ActionCategory` in `Packages/AgentsKit/Sources/AgentsKitCore/Notifications/ActionCategory.swift`: the table-driven registry of `UNNotificationCategory` values and their actions, with titles **"Allow once"**, **"Always allow"**, **"Deny"**, **"Never allow"**, and `authenticationRequired` **true** on Always allow and Never allow and **false** on Allow once, `destructive` on Deny and Never allow, and `foreground` on none of them. `perm.openOnly` and `agent.done` carry no actions. Depends on T040.
- [ ] T042 [US1] Create `OutstandingQuestion` in `Packages/AgentsKit/Sources/AgentsKitCore/Notifications/OutstandingQuestion.swift` and its app group store: one record per outstanding question keyed by notification request identifier, written by the extension, read once by the handler, deleted on answer, withdrawal or expiry, and swept at every app launch and every extension run. Protection matches the device key — after first unlock, this device only, never synced. **A missing record is not an error.** Depends on T003, T039.

### The push, and the words on it

- [ ] T043 [US1] Create the device's `CKQuerySubscription` in `Remote/Sources/Pairing/Subscribe.swift`: `firesOnRecordCreation`, predicate `to == <this device>`, `alertBody` set to a generic placeholder — **not optional**, because a notification with no alert, sound or badge is sent at lower priority and SC-001 cannot rest on one — `shouldSendMutableContent = true`, and `desiredKeys = ["h1", "h2", "h3"]`. Depends on T019. *(005 T049)*
- [ ] T044 [US1] Create `Remote/Sources/NotificationService/NotificationService.swift`: decrypt `h1`, `h2`, `h3` with the device's key and rewrite the banner to name the project and the agent; decrypt the sealed body and write the `OutstandingQuestion` for the action handler; set `categoryIdentifier` from the `Escalation`. **No network I/O and no CloudKit**, which is what keeps it inside a memory ceiling of roughly 20 MB. Implement `serviceExtensionTimeWillExpire` and always deliver something; on any failure deliver the placeholder rather than nothing (FR-007). Depends on T012, T017, T041, T042. *(005 T050)*
- [ ] T045 [US1] Register the categories from `ActionCategory` at launch in `Remote/Sources/RemoteApp.swift`, and request notification authorisation the first time the app is opened after pairing — not at first launch, when there is nothing to be notified about. Depends on T041.

### Answering

- [ ] T046 [US1] Implement the action handler in `Remote/Sources/NotificationService/ActionHandler.swift`, following `contracts/notification-actions.md` exactly: read the option map; missing or unmatched → open the app on that agent and stop, **never guess an `optionID`**; otherwise map action → `kind` → `optionID`, seal one `permissions/answer` with `answeredBy` set to this device's name, write it to the mailbox, delete the record, call the completion handler. It **must not** connect a `DaemonClient`, open a transcript, or do anything the app does on a normal launch. Depends on T020, T042, T044.
- [ ] T047 [US1] In `ActionHandler.swift`, schedule a local notification — "That did not reach your Mac", naming the agent — before giving up when the mailbox write fails or the budget expires (FR-013). Silence is the one unacceptable outcome. Depends on T046.
- [ ] T048 [US1] Handle the withdrawal in `Remote/Sources/RemoteModel.swift`: on a `agent/permission` broadcast with `request: nil` and `answeredBy` set, remove the delivered notification for that question via `UNUserNotificationCenter.removeDeliveredNotifications`, delete the `OutstandingQuestion`, and if the app is open on it, replace the buttons with what became of it and who answered (FR-012). A settled question must not sit on the lock screen inviting an answer. Depends on T028, T042.
- [ ] T049 [US1] In `Remote/Sources/Permission/PermissionSheet.swift`, send `answeredBy` with every answer, and on receiving a withdrawal with `answeredBy` set, put the outcome where the buttons were — never a second answer. Depends on T026, T048. *(005 T052)*
- [ ] T050 [US1] Answer a form from the app in `Remote/Sources/Elicitation/ElicitationSheet.swift` (new file), mirroring `App/Sources/Elicitation/ElicitationView.swift`, with the same fields and the same choices (FR-011). Forms are always `.openOnly`; there is no banner that can take one. Depends on T039.

### Being told about endings

- [ ] T051 [US1] Notify on an agent finishing and on an agent stopping with an error in `Bridge/Sources/BridgeCore.swift`, under the `agent.done` category with no actions, and honour `Device.wants` so each kind is switchable per device independently of the escalations (FR-003). Depends on T031, T041.
- [ ] T052 [US1] Add the three notification switches to `Remote/Sources/Settings/NotificationSettings.swift` (new file), writing through `devices/approve`'s `wants` field, and never offering to turn off the escalation itself — that is the feature. Depends on T024, T051.
- [ ] T053 [US1] Land a notification tap on the agent it names in `Remote/Sources/RemoteModel.swift`, showing whatever that agent's state is by then, including that the question is gone (FR-005). A notification for something already dealt with opens the agent, not an empty question. Depends on T042.

**Checkpoint**: US1 is independently testable. Run quickstart A1–A5. This is the MVP — an agent that stops is answered from a pocket, and nothing else in this spec is needed for that to be worth having.

---

## Phase 4: User Story 4 - Pairing an iPad, and taking it back (Priority: P4, built here)

**Goal**: add the iPad once at the Mac; remove it and it sees nothing.

**Independent Test**: pair at the Mac in under 60 seconds with no account and nothing typed; revoke with the app open and confirm access is gone within 10 seconds and nothing readable remains. (quickstart A6)

**Why out of priority order**: T037 hard-codes approval of the first device so US1 could be tested. That is a knowing hole and it should not sit open for long. US4 is P4 in value and second in the build.

- [ ] T054 [US4] Create `Remote/Sources/Pairing/PairingView.swift`: first run says what this is, that it needs the same Apple Account with iCloud Drive on, and offers one button; then "Waiting for you to approve this on your Mac." No typed address, no code longer than a short one on screen. Depends on T012, T024.
- [ ] T055 [US4] Check `CKAccountStatus` on first run in `Remote/Sources/Pairing/PairingView.swift` and say in one plain sentence when iCloud Drive is off, rather than failing as though the Mac were unreachable. Depends on T054.
- [ ] T056 [US4] Create `App/Sources/Devices/DevicesView.swift` on the Mac: each paired device by name, when it was paired, when it last connected, which notifications it wants, and **Revoke**. Revoking says plainly that the device will no longer be able to read anything. Depends on T024, T025.
- [ ] T057 [US4] Show the approval question on the Mac in `App/Sources/Devices/ApprovalAlert.swift` — "Alex's iPad would like to connect", **Approve** and **Deny** — and seal nothing to a device before it is approved. Depends on T056.
- [ ] T058 [US4] Delete the hard-coded approval from `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Devices.swift` and its `// TODO(T070)` comment. Depends on T037, T057.

**Checkpoint**: nothing is trusted that the person did not approve, and revoking is real.

---

## Phase 5: User Story 2 - Everything the Mac shows about the work (Priority: P2)

**Goal**: project → agent → work, with nothing on the Mac that is missing on the iPad.

**Independent Test**: put an agent through a full piece of work on the Mac, then walk `contracts/parity.md` row by row with both screens side by side. (quickstart B4)

**⚠️ Depends only on Phase 1.** Run it over the direct link with the bridge started by hand, in parallel with Phase 2. This is Track B.

- [X] T059 [P] [US2] Create `Remote/Sources/Chat/PlanView.swift` drawing `Agent.plans`, mirroring `App/Sources/Chat/PlanView.swift` (FR-017). The data already arrives on `agent/changed` and nothing draws it. **Do not wire `agent/plan`** — the constant is declared and referenced nowhere, and the plan travels on the record (research §5).
- [X] T060 [P] [US2] Create `Remote/Sources/Chat/FileView.swift`: the content of a file a tool call touched, and the change if the tool made one, **read only** (FR-020a). Consume the existing `AgentsModel.takeFileToShow(for:)` and the `agent/showFile` notification rather than adding a second path — 011 already built one the Mac uses (research §6).
- [X] T061 [P] [US2] Create `Remote/Sources/Chat/DocumentView.swift`: a document the agent produced, laid out for the screen as `App/Sources/Sidebar/DocumentView.swift` lays it out on the Mac, **read only** (FR-020b).
- [X] T062 [US2] Audit `Remote/Sources/` for any path that offers to edit, save or share back a file or document, and remove it. Read-only is enforced by there being no such screen, not by a flag (SC-014). Depends on T060, T061.
- [ ] T063 [P] [US2] Create `Remote/Sources/Projects/WorkflowsSection.swift`: a project's workflows listed with what they are doing, mirroring `App/Sources/Projects/WorkflowsSection.swift` — **listed, not driven**. Starting, confirming and cancelling stay at the Mac (spec, Out of scope). `AgentsModel` already applies `workflow/changed` and `workflow/removed`.
- [ ] T064 [P] [US2] Show the project's cost total on `Remote/Sources/Projects/ProjectPageView.swift` and the grand total on a new `Remote/Sources/Projects/TotalsView.swift`, matching feature 012 on the Mac (parity.md). Reported, never estimated.
- [ ] T065 [P] [US2] Show that a cost limit stopped an agent, in `Remote/Sources/Projects/AgentCard.swift` and `Remote/Sources/Chat/RemoteChatView.swift`, matching feature 010. **Showing, not setting** — changing a limit stays at the Mac (spec, Out of scope).
- [ ] T066 [P] [US2] Show the resuming / coming-back state from feature 011 in `Remote/Sources/Projects/AgentCard.swift`, using the shared `AgentsModel.isComingBack(_:)` so the Mac and the iPad cannot disagree.
- [ ] T067 [P] [US2] Add the runtime's slash commands while typing to `Remote/Sources/Chat/RemoteChatView.swift`'s prompt bar, mirroring `App/Sources/Chat/CommandList.swift` (parity.md). The list is the runtime's, not ours.
- [ ] T068 [P] [US2] Add the jump-to-the-live-end control to `Remote/Sources/Chat/RemoteChatView.swift`, mirroring `App/Sources/Chat/JumpToEnd.swift`: shown only when it would do something.
- [ ] T069 [P] [US2] Add suggested next prompts to `Remote/Sources/Chat/RemoteChatView.swift` via `agents/suggestPrompts`, as the Mac shows them (parity.md).
- [ ] T070 [US2] Size the first transcript page to the screen rather than a constant, in `Remote/Sources/RemoteModel.swift`. An iPad shows two to three times a phone's lines, and a constant page means the person watches it fetch twice before they have read anything (research §9, SC-007).
- [ ] T071 [US2] Walk `specs/013-ipad-app/contracts/parity.md` row by row with the Mac and the iPad side by side, on a project that has a workflows section, a cost total, an archived agent, an agent that ended in an error and an agent resuming. Add a row for anything on the Mac that is not in the table, then decide it. Record the walk's date in `parity.md` (SC-005).

**Checkpoint**: US2 stands alone over the direct link. It is worth demonstrating on its own.

---

## Phase 6: User Story 3 - Carrying on from the iPad (Priority: P3)

**Goal**: send a prompt, start an agent, stop one, archive one.

**Independent Test**: from the iPad, prompt an existing agent, start a new one in an existing project, stop it, archive another — confirming each on the Mac. (spec US3)

- [ ] T072 [P] [US3] Start an agent in an existing project from `Remote/Sources/Projects/ProjectPageView.swift`, choosing from the runtimes the Mac has via `runtimes/list` and `agents/options`, with the mode, model, effort and permission controls the Mac offers (FR-026, parity.md).
- [ ] T073 [P] [US3] Stop a running agent, and archive and unarchive one, from `Remote/Sources/Projects/AgentCard.swift` via `agents/stop`, `agents/archive` and `agents/unarchive` (FR-027).
- [ ] T074 [P] [US3] Attach a file or image to a prompt from the iPad's photo library or Files in `Remote/Sources/Chat/AttachmentStrip.swift` (new file), refused before sending when the runtime cannot take them — the same refusal the Mac gives, for the same reason (FR-025).
- [ ] T075 [US3] Refuse any action taken against stale state at the moment it is taken, in `Remote/Sources/RemoteModel.swift`, rather than appearing to accept it (FR-028, FR-036). `Remote/Sources/StaleBanner.swift` already says when the Mac was last heard from; this is the other half of it.

**Checkpoint**: all four stories work. Run the whole of quickstart.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T076 **Gate, FR-034.** Build and run on a **real iPad**, not the simulator, and walk every screen in `contracts/parity.md` and `contracts/notification-actions.md` beside the Mac. Iterate until the layout has stopped changing. This is 005's T024 gate, narrowed to one device and enforced this time.
- [ ] T077 [P] Install and launch on a real iPhone, reach every screen, and write the layout defects into a new `specs/013-ipad-app/iphone-defects.md` for the iPhone feature (FR-033, FR-035, SC-013). **Do not fix them here.**
- [ ] T078 [P] Decide the two unsettled rows at the foot of `specs/013-ipad-app/contracts/parity.md` — dictation, and sessions adopt/delete — and move each into a requirement or into the spec's *Out of scope*. FR-021 makes silence a defect.
- [ ] T079 [P] Check every control has an accessibility label, every group heading is a heading, and a permission is readable in full at the largest Dynamic Type setting in `Remote/Sources/`, because a permission the person cannot read is one they cannot answer (FR-037).
- [ ] T080 Capture traffic on both links and inspect the CloudKit records and the push payload: no readable prompt, transcript, file content, command or credential anywhere (SC-011). Depends on T034.
- [ ] T081 Update `README.md`'s daemon section to mention the bridge — what spawns it, when it exits, and that the Mac app must be opened once after a reboot before an iPad can reach anything.
- [ ] T082 Run the whole of `specs/013-ipad-app/quickstart.md`, Track A and Track B, and record the measured numbers for SC-001, SC-002 and SC-007 in `research.md` §10.

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 Setup**: no dependencies.
- **Phase 2 Foundational**: depends on Phase 1. Blocks **US1 and US4 only**.
- **Phase 3 (US1)**: depends on Phase 2 in full, including T011's answer.
- **Phase 4 (US4)**: depends on Phase 2. Should follow US1 closely — T037 leaves a hole open until T058.
- **Phase 5 (US2)**: depends on **Phase 1 only**. Runs in parallel with Phase 2.
- **Phase 6 (US3)**: depends on Phase 1; T075 is better after Phase 2's `LinkChooser` (T021).
- **Phase 7 Polish**: after the stories it checks.

### The critical path

T001 → T008 (spike) → T012/T013 → T015 → T019 → T020 → T031 → T033 → T044 → T046. Everything
in US1 is downstream of a spike that could end the feature, which is why Phase 5 does not wait.

### Within Phase 2

- T008 gates T033 and everything CloudKit.
- T010 gates T017, which gates T044.
- T011 gates T046 and may amend FR-008.
- T015 gates T019, T031 and T034.
- T024 gates T025, T035 and T037.

### Parallel opportunities

- **Phase 1**: T004, T005, T006, T007 together.
- **Phase 2 spikes**: T009 and T010 alongside T008; T011 needs none of them.
- **Phase 2 models**: T012, T013, T014, T016, T022 together.
- **Phase 2 tests**: T027 and T030 together, before their subjects.
- **Phase 3**: T038 and T040 together.
- **Phase 5**: T059 through T069 are eleven different files — the widest parallel block in the feature.
- **Phase 6**: T072, T073, T074 together.
- **Across tracks**: one person on Phase 2, another on Phase 5, from the moment Phase 1 lands.

### Parallel example: Phase 5, Track B

```bash
Task: "Create Remote/Sources/Chat/PlanView.swift drawing Agent.plans"
Task: "Create Remote/Sources/Chat/FileView.swift, read only"
Task: "Create Remote/Sources/Chat/DocumentView.swift, read only"
Task: "Create Remote/Sources/Projects/WorkflowsSection.swift, listed not driven"
Task: "Show project and grand cost totals in Remote/Sources/Projects/"
Task: "Show the resuming state in Remote/Sources/Projects/AgentCard.swift"
```

---

## Implementation Strategy

### Start here, today

Phase 1, then **split**. T008 and T011 are the two spikes that can reshape the feature and they
cost days of waiting on hardware; start them and work Phase 5 while they run.

### MVP

Phase 1 → Phase 2 → Phase 3 (US1). At that point an agent that stops is answered from a
pocket, which is the whole reason the feature exists. Stop and validate with quickstart A1–A5
before going further.

### Then, in order

1. Phase 4 (US4) — close T037's hole before anything is paired in earnest.
2. Phase 5 (US2) — likely already done, having run beside Phase 2.
3. Phase 6 (US3).
4. Phase 7, with T076 the gate nothing ships past.

### What this deliberately does not finish

Feature 005 stays open. The iPhone keeps building and launching (T077) and is not judged. Any
005 requirement this feature does not discharge is still owed by the iPhone feature, and T077's
defect list is where that starts.

---

## Notes

- `[P]` = different files, no dependency on an incomplete task.
- Tasks marked *(005 Txxx)* are carried from `specs/005-mobile-remotes/tasks.md`. Read them
  there for detail. **Never copy their error numbers** — research §7.
- Commit after each task or logical group.
- Three tasks — T034, T035, T036 — are 005's security debt and block ship. Nothing should be
  paired in earnest until all three are done.
