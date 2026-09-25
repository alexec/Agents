# Implementation Plan: My Pull Requests, Babysat

**Branch**: `038-github-pr-babysit` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/038-github-pr-babysit/spec.md`

## Summary

A project whose `origin` host contains `github` gets a **Pull requests** section on the Mac. It
lists the person's open pull requests there, with checks, review and conflict state, and the
worktree each is checked out in.

The daemon reads the list with the person's own `gh`: one GraphQL query per project, at most every
five minutes, driven by the workflow ticker that is already running (R1–R3). Pull requests are
matched to worktrees through git itself (R4). An unmatched one can be checked out into a 030-style
worktree on its existing branch (R5).

Workflows gain three triggers: `pull-request-checks-failed`, `pull-request-review-comments` and
`pull-request-conflicts`. Each one:
- Fires once per distinct change, recorded by a change key for each (workflow, pull request)
  (R6).
- Counts only comments from people with write access (FR-011a).
- Runs in the pull request's worktree, with one in-flight run for each pull request (R9).
- Refuses when the worktree is missing, dirty or busy, or when three runs in a row went unanswered
  (R8, R9).

The agent acts on GitHub only through two new auto-allowed app tools, `push_pull_request` and
`reply_on_pull_request`. The daemon fixes their destination from the run, so it is structurally
impossible for a babysitting agent to force-push, push elsewhere, merge, close or approve (R7,
SC-004). Because the daemon does the pushing, it can also tell the person's own pushes from
babysitting's, which is what resets the count (R8).

A **Babysit my pull requests** button writes a starter workflow using the three triggers and
`permission-mode: acceptEdits` (R10).

See [research.md](research.md) for the decisions, [data-model.md](data-model.md) for the types,
and [contracts/pull-requests.md](contracts/pull-requests.md) for the methods, tools, file syntax
and section.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**:
- AgentsKit and AgentsKitCore (in-repo package).
- The person's `git` through `GitProcess` (027), and 030's `GitWorktrees`.
- The person's `gh` (GitHub CLI) through a new `GitHubCLI`, which mirrors `GitProcess`.
- ACP runtimes.

**Storage**:
- A new daemon file, `pull-requests.json` (`PullRequestStore`): change keys, watermarks,
  babysitting counts, pushed oids and posted comment ids, the last outcome for each pull request,
  and the last good list (R12).
- `WorkflowState` gains `standingAgentIDs`.
- Nothing is written to the repository except the starter workflow file, when asked for.

**Testing**:
- swift-testing in `Packages/AgentsKit`:
  - Unit tests: decoding recorded GraphQL, change keys, the count, refusal order, trigger
    round-trip.
  - Integration tests: real temporary git repositories, a bare local "remote", a fake `gh` script
    on PATH, and fake runtimes.
- xcodebuild for both schemes.
- The run-app skill on a scratch root.
- One live run against a throwaway GitHub repository (quickstart §3).

**Target Platform**: The macOS app and the `agentsd` daemon. The iOS Remote app is unchanged,
apart from decoding the new trigger and refusal cases.

**Project Type**: Desktop app with a daemon, plus a companion iOS app

**Performance Goals**:
- The list appears within 5 s of opening a project (SC-001). It is served from cache at once, then
  refreshed.
- A fire happens within 6 minutes of a change (SC-002).
- One `gh` process per GitHub project per five minutes while idle.

**Constraints**:
- No token is stored or asked for (FR-002).
- No fire happens on stale state (spec edge case). A failed refresh fires nothing.
- There is no way for an agent to force-push, or to act on another pull request (FR-022).
- Reviewers' text goes into prompts only from people with write access, and quoted (FR-011a, R10).
- Projects not on GitHub are unchanged (SC-006).

**Scale/Scope**:
- One model file and three changed ones in Core.
- Four new daemon files: `GitHubCLI`, `GitHubQuery`, `PullRequestStore` and
  `DaemonCore+PullRequests`.
- Five methods, one notification, two tools, three triggers and five refusals.
- One Mac section and one row.

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there are
no gates. The repo's working rules apply:

- **Settle the UX before depth**: Phase 2 builds the list and the section with no triggers, and
  Phase 3 screenshots it with run-app for Alex before any firing is built.
- **One path, not two**:
  - Firing goes through the existing `fire` and `refusalIfBlocked`, with the pull-request checks
    added in front.
  - Starting goes through `startRequest` and `start`, with the worktree as `cwd`.
  - The starter goes through `manage_workflows`'s write path, so the ceilings are enforced once.
  - `gh` is the only way to reach GitHub (R1).
- **Prove it running**: quickstart §3 is a live run on a real repository. SC-004 is checked from
  GitHub's own event log.
- **Outward-facing actions need a yes**: the live run pushes and comments on GitHub. It uses a
  throwaway repository that Alex creates or approves.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/038-github-pr-babysit/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── pull-requests.md
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/PullRequest.swift          # NEW: GitHubRepository, PullRequest, checks/review/conflicts, ReviewItem, BabysittingStatus, PullRequestList, PullRequestProblem
├── Model/WorkflowTrigger.swift      # 3 cases, isPullRequest, hand-written Codable (R11)
├── Model/WorkflowOutcome.swift      # 5 refusals; WorkflowRun.pullRequest + PullRequestRef
├── Model/Workflow.swift             # respondsToPullRequests; summary text
├── Model/AppTool.swift              # pushPullRequest, replyOnPullRequest names
└── Daemon/DaemonAPI.swift           # 5 methods, notification, requests, failures

Packages/AgentsKit/Sources/AgentsKit/
├── GitHub/GitHubCLI.swift           # NEW: find and run gh, classify auth and access failures
├── GitHub/GitHubQuery.swift         # NEW: the R2 query text and its decoding into PullRequest
├── GitHub/PullRequestStore.swift    # NEW: pull-requests.json (R12)
├── Projects/GitWorktrees.swift      # upstream URL, is-ancestor, fetch, add on existing branch, push
├── Workflows/WorkflowFile.swift     # parse the three names
├── Workflows/WorkflowStore.swift    # standingAgentIDs
├── ACP/Serve/AppService.swift       # the two tools and their sink
└── Daemon/
    ├── DaemonCore+PullRequests.swift # NEW: refresh, match, change keys, count, fire, checkout, resume, starter
    ├── DaemonCore+Workflows.swift    # run key per PR; PR branch in runAgent/promptText; refresh after run ends; ticker hook
    ├── DaemonCore+AppTools.swift     # push and reply handlers; autoAllowed covers the two
    ├── DaemonCore+Dispatch.swift     # 5 cases
    └── DaemonCore.swift              # pullRequestStore, lists in memory

Daemon/Sources/main.swift            # relay the two tools

App/Sources/
├── AppModel.swift                         # pull request lists by folder; refresh on open; notification
├── Projects/ProjectAgentsView.swift       # section between Sessions and Workflows
├── Projects/PullRequestsSection.swift     # NEW: header, problem line, footer, Babysit button
└── Projects/PullRequestRow.swift          # NEW: badges, worktree link, babysitting line, Resume, Check out

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/GitHubRepositoryTests.swift       # NEW
├── Unit/GitHubQueryDecodingTests.swift    # NEW: recorded responses under Fixtures/
├── Unit/PullRequestChangeTests.swift      # NEW: keys, first sight, FR-011a, UNKNOWN
├── Unit/BabysittingCountTests.swift       # NEW
├── Unit/WorkflowTriggerCodingTests.swift  # NEW or extended: round trip + old reader
└── Integration/PullRequestFireTests.swift # NEW: fake gh, real git, fake runtime: match, checkout, fire, refuse, push, reply
```

**Structure Decision**: The existing layout, plus a `GitHub/` folder in `AgentsKit`, next to
`Projects/`, `Workflows/` and `Files/`. It holds the three pieces that know GitHub exists. Every
other change is to a file that already owns the concept.

## Phases (for /speckit-tasks)

1. **Model**:
   - `PullRequest.swift`.
   - The three triggers, with parsing, summaries and the R11 coding.
   - The five refusals, and `WorkflowRun.pullRequest`.
   - Unit tests. No daemon behaviour yet.
2. **The list (US1, P1)**:
   - `GitHubCLI`, `GitHubQuery` and `PullRequestStore`.
   - Refresh on the ticker and on demand, matching (R4), and `pullRequests/list`, `pullRequests/refresh`
     and the notification.
   - `AppModel`, the section and the row, all read-only.
3. **Gate: the look**:
   - Run-app on a scratch root, against a real GitHub project (this repository has an `origin`),
     to screenshot the section.
   - Settle the layout with Alex before going on.
4. **Firing (US2, P2)**:
   - Change keys and watermarks (R6), and the per-pull-request run key (R9).
   - The pull-request refusals, the mode against the worktree, and the prompt block (R10).
   - `push_pull_request` and `reply_on_pull_request` (R7).
   - The integration tests with fake `gh`.
   - `pullRequests/checkout` and the row's Check out.
5. **Stopping (US3, P3)**: the count, the reset rules, `pullRequests/resume`, the stopped line and
   Resume, and the refresh after a run ends.
6. **Starter (US4, P4)**: `pullRequests/addBabysitter`, the button, and Show babysitter.
7. **Proof**:
   - Both schemes build.
   - The full suite, compared across runs because the suite is flaky under load.
   - Quickstart §2 and §3 live on the throwaway repository, with Alex's go-ahead for the
     outward-facing part.
   - The §4 audit.

## Risks

- **Prompt injection through review text.** FR-011a keeps strangers out, but a collaborator's
  comment is still text an agent reads. Several things limit the damage:
  - The comment is quoted.
  - The starter is `acceptEdits` and never bypasses permissions.
  - The only GitHub actions available are the two fixed-destination tools.

  A workflow file that sets `permission-mode: bypassPermissions` together with these triggers is
  the person's own choice. The project page could warn about that combination. That's not planned
  now.
- **`git push` by the agent's own shell.** The prompt says not to. If the agent does it anyway,
  the runtime's permission question waits for the person, unless the workflow bypasses
  permissions. Hardening with `autoRefused` is noted in R7 and deferred.
- **`gh` missing, or signed in with the wrong scopes.** The one-line problem says so. Replying
  needs the `repo` scope (or `public_repo`), which `gh auth login` grants by default.
- **An older phone and new refusals.** An older Remote build fails to decode a workflow summary
  whose last outcome is one of the new refusals (R11). Mac and phone are built from the same tree
  and installed together, so this is accepted. The new *triggers* are safe on old readers.
- **GitHub's lazy `mergeable`.** A conflict can take one extra refresh to show. That is within
  SC-002.
- **A fork branch sharing a name with a local branch.** R4's containment check stops the false
  match. The cost is that a fork pull request checked out by hand, before its head commit was
  fetched, is shown unmatched until the next `git fetch`.

## Complexity Tracking

None. There are no constitution gates. The two app tools are the one addition the spec did not
name. They are what makes FR-020 to FR-022 hold unattended (R7).
