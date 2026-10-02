# 099: Finer event matching for triggers and waits

2026-10-02, branch `agents/work-github-issue-99` off main at 55874325. This covers issue #99. It is review and design only; nothing is built.

**Method**: I read `EventPattern`, `EventCatalogue`, `WorkflowTrigger` and `WorkflowTriggerWords`, every `raise(` and `raiseAgentEvent(` in the daemon, the three places that read filters (the workflow file, the wait tool and the wire), the Mac workflow page's Triggers section (#98), the web page's trigger words, and `docs/reference/workflows.md` and `events.md`. The control plane raises no catalogue events. Its `ControlEvent` is a different thing: it copies pairing and enrolment between control-plane copies.

## Summary

- **The details are the real gap, not the matcher.** Of the 14 triggers in [§2](#2-triggers-people-would-write), 11 can't be written with *any* matcher today, because the event doesn't carry what they filter on. Examples are labels, runtime, who started the agent, and whether it was parked. Most of these details are one line each to add, in `agentDetails`.
- **Three details are sentences, not codes.** These are `agent.failed reason`, `agent.stopped by` and `workflow.refused reason`. A filter has to match the exact English, such as `reason: "rate limited, and still limited after retrying"`. Nobody writes that, so "failed with a quota reason" can't be said today.
- **A list in a filter is treated three ways today.** The workflow file refuses it ("should be one value"). The wait tool's `where` and the wire decoder **drop it silently**, so the wait or trigger becomes wider than what was written. The web page drops it too.
- **Recommendation**: richer filter values (option A) with set-valued labels, and no expression language.
  - **First step**: add agent context to agent events (`labels`, `runtime`, `started_by`), add `afterwards` to `agent.finished`, turn the three sentence details into codes, and allow a list to mean "any of", checked against each detail's known values. This makes 9 of the 14 triggers writable.
  - **Second step**: negation and globs.

## How matching works today

- `EventPattern` is a name (or `subject.*`) plus `filters: [String: String]`. `matches` asks the name, then `filters.allSatisfy { event.details[key] == value }`. This is exact string equality, and a detail that is missing never matches (`EventPattern.swift:27-34`).
- `parse` checks only the **keys**. A filter key must be in the kind's `details`, or for `subject.*` in the details of any kind in that subject. A **value** is never checked. `outcome: complete` parses, and then silently never fires, because the code is `done`.
- **Filters are read in three places, and each treats a list differently:**
  - The workflow file (`WorkflowFile.swift:241-246`) throws `The "outcome" under "agent.finished" should be one value`. So no file on disk has a list today, which means giving lists a meaning breaks nothing.
  - The wait tool's `where` (`AppService.swift:470-478`) keeps only strings, numbers and booleans. An array is **dropped without a word**: `where: {"outcome": ["done","nothing_to_do"]}` waits for *every* outcome.
  - The wire (`WorkflowTrigger.swift:156`, `compactMapValues(Self.scalar)`) drops it the same way. So does the web page (`Web/src/model/workflows.ts:69`).
- **Copy as trigger** (`EventPattern.matching`) copies every detail the kind lists, `agent` included. A trigger copied from an `agent.finished` row therefore fires only for that one agent's id. Adding context details would make the copy narrower still.
- **Old trigger names** (`agent-finished` and the rest) don't go through `EventPattern.matches`. They fire from `workflowsRespond` and take no filters, so narrowing is only for dotted names. That is fine, and the docs already point people to `agent.finished`.
- **Events never leave their host.** Each host's agentsd raises its own events, keeps its own log and matches them against its own waits and workflows (`DaemonCore+Events.swift:17`). So a `host` detail would never narrow anything: every event a workflow hears is already from its own host.
- **Scope**: a project event reaches only that project's workflows and waits. A Mac event reaches every project on that host.
- **When `agent.finished` is raised relative to parking.** `move` decides parking (`DaemonCore.swift:871-887`) before it raises the ending (`:953`). It raises `agent.parked` straight after (`:968`). So when `agent.finished` is raised, the daemon **already knows** whether this ending parks the agent. Archiving is never part of an ending: an agent can't archive itself (the ask is dropped). An agent is archived later, by the person or by its starter, as its own move, so "finished, then archived" can only be known from `agent.archived`.
- `agent.parked` raised by `park()` (`DaemonCore+Commands.swift:1720`) carries no `by`. `agent.archived` carries `by: you | another agent`.

## 1. The catalogue, event by event

"Context" means one shared set of agent details, added in `agentDetails(_:)` (`DaemonCore+EventWaits.swift:338`), so that every event about an agent carries it the same way:

| Context detail | From | Values |
|---|---|---|
| `labels` | `agent.labels` | A **set** of normalised label keys. Labels can't contain commas (the tag field splits on them), so on the wire it is one comma-joined string. |
| `runtime` | `agent.runtimeID` | `claude`, `codex`, `gemini`, … |
| `model` | `startOptions.values["model"]` | The runtime's own model id. It is missing when the agent uses the runtime's default. |
| `started_by` | `startedByWorkflow` / `startedByAgent` / neither | `person`, `workflow`, `agent` |
| `workflow` | `startedByWorkflow` | A workflow id, only when `started_by: workflow`. It is the same key and the same meaning as on `workflow.*`, so `agent.*` with `workflow: nightly` reads naturally. |
| `branch` | `agent.worktree?.branch` | Only in a worktree. It is the same key as `branch.moved`'s. |
| `worktree` | `agent.worktree?.name` | Only in a worktree. |

`host` is left out, for the reason given above. It could go on `agent_title`'s side as a detail you can read but not filter on, if the log is ever merged across hosts.

| Event | Carries now | Could usefully carry | Missing or wrong |
|---|---|---|---|
| `agent.started` | `agent` | context | — |
| `agent.finished` | `agent`, `outcome` | context; **`afterwards: park \| stay`**, which is known at raise time (see above) | `outcome` is missing when there was no report. Archived can't be known here; use `agent.archived` |
| `agent.asked_permission` | `agent` | context; later, `tool` (the kind of call) | — |
| `agent.asked_form` | `agent` | context | — |
| `agent.blocked` | `agent`, `waiting_on` | context; `on: agents \| event \| time` | `waiting_on` is a sentence of quoted titles, from two places (`AppTools:303`, `EventWaits:218`) |
| `agent.stopped` | `agent`, `by` | context | **`by` is a lowercased sentence** ("stopped by you", "reached its cost limit", "stopped"). It should be a code: `you`, `agent`, `cost_limit`, or `unknown` when no reason was given |
| `agent.failed` | `agent`, `reason` | context | **`reason` is a lowercased sentence.** It should be the `EndedReason` code: `allowance_spent`, `rate_limited`, `process_died`, `sign_in_refused`, `runtime_error`, `sandbox_failed`, `max_tokens`, `refusal`, … |
| `agent.parked` | `agent` | context; **`by: you \| agent`** (the agent's own `afterwards`) **`\| ending`** (a park asked for while a turn was running); `outcome` of its last report | `by` is missing, unlike `agent.archived` |
| `agent.archived` | `agent`, `by` | context; `outcome` of its last report | `by` is `you \| another agent`; as a code it would be `you \| agent`, to match the others |
| `agent.retired` | `agent`, `because` | `labels`, `runtime`, from the tombstone | — |
| `workflow.ran` | `workflow`, `agent` | `runtime`, `model`; **`cause: schedule \| event \| by_hand`** | — |
| `workflow.completed` | `workflow`, `agent` | **`outcome`** of the run's agent | Without `outcome`, "nightly finished stuck" can't be said |
| `workflow.refused` | `workflow`, `reason` | — | **`reason` is `refusal.message`, a sentence.** It should be the `WorkflowRefusal` case: `run_in_flight`, `chain_too_deep`, `over_limit`, `awaiting_approval`, `agent_unavailable`, `no_triggering_agent`, `folder_gone`, `day_limit_reached`, `unreadable`, `trigger_not_supported`, `setting_refused`, `missed_while_closed`, `archived`. `disabled` and `cooling_down` are never raised |
| `branch.moved` | `branch`, `from`, `to` | `default: true \| false`; `agent` when it is an agent's worktree branch | A glob on `branch` is the common need |
| `lease.granted` | `resource`, `agent` | context | — |
| `lease.released` | `resource`, `how` | **`agent`** (the holder) | It has no agent, so a `triggering` workflow can't resume the holder |
| `mac.sleep`, `mac.wake` | — | — | — |
| `person.away`, `person.back` | `why` | — | — |
| `cost.limit_reached` | `limit`, `agent`? | context when it is an agent's | — |
| `cost.allowance_out` | `runtime`, `until`, `retry_after`, `reason` | — | — |
| `cost.allowance_back` | `runtime`, `how` | — | — |
| `server.offline`, `server.online` | `server` | — | — |
| `custom.*` | the publisher's details | — | A publisher's own detail called `labels` or `runtime` would collide with context keys if context were ever added. Leave custom events without context, as the publisher is in `event.publisher`, not in the details |

**Events that are missing:**

- **`agent.labelled`**, with `label`, `change: added | removed` and `by: you | agent`. This is the one worth adding: "when I label an agent `ship`, start the release workflow". It is a later step, not part of this matcher work.
- `agent.unparked` and `agent.unarchived` are low value. Nobody asked for them.
- **Should any events merge into one with a detail?** No. `agent.finished`, `agent.stopped` and `agent.failed` are shipped and have aliases. `agent.parked` and `agent.archived` shipped in #96. `agent.*` with a filter already gives "one event with a detail" when someone wants it.
- A cooldown hold is deliberately not raised (#103), and stays that way.

## 2. Triggers people would write

These are the test set. Each line gives the details it needs, and whether **today**'s catalogue carries them.

| # | In words | Needs | Today |
|---|---|---|---|
| T1 | Every finished agent labelled `bug` that was parked | `agent.finished` + `labels` has `bug` + `afterwards: park` | ✗ no labels, no afterwards |
| T2 | Any Claude agent that failed with a quota reason | `agent.failed` + `runtime: claude` + `reason` ∈ {`allowance_spent`, `rate_limited`} | ✗ no runtime; reason is a sentence |
| T3 | Workflow `nightly` refused on this host | `workflow.refused` + `workflow: nightly` | ✓ in `nightly`'s own project. Every event is from its own host. Another project can't hear it (scope, not matching) |
| T4 | Any agent that finished with `done` or `nothing_to_do` | `outcome` any-of | ✗ no lists |
| T5 | Any agent that finished but not `done` | `outcome` not `done` | ✗ no negation |
| T6 | An agent a workflow started failed | `agent.failed` + `started_by: workflow` | ✗ no started_by |
| T7 | An agent not labelled `wip` asked for permission | `agent.asked_permission` + labels lacks `wip` | ✗ no labels, no negation |
| T8 | Any `release/*` branch moved | `branch.moved` + glob | ✗ no glob |
| T9 | `nightly` completed and its agent ended `stuck` or `partly_done` | `workflow.completed` + `workflow` + `outcome` any-of | ✗ no outcome on the event, no lists |
| T10 | I archived an agent labelled `bug` or `regression` | `agent.archived` + `by: you` + labels any-of | ✗ no labels |
| T11 | An agent working on an `agents/work-github-issue-*` branch finished | `agent.finished` + `branch` glob | ✗ no branch, no glob |
| T12 | The simulator lease ran out on someone | `lease.released` + `resource: simulator` + `how: expired` | ✓ |
| T13 | An agent labelled both `bug` and `p1` finished | labels all-of | ✗ |
| T14 | An agent on Gemini or Grok failed, except a refused sign-in | `runtime` any-of + `reason` not `sign_in_refused` | ✗ |
| W1 | *(a wait)* "Wake me when any agent labelled `deploy` finishes `done`" | `wait_for_event agent.finished where {labels: deploy, outcome: done}` | ✗ no labels |

## 3. The matcher options

The **one matcher rule** holds for all three options. `EventPattern` keeps being what a wait and a trigger are made of, and `matches` stays the only place that decides. What changes is what a filter holds: `[String: String]` becomes `[String: EventFilter]`.

### Option A: richer filter values

```yaml
on:
  - agent.finished:
      labels: bug                    # a set detail: has bug
      afterwards: park
      outcome: [done, nothing_to_do] # a list: any of these
  - agent.failed:
      runtime: claude
      reason: [allowance_spent, rate_limited]
  - branch.moved:
      branch: release/*              # * is a glob
  - agent.asked_permission:
      labels: "!wip"                 # ! is not
```

- **A scalar** means equals, as today. On a **set** detail (`labels`), it means "has".
- **A list** means any of these. On a set detail, it means "has any of these".
- **`!` before a value** means not: `"!done"`, or `["!stuck", "!partly_done"]` for none of these. A list that mixes `!` and plain values is a parse error. A `!` filter on a detail that is **missing** matches, because an agent with no report has no outcome, and that is "not `done`".
- **`*` in a value** is a glob over the whole value, and nothing else (no `?`, no classes). Git forbids `*` in a branch name, and every closed vocabulary is codes, so only custom details could have held a literal `*`. Those can escape it as `\*`.
- **YAML caveat**: in real YAML, an unquoted leading `!` is a tag and a leading `*` is an alias. Our `YAMLNode` subset reads both as plain text, but editors and linters will complain. Copy as trigger and the page's writers quote them already (`yamlScalar` quotes anything outside `[A-Za-z0-9_./-]`), and the docs should show `"!wip"` quoted.
- **Against the triggers**: T1, T2, T4–T12, T14 and W1 all work. **T13 (all-of) doesn't**, because one key can hold only one list, and a list means "any of".

### Option B: set filters for labels

Option B adds `labels: [bug, p1]` for "has all" and `labels_any: [bug, regression]` for "has any". On its own, it doesn't help T2, T4, T5, T8, T9, T11 or T14. It also gives a list two meanings: all-of under `labels`, but any-of under `outcome` in option A. The page would then have to say "bug and p1" for one and "done or nothing_to_do" for the other, from the same YAML shape. It is worth keeping only as the **way to say all-of** on top of A: one extra key, `labels_all:`, instead of reversing what `labels:` means. If T13 is rare, even that can wait.

### Option C: a small expression language

```yaml
on:
  - agent.finished:
      when: outcome in [done, nothing_to_do] and "bug" in labels and afterwards == park
```

- **What it adds**: everything A does, plus all-of (`"bug" in labels and "p1" in labels`) and OR across different keys. A trigger already ORs by listing several entries under `on:`, so the only new power is OR inside one event. None of the 14 triggers needs that.
- **What it costs**:
  - A tokenizer and parser, with errors that point at a column.
  - Turning a tree back into words for the summary and the Triggers section.
  - A string form for the wait tool's `where`, which agents would get wrong more often than an object.
  - A `when:` that older daemons reject, as they already reject any detail they don't know. A file using it is listed as unreadable on an older daemon, the same as A's lists.
- **Against the triggers**: all of them, at several times the cost of A, for one trigger (T13) that A plus `labels_all` also covers.

### Each option against the constraints

| | A: richer values | B: set keys alone | C: `when:` |
|---|---|---|---|
| Triggers covered (with the new details) | 13/14 (14/14 with `labels_all`) | 4/14 | 14/14 |
| Older files keep their meaning | Yes. No file can hold a list today, so lists are new. A value starting with `!` or holding `*` changes meaning, and only a custom detail could have one | Yes | Yes |
| One matcher | Yes, in `EventFilter.matches(detail:)` | Yes | Yes, but the evaluator becomes the matcher |
| How `parse` errors read | Close to today's: a bad key, a bad value, or a mixed list (below) | The same as today | New: syntax errors with a position |
| Words on the page | Easy, per key (below) | Easy | Needs a tree-to-words pass |
| Wait tool's `where` | Lists become JSON arrays, the obvious thing | The same | A string expression |
| Older Mac, phone or web page reading the wire | The filter is dropped, so the page shows the trigger wider than it is. Display only: firing is the daemon's | The same | It shows the trigger with no filters |

### `parse` errors, as the agent or the page would read them

These keep the current shape of a sentence that lists what would have been right:

- **A bad key** (as today, with a guess): `agent.finished carries agent, afterwards, branch, labels, model, outcome, runtime, started_by, workflow, worktree; "lables" is not one of its details. Did you mean labels?`
- **A bad value on a detail with known values** (new, from a `values` list on each catalogue detail): `outcome on agent.finished is one of done, nothing_to_do, needs_answer, partly_done, stuck, blocked; "complete" is not one of them.` This fixes today's silent `outcome: complete`. Custom details, labels, branches, models and other open values are not checked.
- **A mixed list**: `A list under outcome either names values it may have or, all with !, values it must not have; not both.`
- **A list in a file on an older daemon**: unchanged, `"outcome" under "agent.finished" should be one value`. This is the honest failure on a downgrade.

### Words

- **`summary`** (the project page, Triggers section, web page and phone) says each key with its own phrase, kept on the catalogue detail, and falls back to today's "key value":
  - `labels`: "labelled bug", "labelled bug or regression", "not labelled wip"
  - `runtime`: "on Claude", "on Gemini or Grok" (with `PoolWords.runtimeName`)
  - `outcome`: "done or nothing to do", "not done"
  - `afterwards: park`: "and parked"
  - `started_by: workflow`: "started by a workflow"
  - `reason`: the `EndedReason`'s `summary`, lowercased, "its allowance ran out or rate limited"
  - `branch: release/*`: "a branch matching release/*"
  - So T1 reads: *When an agent in this project ended a turn having done its work (labelled bug, and parked)*.
- **`label`** (the status line and the run's cause): `agent.finished labels bug afterwards park outcome done|nothing_to_do`. A list is joined with `|`, and `!` is kept.
- **`asTrigger`**: a list in flow style `[done, nothing_to_do]`, and `!` or `*` values quoted.
- **Copy as trigger**: copy the kind's **own** details (`outcome`, `reason`, `by`, `afterwards`), not the context. Today it also copies `agent`, which pins the trigger to one agent; that is in Decisions.

### The Triggers section (#98)

Today it shows one `key: value` capsule per filter (`WorkflowPage.swift:303-312`). With option A, each capsule says the filter in the same short form as `label`: `outcome: done | nothing_to_do`, `labels: not wip`, `branch: release/*`. The summary line above it carries the words.

Three readers have to change together, so the page never shows a wider trigger than the file says:

- `WorkflowTrigger.filters` (`[String: String]` today)
- the web `triggerSummary` (`workflows.ts:69`)
- the generated `EventPattern.filters` type (`generated.ts:561`)

### Storage and the wire

- **Encoding**: `EventFilter` encodes as a **plain string** when it is one positive value, so every pattern written today round-trips byte for byte. This matters because `EventPattern` is saved inside `EventWait` on agent records and inside `WorkflowCause`, and a downgraded build must still read them. It encodes as an array only when it is a list or holds `!`.
- **Catalogue**: `EventKind.details` gains a per-detail description: its name, whether it is a set, its known values if any, and its phrase. `describe()` and `docs/reference/events.md` list the known values.
- **The wire**: event details stay `[String: String]`, and `labels` is comma-joined. `Event` doesn't change shape.

## 4. Recommendation

**Option A, built in two steps.** Option B stays only as `labels_all:`, if asked for. Option C isn't built: none of the triggers needs OR across keys that listing two `on:` entries doesn't already give.

**Step 1, the smallest one worth building.** It makes T1, T2, T4, T6, T9, T10, T12, T14 (minus the "except") and W1 writable, and stops three silent failures:

1. Add `labels`, `runtime` and `started_by` to `agentDetails`, so every `agent.*` event, `lease.granted` and `cost.limit_reached` carries them. Mark `labels` as a set detail.
2. Add `afterwards: park | stay` to `agent.finished` (it is already known when it is raised), and `outcome` to `workflow.completed`.
3. Turn `agent.failed reason`, `agent.stopped by` and `workflow.refused reason` into codes. `parse` maps an old sentence value to its code, so a file or wait that matched the sentence still matches. The event's `sentence` keeps the words.
4. A list means any of. That covers the file, the wait tool's `where` (no more silent drop) and the wire. Each catalogue detail gets its known values, checked by `parse`.
5. Update `summary`, `label`, `asTrigger`, the Triggers capsules, the web `triggerSummary` and `events.md`, together.

**Step 2:**

- `!` for not, and `*` globs, for T5, T7, T8, T11 and T14 whole.
- `model`, `branch`, `worktree` and `workflow` context.
- `by` on `agent.parked`, and `agent` on `lease.released`.

**Later, separately:** `agent.labelled`, and `labels_all:` if T13 turns out to be wanted.

## Decisions for Alex

1. **What does a list under `labels` mean?** I recommend "has any of these", the same as every other list, with `labels_all:` added only if needed. The alternative is "has all of these", which reads naturally for labels but gives a list two meanings.
2. **Turn sentence details into codes** (`agent.failed reason`, `agent.stopped by`, `workflow.refused reason`), with old sentence values mapped by `parse` so they keep matching? I recommend yes. The alternative is to leave them as they are and add new code keys beside them, such as `reason_code`.
3. **Should Copy as trigger stop copying `agent`?** Today it pins a copied trigger to the one agent on the row, which is rarely what a workflow wants. It is a change to shipped behaviour.
4. **Should "workflow X refused" be heard from other projects?** Project events only reach their own project (T3). A trigger-level `in: this host` would let one watcher workflow hear every project's refusals. That is a scope change, separate from matching. I recommend not now.
