---
diataxis: how-to
devices: [mac]
description: Keep the app fast with budgets that CI holds on each pull request and times that this Mac measures at night.
---

# Keep the performance budgets

The app has budgets for how fast it feels (#73): 100 ms for a click to show that it was
taken, 1 s for a list to be there. All of them are in one file,
`scripts/perf-budgets.json` (#4784).

## What each pull request holds

CI's runners are shared, so a time measured there measures the load. A pull request is held
only to what does not change with load:

| Budget | Checked by | CI job |
|---|---|---|
| `web.gzipBytes`: the web page's scripts, styles and HTML, gzipped | `Web/test/perfBudgets.test.mjs` | `web` |
| `web.callsBeforeFirstList`: the calls the page makes from its link opening until its first list | `Web/test/perfBudgets.test.mjs` | `web` |
| `host.leanAgentBytes`: the largest lean `Agent` record in `agents/list` | `Go/internal/agentsd/perfbytes_test.go` | `go` |
| `host.catchUpBytes`: one `client/catchUp` answer for 50 live sessions | `Go/internal/agentsd/perfbytes_test.go` | `go` |

A check that fails says the number, the budget and the file. Make the change smaller, or,
when the change is worth the bytes, raise the budget in `scripts/perf-budgets.json` in the
same pull request and say why in its body.

To run them before a push:

```sh
scripts/web.sh build && (cd Web && node --test test/perfBudgets.test.mjs)
Go/scripts/go.sh test ./internal/agentsd -run 'KeepsItsBudget'
```

## What runs at night

The Performance budgets workflow (`.agents/workflows/performance-budgets.md`) runs
`scripts/perf-nightly.sh` on this Mac at 03:00. It seeds a scratch root (41 live sessions, a
transcript of 100,000 entries, a repository of 40,000 files), launches a scratch app on it,
and measures against the `night` budgets:

- the host's answers, with `scripts/perf-budgets.py`;
- the Mac window's cold start, first list, project switch and chat open, with
  `scripts/perf-window.sh`;
- the web page's first list, session open and long transcript, from the page's own
  `performance` marks (`agents:first-list`, `agents:session-open`), with
  `Web/test/walk/budgets.mjs`;
- the tests marked `.perfBudget`, with `scripts/perf-tests.sh`.

The report goes to `~/.agents/reviews/performance-nightly/<date>.md`. When a time is over
its budget, the run files an issue, "Performance budgets over at night", labelled
`feature:performance`, or adds its numbers to the one still open.

To run it by hand, on a quiet Mac:

```sh
scripts/perf-nightly.sh --no-issue
```

## The phone: your check

No runner has the phone on Wi-Fi or cellular, so its times stay a check by hand. About once
a release, on the iPhone:

1. Quit the Remote. Turn off Wi-Fi, so the phone is on cellular.
2. Open the Remote and count the time until the session list is there. The budget is 2 s.
3. Open a long session. The budget is 500 ms until its last messages are there.
4. Turn on Wi-Fi and do steps 1 to 3 again.

When a time is over, file an issue labelled `feature:performance` with the times, the
network and the phone.
