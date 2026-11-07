# Needs you: the request record (#3862)

Part of epic #3861. This spike gives the record, the wire shape and the mapping. #3863 builds them in the daemon and the wire, #3864 draws them on the three clients, and #3865 brings in the forge items.

## Today

- `ask_question`, `ask_secret` and `hand_to_person` make one `wire.ElicitationRequest` each (`Go/internal/agentsd/agenttools.go`, `secretask.go`, `handoff.go`). The daemon keeps it **in memory only** (`live.elicitations`). The tool call holds for 45 s (`formHoldLimit`). Then the agent can end its turn, and `elicitations/answer` starts it again with a prompt.
- A tool permission is a `wire.PermissionRequest`, also in memory, held by the runtime's callback.
- A guarded change (`approvals/answer`) is a folder-level approval: an MCP server, a workflow, a deploy.
- The attention layer (`attention.go`, `needs()`) derives a `wire.Need` from each of these. It keeps only the first-seen times, in `<root>/attention.json`.
- **Needs you counts sessions, not requests** (`waitingCount()`, `needsPersonCount`).
- **A session that waits holds a running place.** `helperRunning` counts `WaitingOnUser` and an open `EventWait`.
- The forge is **polled**, not watched by webhook (`Go/internal/githubmcp/events.go`, every 30 s by default). The `alex-todo`, `needs-account` and `needs-approval` labels are not read by the daemon at all.

So a restart loses every open question, nothing joins the app's requests to the forge's, and a lane that waits for Alex costs a place.

## 1. The record

```jsonc
// <root>/requests/<id>.json
{
  "id": "6f1c…",                 // UUID. For an app request, the same id as the ElicitationRequest or PermissionRequest.
  "kind": "decide",              // decide | approve | account | step | secret
  "source": "question",          // question | secret | handOff | permission | guardedChange | forge
  "state": "open",               // open | answered | dropped
  "title": "Which port for the scratch server?",  // one line, for the row
  "detail": { … },               // the part that depends on the source, below
  "folder": "file:///Users/…/Agents",
  "askedBy": "agent-uuid",       // the session that asked; null for a forge item nobody's session made
  "for": { "person": "people-id" },  // or { "group": "group-id" }; null = this machine's person
  "waiters": [ { "agent": "agent-uuid", "since": "2026-11-07T10:00:00Z" } ],
  "forge": null,                 // for a forge item, below
  "askedAt": "2026-11-07T10:00:00Z",
  "answeredAt": null,
  "answeredBy": null,            // a wire.AuditActor: person, client
  "answer": null,                // a summary for the transcript and the row; never a secret's value
  "droppedWhy": null             // askerEnded | folderArchived | forgeClosed | restarted | byPerson
}
```

### Kind and source

| Source | Kind | `detail` |
|---|---|---|
| `ask_question` | decide | the `ElicitationRequest` (its form, mode, message) |
| `ask_secret` | secret | the `ElicitationRequest` with its `secret` part: the name, never the value |
| `hand_to_person` | step | the `ElicitationRequest` with its `handOff` part: the step and the reason |
| tool permission | approve | the `PermissionRequest` (the tool call and its options) |
| guarded change | approve | the `ApprovalAnswer` key: folder, kind, key, digest |
| forge, `needs-approval` PR | approve | the PR's `## Screenshots` links |
| forge, `alex-todo` issue | step | the checklist |
| forge, `needs-account` issue | account | the checklist |

- **Decided: five kinds for the person and a separate source for the code, because** the row shows what the person must do (decide, approve, make an account, do a step, give a secret), and the answer path depends on where the request came from. Alex can overrule.
- **Decided: an app request keeps the id of the `ElicitationRequest` or `PermissionRequest`, because** then `NeedID.elicitation` and `NeedID.permission` stay the same, and the clients do not break while #3864 moves them. Alex can overrule.

### Waiters

- `waiters` lists every session that waits on the request. The asker is the first waiter.
- A second session joins with `wait_for_event` on `request.answered` with `where: {"request": "<id>"}` (or `{"pr": <n>}` for a forge request on that PR).
- When the request is answered or dropped, each waiter is woken once, and the list stays in the record as history.

### Forge part

```jsonc
"forge": {
  "provider": "github",          // github | gitlab | forgejo
  "repo": "alexec/Agents",
  "item": "issue",               // issue | pr
  "number": 1781,
  "url": "https://github.com/alexec/Agents/issues/1781",
  "label": "alex-todo",
  "checklist": [ { "text": "Sign in to gitlab.com", "done": false } ],
  "seenAt": "2026-11-07T10:00:00Z"   // the last poll that saw it open with the label
}
```

### Where it is kept, and the bound

- **One file a record**, `<root>/requests/<id>.json`, written atomically (temp, fsync, rename), as the other stores are. A record is small (a form and a checklist), so one file each is simple and safe.
- **The bound, enforced in code with a test** (the HADR rule "every store has a bound"):
  - an answered or dropped record is deleted **14 days** after it ended;
  - at most **1,000 files**. Above that, the oldest ended records go first. When all 1,000 are open, the daemon makes no new **forge** request (it logs once per poll), but it still makes app requests: each session holds at most one held form, so the sessions' own limit bounds those.
  - The daemon prunes at start and once an hour.
- **A secret's value is never in the record.** It goes to the Keychain, as `saveAskedSecret` does now. The record keeps the name.
- **After a restart:**
  - a question, a secret or a step stays open. Its held tool call is gone, so the answer starts the session again with the prompt it gets now when the form was left open (`formAnsweredWords`);
  - a tool permission is dropped (`restarted`): the runtime's callback is gone, and the runtime asks again when the session goes on;
  - a guarded change and a forge request stay open: their source is still there.
- `attention.json` stays for the sessions' needs (a report that needs an answer, a stopped session). The needs for requests come from the records.

## 2. The wire

All of these go in `Packages/Wire` first (`daemon.schema.json`, `daemon.openrpc.json`, `event-catalogue.json`), then `scripts/wire.sh gen`.

### Methods

| Method | Params | Result |
|---|---|---|
| `requests/list` | `{ state?: open\|ended\|all (default open), folder?, since? }` | `{ requests: [Request] }`: only the requests the caller can see (§5) |
| `requests/answer` | `{ id, answer }` | `{ request: Request }` |
| `requests/drop` | `{ id, why? }` | `{ request: Request }` |

`answer` is one of:

- `form`: the `ElicitationAnswer` that `elicitations/answer` takes now (decide, secret, step);
- `option`: a `PermissionOption` id (a tool permission);
- `approval`: `{ action: approve | changes, note? }` (a guarded change, a `needs-approval` PR);
- `checklist`: `{ done: [int] }`, the lines now ticked. When the last line is ticked, the request is answered.

A second answer to a request that has ended is refused with the record, so a client that was late shows what happened.

- **Decided: one `requests/answer` with a typed answer, not one method per kind, because** each client then has one path for every row, and the daemon already has the four answer paths to call. Alex can overrule.
- `elicitations/answer`, `permissions/answer` and `approvals/answer` call the same code. They stay until #3864 has moved the three clients, and a later task removes them (v0.x takes breaking changes).

### Notification

- `requests/changed` `{ request: Request }`, to every client that can see it, when a request is opened, answered, dropped or its waiters change. The clients keep the list from `requests/list` plus these.

### Events (for `wait_for_event` and workflows)

| Event | Payload | `where` keys |
|---|---|---|
| `request.opened` | `request, kind, source, folder, title, agent (asker), pr?, issue?` | `request`, `kind`, `folder`, `pr`, `issue` |
| `request.answered` | the same, plus `answered_by`, `answer` (the summary) | the same |
| `request.dropped` | the same, plus `why` | the same |

`agent.asked_form` and `agent.asked_permission` stay: workflows use them.

## 3. App requests: what changes for an agent

**Nothing, for the agent.** `ask_question`, `ask_secret` and `hand_to_person` take the same arguments and give the same results. The 45 s hold stays.

- The daemon opens the record in `showForm` and in `live.Permission`, before it broadcasts `agent/elicitation` or `agent/permission`. The answer paths end the record, and the record's end wakes the waiters.
- **The running place (#3863).** A session holds no running place when its turn has ended and all it waits on is open requests: a form it left open, or a `wait_for_event` whose patterns are all `request.*` (or all for-person, as #3051's `ForPerson`). `helperRunning` checks this. A session in a held tool call (the first 45 s) still holds a place: its turn is running.
- **An approval wait** (AGENTS.md, step 3 of "A UI enhancement waits for Alex") becomes `wait_for_event` on `request.answered` and `request.dropped` with `where: {"pr": <n>}`, in place of `pr.commented` and `pr.closed`. The lane reads the answer from the event (`approve` or `changes`, and the note), with no comment to parse. Until #3865 lands, `pr.commented` still works.
- When the asker ends or is archived, its own app requests are dropped (`askerEnded`, `folderArchived`). A forge request does not end with its asker.

## 4. Forge items

- **Polled, not by webhook.** The daemon already polls each folder's forge for events, and a Mac behind a home router has no public address for a webhook. Each forge poll that sees `issue.labelled`, `issue.unlabelled`, `pr.labelled`, `pr.unlabelled`, `issue.closed`, `pr.closed` or an edit to the body makes or updates the request at once. A **sweep** every 5 minutes lists the open items with the labels (`gh issue list --label`, and the same for GitLab and Forgejo), so the daemon finds the items that were there before it started and the edits that no event names.
- **Which labels count:** `alex-todo` and `needs-account` on issues, and `needs-approval` on PRs. The set is a constant in the daemon now.
  - **Decided: a fixed set of three labels, not a setting, because** only this folder uses them now, and a setting is easy to add when a second folder needs other names. Alex can overrule.
- **For whom:** the item's assignee, matched to a person by the sign-in login (`signIns[].login`, spec 736); with no assignee, or no match, this machine's person.
- **The checklist** is the list under the first `## What <name> does` heading (`- [ ]` and `- [x]` lines).
- **The answer goes back to the forge:**
  - a ticked line ticks the same line in the issue body;
  - the last line ticked unassigns the person and removes `alex-todo` or `needs-account`, as AGENTS.md says;
  - approving a PR posts the person's note (or "Approved in Agents") as a comment, as the person: it is Alex's comment, so it has no `<!-- agent -->`. It adds `approved` and removes `needs-approval`. "Changes" posts the note and adds `changes-wanted`.
  - The labels then mirror the request. A label set on the forge by hand still opens or ends the request at the next poll, so both places agree.
- **The forge ends a request** when the item closes (answered if all lines are ticked, else dropped with `forgeClosed`), or when the label is removed (answered).
- **The asker** of a forge request is the session that opened the item, when the lineage (spec 2348) names one; else none, and the row says the author.

## 5. A team

- `for` is one person (`{person}`) or a group (`{group}`), the people and groups of spec 736 (`people/<id>.json`, `groups/<id>.json`).
- **Who sees it:** the person, or each member of the group, and the folder's admins. `requests/list` and `requests/changed` filter by the caller's sign-in. With no people store (one person, signed out), `for` is null and every client of this machine sees every request, as now.
- **Who answers:** anyone who can see it. The first answer wins, and `answeredBy` keeps who answered and from which client (`wire.AuditActor`).
  - **Decided: anyone in the group can answer, and the first answer wins, because** a group request means "any one of us", and the record says who it was. Alex can overrule.
- An agent sets `for` with nothing new: an app request is for the folder's person. A later issue can let `ask_question` name a person or a group, when a team uses it.

## Not in this spike

The epic's own open questions stay open for Alex: whether a request times out to its recommended option, a daily digest, and the rules for a group beyond §5. The record leaves room for them (a `recommended` option and an `expiresAt` are new fields, not a change).

## Principles (`docs/explanation/direction.md`)

The records stay on the person's machine, in plain files with a bound. The forge sync uses the forge connection the daemon has now, with no new account and no public endpoint.
