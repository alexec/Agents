---
description: "Tasks for 038: my pull requests, babysat"
---

# Tasks: My Pull Requests, Babysat

**Input**: `specs/038-github-pr-babysit/`: [plan.md](plan.md), [spec.md](spec.md),
[research.md](research.md) (R1–R12), [data-model.md](data-model.md),
[contracts/pull-requests.md](contracts/pull-requests.md), [quickstart.md](quickstart.md),
[wireframes.md](wireframes.md).

**Tests**: Included. The plan names the test files, and quickstart §1 is the list of what they
prove.

**Paths**: `Core` = `Packages/AgentsKit/Sources/AgentsKitCore`, `Kit` =
`Packages/AgentsKit/Sources/AgentsKit`, `Tests` = `Packages/AgentsKit/Tests/AgentsKitTests`.

**Working rules for whoever implements this**:
- Work only in `.agents/worktrees/038-github-pr-babysit`, never the shared checkout.
- Build with `-skipPackagePluginValidation`, one scheme at a time.
- Never poll `daemon.sock` tightly.
- Launch the app with the run-app skill on a scratch root, never on the real daemon.
- Anything that pushes or comments on GitHub for real needs Alex's go-ahead first.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, and no dependency on an unfinished task).
- **[Story]**: US1–US4, from spec.md.

---

## Phase 1: Setup

- [X] T001 Merge `main` into `038-github-pr-babysit`. It is 7 commits ahead, including `3290695`, which changed how Worktree rows look, and `76121d5`, which says which branch the project folder is on; both touch `App/Sources/Projects/`. Check with `git merge-base HEAD main` that the merge landed on this branch. Run `swift test` in `Packages/AgentsKit` and record the pass/fail count as the baseline in this file's Notes, remembering that the suite is flaky under load.
- [X] T002 [P] Record the GraphQL fixtures in `Tests/Fixtures/GitHub/`, as R2's query would return them:
  - `pulls-mixed.json`: 5 pull requests matching the wireframe moment (#412 failing checks and changes requested; #405 passing and approved; #398 failing; #390 a draft, checks running, `CONFLICTING`; #377 failing). Include review items from `OWNER`, `COLLABORATOR` and `NONE` authors, one from a bot, and one from the viewer.
  - `pulls-empty.json`: no pull requests.
  - `pulls-fork.json`: one pull request with `isCrossRepository: true`.
  - `error-not-found.json`: a GraphQL `NOT_FOUND` error for the repository.
  - `pulls-unknown-mergeable.json`: #412 with `mergeable: UNKNOWN`.

  Write them by hand from the R2 field list. Do not call GitHub.

---

## Phase 2: Foundational (model and storage; blocks every story)

- [X] T003 [P] Create `Core/Model/PullRequest.swift`, with fields exactly as data-model.md lists them:
  - `GitHubRepository` (`host` lowercased, `owner`, `name` with `.git` removed). `init?(remote: GitRemote)` returns nil unless `host.contains("github")` and the path has exactly two parts; `webURL` is `https://<host>/<owner>/<name>`.
  - `PullRequest`.
  - `PullRequestChecks`: `.passing`, `.failing([FailedCheck])`, `.running`, `.none`.
  - `PullRequestReview`: `.approved`, `.changesRequested`, `.commented`, `.none`.
  - `PullRequestConflicts`: `.clean`, `.conflicting`, `.unknown`.
  - `FailedCheck` (`id`, `name`, `logURL`).
  - `ReviewItem` (`id` Int databaseId, `kind` `.review`/`.threadComment`/`.conversationComment`, `author`, `body`, `path?`, `line?`, `createdAt`, `url`).
  - `BabysittingStatus` (`lastRun`, `lastRunWorkflowID`, `consecutiveRuns` 0–3, `isStopped`, `isRunning`).
  - `PullRequestList` (`folder`, `repository`, `viewer?`, `pullRequests` sorted by `createdAt` newest first, `fetchedAt?`, `problem?`, `babysitterWorkflowID?`).
  - `PullRequestProblem`: `.noCLI`, `.notSignedIn(host)`, `.cannotSee(host, repo)`, `.unreachable(String)`. Its `message` uses the wireframe wording, which supersedes R1's draft:
    - "Can't see pull requests: the GitHub CLI isn't installed. `brew install gh`"
    - "Can't see pull requests: gh isn't signed in. Run `gh auth login --hostname <host>` in Terminal."
    - "Can't see pull requests on <owner>/<name> with the account <login>."
    - `.unreachable` is never shown as the one line. It gives the footer "Couldn't reach GitHub · showing <HH:mm>".

  All the types are `Codable, Hashable, Sendable`.
- [X] T004 [P] Add the three cases to `Core/Model/WorkflowTrigger.swift`:
  - The cases, with file names and `summary` exactly as data-model.md gives them:
    - `.pullRequestChecksFailed` / `pull-request-checks-failed` / "When checks fail on one of my pull requests"
    - `.pullRequestReviewComments` / `pull-request-review-comments` / "When one of my pull requests gets review comments"
    - `.pullRequestConflicts` / `pull-request-conflicts` / "When one of my pull requests conflicts with its base"
  - `isPullRequest`.
  - A hand-written `Codable` that encodes the three in the same shape as `.unrecognised(name:keys:)` and decodes them from it by name (R11).
- [X] T005 [P] Add five cases to `WorkflowRefusal` in `Core/Model/WorkflowOutcome.swift`, with `message` and `needsAPerson` exactly as data-model.md gives them:
  - `.noWorktree(pr:)`, "#n has no local worktree", no.
  - `.worktreeDirty(pr:)`, "#n's worktree has uncommitted changes", no.
  - `.worktreeBusy(pr:)`, "an agent is already working in #n's worktree", no.
  - `.noPullRequest`, "nothing says which pull request", no.
  - `.babysittingStopped(pr:runs:)`, "babysitting #n stopped after 3 tries in a row", **yes**.

  Also add a `rowMessage` that says "its" in place of "#n's" for the pull request's own row (wireframe §1). `isSameReason` compares the case and the pull request number. In the same file, add `WorkflowRun.pullRequest: PullRequestRef?` (`number`, `headBranch`, `worktree: URL`, `changeKey: String`).
- [X] T006 [P] In `Core/Model/Workflow.swift`, add `respondsToPullRequests` (any trigger `isPullRequest`). When a workflow has all three pull-request triggers, its summary is the combined sentence the wireframe uses: "When one of my pull requests fails its checks, gets review comments or conflicts with its base".
- [X] T007 [P] Add `pushPullRequest = "push_pull_request"` and `replyOnPullRequest = "reply_on_pull_request"` to `Core/Model/AppTool.swift`.
- [X] T008 Add the five methods from the contract table to `Core/Daemon/DaemonAPI.swift`:
  - `pullRequests/list`, `pullRequests/refresh`, `pullRequests/resume`, `pullRequests/checkout` and `pullRequests/addBabysitter`, with their request types (`{ folder }`, `{ folder, number }`).
  - The notification `pullRequestsChanged` carrying `PullRequestList`.
  - The failures `worktreeExists`, `branchCheckedOut`, `fetchFailed` and `babysitterExists(workflowID)`, each with a message.

  Depends on T003.
- [X] T009 Parse the three trigger names in `Kit/Workflows/WorkflowFile.swift`. They take no settings, so any keys under them are an `.unreadable` error. Add `standingAgentIDs: [Int: UUID]` to `WorkflowState` in `Kit/Workflows/WorkflowStore.swift`, decoded with `decodeIfPresent` and defaulting to empty. Depends on T004.
- [X] T010 [P] Create `Kit/GitHub/PullRequestStore.swift` for `pull-requests.json` next to `workflows.json`, shaped like `WorkflowStore`: a lenient read, where a file it cannot read reads as empty. It holds `PullRequestRecord` (key `folder` + `number`; `firedKeys [String: String]` keyed `"<workflowID>/<trigger name>"`; `commentWatermark [String: Int]` keyed by workflow ID; `consecutiveRuns`; `stoppedAt?`; `lastRunStartedAt?`; `lastOutcome?` + `lastOutcomeWorkflowID?`; `pushedOids`, last 20; `postedCommentIDs`, last 50), plus `lists: [PullRequestList]` and `lastAttemptAt: [String: Date]` keyed by folder path. Depends on T003.
- [X] T011 [P] Write `Tests/Unit/GitHubRepositoryTests.swift`. `github.com` and `github.example.com` are accepted in HTTPS and scp form. `gitlab.com`, a one-part path and a three-part path are refused. `.git` is stripped, and the host is lowercased.
- [X] T012 [P] Write `Tests/Unit/WorkflowTriggerCodingTests.swift`:
  - The three names round-trip through `WorkflowFile` and through JSON.
  - A decoder with no knowledge of the new cases sees `.unrecognised` (R11).
  - A pull-request trigger with a key is refused as unreadable.
  - `WorkflowState` without `standingAgentIDs` decodes.
- [X] T013 Add `pullRequestStore` and the in-memory `pullRequestLists: [URL: PullRequestList]` to `Kit/Daemon/DaemonCore.swift`, loaded from the store at start so a restarted daemon shows the last good list at once (R12). Depends on T010.

**Checkpoint**: `swift test --filter 'GitHubRepository|WorkflowTriggerCoding'` passes, both schemes build, and no behaviour has changed yet.

---

## Phase 3: User Story 1: See my pull requests in the project (P1) 🎯 MVP

**Goal**: a GitHub project shows a Pull requests section, listing the viewer's open pull requests with their checks, review and conflict state, and the worktree each is in.

**Independent test**: quickstart §2, steps 1–4, on a scratch app.

- [X] T014 [P] [US1] Create `Kit/GitHub/GitHubCLI.swift`, modelled on `GitProcess` in `Kit/Projects/GitClone.swift`:
  - Find `gh` through `LoginShellPath`. Give it empty stdin and set `GH_PROMPT_DISABLED=1` and `GH_NO_UPDATE_NOTIFIER=1`.
  - End it on `terminationHandler`, never `waitUntilExit`.
  - `graphql(query:variables:host:)` and `api(method:path:fields:host:)` return `Data`.
  - Classify failures: not found → `.noCLI`; `gh auth status --hostname` failing → `.notSignedIn`; GraphQL `NOT_FOUND`/`FORBIDDEN` for the repository → `.cannotSee`; everything else (network, rate limit) → `.unreachable`.
  - Take the executable URL as an injectable parameter, so the tests can put a fake `gh` on PATH.
- [X] T015 [P] [US1] Create `Kit/GitHub/GitHubQuery.swift`:
  - R2's query text, with the fields exactly as listed and `search … author:@me first: 50`.
  - Decoding into `[PullRequest]`. Checks are failing when a check run concluded `FAILURE`, `TIMED_OUT`, `CANCELLED`, `ACTION_REQUIRED` or `STARTUP_FAILURE`, or a status context is `FAILURE` or `ERROR`; running when any are pending; none when there are none.
  - `countableComments`: the author is not the viewer and not a bot, `authorAssociation` is `OWNER`, `MEMBER` or `COLLABORATOR` (FR-011a), and the item is a `CHANGES_REQUESTED` review, a `COMMENTED` review with a body, a thread comment, or a conversation comment. Sorted oldest first.
- [X] T016 [US1] Write `Tests/Unit/GitHubQueryDecodingTests.swift` against the T002 fixtures:
  - The checks, review and conflict state of each of the five pull requests.
  - `NONE`, bot and viewer comments are dropped.
  - Newest first.
  - The fork flag and head repository URL.
  - `error-not-found.json` gives `.cannotSee`.

  Depends on T002 and T015.
- [X] T017 [US1] Add `upstreamURL(of:in:)`, `fetch(remote:refspec:in:)` and `add(existingBranch:path:in:)` to `Kit/Projects/GitWorktrees.swift`, next to the existing `isAncestor`, for R4 and R5. Each is a thin wrapper over `git(_:in:)`.
- [X] T018 [US1] Create `Kit/Daemon/DaemonCore+PullRequests.swift` with the refresh:
  - Read `origin` through `GitRemote` → `GitHubRepository`, or no list at all (SC-006). Read `origin` again on every refresh, so a changed remote takes effect.
  - Run one `GitHubCLI.graphql` per project.
  - Match worktrees (R4): the `GitWorktrees.list` entry whose branch is `refs/heads/<headRefName>`, where the project folder counts. A fork pull request also needs `upstreamURL` to equal the head repository, or `isAncestor(headOid)`.
  - Fill `babysitterWorkflowID`.
  - On success, replace the cached list and `fetchedAt`, and drop records for pull requests no longer listed (US1-5).
  - On `.unreachable`, keep the rows and set `problem`. On the other problems, clear the rows.
  - Store, then broadcast `pullRequestsChanged` if anything changed.
- [X] T019 [US1] Drive the refresh from the existing workflow ticker in `Kit/Daemon/DaemonCore+Workflows.swift` (R3):
  - A GitHub project that is not archived and whose folder exists refreshes when its `lastAttemptAt` is at least 5 minutes old.
  - `pullRequests/refresh` is served unless the last attempt was under 60 s ago, in which case it returns the cache.
  - Projects refresh one at a time, never in parallel.
- [X] T020 [US1] Add `pullRequests/checkout` (R5) to `DaemonCore+PullRequests.swift`:
  - Reuse 030's `prepare` for the path, the exclude line and the name reservation. The name is `WorktreeName.from(branch:)`, a new static in `Core/Model/AgentWorktree.swift` that follows the same rules as `from(prompt:)`.
  - Same repository: `git fetch origin <head>`, then `add(existingBranch:)` when a local branch exists and is not checked out, else `git worktree add --track -b <head> <path> origin/<head>`.
  - Fork: `git fetch <headRepositoryURL> <head>:<head>`, then `add(existingBranch:)`.
  - Fail with `worktreeExists`, `branchCheckedOut` (naming the path it is checked out in) or `fetchFailed`. On success, refresh the match and return the list.
- [X] T021 [US1] Route `pullRequests/list`, `pullRequests/refresh` and `pullRequests/checkout` in `Kit/Daemon/DaemonCore+Dispatch.swift`. Don't relay any of them to the phone (FR-010).
- [X] T022 [US1] Write `Tests/Integration/PullRequestListTests.swift`, with a real temporary repository, a bare local "remote" as `origin` rewritten to a `github.com` URL through `url.<bare>.insteadOf`, and a fake `gh` script on PATH that prints the T002 fixtures:
  - A pull request matched to the project folder and to a worktree.
  - An unmatched one.
  - `checkout` making a worktree on the existing branch.
  - A same-named local branch not claiming a fork's pull request.
  - A non-GitHub project giving `nil`.
  - The fake `gh` exiting "not logged in" giving `.notSignedIn`.
  - A network failure keeping the rows.
- [X] T023 [US1] Add the app side to `App/Sources/AppModel.swift`:
  - `pullRequestLists: [URL: PullRequestList]`, filled by `pullRequests/list` when a project page opens, then `pullRequests/refresh`.
  - Updates on `pullRequestsChanged`. Don't poll.
  - `checkOut(_:)`, with an in-progress set per folder and number, and the last check-out failure per folder and number, cleared on the next list.
- [X] T024 [P] [US1] Create `App/Sources/Projects/PullRequestRow.swift`, following wireframes §1:
  - Line one: `#n` (`.supporting`, secondary), then the title (`.reading`, semibold), then a Draft capsule. Then two fixed-width columns, so states line up down the list: checks (✕ failing, ✓ passing, ◌ running, nothing for none) and review (● changes requested, ✓ approved, ◦ commented). Then `⚠ conflicts`, then a trailing ↗.
  - Line two, `.fine`: the worktree name, or "project folder", as a link to that worktree's agents; or "Not checked out here" and a **Check out into a worktree** button; then "Checking out `branch`…" and the failure line (wireframe E).
  - All grey. No `StateTint`.
  - The whole row is the Button that opens `url` (FR-005), with the links inside it keeping their own clicks (see the SwiftUI card-taps note in memory).
- [X] T025 [P] [US1] Create `App/Sources/Projects/PullRequestsSection.swift`:
  - A `SectionHeading("Pull requests")` with ↻, which calls refresh.
  - A trailing **Babysit my pull requests** button, or **Show babysitter** when `babysitterWorkflowID` is set. Wire both in US4; here the button is present and disabled.
  - The rows in one card, then the footer "Fetched <relative> · <n> open".
  - With a `problem`, the one line replaces the rows and the button is hidden (wireframes A, B). The command text is selectable and never a button.
  - With `.unreachable` and a cache, the rows stay at full strength and the footer reads "Couldn't reach GitHub · showing <HH:mm>" (C).
  - With no pull requests, "No open pull requests of yours on <owner>/<name>", and the button stays (D).
- [X] T026 [US1] Put `PullRequestsSection` in `App/Sources/Projects/ProjectAgentsView.swift`, after `archivedSection` and before `WorkflowsSection`. It is present only when a list exists for the folder, so there is nothing on a non-GitHub project (H). Depends on T024 and T025.
- [X] T027 [US1] Build the `agentsd` scheme, then the `Agents` scheme. Run `swift test --filter 'GitHub|PullRequestList'`.
- [X] T028 [US1] **Gate: the look.** With the run-app skill on a scratch root, add this repository (its `origin` is on GitHub) as a project, open it, and screenshot the Pull requests section, including a check-out. Compare it with `wireframes/mac-project.svg`, then settle the layout with Alex (ask with the question tool) before starting Phase 4. Record what was decided in this file's Notes.

**Checkpoint**: US1 works alone. The section lists, matches, checks out and says what's wrong, with no triggers yet.

---

## Phase 4: User Story 2: A failing check or a review gets an agent, without me (P2)

**Goal**: a workflow with a pull-request trigger fires once per distinct change, in the pull request's worktree, with a prompt that is enough to act on. The agent pushes and replies only through the two app tools.

**Independent test**: quickstart §1 (the integration part), and §3 steps 2–3 once Alex has approved the sandbox.

- [X] T029 [P] [US2] Write `Tests/Unit/PullRequestChangeTests.swift` (R6):
  - The checks key is `checks:<head oid>:<sorted failing ids>`; the same response twice fires once, and a new failing id fires again.
  - The comments key is `comments:<newest countable id>`, compared against the watermark.
  - The conflict key is `conflict:<base oid>`, and `UNKNOWN` never fires.
  - On first sight, only items newer than the viewer's own latest comment or pushed head count.
  - An item from a `NONE` author never counts.
  - Babysitting's own `postedCommentIDs` never count.
- [X] T030 [US2] Put the change keys in `DaemonCore+PullRequests.swift`, as pure functions that T029 can call:
  - `changeKey(for trigger:, pr:, record:, viewer:) -> String?`.
  - `isNew(key:, record:, workflowID:, trigger:)`.
  - The watermark update, done only when a run actually starts, never on a refusal or while one is in flight (R9).
- [X] T031 [US2] Key runs per pull request in `DaemonCore+Workflows.swift` (R9). The `workflowRuns` key is `workflow.id + "#<number>"` for pull-request runs, and `WorkflowSummary.isRunning` becomes "any key for this workflow". Check every existing reader of `workflowRuns[workflow.id]` and change it.
- [X] T032 [US2] Add the pull-request refusals in front of `refusalIfBlocked`, in this order (R9):
  1. `.noWorktree`
  2. `.babysittingStopped`, reading the count from the record (it is filled in US3; here always allow)
  3. `.worktreeDirty` (`GitWorktrees.statusCount > 0`)
  4. `.worktreeBusy` (an agent whose `cwd` is the worktree is mid-turn)

  Then 008's own checks. Refusals are recorded on the pull request's record and on the workflow's `lastOutcome`, and collapse through `WorkflowOutcome.following`.
- [X] T033 [US2] Decide the mode against the worktree, in `runAgent` in `DaemonCore+Workflows.swift` (FR-017):
  - `new`: `startRequest(settings:folder:)` with the worktree as `folder`, and the agent's `worktree` set as 030 does it.
  - `standing`: `WorkflowState.standingAgentIDs[number]`.
  - `triggering`: the most recently active non-archived agent whose `cwd` is the worktree, else `.noTriggeringAgent`.

  Run now on a workflow whose only triggers are pull-request ones is refused with `.noPullRequest`.
- [X] T034 [US2] Add R10's pull-request block to `promptText(for:run:)`, after the file's own body:
  - "(You were started by the workflow "<name>" for pull request #<n>, "<title>", <url>. Branch <head> into <base>, checked out here. <behind/diverged line>)". The behind/diverged line comes from `git rev-list --left-right --count HEAD...<upstream>`, saying to bring the remote's commits in and not discard them.
  - "What changed:", then one line per item:
    - Check "<name>" failed: <logURL>
    - <author> on <path>:<line> (comment <id>): followed by the body quoted with `> `, each body cut at 2,000 characters
    - It now conflicts with <base>.
  - "Push with push_pull_request, and reply with reply_on_pull_request. Never force-push, and never use git push or gh yourself."
- [X] T035 [US2] Fire from the refresh. After each good refresh, for every non-archived workflow in that project with pull-request triggers, and every matched pull request, compute the change keys (T030). For each new one, run the fire path (T032 → T033). Fire nothing on a refresh that failed (spec edge case). The project and machine ceilings (008 FR-031b) apply as they do today. Fires over the ceiling are looked at again on the next refresh.
- [X] T036 [US2] After a run ends, when `workflowRunFinished` is for a pull-request run, make the project due for a refresh at the first tick that is at least 60 s after its last attempt (FR-014, R3). Don't mark the change key fired if the run started while it was already in flight, so it fires then if it still holds.
- [X] T037 [P] [US2] Add the handler for `push_pull_request` to `Kit/Daemon/DaemonCore+AppTools.swift` (R7):
  - Find the caller's run by agent id; if there is none, refuse with "Only a run started for a pull request can push or reply; ask the person to do it."
  - If the agent's `cwd` is not the pull request's worktree, refuse with "This agent is not in #n's worktree."
  - Run `git push <headRepositoryURL> HEAD:refs/heads/<headBranch>` in the worktree. Never `--force`, `--force-with-lease` or a leading `+`.
  - Reply "Pushed <short oid> to <head> (#n).", or "Git refused: <stderr>".
  - Record the pushed oid in `pushedOids`, keeping the last 20.
- [X] T038 [P] [US2] Add the handler for `reply_on_pull_request` to `DaemonCore+AppTools.swift` (R7):
  - The same run check as the push.
  - With `in_reply_to`, it must be the id of an item on *that* pull request in the last fetched state, else "Comment <id> is not on #n.". It posts through `GitHubCLI.api` to `POST /repos/{o}/{r}/pulls/{n}/comments/{id}/replies`.
  - Without it, it posts to `POST /repos/{o}/{r}/issues/{n}/comments`.
  - Reply "Replied: <url>", and record the new id in `postedCommentIDs`, keeping the last 50.
- [X] T039 [US2] Serve the two tools from `Kit/ACP/Serve/AppService.swift`, with the names, descriptions and input schemas exactly as the contract gives them. List them for every session, like `manage_workflows`. Relay them in `Daemon/Sources/main.swift`, and make `autoAllowed` in `DaemonCore+AppTools.swift` cover both. Depends on T037 and T038.
- [X] T040 [US2] Write `Tests/Integration/PullRequestFireTests.swift`, with a fake `gh`, real git, a bare remote and a fake runtime:
  - A failing check fires once and starts an agent whose `cwd` is the worktree and whose prompt names #n, the check and its log URL.
  - The same state again does not fire.
  - A comment from a `NONE` author does not fire.
  - A dirty worktree gives `.worktreeDirty`, and repeats collapse.
  - A busy worktree gives `.worktreeBusy`.
  - A change during a run fires after it ends.
  - `push_pull_request` pushes to the bare remote, and refuses a non-fast-forward with "Git refused".
  - The push is refused outside a pull-request run.
  - `reply_on_pull_request` refuses an id from another pull request, and the fake `gh` receives the right endpoint.
  - Two pull requests in one workflow run at once.
- [X] T041 [US2] Show the latest run on the row in `PullRequestRow.swift` (FR-019):
  - "Babysitting now →" while running.
  - "Babysat <relative> →" · the run agent's report, cut to one line.
  - The refusal's `rowMessage` in grey ("Did not run — its worktree has uncommitted changes").
  - → selects the run's agent.
- [X] T042 [US2] Update the workflow row in `App/Sources/Projects/WorkflowRow.swift` for pull-request workflows. The "next" text is "Watching <n> pull requests", counting matched pull requests that are not stopped. A run reads "Running on #<n> →" or "Ran on #<n> →". A refusal names its pull request, as data-model's messages do.

**Checkpoint**: with fakes, a pull-request change starts one agent in the right place, with the right prompt, and it can push and reply only to its own pull request.

---

## Phase 5: User Story 3: It stops when it should (P3)

**Goal**: at most 3 babysitting runs in a row on one pull request, then it stops and says so, until somebody acts or the person chooses Resume.

**Independent test**: quickstart §3, step 5.

- [X] T043 [P] [US3] Write `Tests/Unit/BabysittingCountTests.swift` (R8):
  - Three runs, then `.babysittingStopped(runs: 3)` with `needsAPerson`.
  - A new head oid that is not in `pushedOids` resets the count; one that is in `pushedOids` does not.
  - A countable comment newer than `lastRunStartedAt` resets it; the viewer's own comment does not.
  - Resume resets it.
  - The refusal order puts stopped after no-worktree and before dirty.
- [X] T044 [US3] Implement the count in `DaemonCore+PullRequests.swift`:
  - On each good refresh, before any triggers are looked at, apply R8's resets (a foreign head oid, a newer countable comment).
  - Starting a pull-request run adds one to `consecutiveRuns` and sets `lastRunStartedAt`.
  - T032's check refuses at `>= 3` and sets `stoppedAt`.
  - Fill `BabysittingStatus` on each `PullRequest` in the list.
- [X] T045 [US3] Add `pullRequests/resume`, which clears `consecutiveRuns` and `stoppedAt`, stores, and broadcasts. Route it in `DaemonCore+Dispatch.swift`, and add `resume(_:)` to `AppModel`.
- [X] T046 [US3] Show the stopped state on the row in `PullRequestRow.swift`: "Babysitting stopped after 3 tries in a row", semibold, in `StateTint.attention`, with a **Resume** button. It is the only tinted thing in the section (wireframes §4). The workflow row's status icon already turns orange through `needsAPerson`; check that it does.

**Checkpoint**: an unfixable check stops after three runs, and a hand push or Resume starts it again.

---

## Phase 6: User Story 4: A babysitter to start from (P4)

**Goal**: one click writes a working babysitting workflow.

**Independent test**: quickstart §3, step 1.

- [X] T047 [US4] Add `pullRequests/addBabysitter` to `DaemonCore+PullRequests.swift`:
  - If any workflow in the project, archived or not, has a pull-request trigger, fail with `babysitterExists(workflowID)`.
  - Otherwise write `.agents/workflows/babysit-pull-requests.md` through the write path `manage_workflows` uses, so the ceilings apply (per project 3: "This project already runs its 3 workflows. Archive another in this project to let it run.").
  - The front matter is exactly R10's: `name: Babysit my pull requests`, the three triggers, `agent: new`, `permission-mode: acceptEdits`.
  - The body is the starter prompt as wireframe §3 words it: "Read what changed. Fix what you can, run the build and tests you can, commit, push, and reply to each comment with what you did or why not. If you cannot fix it, say so in one reply and stop."
  - Above the body goes an HTML comment saying the mode is `acceptEdits` on purpose, so runs ask before building, testing or committing. To make it hands-off, allow those commands in the project's Claude settings, or change `permission-mode` knowingly (Alex's decision, wireframes §5).
  - Route it in `DaemonCore+Dispatch.swift`.
- [X] T048 [US4] Wire the section's button in `PullRequestsSection.swift` and `AppModel`:
  - **Babysit my pull requests** calls `addBabysitter`. A ceiling refusal shows under the button in `.fine` grey (wireframe G), with no alert.
  - **Show babysitter** sets `model.openWorkflow` to `babysitterWorkflowID`.
- [X] T049 [US4] Add tests to `Tests/Integration/PullRequestFireTests.swift`:
  - `addBabysitter` writes a file that parses into the three triggers and `acceptEdits`.
  - A second call fails with `babysitterExists`.
  - A project at its ceiling fails with the ceiling's message.

---

## Phase 7: Polish and proof

- [X] T050 [P] Build the iOS Remote scheme for the generic simulator only, and confirm it decodes the new trigger and refusal cases. Don't create or boot a simulator.
- [X] T051 Build `agentsd`, then `Agents`. Run the full `swift test` six times on this branch and six on `main`, and compare pass counts before blaming any failure on this branch.
- [X] T052 With the run-app skill on a scratch root, screenshot wireframe states A, C, D and E (using `GH_CONFIG_DIR` pointed at an empty folder for A) and the stopped row. Compare them with `wireframes/mac-section-states.svg`, and record the differences in Notes.
- [X] T053 Ask Alex (question tool) to create or approve the throwaway sandbox repository. Only then run quickstart §3 live, then run the §4 audit (`gh api repos/<o>/<r>/events` and the branch reflog): no force-push, no other branch, no merge, close, approve or edit (SC-004). Record the results in this file's Notes and in research.md.
- [X] T054 Update memory: 038's status in the spec-queue entry and its MEMORY.md line.

---

## Dependencies

- Phase 1 → Phase 2 → US1 (Phase 3) → **gate T028** → US2 (Phase 4) → US3 (Phase 5). US3 needs the fire path and the push tool's `pushedOids`.
- US4 (Phase 6) needs only Phase 2, T021's dispatch and T025's section. It can go alongside US2 or US3 once the gate has passed.
- Polish comes last. T053 waits for Alex.

## Parallel opportunities

- Phase 2: T003–T007, T010, T011 and T012 touch different files.
- US1: T014 and T015 together, then T024 and T025 together, while T018–T022 go on in the daemon.
- US2: T029 first; T037 and T038 together; T041 and T042 together.
- US3: T043 while T044 is written.

## Implementation strategy

1. **MVP = US1**, through the gate T028. The section on its own already answers "what state are my pull requests in".
2. Then US2 with fakes only, to its checkpoint. Nothing touches GitHub for real until T053.
3. Then US3, which is what makes it safe to leave on. Then US4.

## Notes

- Baseline (T001): merged main twice (35 commits on 2026-09-25, then 10 more with 035, which took
  -32034; 038's error codes start at -32040). Full suite before any 038 code: 1517 tests, 1 issue
  (flaky; the run overlapped the first edits). The 038-related filter after US1: 257 tests green.
- Changed from the design while building:
  - The matched worktree is `PullRequestWorktree` (root, name, isProjectFolder), not
    `AgentWorktree`, which records how an agent started and cannot say "the project folder".
  - `viewerLastCommentAt` became `viewerLastActionAt` (R6 also counts the head commit).
  - The query also asks `repository(owner:name:) { id }`: a search on a repository the sign-in
    cannot see comes back empty rather than as an error, so this is what makes `.cannotSee` work.
  - `remote.origin.url` is read raw from config (not `git remote get-url`, which applies
    `insteadOf`), so the project's own spelling decides whether it is on GitHub.
  - `GitProcess` gained an internal init taking an executable, and `gh` runs through it.
  - The ticker's sweep is off until `Daemon.start()` calls `watchPullRequests()`, so the many tests
    that drive the ticker never run git or gh on the side.
  - `pullRequests/changed` goes to Mac windows only (`surface == .mac`).
  - Each pull request is its own card, like every other card on the page, not rows in one card as
    the wireframe drew. Only the first line is the "open on GitHub" button: a button's label is one
    element to accessibility, which hid Check out from VoiceOver (and from AX pressing).
  - A failed check-out keeps its reason beside a **Try again** button.
  - `run-app`'s `ui.swift` gained `select`, to choose a sidebar row without a click.
- Gate (T028), screenshots in `walk/`, on a scratch root with the real `gh` and two real
  repositories cloned read-only: kitproj/kit #116 (draft, passing, changes requested, not checked
  out, then checked out into `discussion-useful-hooks` on `copilot/discussion-useful-hooks` and
  listed under Worktrees) and alexec/EquilibriumApp #85 (passing, commented, in the project folder).
  A failed check-out (a leftover folder) shows its reason on the row. Decisions: Alex approved the
  layout on 2026-09-25 as built, one card per pull request (not the wireframe's shared card). US2 next.
- US2–US4 (2026-09-25), all with fakes, nothing sent to GitHub:
  - Changes (R6) are pure functions in `Kit/GitHub/PullRequestChanges.swift`. All of a workflow's
    unfired changes on one pull request go into one fire, so a review and a failing check that
    arrive together make one run.
  - A run in flight on a pull request makes the refresh skip it without recording a refusal; the
    run ending makes the project due a look at the first tick a minute on (FR-014).
  - `PullRequestWorktree` gained `checkout` (the worktree's top), which `.existing` needs.
  - The busy check counts agents that hold a runtime (starting, running, waiting on the person).
  - The two tools are auto-allowed through `ToolCall.isAutoAllowable`, not `isTheApps`. Push goes
    through `origin` for a same-repository pull request (the person's own remote, and what
    `insteadOf` rewrites in tests) and to the fork's URL otherwise.
  - The count also resets when the head commit changes to one babysitting did not push; the
    record keeps `lastSeenHeadOid` for that. `isStopped` is three runs or `stoppedAt`.
  - The starter's note about acceptEdits is a YAML comment in the front matter: the body is the
    prompt word for word, and a note there would reach every run.
  - T042: the workflow row says "Watching N pull requests". "Running on #n" is not drawn: a
    `WorkflowSummary` does not say which pull request its run is for, and the pull request's own
    row already says "Babysitting now".
  - A test showed the starter refused with `settingRefused` on a runtime offering no modes, which
    is right; the test now offers `acceptEdits` as Claude does.
  - `WorkflowToolTests.archivingOneLetsAnAgentWriteAnother` fails 2 runs in 5 on this branch (a
    token dropped as the agent's turn ends); compared on main below.
- T050: Remote builds for the generic simulator at `98ae7d0`; nothing was installed on a device
  (038 changes nothing the phone shows).
- T051 (2026-09-25, `dabd496` against main `e3ce367`+): six full runs each. Branch 1696 tests: 2
  clean, failures only `aLeaseThatRanOutWhileTheDaemonWasDown…` (3) and
  `theEndingAPersonsPromptOvertook…` (3). Main 1631 tests: 1 clean, the same two (2, 4) plus
  `twoHelpersFinishingGiveOneResumeNamingEach` (4). No 038 test failed in any run.
  `WorkflowToolTests` flakes 2 in 6 on main as well.
- Screenshot differences (T052): the screen was locked when this was reached, so the new states
  (Show babysitter, the stopped row with Resume, Watching N) were proved over the scratch root's
  socket against the real gh instead: the starter written with the three triggers and acceptEdits,
  a second press refused with `babysitterExists`, Run now refused with `noPullRequest`, no agent
  started. The screenshots are still owed.
- Live run and audit (T053), 2026-09-25, Alex's go-ahead to create a private sandbox:
  `alexec/agents-babysit-sandbox` (private; one check that fails while a file `FAIL` exists), PR #1
  on `babysit-demo` adding `FAIL`. Scratch root, real gh, a real Claude agent; permission questions
  answered by a watcher that allowed edits and commits and would refuse any `git push`/`gh` the
  agent ran by itself (none were asked).
  - The live run found a bug: the starter, written untracked into the project's `.agents`, made the
    project folder look dirty, so every fire was refused (fixed in `8b12b4d`; the test sandbox had
    hidden it by excluding `.agents`).
  - After the fix: one fire on the failing check, in the project folder. The prompt named #1, the
    check and its log. The agent ran `git rm FAIL && git commit`, pushed `1547836` with
    push_pull_request, replied on the pull request with reply_on_pull_request (as alexec), and ended
    blocked until CI confirmed. The check passed. The refresh a minute after the run saw it passing,
    fired nothing, and kept the count at 1 (babysitting's own push does not reset it).
  - Copilot's automatic review (a bot) arrived on the pull request and was correctly ignored.
  - SC-004 audit (`gh api repos/alexec/agents-babysit-sandbox/events`): one push to
    `refs/heads/babysit-demo`, `forced=false`; one issue comment; no merge, close, approve or edit.
  - Not exercised live: review comments from another person with write access (there is no second
    account) and stopping after three. Both are covered by the tests with fakes.
  - Screenshot: `walk/05-live-babysat.png`: the Blocked babysitting agent, the pull request row
    reading "project folder · Babysat 1 minute ago → · Removed the stray FAIL file…", Show
    babysitter, and the workflow row.
  - The sandbox repository and its PR are left in place for Alex to delete or reuse.
- Merged main again 2026-09-25 (`e3a2819`, 2 commits: worktrees on an existing branch). All three
  schemes build. Main's new `WorktreeStartTests.anAgentCanStartInANewWorktreeOnALocalBranch` fails
  when run beside `PullRequestFireTests`, and passes alone here and on main. Traced with a
  temporary print in `FakeLauncher`: the second launch is the daemon's own `askForOutcomeIfSilent`
  relaunching the agent after its silent first turn, which lands before the test reads
  `launcher.launches` whenever other suites load the machine. A race in that test, not 038; left
  for its owner.
