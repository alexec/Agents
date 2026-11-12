# As fast as Linear on every client (#4777)

Status: the spike (#4777) is done. This file holds what it found and what it decided.
The epic is #4783. Its children are in the table at the end.

Clients: the Mac window, the Remote and the web page. Tier: Core (the session list, chat,
the prompt bar, question cards and approvals).

## The question

People like Linear because it is fast: a click shows its result at once, a page opens
with no spinner, and the keyboard does everything. Which of Linear's patterns do the
three clients use now, which are missing, and where are they slow?

## What the clients do now

Found on 2026-11-11 at `78e298bf6`. "Optimistic" means the screen changes before the
reply comes.

| Pattern | Mac window | Remote | Web page |
|---|---|---|---|
| 1. Local copy first | **Missing.** Nothing keeps sessions or transcripts on disk. A chat restored at launch shows a spinner (`App/Sources/Chat/ChatView.swift:87`). | **Missing.** Only the pairing, folders and settings are kept. Launch draws nothing until the link answers. | **Missing.** IndexedDB holds only keys (`Web/src/wire/keys.ts`). The page shows "Connecting…" until the link opens (`Web/src/App.tsx:11`). |
| 2. Deltas, not a full fetch | Live: per-item notifications (`agent/changed`, `agent/entry`, `agent/removed`, …). Each connect and reconnect runs `refreshEverything`: the lean `agents/list` (up to 20 pages), `folders/list`, then about 33 other lists (`AppModel.swift:4496`). | Live: per-item notifications. Each connect runs one `client/catchUp` (lean first page, needs, the parts on screen), then the open transcript (`RemoteModel.swift:3291`). | Live: per-item notifications. Each connect runs `load()`: "Everything again, on every connection… No cursors on the wire" (`Web/src/model/store.ts:1607`). |
| 3. Optimistic updates, with rollback | Optimistic: send (field clears, text comes back on failure), `setOption`, Auto settings (with rollback), display preferences (no rollback). Waits: archive, stop, send now (#87 in-flight mark only), rename, labels, unarchive, move to worktree, card answers, approvals, most Settings. | Optimistic: pin, unpin, reorder, display preferences (no rollback). Waits: archive, rename, mute, labels, Later and Bring Back, approvals, card answers, send (spinner while `sending > 0`). | Optimistic: send (field clears), preferences (failure swallowed), `setOption`. Waits: archive, unarchive, stop ("Archiving — telling your Mac"), Later, rename, labels, card answers ("sending"), approvals, Move to Machine. |
| 4. Keyboard first, ⌘K | 179 `.keyboardShortcut` uses. **No ⌘K.** ⌘F is Find in Chat with a chat open, Find Session otherwise; ⌥⌘F is Find Session (`AgentsCommands.swift:237`). No bare j/k; ⌥⌘↑/↓ and ⌘J step sessions. | ⌘F Find in Chat, ⌘P Open File, ⇧⌘P Prompts, ⌃\` terminal, ⌘Z undo archive. **No ⌘K.** | `g` + a letter jumps to a section, `/` search, j/k on Work only, arrows in the sidebar, ⌘F, ⌘P, ⌘Z. **No ⌘K.** |
| 5. No spinner for local data, prefetch | 120 `ProgressView` uses; the chat, the files pane and the folder window spin while they load. No prefetch on hover (only `prewarm` of the runtime). | A full-screen spinner while a chat loads (`RemoteChatView.swift:66`). Skeletons on Work and Archived only. No prefetch. | About 77 "Loading…" places, all for data from the host. No prefetch on hover. |
| 6. Long lists stay smooth | Transcript windowed: `TranscriptStack` draws only the rows near the view (`Shared/UI/Chat/TranscriptStack.swift`), turns come a page at a time. Sidebar is a `List`. | The same `TranscriptStack`; first page sized to the screen (30–200 entries). Sidebar is a `List`. | **Not windowed.** Bounded by caps instead: 1,600 entries, 200 turns (`store.ts:92`). Work loads more by `IntersectionObserver`. |
| 7. Undo, not confirm | Archive has Undo (#1534). Confirms on reversible actions: "End this wait?", "Stop <machine>?", org policy stop or resume. No `UndoManager`. | Archive has a 5 s Undo. Confirms: "End this wait?", Later asks "when" in a dialog. | Archive has a 5 s Undo and ⌘Z, no confirm. `window.confirm` for "stop live agents" and the deletes. |
| 8. Short motion | Most response motion is 0.2 s (the undo strip, file lines, a highlight then 0.6 s). | The same 0.2 s set, and the question card's `.snappy`. | `width .2s` progress bar; notice line 0.6 s; "Connecting…" fades in after 0.6 s. Loops and celebrations (pulses, shimmer, badges) are not response motion. |
| 9. Budgets that CI keeps | `scripts/perf-window.sh` (cold start, first list, folder switch, chat open) and `Perf.swift` signposts. **Not in CI.** | Elapsed times in its own log only. No signposts, no test target. | **None:** no `performance.mark`, no size budget. `Web/test/walk/performance.mjs` measured once by hand. |

What is shared: `scripts/perf-budgets.py` times the host's answers against budgets, by
hand, on a seeded scratch root. The `.perfBudget` tests run in `slow-tests.yml`'s
`perf-tests` job, but only on `workflow_dispatch`, so nothing holds a budget on a pull
request or at night.

## Measured times

New in this spike (2026-11-11, this Mac, the live root, read only):

| What | Measured |
|---|---|
| `daemon/ping` on the live socket, 50 runs | 0.05 ms median, 0.10 ms p95 |
| Sessions on the live root | 2,805 (24 not archived) |
| `agent.json` of the 24 live sessions | 1,006 KB in all; `availableCommands` is 878 KB of it, which the lean list leaves out |
| Transcripts, on disk | median 419 KB and 509 entries; p90 3.8 MB and 1,871 entries; largest 30 MB and 39,193 entries; 3.6 GB in all |

From earlier walks, on a settled scratch host (`specs/research/073-robustness-speed-feedback.md`,
`specs/071-web-remote/walks/performance.md`):

| What | Measured | Budget (#73) |
|---|---|---|
| Window cold start, first frame | 961–1169 ms | 1.5 s |
| Window cold start, first list on screen | 1236–1520 ms; 389 ms after the lean list (#107) | 2 s |
| `agents/list`, lean, 200 live agents (host) | 8 ms, 0.115 MB | 100 ms |
| Web page painted, 200 sessions in 20 projects | 105 ms after #107 (1150 ms before) | 2 s (SC-004) |
| Chat open, 100k entries (host part) | 13 ms warm, about 130 ms the first time (#91) | 500 ms |
| Chat open, 97 messages (window) | 1154 ms the first time, 267–347 ms after | 500 ms |
| Folder switch (window) | 38–103 ms | 100 ms |
| Keystroke echo through the control plane | 1.71 ms median | 10 ms |
| Remote cold start; phone on Wi-Fi and cellular | not measured (no Simulator GUI; the phone is Alex's) | 2 s |

What the numbers say:

- **The host is fast.** Its answers are milliseconds. The local socket costs nothing.
- **What is slow is what each client does before it draws:** it waits for a link, fetches
  everything again, and only then draws. On the web and the Remote that wait is the
  network. A local copy removes the wait from the first frame; deltas remove most of the
  fetch.
- **A transcript is too large to keep whole on a phone.** 3.6 GB in all, and the p90 is
  3.8 MB. The copy keeps the end of each transcript, not all of it.
- **The cold-start numbers are a month old and were taken by hand.** Nothing measures
  them again. Budgets that CI keeps come first, so that each later change is measured.

## Decided

Decided: **the copy is a cache, never the record.** Each client keeps, keyed by the
session's ref (#4727), the lean record of every live session, the lean records of the
last archived page that was shown, and the end of the last 20 transcripts opened (at most
the last 200 entries each, as the web page's `turnPage`). Caps: 50 MB on the Remote and
the web page, 200 MB on the Mac; the oldest transcript goes first. Because a lean record
is about 0.6 KB and 200 entries are a few hundred KB, all live sessions fit in well
under a megabyte. Alex can overrule.

- **Web:** IndexedDB (a new store beside `key`), never `localStorage`. Cleared at sign-out
  (`forgotten`) with the keys, because the page can be on a shared computer
  (`docs/explanation/direction.md`, customer data).
- **Mac and Remote:** plain JSON files in the platform's `Caches` folder
  (`StoreLocations` already makes `~/Library/Caches/com.alexecollins.agents`), one file
  per session, written off the main actor. No SQLite (`.agents/memory/local-first-no-cloud-login.md`).
  The system can delete them; the client then fetches as now.
- The client draws the copy at once, marked as "from this device" until the host
  answers, and the host's answer always wins.

Decided: **clients resume from their host, not from the bus log.** A client's sessions
and transcripts come from its host (the daemon), over the socket or the control link.
The host can give an order that a client resumes from; the bus (#4724) cannot, because
an event's id is a ref and not a sequence, several control-plane copies write the bus
log, and #4724 is best effort with no backfill. So:

- **Transcripts already resume.** A transcript is append-only and indexed, and
  `agents/transcript` takes `from`. The copy asks `from: <last index + 1>`.
- **The session list needs a revision.** The host gives each record a `revision`, a
  number per host that goes up with each change and is kept on disk.
  `agents/list` and `client/catchUp` take `changedSince: <revision>` and answer the
  records changed since, the ids removed since (kept for a bounded time), and the
  host's current revision. A revision that is too old, or from another host epoch,
  answers "send all", and the client fetches as now. This changes `Packages/Wire`.
- The bus log keeps its own catch-up for machines (#4729, "a machine that was away
  catches up from the bus log"). It needs no cursor for the clients.

Because the host already orders what it writes, and the bus cannot without a global
sequence across copies. Alex can overrule.

Decided (in #4777, kept here): **⌘K opens a command menu on all three clients.** It finds
any session, folder, issue or PR (by words or by ref, such as `#4777`) and any action
("Archive session", "New session in…"), and each item shows its shortcut. Find Session
goes into it. ⌘F is always Find in Chat, the find in the page in front. ⌥⌘F stays as
Find Session for one release, then goes. The terminal keeps its own ⌘K (clear) while it
has focus. It adds a new control, so its PRs wait for Alex (#3474).

Decided: **every reversible action is optimistic, with rollback.** The client changes
its copy at once, keeps the change as pending until the reply, and on failure puts the
record back and shows one line that says what failed ("Could not archive — your Mac did
not answer"). One shared pending-writes layer per client, not code in each action. The
actions: archive, unarchive, stop, send now, rename, labels, mute, Later and Bring Back,
answer a question card, answer a permission, approvals, move to worktree, and each
Settings change. Send draws the prompt as a pending bubble at once. Because it is the
largest change to how the clients feel, and the host's notifications already settle it.
Alex can overrule.

Decided: **budgets CI keeps are counts and bytes; times run at night.** Wall-clock times
on CI's shared runners measure the load, not the change (`scripts/perf-tests.sh`). So the
pull-request check holds what does not change with load: the web bundle's gzip size, the
bytes of a lean record and of `client/catchUp`, and the number of calls before the first
list on each client. The times (cold start, first list, chat open, a long transcript,
send to echo) run at night on a seeded scratch root, with `perf-budgets.py`,
`perf-window.sh` and the web walk, and a run over budget files an issue. The phone's
times stay a manual check for Alex, on Wi-Fi and on cellular. Alex can overrule.

Decided: **a spinner only after 300 ms, and only for the network.** Data in the copy
draws at once. A wait shorter than 300 ms shows nothing; a longer one shows the
in-flight state it has now. Prefetch: the session under the pointer (after 100 ms) and
the next and previous rows of the list in front.

Decided: **response motion is 150 ms or less.** Loops (pulses, shimmer) and celebrations
(badges, the Multiplier) are not response motion and keep their times. The 0.6 s notice
line, the 0.6 s highlight step and the 0.6 s delay before "Connecting…" go to 150 ms or
less; with a local copy, "Connecting…" no longer covers the page.

Decided: **undo, not confirm, where the action can be undone.** "End this wait?" and
"Stop <machine>?" stay confirms, because the wait's time and a running machine cannot
come back. The rest of the confirms are for deletes. So this pattern adds Undo (⌘Z) to
the optimistic actions above that have an inverse (unarchive, rename, labels, mute,
Later), and removes no confirm.

## Patterns to adopt, in RICE order

Reach is every person on every client (3 clients); impact is 3 (large), 2 (medium) or 1
(small); confidence is from the measurements above; effort is in points (`size:`).

| # | Pattern | Reach | Impact | Confidence | Effort | RICE |
|---|---|---|---|---|---|---|
| 1 | Budgets that CI keeps | 3 | 2 | 100% | 3 | 2.0 |
| 2 | Optimistic updates with rollback | 3 | 3 | 80% | 5 | 1.4 |
| 3 | ⌘K command menu | 3 | 3 | 80% | 5 per client | 1.4 |
| 4 | Local copy first | 3 | 3 | 80% | 8 per client group | 0.9 |
| 5 | Deltas by revision | 3 | 2 | 80% | 5 | 1.0 |
| 6 | No spinner for local data, prefetch | 3 | 2 | 80% | 3 | 1.6, after 4 |
| 7 | Web transcript windowed | 1 | 2 | 80% | 3 | 0.5 |
| 8 | Single-key list shortcuts | 3 | 1 | 80% | 3 | 0.8, after 3 |
| 9 | Undo for the optimistic actions | 3 | 1 | 80% | 2 | 1.2, after 2 |
| 10 | Response motion 150 ms | 3 | 1 | 100% | 1 | 3.0, polish |

Motion (10) scores high because it is small; it is polish and goes in any free place.
A pattern that waits for another goes after it whatever its score.

## Open questions, answered

- **Where does each client keep its copy, and how much?** In IndexedDB on the web, in
  `Caches` on the Mac and the Remote; all live sessions and the end of the last 20
  transcripts, capped (above).
- **Can the bus log give a cursor?** It can for machines (#4729 has catch-up), but the
  clients do not use it: they resume from their host by `revision` and by transcript
  index (above).
- **⌘K:** Core, all three clients; its PRs wait for Alex.
- **Which device and network do the budgets use?** This Mac, on a seeded scratch root,
  at night; the phone on Wi-Fi and cellular is Alex's manual check.

## The epic and its children

#4783 (`feature:performance`). "Blocked by" is in the forge; this table is prose.

| Child | Level, size | Pattern | Clients | Blocked by |
|---|---|---|---|---|
| #4784 Budgets that CI keeps | task, S | 9 | tooling, web marks | — |
| #4785 `revision` and `changedSince` on the wire | task, S | 2 | none (wire, host) | — |
| #4786 Optimistic updates with rollback | story, M | 3 | all three | — |
| #4787 Mac: ⌘K command menu | story, M | 4 | Mac | — |
| #4788 Web: ⌘K command menu | story, M | 4 | web | — |
| #4789 Web: window the chat transcript | story, S | 6 | web | — |
| #4797 Response motion 150 ms or less | story, M | 8 | all three | — |
| #4790 Web: local copy in IndexedDB | story, S | 1 | web | #4727 |
| #4791 Mac and Remote: local copy in Caches | story, S | 1 | Mac, Remote | #4727 |
| #4792 Remote: ⌘K command menu | story, M | 4 | Remote | #4787 |
| #4793 Undo for the optimistic actions | story, L | 7 | all three | #4786 |
| #4794 Resume by revision | story, M | 2 | all three | #4785, #4790, #4791 |
| #4795 No spinner for local data, prefetch | story, M | 5 | all three | #4790, #4791 |
| #4796 Single-key list shortcuts | story, L | 4 | all three | #4787, #4788, #4792 |
