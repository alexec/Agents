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
4. Tap the archive-box icon. The row leaves the list for *Archived* and says it will not run. Confirm `git status` shows the workflow file unchanged (FR-024). Tap **Restore** to bring it back.
5. Wait for the next half hour with it live. The agent starts within a minute of the stated time (SC-008).

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
| `archived` | Archive the workflow; assert it refuses, including against **Run now**, and that its file is untouched |
| `overLimit` | Four in one project, and four projects of three; assert which refuse and with which ceiling |
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

1. In any project, ask an agent: *"Use the manage_workflows tool to set up a workflow that runs every weekday at 9am and tells me whether the build is green."* This is `WorkflowExample.prompt`, the sentence the empty state on a project page offers, and it names the tool for a reason: the live runs found that "set up a workflow that runs every weekday at 9am", on its own, sends Claude to its own cron and Copilot to a GitHub Actions file. The word is not ours.
2. Expect no question and no sheet. The workflow appears on the project page with no further step (FR-038), and what the agent reports back names the trigger and the mode in plain words — *Every weekday at 9am, in a new agent* — and says where to look (FR-036).
3. Tap **Archive** on the row. It leaves the list, goes under *Archived*, and `git status` shows the file unchanged (FR-031a). Tap **Run now** first if you want to see it work before putting it away.
4. Ask the same agent to change that workflow. It writes, and says it is archived and will not run until you bring it back (FR-039).
5. Tap **Restore**. The row returns to the list and its next fire time comes back.
6. Ask the agent to list the project's workflows. Nothing is asked of you (FR-034), and the archived ones are marked `[archived]`.
7. Get the project to three live workflows and ask for a fourth. The agent is refused, and says which three are in the way (FR-040). Archive one and ask again: it writes.
8. Get four projects to three workflows each. The last two are listed and say *10 workflows are already running, across every project* — the remedy is in another project, and the row says so. Archive one anywhere and the next along starts counting down to its fire.

### Automated

`Integration/WorkflowToolTests`:

- `list` and `read` ask nothing and change nothing; `list` marks the archived and the over-limit ones.
- `write` writes the file and lists it, and what comes back names the trigger, the project page and archiving (FR-036).
- `write` with a path outside `.agents/workflows` is refused with the scope message (FR-037).
- `write` with unparseable front matter is refused before anything is written.
- `write` with `connectionCount == 0` still writes: an agent working at three in the morning has nobody to ask, and that is the case asking first could never serve.
- `write` to an archived id leaves it archived and says so (FR-039).
- `write` of a fourth workflow is refused and nothing lands; `write` to one of the three still changes it; archiving one lets the fourth through (FR-040).
- `write` into an empty project is refused too once ten are running elsewhere, and says the remedy is in another project.
- `autoAllowed(_:)` returns an option for all three of the app's own tools, `manage_workflows` included, and `nil` for anything else.

And in `Integration/WorkflowRefusalTests`, the ceilings as refusal rules — including four projects of three, where twelve are listed, ten run, and the two that do not are the last project's last two by name: a fourth file written by hand is listed rather than hidden, refuses with `.overProjectLimit(limit: 3)` and needs a person; the first three still run; archiving one of them lets the fourth run; an archived one is never also over the limit. Plus archiving as a refusal rule: Run now on an archived workflow refuses with `.archived` and starts nothing; the clock passes one by without even recording a refusal; the file is untouched; restoring makes it run again.

And against the real runtimes, `Live/WorkflowToolLiveTests`: the same sentence, sent to each of them, has to come back as the same file. Claude, Grok and Cursor do. Copilot does not, and cannot: it takes the `mcpServers` on `session/new` and never starts the helper, so the tool is not on its list at all — asked for a workflow it says the capability is not available in this session, which is the truthful answer. That is the same silence `SuggestedPromptLiveTests` reads as Copilot preferring its own follow-up feature.

---

## Cross-cutting checks before calling it done

- **SC-003, the one that matters most.** Across the whole integration suite, every fire either produced an agent or recorded a refusal. Worth an explicit test that walks every trigger and every refusal and asserts the count of fires equals runs plus refusals.
- **SC-009.** Twenty workflows in one project; the page scrolls as smoothly as the agent list beneath it.
- **Nothing written to the repository.** After running the full suite against a scratch project, `git status` in it is clean apart from the workflow files that were deliberately created.
- **Older records still decode.** `Agent` gains two optional fields; confirm `Unit/LegacyRecordTests` still passes unchanged.
