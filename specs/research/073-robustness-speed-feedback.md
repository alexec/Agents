# 073: Robustness, speed and feedback

2026-10-01, branch `agents/work-github-issue-73` off main at 662beef4. This covers issue #73.

**Method**:
- I read the crash reports of the last two weeks.
- Three read-only code audits looked at waits and deadlines, swallowed errors and disk, and reconnects and feedback. I checked their main claims against the code before filing them.
- I timed a scratch set-up (run-app, root `/tmp/run-p73`) with a seeded 100k-entry chat, 42 agents and a 40,000-file repo.
- I profiled the window with Time Profiler.
- I walked the window by accessibility, behind Alex's windows, without clicks or keystrokes.

The Remote's look and the phone over Wi-Fi and cellular are Alex's to check.

Every finding is its own issue, #74–#94, all of them linked from #73.

## Summary

- **Crashes.** There are five distinct stacks.
  - Two were already fixed: #71 and 868f4d8b.
  - One is fixed on this branch (#75).
  - Two are open: #74, a live crash on swipe-to-archive, and #76, whose reason was lost.
  - Agents Host and agents-control have no crash reports.
- **Robustness.** The pattern behind "stuck" states is a wait with no deadline inside a loop that only one task may run.
  - This branch bounds the reconnect catch-up (#78) and adds a missed-pong deadline (#80).
  - The rest of the Remote's reconnect hang was the control plane silently dropping a call in flight when the host goes (#77) and a transient refusal that wiped the pairing (#81), both since fixed on this branch, as is the relay (#79).
- **Speed.** The host is fast everywhere; the slowest host answer is Changes on 1,800 files at 0.34 s. The window is where time goes.
  - Opening a chat costs 270–550 ms, with a 371 ms main-thread hang on the first open (#90).
  - The first open of a very long chat costs 3.5 s (#91).
  - Cold start is about 1 s to the first frame and 1.2–1.5 s to the first list (Debug build).
- **Feedback.** Thirteen Mac actions and settings failed in silence; this branch makes them say why (#85).
  - A host that is down is nearly invisible on the Mac (#83).
  - Cards and buttons show nothing while in flight (#86, #87).

## Crashes (2026-09-17 to 2026-10-01)

From `~/Library/DiagnosticReports`. "Live" means a build in Alex's own app; "scratch" means a `/private/tmp` copy.

| # | Process | Stack | Count | Status |
|---|---|---|---|---|
| A | Agents | Stack overflow in `_NSAccessibilityOverrideValueForAttribute` / `_accessibilityFindRoleFromProtocol` (stacked accessibility labels) | 7 live (2026-10-01 14:28–15:08), 2 scratch (2026-09-25) | #71, fixed 662beef4 (merged, not live) |
| B | Agents | Uncaught exception in `_NSViewLayout` → `_crashOnException`; one from `setNeedsUpdateConstraints` during the cursor hit-test | 3 live (2026-09-24, 2026-09-25) | **#76**: the reason was not captured; none since 2026-09-25 |
| C | Agents | `NSTableRowData _updateActionButtonPositionsForRowView` after a swipe animation ends | 1 live (2026-09-30 21:53) | **#74**: swipe-to-Archive moves the row mid-animation |
| D | agentsd | `-[NSTask setCurrentDirectoryURL:]` exception from `RuntimeProcess.init`: a cwd that is not a file URL | 9 scratch (2026-09-24 07:41–07:54) | **#75**, fixed on this branch caef5699 |
| E | agentsd | NIO `EventLoopFuture.deinit` assertion: the upgrade promise was left behind on a refused connect | 1 (2026-09-28 22:56, debug build) | Fixed 868f4d8b, three minutes later |

`swiftpm-testing-helper` had 16 crashes. Each one ended a whole test run:
- tests indexing after a failed expectation;
- `SecIdentityCreate` raising;
- a P-256 parse that has since been fixed.

These are filed as **#94**. They are part of why the suite looks flaky under load.

## Robustness

### Deadlines

| Wait | Deadline | On timeout | Finding |
|---|---|---|---|
| `DaemonClient.call` (about 190 call sites) | **None** | Waits until a reply or until the connection ends | **#78**. This branch adds `DaemonClient.patience`, a task-local deadline, and puts the reconnect catch-up of both apps under 20 s |
| Remote `tryOnce`: announce, identify, about 16 refreshes inside the `reconnecting` task | None before this branch | Wedged the loop; coming to the front could not help | #78, fixed on this branch |
| Window `connect()`: `refreshEverything` inside `reconnect()` | None before this branch | Same | #78, fixed on this branch |
| Remote `sendOnce` waiting on the reconnect loop | None | The start sheet spins as long as the Mac is gone | #78 and #87, open |
| `ControlRouter.dropHost`: requests in flight | None, and the request is dropped | The phone (bare wire) waits for ever and is never told the host changed | **#77**, fixed on this branch (ca67c79d) |
| Relay session after a Mac restart | None | The phone's relayed link stays open with nothing behind it | **#79**, fixed on this branch (9f05c0e8): the restarted Mac says the session is over; the phone lets go after 2.5 keep-alives of silence |
| `WebSocketLink` ping | Ping every 20 s, no pong deadline | A half-open socket looked alive for minutes | **#80**, fixed on this branch: an unanswered ping ends the link |
| `ControlDial` connect and upgrade | 10 s plus 10 s | Fails | Fine since 868f4d8b |
| `RemoteFiles` list, read and watch | 10 s | "took too long to read", and re-read on reconnect | Fine (#62) |
| `ControlAuth.join`, announce, `hostArrived` | 15 s | Fails | Fine |
| Mac Connect… sheet | Bounded pairing, then the unbounded reconnect loop | Spins for ever; raw error text | **#84** |
| Add Server, Settings codes | None (install legitimately takes minutes) | Spinner with Cancel, no error | In #84's family; Cancel is the way out |
| `LocalServices` launchctl | None, and the pipe is read only after exit | Deadlock on output over 64 KB | **#92** |
| JSON-RPC failure with `id: null` | — | Dropped; the caller waits | **#93** |

### Reconnects

- **Host or daemon restart.**
  - Mac window: good. `control/hostChanged` ends the route; measured 0.6–1.2 s from the host coming back to the window catching up.
  - Remote: broken by #77 and #78, both fixed on this branch. A fake iPhone is answered again 0.55 s after the host comes back.
- **Sleep and wake, and network changes.** Nothing listens for them on any platform. Recovery waits out the backoff, up to 30 s (**#82**). A half-open socket is now dropped within about 40 s (#80).
- **The phone coming to the front.** `cameToTheFront` pings with a 4 s limit, but only when no reconnect is running, which is exactly the case that was stuck (#78).
- **Pairing lost to a hiccup.** A store that can't be read for a moment answers `.unknown`, and the Remote then forgot its pairing and stopped dialling for good (**#81**, fixed on this branch: `unavailable`, and a forget only on a verdict that lasts).

### Errors that vanish

There are about 1,050 `try?` outside tests; most are harmless. The ones that hide what the person did:

**Mac, fixed on this branch (#85, f3dcee1e)**:
- Run now and archive for workflows;
- Reveal, Open and Open in Terminal;
- the Sleep, client-permission, sandbox-default and cost-limit settings, and an agent's cost ceiling;
- Archive leaving the chat after a failure;
- "too big" shown for an attachment that could not be read.

**Mac, still open (#85)**:
- settings pushed to servers;
- `saveText` (AGENTS.md);
- lending the Gemini key;
- a failed Keychain delete.

**Daemon (#88)**:
- `saveQuietly` and transcript appends: now logged on this branch;
- projects.json and spend limits: `try?`, with the cache updated first, so a change looks saved until a restart;
- workflow store, plugin approvals and the spend ledger: still `try?`.

**Remote**: errors are surfaced well (`problem` and `sentence(for:)`). The defect was routing: stop, park, archive, Send now and unqueue for an agent on another host went to the home host. Fixed on this branch, 88a4a152.

### Disk full and permission refusals (#88)

- **No hangs found.** Writes fail fast, and git prints its own stderr.
- **Lost work.** A transcript append that fails part-way left a half line, and the next entry was glued to it. Fixed on this branch: a failed write releases its handle, and the next open ends the fragment.
- **Proof.** `DiskFullLiveTests` (`AGENTS_DISK_FULL=1`) fills a 2 MB disk image and checks that every entry before and after the full disk reads. I did not show it failing without the fix, because that would mean changing the source.
- **Raw errors.** Errors reach the person raw (`NSCocoaErrorDomain Code=640`). There is no mapping from ENOSPC or EACCES to words outside the runtime installers.
- **No warnings.** There is no free-space check before a clone or a worktree, and no low-space warning.

## Speed

All figures are from a **Debug** build on this Mac (Apple M5, macOS 27.0) while three other lanes were building, on 2026-10-01. Release builds will be faster, so the budgets are set for Debug, where regressions show first. "Host" is the daemon's answer over `daemon.sock`, the median of 5 (`scripts/perf-budgets.py`). "Window" comes from the window's own `perf` log lines (`App/Sources/Perf.swift`): an interval ends at the first run-loop wait after the change, when it is drawn.

| What | Measured | Budget | Status |
|---|---|---|---|
| Host cold start: socket answers | 318 ms (751 ms the first time after seeding) | 1 s | ok |
| Host cold start: uplink joined to the control plane | 348 ms | 1 s | ok |
| Window cold start: first frame | 961–1169 ms (4 runs) | 1.5 s | ok |
| Window cold start: first list on screen | 1236–1520 ms after launch (3 runs) | 2 s | ok |
| `agents/list`, 42 agents (host) | 45 ms | 250 ms | ok |
| `projects/list` (host) | 0.4 ms | 100 ms | ok |
| Project switch (window), 1 or 41 sessions | 38–103 ms, median about 74 (10 switches) | 100 ms | ok, at the limit |
| Chat open, 97 messages of 2 KB (window) | 1154 ms the first time, 267–347 ms after | 500 ms | **over the first time** (#90) |
| Chat open, 100k entries, 50 turns shown (window) | 287–552 ms | 500 ms | **at or over** (#90) |
| Host part of a chat open: turns plus the open turn, 100k entries | 33 ms warm, 79 ms after a host restart, **3,490 ms the very first time** | 500 ms | **over the first time** (#91) |
| The same after #91 (2026-10-02, another load: main measured 1,983 ms first, 41 after a restart, 17 warm) | 13 ms warm, 37 ms after a host restart, about 130 ms the very first time; the window's `chat-open` 2,150 → about 250 ms the first time | 500 ms | ok |
| Remote's page: the last 500 of 100k entries (host) | 41 ms | 500 ms | ok |
| Files: root of a 40,000-file repo (host) | 0.4 ms | 250 ms | ok |
| Files: a deep folder (host) | 0.7 ms | 100 ms | ok |
| Changes: 1,800 changed files (host) | 336 ms (slowest 465) | 1 s | ok |
| Changes pane drawn after the press (window, timed by AX polling) | about 440 ms | 1 s | ok |
| Typing in the prompt | Not measured reliably; see below | 16 ms per key | — |
| Control-plane round trip: keystroke echo, one copy (`LatencyLiveTests`, 200 samples) | 1.71 ms median, 3.25 p90 (0.38 on 2026-09-29, unloaded) | 10 ms (SC-004) | ok |
| Control-plane round trip: keystroke echo, two copies | 1.63 ms median | 10 ms | ok |
| Control plane: a question reaching the window | 1.19 ms median | 50 ms | ok |
| Window back after a host restart | 0.6–1.2 s after the host is up | 2 s | ok |
| Remote cold start; phone over Wi-Fi and cellular | Not measured: there is no Simulator GUI, and the phone is Alex's | 2 s; 50 ms over Wi-Fi | — |

### Main-thread work

- **Chat open (#90).** Time Profiler shows a 371 ms microhang on the first open. Of 551 main-thread samples:
  - 219 are TextKit laying out every fragment of the selectable text (`AppKitTextInteractionView.layout`);
  - 145 are glyph rasterising;
  - 37 are `MarkdownBlock.parse` called from `MarkdownText.body`. Each body evaluation re-parses the whole message, and so does every streamed chunk.
- **Typing.** Accessibility value sets cost about 1.4 ms of main thread each. They do not reach the prompt's binding, though (Send stays disabled), so this is not real typing. Measuring real keystrokes needs the window in front, which was not possible while Alex was working.
- **Accessibility over a long list.** A walk of the accessibility tree over the 1,800-row Changes list held the window at about 99% CPU for over a minute; idle, the window sits at 0%. Rows are lazy, but a full accessibility walk materialises every one. This affects scripted walks, not people.

### The repeatable checks

- `scripts/perf-budgets.py ROOT`: the host table above, with budgets. It exits 1 over budget. Seed the root with `scripts/seed-big-repo.py` and `scripts/seed-long-transcript.py` (usage is in its docstring).
- `scripts/perf-window.sh SLUG …`: cold start, first list, project switches and chat opens, read from the window's `perf` lines. **Not yet run end to end.** Alex stopped the first run, so every window figure above comes from the same steps run by hand.
- `DroppedReplyTests`, in the unit suite: replies dropped, delayed and silenced on a `PairedTransport`, plus the router's in-flight drop recorded as a known issue (#77).
- `DiskFullLiveTests` (`AGENTS_DISK_FULL=1`) and `LatencyLiveTests` (`AGENTS_LATENCY=1`, from 058).

## Feedback

Walked on the scratch window, and traced in code for the Mac and the Remote.

| Action | Mac | Remote |
|---|---|---|
| Start an agent | The field clears; no spinner (#87) | Spinner; bounded only since this branch's catch-up deadline, and `sendOnce` is still unbounded (#78) |
| Send | Clears optimistically; text restored on failure | Same |
| Send now | No pressed state; can be pressed repeatedly (#87) | Same; went to the wrong host for other hosts' agents (fixed) |
| Stop, park, archive | No pressed state (#87). Archive left the chat after a failure (fixed) | No pressed state; wrong host (fixed) |
| Permission card | No pressed state; can be answered twice (#86) | "Telling your Mac" spinner: good |
| Question card | No pressed state (#86) | Spinner: good |
| Pair a device or window | Code: inline. Connect… can spin for ever and shows raw errors (#84) | Bounded, with a sentence: good |
| Move to a worktree | No spinner; inline line on failure (#87) | Only at start |
| Open a file | Spinner, then a sentence, 10 s. A stale read can land on the next file (#89) | Spinner, 10 s, guarded: good |
| Run a workflow | **Silent** before this branch (#85) | Alert: good |
| Settings changes | Sleep, permissions, sandbox and limits **silent** before this branch (#85) | Alert and revert |
| Host down | A grey line cut off as "Not connected to the daemon. Tr…"; the chat looks usable; actions take several seconds to fail (#83) | A stale banner, driven by `isConnected` |

## Fixes on this branch

Each commit is small and built for the window, Agents Host and the Remote (generic iOS Simulator). The related AgentsKit suites pass: 107 tests in 17 suites, including the new ones, with 2 known issues recorded. So do the ControlPlane service tests (33).

| Commit | What | Issue |
|---|---|---|
| caef5699 | agentsd: a runtime's folder is always a file URL | #75 |
| 170069a4 | A deadline on every call of the reconnect catch-up (`DaemonClient.patience`), plus `DroppedReplyTests` | #78 (#77 recorded) |
| 77933b3c | `WebSocketLink`: an unanswered ping ends the link | #80 |
| a749e9b8 | Store: a failed append releases its handle; failed saves and appends are logged; `DiskFullLiveTests` | #88 (part) |
| 88a4a152 | Remote: agent actions go to the agent's own host | (found by the feedback audit) |
| f3dcee1e | Mac: silent failures say why; Archive stays on failure; unreadable is not "too big" | #85 (part) |
| 2498681f | `Perf.swift` signposts, `perf-budgets.py`, `perf-window.sh` and the seeders | — |
| ca67c79d | Router: a call in flight when its host goes is answered `hostOffline`; the phone's bare session ends with the home host. `HostRestartLiveTests`: the connection ended 11 ms after the host stopped, answered again 0.55 s after it came back | #77 |
| 965ff42b | `unavailable` refusal when the store can't be read; the Remote forgets only `forgotten`, or `unknown` lasting two minutes; the loop clears itself | #81 |
| 9f05c0e8 | Relay: an end for a session the Mac does not know; keep-alives answered; the phone lets a silent Mac go | #79 |

Walked: on a scratch window, Archive with the host stopped shows "Could not finish that / Could not reach the helper that runs the agents" and keeps the chat. The window reconnects 0.6–1.2 s after a host restart.

Not walked: the WebSocket pong deadline (it needs a far end that stops answering pings) and the Remote's changes (no Simulator GUI). Only the final tree was built; the intermediate commits were not built one by one.

## Issues filed

| Bugs | |
|---|---|
| #74 | Crash: swipe-to-archive in the Sessions list |
| #75 | Crash: agentsd on a bare-path folder (fixed on the branch) |
| #76 | Crash: AppKit layout exceptions, reason lost |
| #77 | Control plane drops a call in flight when its host goes |
| #78 | A lost reply holds the reconnect loop (partly fixed) |
| #79 | Relay session left open after a Mac restart |
| #80 | Missing pong never noticed (fixed on the branch) |
| #81 | A transient "unknown" wipes the Remote's pairing |
| #83 | Mac: a host that is down is nearly invisible |
| #84 | Connect… sheet spins for ever and shows raw errors |
| #85 | Mac: silent failures (mostly fixed) |
| #86 | Permission and question cards: no pressed state |
| #88 | Disk full and permission refusals (partly fixed) |
| #89 | Files pane: a stale read lands on the next file (#67's area) |
| #92 | launchctl pipe deadlock |
| #93 | JSON-RPC failure with id null is dropped |

| Enhancements | |
|---|---|
| #82 | Reconnect on wake and on a network change |
| #87 | In-flight feedback for start, Send now, stop, park and archive |
| #90 | Chat open: main-thread layout and Markdown parsed in `body` |
| #91 | First open of a very long chat builds its turn index (3.5 s) |
| #94 | Tests that crash the whole run |

**Suggested order, bugs first**: #77 and #81 are now fixed on the branch (with #78, the Remote's reconnect hang). Next: #74, #83, #86, #88, #79, #84, #93, #92, #89 and #76.
