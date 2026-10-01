# Back-compat shims (issue #58)

Every piece of code that exists only so this build can read something an *older* build
wrote: a record on disk, a message on the wire, or a call from a conversation that was
briefed before a tool changed. Filed as `071` because `058` is the control plane.

Line numbers are on `agents/work-github-issue-58` before any shim was removed.

## How old is old

The repository's first spec landed on 2026-09-18. Every shim below is for something at
most twelve days old, and alpha users build from source (see the alpha scope). So a
cut-off is a date in the last fortnight, not a version anyone is pinned to.

| Spec | Landed | Spec | Landed |
|---|---|---|---|
| 003 ACP coverage | 09-18 | 043 zero-setup servers | 09-25 |
| 014 outcomes | 09-19 | 046 Gemini / remote away | 09-25 |
| 029 phone starts | 09-24 | 047 Codex | 09-25 |
| 031 one suggested prompt | 09-24 | 048 runtime install | 09-25 |
| 035 chat diff | 09-24 | 051 retire archived | 09-25 |
| 039 blocked status | 09-24 | 052 quota fallback | 09-25 |
| 040 parked | 09-24 | 053 move to worktree | 09-25 |
| 042 events | 09-25 | 056 Claude sign-in relay | 09-26 |
| | | 065 continue successor | 09-28 |
| | | 069 turn detail | 09-29 |

## What is not a shim

These look like shims under the grep and are not. They stay whatever the cut-off.

- **Forward compatibility.** "An older build keeps what it didn't understand":
  `Agent.unknownFields` (`Agent.swift:219`), `Project.unknownFields` (`Project.swift:26`),
  `TranscriptEntry.Kind.unrecognised` (`TranscriptEntry+Coding.swift:15,171`), unknown
  `EndedReason` → `.unrecognised` (`EndedReason.swift:87`), an unknown `WorkOutcome`
  read as no report (`Agent.swift:337`), an unknown `RuntimeAvailability` case
  (`Runtime.swift:89`), unknown group names dropped from `ProjectSummary.counts`
  (`DaemonAPI.swift:561`), unknown vendor kinds (`VendorExtensions.swift:147`), unknown
  workflow triggers (`WorkflowTrigger.swift:131,173`).
- **Absent means the default, today.** Most `decodeIfPresent(…) ?? default` reads are
  for fields the encoder itself leaves out when they are empty, nil or false:
  `isUnread`, `plans`, `costToDate`, `queuedPrompts`, `restartPickUps`, `outcomeAsked`,
  `titledByAgent`, `labels` and the like on `Agent`; `from` on a user message
  (`TranscriptEntry+Coding.swift:23`, written only when not the person's). A current
  record needs every one of these.
- **Set aside, not migrated.** `DraftStore.swift:51` discards a draft it cannot read,
  and `AllowanceStore.swift:15` sets an unreadable file aside. That is the behaviour the
  issue asks for, not a shim.
- **Guards that happen to mention the past.** `Bridge/Sources/DirectLink.swift:96` skips
  a device with no usable key (it pairs again); there is no old shape being read.
- **The 058 move, which is current.** `ControlRecords.legacyDevices`
  (`ControlRecords.swift:267`, used by `ControlMove.swift:36,53` and
  `agents-control/main.swift:233`), `HostPaths.isOldSetUp` (`Host/Sources/HostPaths.swift:49`),
  the `.legacy` bare JSON-RPC line (`ControlWire.swift:26,86`, `ControlRouter.swift:531`)
  and `ControlRecords.operatorList` (`ControlRecords.swift:157`). T105 moved Alex's own
  root on 2026-09-30 and the `Agents` window still speaks bare lines; these go when
  058 says the developer window does.
- **One-off record repair that is not about a spec.** `DaemonCore.seedingCost`
  (`DaemonCore.swift:1039`) gives a chat run before cost banking was fixed (e9a0ff45,
  09-19) its total; `DaemonCore+Recovery.swift:166` handles a `starting` record with an
  empty queue. Both are listed below too, under 003-era records, in case the cut-off is
  meant to take them.

## Records on disk

What a record written by an older build still needs to open. Removing one means that
record is set aside (or the field is lost) instead of read.

| # | Where | Predates | What it reads | Notes |
|---|---|---|---|---|
| D1 | `Hosts/Host.swift:60` | 043 | `hosts.json` entries with no `ownSignInOnly` / `knownProjects` | Hand-written `Host.init(from:)`. `facts` and `trustedFingerprint` are legitimately optional; the two defaults are the shim. |
| D2 | `Hosts/Host.swift:147` | 043 / 046 | `ServerFacts` with no `libc`, `hasNpx`, `hasOwnClaudeSignIn`, `toolsetIDs`, `ownSignIns`, `avx2` | Facts are re-probed on every connect, so an old one is replaced at once. |
| D3 | `Hosts/Host.swift:166` | 046 | Facts with a single `toolsetID` and no `toolsetIDs` | Copies it to Claude's slot. `toolsetID` is still written for the same reason (`Host.swift:142`). |
| D4 | `Hosts/Host.swift:343`, `App/Sources/AppModel.swift:1142` | 037 (servers) | A selected-project default holding a bare path, not `host\|path` | `ProjectKey.init?(stored:)` falls back to this Mac. |
| D5 | `Model/Agent.swift:279` | a5f0557e (09-18, controls on the prompt bar) | `advertisedOptions`, `availableCommands` missing | Both are always written now. |
| D6 | `Model/Agent.swift:296` | 003 | `usage`, `lastTurnUsage`, … missing | All optional today as well; only the comment is about 003. |
| D7 | `Model/Agent.swift:313` | 031 | `suggestedPrompts` with up to four entries | Cut to one on read. |
| D8 | `Model/Agent.swift:181`, `Daemon/DaemonCore+Changes.swift:122` | 035 | An agent with no `startingPoint` | Changes are measured from `HEAD` and called shared. Also the path for a folder git could not answer for at start, so the `else if` stays even if the comment's 035 case goes. |
| D9 | `Model/Agent.swift:348`, `:423` | 052 → 065 | `poolEntryID`, `switchingOff`, `allowanceWait` | Read, never written. |
| D10 | `Daemon/DaemonCore+Allowances.swift:255` | 065 | An `allowanceWait` left by a 052 build | Cleared at launch with a log line. Goes with D9. |
| D11 | ~~`Model/Agent.swift:354`, `Model/Parking.swift:50`~~ **Removed in step 1** | self-archiving removed | `afterTurn: "archive"` | Read and dropped. `try?` already drops an unknown value, so the case can go with no shim at all. |
| D12 | `Model/Agent.swift:196`, `Daemon/DaemonCore.swift:993` | 051 | An archived agent with no `archivedAt` | Stamped "now" and saved, once. Every live root has run a 051 build, so these are all stamped. |
| D13 | `Daemon/DaemonCore.swift:1039` | cost banking (09-19) | An agent with `usage.cost` and empty `costToDate` | Seeds the total in memory, every launch. |
| D14 | `Model/TranscriptEntry.swift:120` | 003 | A message with text and no `blocks` | Also how a streamed text chunk with no blocks draws today — **keep**. |
| D15 | `Model/TranscriptEntry.swift:49`, `TranscriptEntry+Coding.swift:39,126` | 003 (`planUpdated`) | The `plan` kind, a raw JSON plan | Nothing writes `.plan` any more. |
| D16 | `Model/TranscriptEntry.swift:81,89`, `TranscriptEntry+Coding.swift:77` | 052 → 065 | `poolSwitch` / `settingsChanged` entries, `SwitchRecord` | Nothing writes them since 065; old transcripts still draw the note. Dropping them would show these entries as unrecognised (skipped), not fail. |
| D17 | `Model/OutcomePage.swift:64,145,147`, `Store/AgentStore.swift:371` | 069 | `TurnSummary` with no `outcome` / `steps`; still **writes** `last` and `concise` | The write is for windows and phones before 069 (wire, W15). `AgentStore.turns` already rebuilds a pre-069 summary from the transcript when it is paged in, so the `ChatTurn` fallback at `:64` is a second copy of the same shim. |
| D18 | `Model/PermissionRequest.swift:107` | 003 | A permission record with only `raw` | Splits `raw` into fields. |
| D19 | `Model/PermissionRequest.swift:168`, `AppTool.swift:91` | 023 R5 (09-29) | `suggest_next_prompts` / `report_outcome` calls in an old transcript | Draws them as the end of a turn rather than a stray tool call. |
| D20 | `Model/Project.swift:22`, `Projects/DotAgents.swift:3,41`, `Daemon/DaemonCore+Commands.swift:416`, `DaemonCore+Projects.swift:175` | dotagents layout (09-25) | A project with no `laidOutAt` or no `layoutVersion` | Lays the project out at its first start, or gives a v1 project only v2's step. The versioned steps are how the layout grows, not just a shim: **keep the version mechanism**, drop only "nil means 1" if the cut-off is past 09-25. |
| D21 | `Daemon/DaemonCore+Commands.swift:158`, `App/Sources/AppModel.swift:2621`, `DaemonAPI.modesImport` | 029 (09-24) | Modes the window kept in its own `UserDefaults` | The window sends them to `modes/import` on every connect while any are left; it never deletes them, so this runs forever. |
| D22 | `Workflows/WorkflowStore.swift:39` | GitHub removal (6a4b4831, 09-28) | A workflow state whose `lastOutcome` is a pull-request refusal | `try?` forgets just that field. |
| D23 | `Workflows/WorkflowStore.swift:30` | workflow archiving | A state with no `isArchived` | Also optional today (`false` is the default); comment only. |
| D24 | `Credentials/CredentialStore.swift:52,65`, `App/Sources/Settings/ServerCredentials.swift:43` | 047 / 056 | `credentials.json` entries for Codex's OpenAI key and Claude's token | Forgets them and deletes their Keychain items, on every Settings open. The per-entry decode at `:52` is also forward-compatible (an unknown kind costs only itself) — **keep that half**. |
| D25 | `App/Sources/Sidebar/SidebarState.swift:96–122` | 022 width change (09-24) | A stored sidebar width near the old 380 default | Widens once and sets `sidebar.widenedForReadingStep`. |
| D26 | `Store/AllowanceStore.swift:6` | 065 | `pool.json`, `switches.jsonl` | Not read. The two URLs were dead and went in step 1 (8b779d4e); only the comment saying the files are left on disk remains. |

## Wire and peers

What this build accepts from an older window, phone, daemon, server or helper, or still
sends for one. Removing one means that peer gets an error or less than it had.

| # | Where | Predates | Peer | What it reads or sends |
|---|---|---|---|---|
| W1 | `Daemon/DaemonAPI.swift:781` | 014 | phone/remote → daemon | `agents/prompt` with no `from` (and no `attachments`) reads as the person's. `from` is also optional today: the phone sends none. **Keep.** |
| W2 | `Daemon/DaemonAPI.swift:1348`, `Client/AgentsModel.swift:348` | per-request withdrawal | daemon → client | A permission withdrawal with no `requestID` clears all of an agent's questions. Every withdrawal this daemon sends carries a `requestID` (`DaemonCore+Commands.swift:1464,1546,1807`), so only an older daemon sends the bare shape. |
| W3 | `Daemon/DaemonAPI.swift:2542` | 046 | daemon → phone | `device/changed` removal: `device` nil, `removed: true`. |
| W4 | `Daemon/DaemonAPI.swift:2573` | 046 | daemon → phone | `devices/announce` reply is the `Device` record with `macKey` folded in, so a pre-046 phone still decodes it. |
| W5 | `Daemon/DaemonCore+Projects.swift:60` | 040 | daemon → phone | Parked chats left out of `counts`, because a pre-040 phone threw on the key. Since then the decoder drops unknown names (`DaemonAPI.swift:561`). |
| W6 | `Model/AgentGroup.swift:10,38` + `AttentionSnapshot.swift:68,70`, `App/Sources/AppModel.swift:669`, `Remote/Sources/RemoteModel.swift:1452`, `StatusShape.swift:46` | 0ca8ebc5 (09-26) | daemon → client | The `blocked` **group** (not the `blocked` outcome, which is live). Nothing assigns it since groups were simplified; only an older daemon's counts can carry it, and the summary decoder would now drop the name anyway. |
| W7 | `Model/Runtime.swift:44` | 047 / 048 | daemon → client | `Runtime` with no `install`, `installPage`, `usesAppCopyOnly`. |
| W8 | `Model/Runtime.swift:205` | 047 | daemon → client | `RuntimeState` with no `outdated`. |
| W9 | `Model/SuggestedPrompt.swift:52`, `ACP/Serve/AppService.swift:285` | 031 | conversation → daemon | `finish_turn` with a `next_prompts` list instead of `next_prompt`. |
| W10 | ~~`AppTool.swift:33,47`, `AppService.swift:37,42,420,523,1222`, `DaemonCore+Helpers.swift:173`, `DaemonAPI.swift:204,2017` | archive_agent removal | conversation → daemon | `archive_agent` still recognised, then refused.~~ **Removed in step 1** (4e4201b2): now an unknown tool. |
| W11 | ~~`AppService.swift:666`, `DaemonCore+AppTools.swift:150`~~ | self-archiving removal | conversation → daemon | **Removed in step 1** (4e4201b2): `afterwards: "archive"` now gets afterwards' own refusal. D11's case went with it. |
| W12 | `Model/Workflow.swift:88`, `Model/WorkflowSchedule.swift:60` | 017 | daemon → client | `Workflow` with no `settings`; schedule with no range minutes. |
| W13 | `Daemon/DaemonAPI.swift:318` | 052 → 065 | window → server daemon | Method name `pool/applyAllowances` kept so an older server hears it. Renaming is the only change; keeping the name costs nothing. |
| W14 | `Daemon/DaemonAPI.swift:860` | 039 | helper → daemon | `waitingOn` optional in `ReportOutcomeRequest`. Also legitimately absent for any outcome but `blocked`. **Keep.** |
| W15 | `Model/OutcomePage.swift:145,147` | 069 | daemon → window/phone | `TurnSummary.last` and `.concise` still computed and sent for clients before 069. |
| W16 | `Daemon/DaemonAPI.swift:1551`, `App/Sources/Sidebar/TerminalPane.swift:107` | 053 | daemon → window | `ShellAttachResponse.folder` nil; "an older helper that holds one shell per agent". |
| W17 | `Daemon/DaemonAPI.swift:2264` | worktree status | daemon → window | `status` nil from an older daemon. Also nil when the folder is gone. **Keep.** |
| W18 | `Daemon/DaemonAPI.swift:2683,2686,2775,2778` | 049 / 056 | window ↔ server daemon | `notRelayed`, `signIns`, `relayed`, `borrowed` optional. |
| W19 | `Daemon/DaemonAPI.swift:552` | 012 / 051 | daemon → client | `ProjectSummary` with no `costToDate`, `unmeasuredAgents`, `retiredCount`. |
| W20 | `Daemon/DaemonAPI.swift:422` | 051 | daemon → older window | `agent/removed` is ignored by an older window, which drops the agent at its next list. Nothing to remove here. |
| W21 | `Client/AgentsModel.swift:139`, `App/Sources/AppModel.swift:78` | 051 | daemon → window | `retentionState` nil "from a daemon before 051". It is also nil until the first answer, so the optional stays; only the comment is a shim. |
| W22 | `Daemon/DaemonAPI.swift:162,246`, `DaemonCore+Dispatch.swift:579,697`, `ConnectionRole.swift:31`, `DaemonCore+AppTools.swift:124` | 023 R5 (09-29) | older helper → daemon | `agents/suggestPrompts` and `agents/reportOutcome`: the helper stopped relaying them when the tool names were retired, so only a helper binary from before then calls them. Thirteen calls in seven test files use `reportOutcome` directly as a shortcut; they would move to `finishTurn`. |

## Left to 058 (T106 / T042)

The project lead asked on 2026-09-30 that this pass stay out of the code 058's T106 and
T042 delete outright: `Bridge/` (including `DirectLink.swift`), `SocketLink`, `HostSet`
and `LocalServices` in the window, the `AGENTS_STORE` switch, the Remote's old TLS-PSK
path, `ControlNet`, `ControlDialling`, `UnixSocketListener`'s control use and
`ControlPlane.swift`'s bridge wiring. Any shim there is **removed by 058 T106/T042**,
not here:

- `Bridge/Sources/DirectLink.swift:96`: device records from before keys.
- `LinuxControlDial` (`Package.swift`), "kept for one test until the first build's
  listener goes (T042)".
- Periphery's dead hits in that code (`ControlNet.publicKey`, `ControlNet.stop`,
  `LocalServices.remove`, `HostSet.forgetGoneProject`, `ControlRouter.dropQuietly`,
  `ControlWire.isNotification`, `control/pairingChanged`, `ControlHostChanged`,
  `ControlAuth.hostSalt`, `PairingCode`) are left for the same reason.

## Step 1: what the dead-code pass removed and kept

Periphery 3.8 over `Agents`, `Remote`, `AgentsHost` and `AgentsStore` (which covers
AgentsKit) reported 279 unused declarations and 203 assign-only properties. It is
unreliable on this toolchain: it calls properties read inside SwiftUI `body` unused
(`ProjectListView`, `ContextMeter`, the Remote's terminal pane all are used), so a hit
was deleted only when grep found nothing but its declaration and both schemes still
built.

Removed: `archive_agent` and `afterwards: archive`; the 052 pool's dead words, payment
accessors and file paths; six error codes nothing raises (numbers noted as retired);
`agent/plan`; test hooks no test uses; `AgentWorktree.issue` (GitHub's Ready issues);
the Mac's unused swipe-to-archive; `AgentsSetupView`, `SharedReachList` and a handful of
unused model members; `seed-archived.swift --legacy`. Main's test target also did not
compile (070's test passed a `sink:` that 84519ec8 removed); fixed first.

Kept on purpose:

- **Assign-only properties** (203): nearly all are Codable fields that travel to a peer
  or are kept on a record; Periphery cannot see the other end.
- **`ACP.UnusedMethod`**: names the protocol methods we chose not to implement, on
  purpose ("we chose not to" and "we forgot" stay different things).
- **Test-only seams**: `Grammar.queryText`, `InkValues.backgrounds`, the
  `@testable` hooks tests do use.
- **`EventWaitEnding.cancelled(by:)`** and other cases Periphery calls unconstructed:
  they are read from records on disk.
- **Unused parameters** (37): mostly protocol conformances and closures whose shape is
  fixed (`StoreHostSet`'s stubs for the App Store window); changing them is churn.
- **The Blocked group** (W6): not dead code in the sense of step 1, since an older
  daemon can still send it. It goes or stays with the cut-off.
- **The 058-owned hits** listed above.
