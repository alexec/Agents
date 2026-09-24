# Contract: What is on disk, and what reading it back promises

Two files change. One is new, one gains a field. Both are the daemon's, both are read
whole and written whole, and for both the daemon is the only writer.

---

## `<root>/attention.json` — new

```json
{
  "deliveries": [
    {
      "needID": { "report": { "agentID": "5C9…", "at": "2026-09-24T11:02:19.441Z" } },
      "to": { "device": "A31…" },
      "alertedAt": "2026-09-24T11:02:24.500Z",
      "alertCount": 1
    }
  ],
  "raised": [
    {
      "need": { "report": { "agentID": "5C9…", "at": "2026-09-24T11:02:19.441Z" } },
      "at": "2026-09-24T11:02:19.441Z"
    }
  ],
  "withdrawing": [
    {
      "need": { "permission": "7F2…" },
      "device": "A31…",
      "decidedAt": "2026-09-24T11:40:02.010Z"
    }
  ]
}
```

`needID` and `to` are the shapes `NeedID` and `Surface` already encode to. A `mac`
surface is `{"mac": {}}`; that tagged form was chosen in 021 so a third surface later is
additive, and nothing here changes it.

### What reading this back promises

1. A need named in `raised` that is still outstanding keeps that time. Nothing may write a
   later one over it while the need lives.
2. A need named in `deliveries` that is still outstanding is already showing where it
   says, and the person has already been buzzed about it `alertCount` times, most recently
   at `alertedAt`. The ordinary re-alert rule applies from that moment, unchanged.
3. A need named in `deliveries` that is **not** outstanding is over: its surface is
   withdrawn from, and if that surface is a device the withdrawal is added to
   `withdrawing` until it has been handed to a connection that has said `mailbox/carry`
   — the bridge — or to a mailbox of the daemon's own. A later post of the same need to
   the same device voids it.
4. A `deliveries` or `withdrawing` entry naming a device the daemon does not know is
   dropped on load. Nothing is sealed to, or withdrawn from, a device that is not on
   record.
5. A `withdrawing` entry older than seven days is dropped. This is a retry, not a queue.
6. A file that is missing, empty or unreadable is no notes at all. The daemon starts
   normally and behaves exactly as today's does — it re-raises, re-decides and may alert
   again, which is the current behaviour and is never worse than it.

### What it must never hold

Nothing about what a need says. No headline, no title, no tool name, no message. Those
live on `Need`, which is derived from the agents and the pending questions every time it
is asked for, and there must not be a second copy of them.

---

## `<root>/workflows.json` — one new field

```json
{
  "states": [ … unchanged … ],
  "lastTickAt": "2026-09-24T09:00:00.000Z",
  "runs": [
    {
      "id": "1B4…",
      "workflowID": "morning-tests",
      "folder": "file:///Users/alex/code/thing",
      "trigger": { "schedule": { … } },
      "triggeringAgentID": null,
      "depth": 0,
      "agentID": "5C9…",
      "startedAt": "2026-09-24T09:00:01.220Z"
    }
  ]
}
```

`runs` holds `WorkflowRun` exactly as that type already encodes. Nothing about the type
changes.

### What reading this back promises

1. A run listed here was in flight when the daemon stopped. It is in flight again on load,
   keyed by folder and workflow id, which is how it is keyed in memory.
2. Its `depth` is the depth its children inherit. A lifecycle event caused by its agent is
   one deeper, and the chain ceiling counts from here rather than from zero.
3. It is what a second fire of the same workflow collides with, so a workflow that was
   running before the restart is still refused a second run after it.
4. A run whose agent no longer exists, or is archived, or whose workflow file has been
   deleted, is released on load. **Nothing chained on its completion fires** — it did not
   complete, and firing on it would be the app inventing a completion nobody saw.
5. A run older than seven days is released on load, the same way and for the same reason.
6. An older build reading this file ignores `runs` and loses nothing it had. A newer one
   writing it and an older one reading it back is the existing leniency of this file; the
   states and the tick are read as before.

### Ordering, which is part of the contract

The runs are loaded **before** recovery marks the dead agents, not after. Recovery's
lifecycle events carry the depth computed at the moment they are deferred, so a run
loaded later is a depth of zero recorded for every one of them — the exact failure this
feature claims to fix, reintroduced by loading in the tidier-looking place.

Pruning happens after, in `startWorkflows()`, because it needs the agents and the workflow
files that recovery and adoption have by then read.

---

## `UserDefaults` — the window's drafts

Not a file in the daemon's root, and deliberately so. The daemon's directory promises one
writer, and a draft is not the work: it is what one person has half-typed in front of one
app. It goes where that app already keeps the selected project and the sidebar's width.

```
draft.agent.<agent-uuid>          → JSON
draft.new.<folder-path-or-empty>  → JSON
```

### What reading these back promises

1. A draft restores against the conversation it was typed for, and against no other.
2. It is the same draft in every window, as the selection already is.
3. It is gone the moment its text is sent.
4. It is gone if its conversation is gone or archived.
5. It is gone thirty days after it was last touched.
6. If inline attachment data was too large to keep, the text and every by-reference
   attachment still restore, and the draft says that something by value was dropped rather
   than restoring silently incomplete.
7. An entry that will not decode is discarded. A draft is never worth failing over.
