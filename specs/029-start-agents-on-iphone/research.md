# Research: Starting agents on iPhone

Phase 0 for [plan.md](./plan.md). Every question here was answered by reading the code on
`main` at `931394f`; none needed an outside source.

## 1. What the Mac actually remembers today

**Finding.** Less than the spec's words suggest. Three separate things decide what a new
agent is offered first on the Mac:

| What | Where it comes from today | Already shared with the phone? |
|------|---------------------------|--------------------------------|
| Runtime | `AppModel.defaultRuntimeID`: the runtime of the most recently active agent that is still available, else the first available | **Yes, in effect.** It is derived from `agents/list` and `runtimes/list`, both of which the phone already reads. Only the function lives in the app. |
| Mode | `UserDefaults` key `prompt.mode.<runtimeID>`, written by `AppModel.rememberMode` on a draft and on a live agent's mode change, read through `ModeMemory.startingValue` | **No.** This is the one thing the clarification moves. |
| Model, effort, anything else | The runtime's own `currentValue` in what `agents/options` returns (which the runtime itself remembers, e.g. Claude Code's settings file) | **Yes.** It is on the Mac, behind the daemon. |

**Decision.** "One memory, on the Mac" means:

- Move `defaultRuntimeID`'s rule into `AgentsModel` (AgentsKitCore), which both apps compile,
  so the phone and the Mac cannot pick differently.
- Move the mode memory from the app's `UserDefaults` into the daemon, as a small file beside
  the option cache, read and written through two new methods and a broadcast (see
  [contracts/daemon-api.md](./contracts/daemon-api.md)).
- Leave model and effort where they are. They are already one memory on the Mac, held by the
  runtime; copying them into a second store would create the disagreement the clarification
  was asked to prevent.

**Alternatives rejected.**

- *Remember every select option in the daemon.* It would override the runtime's own current
  model with a stale one after the person changed it in the runtime's CLI. The mode is the one
  value runtimes do not persist themselves, which is why the Mac remembers it at all.
- *Keep `UserDefaults` and mirror it to the phone.* Two stores, one of which a scratch copy
  shares with the real app (memory: scratch copies share defaults). The daemon's store is
  already scoped by root.

## 2. Carrying the Mac's existing memory over (FR-011)

**Decision.** On connecting, the Mac app reads every `prompt.mode.*` key it has and sends the
ones the daemon does not already hold with `modes/import`. The daemon only fills gaps, so a
second window, a scratch copy or a later launch cannot overwrite a newer choice made on the
phone. The keys are left in `UserDefaults`, not deleted: removing something we merely stopped
reading is not ours to do, and it keeps a downgrade working.

**Alternative rejected.** A one-shot migration flag. It fails silently the first time a
scratch root imports into the wrong daemon, and filling gaps is idempotent anyway.

## 3. Draft sessions from a phone

**Finding.** `agents/options` starts a runtime session (a "draft") and keeps it in
`DaemonCore.drafts` until an `agents/start` uses it. Nothing ends a draft that is never used:
the Mac makes a new one each time the runtime or folder changes and the old one stays until
the daemon exits. On the Mac that is one abandoned process now and then. On a phone, whose
start screen is opened and dismissed casually, over a link that drops, it is a process per
glance.

**Decision.** Two additions, both small:

- `agents/discardDraft { draftID }`: the phone calls it when the start screen goes away
  without sending, and when it changes runtime. The Mac calls it when it replaces a draft,
  which fixes the existing leak for free.
- Drafts record the connection that made them, and `onDisconnected` ends that connection's
  drafts after a grace period (30 s) so a phone that drops and comes back inside it can still
  use its draft. After the grace period the start falls back to a fresh session, which
  `start` already does for an unusable draft.

**Alternative rejected.** Not using `agents/options` on the phone and starting cold. The form
would draw only after a runtime starts (seconds, not instant), and the phone would lose
`agents/draftOptions` corrections the Mac already gets.

## 4. Starting at most once (FR-006, SC-003)

**Finding.** `agents/start` has no idempotency key. `draftID` is consumed on the first use, so a
retry of the same request after a lost reply makes a fresh session and a second agent.

**Decision.** Add `requestID: UUID?` to `StartRequest`, minted by the phone once per draft send
and reused on every retry of it. The daemon:

- keeps `requestID → agentID` in memory, and answers a repeat with the first agent's id instead
  of starting another;
- stores the `requestID` on the `Agent` record (`startRequestID`), so the answer survives a
  daemon restart between the start and the reply, and so a phone that reconnects can find the
  agent in `agents/list` without asking.

The phone, on reconnecting with a send outstanding, looks for an agent with its
`startRequestID`. Found: clear the draft and open it. Not found: retry with the same id.

**Alternative rejected.** Deduplicating on prompt text and folder within a window of time. Two
deliberate starts with the same words are legitimate, and "within a window" is a guess.

## 5. Attachments from a phone

**Finding.** The Mac sends pictures by value (`.image`) when the runtime takes them and
everything else as a file reference (`.resourceLink` to a `file://` URL), "which every runtime
takes". A reference to a path on the phone means nothing on the Mac.

**Decision.**

- **Pictures** go by value, as on the Mac, refused with `Attachment.refusal(from:)` when the
  runtime does not take images. Photos are downscaled on the phone to a long edge of 2048 px and
  JPEG-encoded, so a whole prompt stays under the relayed link's 1 MB record ceiling
  (005 `contracts/mailbox.md`). The same size cap is applied on the direct link so behaviour
  does not change with the link.
- **Text files** from Files go by value as an embedded resource, which needs the runtime's
  `embeddedContext` capability. Refused the Mac's way when it is missing.
- **Other files** (binary, not images) are refused on the phone with one sentence saying the
  file would have to be on the Mac. Copying phone files into the project on the Mac is a
  different feature.
- The total size of what is attached is checked before sending, with a sentence naming the
  limit.

**Alternative rejected.** Uploading files to the Mac and sending a reference. It writes into the
person's project folder from a phone, which needs its own decision about where and when.

## 6. Refusals the phone must say in one sentence (FR-015)

| Case | Who refuses today | Plan |
|------|-------------------|------|
| Mac not answering | Phone, `isStale` | Same as `RemoteModel.send`: refuse before calling, keep the draft |
| Day's spending limit | Daemon, `dayLimitReached` with a full sentence | Show the daemon's message as it is |
| Per-agent limit of zero | Daemon, `agentLimitReached` | Same |
| Folder gone | Daemon, `folderGone` in `freshSession`; phone already knows `summary.exists` | Refuse on the phone first from `exists`, and show the daemon's sentence if it gets there |
| Runtime not found / unavailable | Daemon, `runtimeNotFound`; phone has `runtimes/list` availability | Mark unavailable in the picker; show the daemon's sentence if it gets there |
| Project archived | Nobody | Phone refuses from the project summary. The daemon is not changed: the Mac's own start in an archived project is a separate question and not this feature's |
| Draft runtime failed to start | Daemon broadcasts `agents/draftOptions` with `failure` | Shown in the choices row, as on the Mac |
| Connection dropped mid-send | Phone | §4 |

Where the daemon has a sentence, the phone shows `JSONRPCError.message` rather than its own
words, which is what "the Mac's words" means in FR-015. Today `RemoteModel.send` replaces every
error with a fixed sentence; the start path does not.

## 7. The link the phone is on

**Finding.** The phone reaches the daemon today over `NetworkLink`, the direct link on the same
network, described in its own header as scaffolding. The relayed link that works from a train
is 013 Track A, which is Alex's (T001, the spikes) and not built.

**Decision.** This feature is built on `DaemonClient` and does not care which link carries it.
Everything is testable over the direct link now. The spec's cellular test (US1 Independent Test)
and SC-002's mobile-connection timing wait on Track A and are recorded as such in
[quickstart.md](./quickstart.md), not claimed.

## 8. Where the screen lives, and what the iPad gets

**Decision.** One SwiftUI view, `Remote/Sources/StartAgent/StartAgentView.swift`, presented as a
sheet from the project page on the phone (a full-height sheet with the prompt field at the
bottom above the keyboard, choices above it) and as a form sheet on the iPad. This is T072's
place; 013's `tasks.md` is updated to point at this feature.

The Mac's `OptionMenu` and `SelectCapsule` are AppKit-flavoured and live in `App/Sources`. Their
pure parts, which options to draw and in what order, are already in AgentsKitCore
(`PromptControlsState.drawable`, `ConfigOption.categoryOrder`). The phone reuses those and draws
its own controls: a `Menu` per select option and a `Toggle` per boolean.

## 9. Keeping a draft on the phone (FR-016, FR-017)

**Decision.** `DraftStore` in AgentsKitCore already keeps a prompt and attachments in
`UserDefaults` with a size cap, scoped. The phone uses it with a scope per project folder.
Attachments over the cap keep their names and drop their bytes, as the store already does, and
the start screen says which ones need attaching again. The draft is cleared when `agents/start`
returns, or when §4's reconciliation finds the agent.
