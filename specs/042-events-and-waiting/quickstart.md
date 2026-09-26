# Quickstart: Proving Events and Waiting Work

Run everything from this feature's worktree, never from the shared checkout or against the real
daemon. Build the Xcode schemes one after the other, with plugin validation skipped. The types
and wording referred to are in [data-model.md](data-model.md) and [contracts/](contracts/).

## 1. The rules, in unit tests

```sh
cd Packages/AgentsKit
swift test --filter 'EventLogTests|EventPatternTests|EventCatalogueTests|WorkflowTriggerEventTests|WaitStatusTests|EventStoreTests'
```

Expected:

- `EventLogTests`: positions only ever go up. An identical event within 60 s folds into the last
  one, with `count` 2. The same event 61 s later is a new row. Pruning keeps 7 days and at most
  10,000 rows. A query filters by scope and subject and pages with `before`.
- `EventPatternTests`: `pull_request.*` matches every pull-request kind. `{number: 41}` matches
  41 and not 42. `custom.build_green` matches only that name. Each of these is refused and the
  refusal lists the valid choices: an unknown name, `nope.*`, and a filter key the kind does not
  carry.
- `EventCatalogueTests`: every old trigger name maps to its kind, and `agent-stopped` maps to
  both `agent.stopped` and `agent.failed`. `describe()` is the text both `list` and
  `manage_workflows` return (FR-024).
- `WorkflowTriggerEventTests`: every workflow file in the repository, and every example the app
  offers, parses to the same values as on `main`. None of them is rewritten (SC-006). `.event`
  encodes as `.unrecognised`. Decoding it with a copy of `main`'s decoder gives an unknown
  trigger, not an error (FR-025).
- `WaitStatusTests`: a 039 block on "Fix login" and a wait on `agent.finished` for that agent
  give the same line and mark (FR-012).
- `EventStoreTests`: a torn last line is dropped on load. Consequences and repeats fold into
  their event. Pruning rewrites the file through a temporary file and a rename.

## 2. The daemon, with fake runtimes

```sh
swift test --filter EventWaitTests
```

Each item below is one test, with the hold limit shortened through `useForEvents(holdLimit:)`
and a fake `MachineWatch`.

- **Waiting and waking**
  - A waits on `custom.ping`. B publishes it. A's open call returns the event.
  - A's call reaches the limit and returns "Still waiting…". B then publishes, and A gets the
    wake prompt `from: .app` within 5 s (SC-001).
  - While A waits, its group is `.blocked`, and `WaitStatus.line` names the event.
- **Timing**
  - `from`: an event raised before the wait but after `from` answers at once. One raised before
    `from` is never matched.
  - Deadline: no match, so A is woken with "timed out".
  - Several matches: A wakes once, and the prompt says "2 more matches".
- **Cancelling.** Each of these ends the wait and nothing wakes A afterwards: `cancel_wait`,
  `events/cancelWait`, the person's prompt, stop, and archive. The person's prompt carries the
  cancel line.
- **Restart**
  - 20 cycles with waits open: every wait is still there each time (SC-005).
  - A wait that was cleared and queued before the restart is resumed exactly once.
  - Nothing is raised for the time the daemon was down.
- **Failures and limits**
  - Cannot wake: A's runtime is removed, so the consequence is `couldNotWake` and A's
    transcript notes the event it missed.
  - Publishing: the 31st publish in an hour is refused, and so is a name outside `custom.`.
  - Chain depth: a publish from a workflow's agent fires the next workflow at depth + 1, and a
    publish loop is refused at the depth limit (FR-020).
- **Workflows on the new events**
  - Workflows on `mac.wake` (fake watch) and on `custom.release_ready` fire, and each fire is a
    consequence on its event.
  - `agent: triggering` on `mac.wake` is refused with `noTriggeringAgent`.
- **Scope.** A in project P waits on Q's events: nothing matches. A can wait on `mac.*`.

Then run the existing suites unchanged:

```sh
swift test --filter 'Workflow|PullRequest|Blocked|Lease'
```

They must pass without edits. If one fails, compare against `main` six times before blaming
this branch, because the suite is flaky under load.

## 3. The real thing, on a scratch root (run-app skill)

1. Build and launch the scratch app with the run-app skill (use `env -i`, as its script does),
   on `/tmp/run-042`, with one scratch project.
2. Start two Claude agents in the project over `daemon.sock`:
   - "Waiter": *wait_for_event custom.ping, then say what the message was.*
   - "Pinger": *wait 60 seconds, then publish_event custom.ping with message "hello".*
3. Expected results:
   - Waiter's first call returns "Still waiting" at about 45 s. Its turn ends and it groups
     under **Blocked** with `◷ Waiting for custom.ping`.
   - Pinger publishes, and Waiter is running again within 10 s, quoting "hello".
   - The Events page shows `custom.ping` published by Pinger, with ↳ *Woke* Waiter.
4. Screenshot the Events page, the waiting chat (capsule and hint line) and the workflow row
   link into `specs/042-events-and-waiting/walk/`.
5. Repeat step 2 with Grok and Cursor as Waiter, and write down what each did with the 45 s hold.

## 4. The Mac and the person

This needs Alex to be away, or it has to be his walk.

- `pmset sleepnow`, then wake the Mac. `mac.sleep` and `mac.wake` are both in the log, and
  `mac.wake` is recorded within 10 s of waking. A workflow on `mac.wake` fired.
- Lock the screen, then unlock it: `person.away` (locked) then `person.back`.

## 5. Pull requests and branches

- `branch.moved`: commit on the scratch project's default branch. One `branch.moved` appears,
  with `from` and `to`.
- On the private sandbox repository from 038 (`alexec/agents-babysit-sandbox`), push a failing
  commit to the pull request. Expect `pull_request.checks_failed` and `pull_request.changed`
  within one refresh. Merging it raises `pull_request.merged`. Ask Alex before merging his
  sandbox pull request.

## 6. Phone and iPad

Build Remote for the generic simulator only. The look on the phone and iPad is Alex's: the Events
row, the list, the detail sheet, and the waiting capsule with no ✕.
