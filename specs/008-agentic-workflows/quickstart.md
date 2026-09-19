# Quickstart: validating Agentic Workflows

How to prove each user story actually works, in the order they ship. Every scenario is runnable; none of them needs a real runtime, a credential or a network, because the daemon's `SessionLauncher` is injectable and the test suite already drives the whole daemon through a fake one.

## Prerequisites

```sh
xcodegen generate      # after editing project.yml
swift test --package-path Packages/AgentsKit
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

Tests are Swift Testing (`import Testing`), under `Packages/AgentsKit/Tests/AgentsKitTests`, split `Unit` / `Integration` / `Live` / `Fake`. Put pure rules in `Unit` and anything that drives `DaemonCore` in `Integration`, following what is there.

Run a second app against a throwaway root so nothing touches your real agents:

```sh
open Agents.app --args --root /tmp/agents-wf-test
```

---

## Story 1 — A workflow runs on a schedule

### By hand, in the app

1. Pick any project the app already knows, and create `.agents/workflows/hello.md`:

   ```markdown
   ---
   name: Say hello
   on:
     - schedule:
         at: [":00", ":30"]
   agent: new
   ---

   Say hello and stop. Do not read or change any files.
   ```

2. Open that project's page **without restarting the app**. Expect the workflow listed within five seconds (SC-001), showing its name, *Every day on the hour and half hour, in a new agent*, and the next fire time.
3. Tap **Run now**. An agent starts in that project with that prompt and appears in the agent list, labelled as started by *Say hello* (FR-019).
4. Tap **Pause**. The row says so. Confirm `git status` shows the workflow file unchanged (FR-024).
5. Wait for the next half hour with it unpaused. The agent starts within a minute of the stated time (SC-008).

### Automated

| Test | Asserts |
|---|---|
| `Unit/WorkflowFileTests` | Round-trips the sample above; unknown top-level keys survive a rewrite; a missing `on:` is unreadable; an empty body is unreadable; `at: [":15"]` is rejected |
| `Unit/WorkflowScheduleTests` | `nextDue(after:)` across a day boundary, a `days:` set, a DST spring-forward and fall-back, and a time-zone change between two calls |
| `Integration/WorkflowFiringTests` | Writing a file into a watched project lists it; a due schedule starts an agent through the fake launcher; `standing` resumes the same agent on a second fire; `standing` with a deleted agent starts and adopts a fresh one |

Drive the clock by injecting `Date` into the tick rather than sleeping — the scheduler reads wall-clock time on every tick precisely so this is possible.

---

## Story 2 — A workflow reacts to an agent

### By hand

1. Add `.agents/workflows/on-finish.md`:

   ```markdown
   ---
   on:
     - agent-finished
   agent: new
   ---

   An agent just finished. Say which one, in one sentence. Do nothing else.
   ```

2. Start an agent yourself and let it finish. The workflow's agent starts, and its prompt names the agent that finished (FR-020).
3. Change `agent: new` to `agent: triggering` and repeat. The prompt now goes to the same agent, continuing its conversation (FR-015).

### Automated

`Integration/WorkflowFiringTests` should cover, each through `DaemonCore` directly:

- `move(agentID, on: .turnEnded(.endTurn))` fires an `agent-finished` workflow.
- A permission request fires an `agent-asked-permission` workflow **while that request is still pending** — assert `pendingPermissionRequests()` is non-empty at fire time.
- An elicitation fires an `agent-asked-form` workflow.
- `.stoppedByUser` and `.processDied` both fire `agent-stopped`.
- Workflow A completing fires workflow B triggered on `workflow-completed`.
- A workflow with two triggers that both match one event runs **once** (FR-011).

---

## Story 3 — You can see that it did not run

This is the story most likely to be quietly wrong, because every assertion is about something *not* happening. Assert on the recorded outcome, never on the absence of an agent.

### By hand

1. Write a workflow whose prompt takes a while, on `at: [":00", ":30"]`. Tap **Run now**, then tap it again immediately. The second tap does not start a second agent; the row says *did not run — a previous run is still going* (FR-023).
2. Write two workflows that trigger each other — one on `agent-finished`, one on `workflow-completed`. Start one agent. The chain stops on its own, and the row of the one that stopped says the chain limit was reached (SC-004). Count the agents: at most four.
3. Break a workflow's front matter. The row states the problem, and it never fires (FR-006).
4. Write a workflow with `on: [- deploys-finished]`. It is listed as not yet supported, not as broken (FR-013), and **Run now** is still offered (FR-012).
5. Quit the app over a scheduled time, reopen. No agent was started, and the row says the fire was missed (FR-014).

### Automated

`Integration/WorkflowRefusalTests`, one case per `WorkflowRefusal`:

| Case | Setup |
|---|---|
| `runInFlight` | Fire twice without letting the first finish |
| `chainTooDeep` | Chain past the limit; assert the run count, not just the final refusal |
| `paused` | Pause the workflow, then the project; assert both, including against **Run now** |
| `unreadable` | A file with a broken fence |
| `triggerNotSupported` | A trigger name from the future |
| `agentUnavailable` | `triggering` mode where the agent has been archived |
| `noTriggeringAgent` | `triggering` mode fired by a schedule |
| `missedWhileClosed` | Advance `lastTickAt` backwards past a due time |
| `folderGone` | Remove the project folder |

Plus, in `Unit/WorkflowOutcomeTests`, the repeat-collapsing rule as a table: same reason twice increments `repeats`; a different reason resets it to 1; a run replaces it entirely (FR-030).

The pure decision function is what makes these cheap. If a refusal case needs a live daemon to test, the decision has leaked out of it — move it back.

---

## Story 4 — An agent sets up its own workflow

### By hand

1. In any project, ask an agent: *"Set up a workflow that checks our dependencies for security advisories every weekday morning."*
2. Expect a confirmation naming the trigger and the mode in plain words — *Runs every weekday at 9:00am, in a new agent* — not a file path and not a diff (FR-036).
3. Decline it. Confirm nothing was written and the agent is told it was declined.
4. Ask again and approve. The workflow appears on the project page with no further step (FR-038).
5. Ask the agent to list the project's workflows. No confirmation is raised (FR-034).

### Automated

`Integration/WorkflowToolTests`:

- `list` and `read` return without raising a confirmation.
- `write` raises one; answering `allow: false` writes nothing and returns the declined message; `allow: true` writes the file and lists it.
- `write` with a path outside `.agents/workflows` is refused with the scope message (FR-037).
- `write` with unparseable front matter is refused **before** any confirmation is raised.
- `write` with `connectionCount == 0` refuses with the no-window message and writes nothing.
- A confirmation left unanswered past the timeout refuses and writes nothing.
- `autoAllowed(_:)` returns `nil` for a `manage_workflows` tool call and still returns an option for `suggest_next_prompts` and `show_file` — the regression guard on narrowing it.

---

## Cross-cutting checks before calling it done

- **SC-003, the one that matters most.** Across the whole integration suite, every fire either produced an agent or recorded a refusal. Worth an explicit test that walks every trigger and every refusal and asserts the count of fires equals runs plus refusals.
- **SC-009.** Twenty workflows in one project; the page scrolls as smoothly as the agent list beneath it.
- **Nothing written to the repository.** After running the full suite against a scratch project, `git status` in it is clean apart from the workflow files that were deliberately created.
- **Older records still decode.** `Agent` gains two optional fields; confirm `Unit/LegacyRecordTests` still passes unchanged.
