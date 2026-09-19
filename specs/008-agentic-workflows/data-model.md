# Phase 1 Data Model: Agentic Workflows

Two halves, deliberately kept apart: what the repository holds, and what the app remembers. A workflow's *definition* is in the file and travels with the code. A workflow's *state* — paused, which agent is its standing one, what happened last — is the app's, and never written back, because writing it would raise a confirmation on every pause and fill the repository's history with state nobody wants to review.

---

## In `AgentsKitCore` — what both platforms can hold

### `Workflow`

One parsed file. Everything about what it does.

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | The file name without extension. Identity (FR-004). Renaming is deletion plus creation. |
| `folder` | `URL` | The project it belongs to, standardized by `Project.standardize`. |
| `name` | `String` | From front matter `name:`, else derived from `id`. |
| `triggers` | `[WorkflowTrigger]` | At least one. May include unrecognised ones. |
| `mode` | `WorkflowMode` | `new`, `standing` or `triggering`. Defaults to `new` when absent. |
| `prompt` | `String` | The body, verbatim, with the front matter stripped (FR-003). |
| `problem` | `WorkflowProblem?` | Set when the file could not be fully understood. `nil` on a good file. |
| `unknownFields` | `[String: JSONValue]` | Front-matter keys this version does not know, preserved on rewrite. |

Two derived properties the UI and the confirmation both read, so they cannot drift:

- `summary: String` — the trigger and mode in plain language. *"Every weekday at 9:00am, in a new agent."*
- `canFire: Bool` — false when `problem` is set or when no trigger is supported.

### `WorkflowTrigger`

```
enum WorkflowTrigger {
    case schedule(WorkflowSchedule)
    case agentFinished
    case agentAskedPermission
    case agentAskedForm
    case agentStopped
    case workflowCompleted(id: String?)   // nil = any workflow in this project
    case unrecognised(name: String, keys: [String: JSONValue])
}
```

`unrecognised` is the open case that lets the format grow (FR-013). The file and glob, git and GitHub triggers the spec defers are future cases here and nothing else.

Manual running is deliberately **not** a trigger. FR-012 makes Run now available on every workflow whatever its triggers, including one whose triggers are all unrecognised, so modelling it as a trigger would make it conditional on the thing it has to work around.

### `WorkflowSchedule`

| Field | Type | Notes |
|---|---|---|
| `minutes` | `Set<Int>` | Subset of `{0, 30}`. The half-hour granularity, enforced at parse. |
| `hours` | `ClosedRange<Int>` | Times of day the workflow may run, 0–23. |
| `days` | `Set<Weekday>` | Defaults to every day. |

Interpreted in the machine's current calendar and time zone on every evaluation, never precomputed (see [research.md §2](./research.md)).

**Rule**: `nextDue(after:)` is a pure function of schedule, date and calendar. It is the single unit under test for DST, time-zone moves and the empty-set cases.

### `WorkflowMode`

`new` | `standing` | `triggering`. An unknown value parses as a `problem` of kind `unsupportedMode`, not as a decode failure.

### `WorkflowOutcome`

What the last fire produced. The whole of user story 3 rests on this being a first-class value rather than the absence of one.

```
enum WorkflowOutcome {
    case ran(agentID: UUID, at: Date)
    case refused(WorkflowRefusal, at: Date, repeats: Int)
}
```

`repeats` is how a fortnight of missed fires stays one line (FR-030). It increments when the incoming refusal has the same reason as the stored one; any different reason, or a run, replaces the value and resets it to 1.

### `WorkflowRefusal`

The enumeration FR-026 requires, closed and exhaustive:

| Case | Raised when |
|---|---|
| `chainTooDeep(depth: Int)` | The fire would exceed the depth limit |
| `runInFlight` | The previous run has not finished |
| `paused` | This workflow, or its project, is paused |
| `unreadable` | The front matter could not be read |
| `triggerNotSupported(name: String)` | Every trigger is unrecognised |
| `agentUnavailable` | `triggering` mode, and the agent can no longer take a prompt |
| `noTriggeringAgent` | `triggering` mode fired by a schedule or by hand |
| `missedWhileClosed` | The due time fell in a gap where the daemon was not running |
| `folderGone` | The project folder is not there |

Each carries a plain-language `message` for the row and for the agent, in the voice `showFile`'s refusals already use.

### `WorkflowRun`

One firing. Lives only while in flight; it is not a history (only the latest outcome is kept — see the spec's Assumptions).

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `workflowID` | `String` | |
| `folder` | `URL` | |
| `trigger` | `WorkflowTrigger` | What actually fired |
| `triggeringAgentID` | `UUID?` | Set for lifecycle triggers |
| `depth` | `Int` | See below |
| `agentID` | `UUID?` | Filled once the agent is started or resumed |
| `startedAt` | `Date` | |

### Chain depth

The rule in one sentence (FR-021): **a fire caused by a schedule, by a manual run, or by an agent nobody automated is depth 0; any other fire is one deeper than the run that caused it.**

Mechanically: the daemon carries `startedByRun: UUID?` on each agent it starts from a workflow, and each run's depth. A lifecycle trigger looks up the triggering agent's originating run; a `workflowCompleted` trigger looks up the completing run. Absent either, depth is 0. `depth > limit` (default 3) refuses with `chainTooDeep`.

### `WorkflowSummary`

What the daemon broadcasts and the project page renders. Definition plus state, resolved, so two windows cannot disagree — the same reasoning that puts names and counts on `ProjectSummary`.

| Field | Type |
|---|---|
| `workflow` | `Workflow` |
| `isPaused` | `Bool` (this workflow, or its project) |
| `nextFireAt` | `Date?` (nil when it has no schedule) |
| `lastOutcome` | `WorkflowOutcome?` |
| `isRunning` | `Bool` |

`id: String { workflow.folder.path + "/" + workflow.id }` — unique across projects, so one window showing two projects cannot collide.

---

## In `AgentsKit` — the Mac's half

### `WorkflowState`, persisted

One JSON file at `root/workflows.json`, following `projects.json` exactly: one file, because the only things in it are the few a workflow's file cannot tell us.

| Field | Type | Notes |
|---|---|---|
| `folder` | `URL` | |
| `workflowID` | `String` | |
| `isPaused` | `Bool` | |
| `standingAgentID` | `UUID?` | Adopted on first fire in `standing` mode |
| `lastFiredAt` | `Date?` | What `nextDue` is measured against |
| `lastOutcome` | `WorkflowOutcome?` | With its repeat count |

Plus two file-level values:

- `pausedProjects: Set<URL>` — project-wide pause (FR-024).
- `lastTickAt: Date?` — the heartbeat that makes `missedWhileClosed` decidable ([research.md §3](./research.md)).

### Changes to existing types

| Type | Change | Why |
|---|---|---|
| `Agent` | `+ startedByWorkflow: String?`, `+ startedByRun: UUID?` | FR-019 (the agent list names the workflow) and FR-021 (depth) |
| `StoreLocations` | `+ var workflows: URL` | `root/workflows.json` |
| `AppTool` | `+ static let manageWorkflows` | The third tool's name |
| `PermissionRequest` | `+ var isAutoAllowable: Bool` | Narrows `autoAllowed` to suggest and show-file only |

`Agent.unknownFields` means older records decode without migration, and the two new fields are optional, so nothing needs rewriting on upgrade.

---

## Lifecycle

### A workflow's

```
file appears ──▶ parsed ──▶ listed (canFire? scheduled : inert)
                   │
                   ├─ unreadable ────▶ listed with the problem, never fires
                   └─ file removed ──▶ delisted; its standing agent stays as an ordinary agent
```

### A fire's

```
trigger matches
      │
      ▼
  may it fire?  ──no──▶ WorkflowOutcome.refused(reason)  ──▶ persist ──▶ broadcast
      │ yes                                                   (repeats++ if same reason)
      ▼
  resolve the agent by mode
      │  new       → start a fresh agent
      │  standing  → resume the standing agent, or start and adopt one
      │  triggering→ resume the triggering agent, or refuse agentUnavailable
      ▼
  WorkflowRun in flight  ──▶ agent finishes ──▶ outcome .ran ──▶ persist ──▶ broadcast
                                                     │
                                                     └─▶ may fire workflowCompleted triggers, depth+1
```

**Ordering rule**, inherited from `record(_:for:)`: persist first, then broadcast. A daemon killed mid-fire leaves something true behind.

**The check is pure.** "May it fire?" takes the workflow, its state, the project's pause set, the proposed depth and the current date, and returns an outcome. No file system, no actor, no clock of its own — which is what makes the whole of FR-021 through FR-026 a table test in `WorkflowOutcomeTests`.

---

## Validation rules, traced to requirements

| Rule | Requirement |
|---|---|
| A workflow with no `on:` key is `unreadable` | FR-005, FR-006 |
| Schedule minutes outside `{0, 30}` are rejected at parse | FR-008 |
| Unknown trigger names parse to `unrecognised`, never to a failure | FR-013 |
| Unknown front-matter keys are preserved and round-trip on rewrite | FR-005 |
| `triggering` with no triggering agent refuses, never substitutes | FR-017, FR-018 |
| `standing` with a lost agent starts a fresh one and adopts it | FR-016 |
| One fire per firing event, however many triggers match it | FR-011 |
| Every path that does not produce an agent produces a `WorkflowRefusal` | FR-026, SC-003 |
| Pausing writes only to `workflows.json`, never to the repository | FR-024 |
| The tool refuses any path outside the calling agent's `.agents/workflows` | FR-037 |
