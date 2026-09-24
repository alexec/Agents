# Research: What Survives a Restart

Everything below was settled by reading the code that exists, not by choosing a
technology. There is no new dependency in this feature and no unknown left over.

---

## 1. Where the attention notes go

**Decision**: a new file, `attention.json`, under the daemon's root, beside
`projects.json`, `workflows.json` and `devices.json`. Read whole, written whole, the
daemon its only writer.

**Rationale**: the three files already there establish the pattern for "what the daemon
has to remember about itself that is not an agent", and each of them is tens of entries
for one person, changed when something happens rather than continuously. Outstanding
needs are a handful at most. `cat` shows it to you, which is how every other piece of this
bookkeeping is debugged.

**Alternatives considered**:

- *Inside `devices.json`*. Rejected: a delivery to the Mac is not a fact about a device,
  and folding it in would make the device file two things.
- *On the agent record*. Rejected for two reasons. `reconsider()` would write one agent
  record per outstanding need per pass, and a report need's identity includes the report's
  timestamp rather than the agent's — an agent is not the key.
- *One file per need*. Rejected: an agent's directory earns that shape because a transcript
  is appended to for hours. These are a handful of lines that change together.

---

## 2. When it is written

**Decision**: written from `reconsider()`, but only when the content actually moved —
compared against the last written copy, exactly as `reconsider()` already compares before
it broadcasts.

**Rationale**: `reconsider()` is not a rare call. It runs on every state change through
`move`, on every question held or answered, and on **every presence report** — which
arrives periodically from every window and every device. Writing a file on each would put
a synchronous write in a path that runs several times a second with nobody doing anything.

The comparison is free: `Delivery` and the raised-at map are already `Hashable`, and
`reconsider()` is already the function that knows whether anything changed.

---

## 3. Making `Delivery` storable

**Decision**: add `Codable` to `Delivery`. `NeedID` and `Surface` are already `Codable`,
both as tagged objects chosen so a case added later is additive.

**Rationale**: no new type is needed. `Delivery` holds exactly the four things FR-001
names — which need, where, when last alerted, how many times — and nothing about what the
need says. FR-007 is satisfied by the existing shape rather than by a new one: the
headline lives in `Need`, which is derived and never stored.

---

## 4. Withdrawing a need the daemon no longer has

**Decision**: no new mechanism. The notes are loaded before the first `reconsider()`, and
that function's existing first loop — "for every delivery whose need is no longer
outstanding, withdraw it and forget it" — does the whole of FR-004 with a pre-populated
dictionary.

**Rationale**: FR-012 of feature 021 says one place decides where a need goes and no
surface may decide for itself. Adding a second, restart-only withdrawal path would be a
second decider. Loading the dictionary and letting the existing loop run is the same rule
applied to facts that now survive.

**Consequence**: `recover()` must be followed by a `reconsider()` even when no agent
changed state, because with no live agents nothing else calls it.

---

## 5. The withdrawal has to outlive the moment it is decided

**Decision**: a note is kept in the file, marked as withdrawing, until the withdrawal has
actually been handed to somebody — and retried on each `reconsider()` and whenever a
connection appears. Dropped once handed over, once its device is unknown, or after seven
days.

**Rationale**: this is the one place where the obvious implementation is wrong, and it is
worth writing down why. A withdrawal for a device goes out as a `mailbox/post`
notification for the bridge to carry into CloudKit. `DaemonCore.broadcast` returns doing
nothing when no broadcaster is set, and the bridge reconnects on a five-second loop, so a
withdrawal decided in the first moments of a daemon's life is very likely shouted into an
empty room. The bridge's own comment says it plainly: *"Nothing here is retried across a
restart: a post that was lost while the bridge was down is posted again by the daemon's
next decision."*

For every other post that is true. For this one there is no next decision — the need is
gone forever, and if the post is lost the banner stays on the phone until the device next
connects directly. That is precisely the failure US2 exists to fix, so the retry has to
live somewhere, and the file is where.

Seven days matches the spend ledger's horizon and exists so this cannot become a queue
that grows forever.

**Alternatives considered**:

- *Decide the withdrawal later, once something is connected*. Rejected: it makes the
  decision depend on who is listening, which is the property FR-012 of 021 protects.
- *Have the device acknowledge*. Rejected: the mailbox is deliberately one-way, and the
  device already sweeps on connect. This retry is the belt; that sweep is the braces.

---

## 6. Where the workflow runs go

**Decision**: into `workflows.json`, as a `runs` array on the existing records, beside
`states` and `lastTickAt`.

**Rationale**: `WorkflowRun` is already `Codable` and already carries everything needed —
which workflow, which folder, which trigger, which agent, how deep, when it started. The
file is already loaded whole and saved whole on every fire. `lastTickAt` set the precedent
for "something in here that belongs to no single workflow".

---

## 7. When the runs are loaded back

**Decision**: **before** `recover()`, not in `startWorkflows()`.

**Rationale**: this is the ordering trap in the feature. `Daemon.start()` runs
`holdWorkflowEventsUntilStarted()`, then `recover()`, then `startWorkflows()`. Recovery
moves every working agent to stopped, and `move` defers each lifecycle event **with its
depth computed at that moment** — `deferredLifecycleEvents.append((event, agentID, depth ??
workflowChainDepth(causedBy: agentID)))`. If the runs are not in memory by then, every
deferred event is recorded at depth zero and the ceiling is lost exactly when this feature
claims to save it.

Loading the runs needs nothing but the file, so it can happen first. Pruning them — a run
whose agent is gone, or whose workflow file has been deleted — needs the agents and the
workflows, so it happens in `startWorkflows()`, after both.

---

## 8. Recovery already holds the run open, and that is correct

**Finding, not a decision**: `move` on `.foundDead` breaks out of its lifecycle branch
before reaching `workflowRunFinished` when the agent may be picked back up. So an agent
carried across a restart does not release its run on the way through recovery — the run
stays in flight and is released when the agent really finishes.

This is why persisting the run is the whole of US3: the code around it already behaves as
though the run were still there. Only the dictionary was missing.

---

## 9. What the conversation says, and how the daemon knows to say it

**Decision**: a `runtimeNote`, with its wording a constant on `RuntimeNote` beside
`stoppedWithDaemon`. Not a new `TranscriptEntry.Kind`.

**Rationale**: three reasons, in order of weight.

1. A build that predates this feature reads a `runtimeNote` and draws it. A new kind
   decodes as `unrecognised` and draws as nothing, which for a line whose whole job is to
   be read back months later is the wrong trade.
2. `runtimeNote` is already the app's own voice, which is FR-017 exactly. The alternative
   of reusing `permissionAnswered` renders as "You chose …" and would put words in the
   person's mouth.
3. It is not a *passing* note. `RuntimeNote.isPassing` names three notes that the chat
   drops once superseded; this one is not among them and must not be added to it. What it
   records is permanent.

**How the daemon knows, after a restart**: it does not need the question. The agent's
state before recovery says it — `waitingOnUser` is the state a held permission or form
puts an agent into, and `recover()` already captures that state in `interrupted`. The line
goes into the transcript immediately after the `permissionAsked` or `elicitationAsked`
entry it is about, so position says which question without naming it.

For the two live paths — the runtime exiting, and the person stopping the agent — the
daemon still has the pending dictionaries and knows exactly which questions died.

---

## 10. Drafts: where, and what they can hold

**Decision**: `UserDefaults`, one entry per draft, JSON-encoded. The model and the store go
in `AgentsKitCore` so they can be tested; the app injects its defaults, as `SidebarFrame`
already does.

**Rationale**: `UserDefaults` is where this window already keeps what it knows — the
selected project, the sidebar's width and pane, the remembered mode per runtime. The
daemon's directory is not an option: its README promises the daemon is that directory's
only writer, and FR-024 says a draft is not the work.

Putting the type in `AgentsKitCore` rather than in `App/Sources` is what makes it testable
at all: the only test target wired into the schemes is the package's, so anything in
`App/Sources` is covered by nothing.

**The one real limit**: an attachment can be a pasted image, which is bytes by value, and
`UserDefaults` is not where megabytes belong. So inline data is capped per draft. Over the
cap, the text and every by-reference attachment are still kept and the inline blocks are
not. A restored draft that has lost a pasted screenshot says so where the strip is drawn,
rather than pretending.

**Alternatives considered**:

- *`@SceneStorage`*. Rejected: it is per-scene, which is the behaviour FR-023 was amended
  away from, and it is meant for small plist values, which an attachment is not.
- *Spilling attachment bytes to files of our own*. Rejected for this feature: it is a
  directory to create, prune and clean up after, for the P3 story in the list. The cap is
  honest and can be replaced later without changing anything else.

---

## 11. Two windows, and what the spec assumed

**Finding**: `AgentsApp` holds `@State private var model = AppModel()` outside its
`WindowGroup`, so one model serves every window — the selected project, the selection and
the spending page are already shared. `SidebarFrame` is per-window in memory but writes to
one set of `UserDefaults` keys, so two windows already overwrite each other's width.

**Consequence**: the spec's original FR-023, one draft per window, would have made drafts
the only per-window state in the app, and would have needed a window identity that
survives relaunch — which nothing here has. Amended to one draft per conversation, shared,
which is what every neighbouring field does.

---

## 12. Scope: the iOS app

**Decision**: drafts are the Mac app's in this feature. The phone keeps its own prompt text
in view state and is untouched.

**Rationale**: `AgentsKitCore` is where the model goes, so the phone can adopt it in a few
lines whenever that is wanted. Doing it here would mean building and walking the iOS app,
which on this Mac cannot be driven without a person. The other four stories are the Mac's
and the daemon's, and holding them behind a device walk would be the wrong trade.

---

## 13. What deliberately stays volatile

Named so that it is a decision rather than an omission. Each is about a live process or a
live person, and writing it down could only mislead the next daemon:

| State | Why it stays in memory |
|---|---|
| `presences` | Where somebody is right now. Gone means gone, which is more truthful than stale. |
| `costReadings` | A running total for a runtime session. A reading that drops *is* a new session, and that rule is what makes losing it safe. |
| `artifactEdits` | The edit itself is in the file on disk. |
| `interrupted`, `resuming`, `sending` | About one restart, consumed within it. |
| `lastWakeVerdict` | A power assertion does not survive its process. |
| `accounts` | Re-derived from the next handshake. |
| `held` | Costs one repeated sentence per restart to an agent already at its limit. Noted, not fixed. |
| Shell scrollback | `ShellState.released` exists for exactly this and says so to the person. |
