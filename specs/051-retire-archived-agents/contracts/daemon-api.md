# Contract: Daemon API for Retirement (051)

All methods are JSON-RPC over `daemon.sock`, like every other method.

**Roles**: the settings and Retire now belong to the person. They are open to `control`
connections (Mac windows) and refused to devices, helpers and strangers, like
`cost/setLimits`. `agents/retired` and `retention/state` are reads, open to anything that can
already read `agents/list`.

## Methods

### `retention/state` → `RetentionState`

No parameters.

```json
{ "settings": { "keepFor": "days30", "cap": "gb2" },
  "archivedCount": 263, "archivedBytes": 829423616, "retiredCount": 0,
  "overCap": null }
```

`overCap`, when present, is `{ "bytesOver": 12345678, "holding": { "worktreeHasWork": 2, "firstDay": 5 } }`.

### `retention/set` { `settings`, `confirmed` } → `RetentionSetResult`

- `confirmed: false` answers with what the change would retire at once, and changes nothing:
  `{ "applied": false, "wouldRetire": { "count": 41, "bytes": 612368384 } }`.
  When nothing would be retired, it applies the change straight away and answers
  `{ "applied": true, "state": RetentionState }`. The window then asks nothing (FR-011).
- `confirmed: true` saves `retention.json`, runs a check at once, broadcasts
  `retention/changed`, and answers `{ "applied": true, "state": RetentionState }`.

The app sends `confirmed: true` to each server after its own Mac daemon has applied the change
(research R8).

### `agents/retire` { `agentID`, `confirmed` } → `RetirePreview` or `{}`

- `confirmed: false` answers `{ "count": 1, "bytes": 5651619 }`, for the confirmation's words.
- `confirmed: true` retires the agent at once, by the same path as the check, with
  `retiredBecause: person`.
- It fails with **`-32051 retireRefused`** when the agent is not archived, or is held. The
  message is the reason, as `RetirementWords.refusal(hold)` says it: for example, "Its worktree
  still has work in it that is not committed or merged."
- It fails with **`-32050 agentRetired`** when the agent is already retired.
- *As built*: "open in a window" does not hold Retire now. The person asking is usually the one
  looking at the chat, and the menu is their explicit choice; work in the worktree and a running
  workflow still refuse it. On the Mac, Retire Now… is always in an archived row's menu, and asks
  first: a refusal comes back as an alert with the reason rather than as a disabled item with a
  tooltip, since a context menu cannot wait on the daemon while it opens.

### `agents/retired` { `folder`?, `ids`?, `limit`? } → `[Tombstone]`

- With `ids`, it returns those tombstones, in any order, leaving out ids it does not have.
- With `folder`, it returns that project's tombstones, newest `retiredAt` first. `limit`
  defaults to 200 and cannot exceed it.
- With neither, it returns the newest 200.

## Failures on existing methods

Any agent method (`agents/prompt`, `agents/unarchive`, `agents/transcript`, `agents/fork`,
`agents/setOption` and the rest) given an id the daemon holds only as a tombstone fails with
**`-32050 agentRetired`**. The message is `RetirementWords.retiredSentence(tombstone)`: "“Fix
the login page” was retired on 12 October, 30 days after it was archived." It replaces
`noSuchAgent` for that id and nothing else.

Agent tools that name another agent (`archive_agent`, `stop_agent`, the helpers of 028) fail
with the same sentence.

## Notifications

| Name | Params | When |
|---|---|---|
| `retention/changed` | `RetentionState` | settings changed, or a check changed a count, size or `overCap` |
| `agent/removed` | `{ "agentID": UUID }` | an agent was retired; windows drop it from their lists |
| `agent/changed` (existing) | `Agent` | also when an archived agent's `retirement` note changes, and when a slim agent is made whole (so the Mac's archived chat gets its commands) |
| `project/changed` (existing) | `ProjectSummary` | also after retiring, for `retiredCount` |

Older clients ignore `retention/changed` and `agent/removed`. They drop a retired agent at their
next `agents/list`.

## Wire additions to existing types

| Type | Field | Notes |
|---|---|---|
| `Agent` | `archivedAt: Date?` | optional; older decoders keep it in `unknownFields` |
| `Agent` | `retirement: Retirement?` | `{ "at": date }`, `{ "nextUnderCap": {} }`, `{ "held": "worktreeHasWork" }`; unknown shapes decode to `.unknown` |
| `ProjectSummary` | `retiredCount: Int?` | nil or 0 means none |
| `ProjectSummary` | `costToDate` | now includes retired agents' costs; the key is unchanged |

## Events (042 catalogue)

`agent.retired`, with scope project and details `agent`, `agent_title`, `project` and
`because` (`age`, `cap` or `person`). Its sentence: "An archived agent was retired and its
conversation deleted." Workflows may trigger on it like any agent event.

## Words (AgentsKitCore/Model/RetirementWords.swift)

All in one place. The Mac and the phone call the same functions:

| Function | Example |
|---|---|
| `rowNote(.at(d), now)` | "Retires in 3 days" / "Retires tomorrow" / "Retires today" |
| `rowNote(.nextUnderCap)` | "Next to be retired to stay under 2 GB" |
| `rowNote(.held(.worktreeHasWork))` | "Kept: its worktree has work in it" |
| `rowNote(.held(.workflowRunning))` | "Kept: a workflow run is still going" |
| `rowNote(.held(.openInWindow))` | nothing (the person is looking at it) |
| `retiredLine(count)` | "12 older agents have been retired." |
| `retiredSentence(t)` | "“Title” was retired on 12 October, 30 days after it was archived." |
| `settingsSummary(state)` | "263 archived agents, 791 MB. Kept 30 days, up to 2 GB." / "Archived agents are kept forever." |
| `overCapSentence(o)` | "Archived agents are 120 MB over 2 GB. 2 are kept because their worktrees have work in them." |
| `confirmSettings(p)` | "This retires 41 archived agents now and frees 584 MB. Their conversations are deleted and cannot be brought back." |
| `confirmRetire(title, bytes)` | "Retire “Title”? Its conversation (5.4 MB) is deleted and cannot be brought back." |
