# Performance: SC-004 and the bundle

**Date:** 2026-10-01

**Commit:** the T070 commit on `agents/write-spec-first-version`.

**SC-004:** "The page is usable within 2 seconds of opening, with 20 projects and 200 sessions."

## How it was measured

- **The root:** the scratch root `/tmp/run-webperf`, with no window.
  - It was seeded before the host started, with `scripts/seed-archived.swift --live`: 10 finished sessions in each of 20 project folders.
  - Each record is the real-sized fixture, about 20 KB. That's the size of a real one: on this Mac, 400 records of the person's own store measured a median of 24.7 KB and a 90th percentile of 36 KB (file sizes only).
  - `launch.sh` gained `--seeded` for this. It lets a root already made and filled through, provided nothing is running on it.
- **The script:** `Web/test/walk/performance.mjs`, in headless Chrome at 1440 × 900.
  - The browser pairs once and opens one project.
  - Each run then navigates afresh to that project's address, by way of `about:blank`, so a new document loads. It connects with the stored key, loads the host, and draws.
- **What counts as painted:** a script injected before the page's own records the first frame after the sessions column holds all 10 of the project's sessions. The 20 projects are in the list by then. That time is measured from navigation start.
- **Runs:** 7 per set.

## Results

| Set | Machine load (1 min) | Median | Fastest | Slowest |
|---|---|---|---|---|
| Settled host | about 5.5 | **1150 ms** | 936 ms | 1795 ms |
| Again, minutes later | about 5.5 | **1006 ms** | 719 ms | 1376 ms |
| Just after the host started, with other lanes' suites running | about 11 | 3242 ms | 2941 ms | 3758 ms |

**SC-004 holds on a settled host:** every run of both settled sets painted within 2 s. It didn't hold under the heavy load straight after start-up, at about 3.2 s.

Notes and the screenshot are in `walks/performance/`: `performance-notes.txt` (the first settled set) and `performance-sessions.png`.

## Where the time goes

**The page itself isn't the cost.** A CPU profile of one load had the page idle for all but about 150 ms. For the profile, an unminified build was swapped in for `/app.js` through CDP's `Fetch` domain, without touching the served files. Grouping 200 sessions, the project counts and drawing the column took a few milliseconds each. HTML was parsed by 50–110 ms.

**`agents/list` is the cost.** A frame-by-frame capture of the WebSocket (in the slow set) showed:
- the reply to `agents/list` is **4.15 MB**: 200 full records, with each agent's option and command lists;
- it arrived 1.4 s after it was asked for;
- the host answers the same call on its own socket in about 0.45 s, so the uplink and the control plane add the rest;
- everything else the page loads (projects, runtimes, accounts, modes, pending cards, worktrees and the open session's options) came after it, all within 300 ms.

The window pays the same 4 MB on its own socket, so this is the protocol's shape, not the browser's. The remedy is a list without each agent's command and option lists, which the sessions column never reads (the open session's menus come from `agents/options`). In the fixture record, `availableCommands` is 18.9 KB and `advertisedOptions` 1.9 KB of 21.5 KB, so without them a record is about 0.7 KB and the reply about thirty times smaller. It is a change to `DaemonAPI` for every client, so it's left as a follow-up rather than made here.

## The bundle

| File | Size | Gzipped |
|---|---|---|
| `app.js` | 228.1 KB | 83.5 KB |
| `app.css` | 18.3 KB | 4.3 KB |
| `assets/favicon.png` | 1.8 KB | 1.8 KB |
| `index.html` | 0.4 KB | 0.2 KB |
| **All** | **248.5 KB** | **89.8 KB** |

The aim was under 150 KB gzipped: it is 89.8 KB.
