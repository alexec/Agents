# Research: My Pull Requests, Babysat

Every decision here was made by reading the code on `main` at `b44bb70` and the Mac it runs on.
Nothing is left as NEEDS CLARIFICATION.

## R1 — Reaching GitHub: the person's `gh`, run by the daemon

**Decision**: Every GitHub read and write goes through the person's own `gh` command-line tool.
The daemon runs it as `gh api graphql --hostname <host>` for reads and `gh api --hostname <host>`
for the reply tool. A new `GitHubCLI` runs it, the same way `GitProcess` runs git (027): it is
found on `LoginShellPath`, gets empty stdin, has `GH_PROMPT_DISABLED=1` and `GH_NO_UPDATE_NOTIFIER=1`
set, and is ended by its termination handler. The app stores no token.

**Rationale**:
- FR-002 says to use the sign-in the Mac already has. `gh` is that sign-in. It keeps a token for
  each host in the keychain, and `--hostname` is how it reaches a GitHub Enterprise host (FR-001).
- It is already installed and signed in here (`gh 2.97.0`, `alexec`, keyring).
- One subprocess per query uses no library and keeps the token out of the daemon's memory.

**What FR-003 shows**: which one-line reason the section gives depends on what went wrong:
- `gh` not found: "Install the GitHub CLI to see pull requests here".
- Not signed in to that host (`gh auth status --hostname`): "Run `gh auth login --hostname <host>`
  in Terminal to see pull requests here".
- The query returns `NOT_FOUND` or `FORBIDDEN` for the repository: "Your GitHub sign-in on `<host>`
  cannot see `<owner>/<name>`".
- Rate-limited, or the network is down: the last good list stays, with "Couldn't reach GitHub,
  showing <time>" (FR-009).

**Alternatives considered**:
- *`git credential fill` for a token, then URLSession.* This covers people who have git
  credentials but no `gh`. But the token would then be in the daemon's memory, and SSH-only
  remotes have no stored HTTPS credential, so for them it fails. It would also be a second path
  alongside `gh`. Rejected.
- *An OAuth device flow in the app.* FR-002 rules it out.

## R2 — One query per project per refresh

**Decision**: Each refresh is one GraphQL request per project:
- `viewer { login }`.
- `search(type: ISSUE, query: "repo:<owner>/<name> is:pr is:open author:@me", first: 50)`. For
  each pull request it reads:
  - `number title url isDraft createdAt headRefName headRefOid baseRefName baseRefOid mergeable
    isCrossRepository headRepository { nameWithOwner url }`.
  - `reviewDecision`.
  - `commits(last: 1) { commit { oid statusCheckRollup { state contexts(first: 50) { … on CheckRun
    { databaseId name status conclusion detailsUrl } … on StatusContext { context state targetUrl } } } } }`.
  - `reviews(last: 30) { databaseId author { login } authorAssociation state body submittedAt url }`.
  - `reviewThreads(last: 50) { comments(last: 20) { databaseId author { login } authorAssociation
    body path line createdAt url replyTo { databaseId } } }`.
  - `comments(last: 30) { databaseId author { login } authorAssociation body createdAt url }`.

`owner` and `name` come from `GitRemote.path`, with `.git` removed.

**Rationale**:
- One request per project fits under GitHub's GraphQL limit of 5,000 points an hour many times
  over: 12 requests an hour per project at the five-minute cadence.
- `search … author:@me` asks for the viewer's pull requests on the server. Listing the whole
  repository and filtering here would read every pull request on a busy repository.
- `authorAssociation` is what FR-011a needs, and it comes on every review and comment.

**Alternatives considered**: `gh pr list --json` plus `gh pr view` for each pull request. That is
N+1 processes, and `gh pr list` has no review-thread comments. Rejected.

## R3 — The refresh cadence

**Decision**: The workflow ticker the daemon already has (15 seconds) also drives pull requests.
On each tick, a GitHub project refreshes if its last attempt was at least five minutes ago
(FR-008). Opening the project in a window, or the Refresh button, asks for a refresh through
`pullRequests/refresh`. That request is served unless the last attempt was under a minute ago, in
which case the cached list is returned (FR-008's floor). When a babysitting run ends, its project
is due for a refresh at the next tick at least one minute after the last one (FR-014).

Only projects that are not archived, whose folder exists, and whose `origin` matches FR-001 are
polled. Whether a project is on GitHub is read from `git remote get-url origin` when it is adopted,
and again on each refresh, so a changed remote takes effect within one refresh (spec edge case).

**Rationale**: The ticker already runs whether or not a window is open, so SC-002 needs no new
timer. Five minutes of polling plus one tick is inside SC-002's six minutes.

**Alternatives considered**: Webhooks. There is no public address to receive them (spec
Assumptions).

## R4 — Matching a pull request to a worktree

**Decision**: `GitWorktrees.list(in: projectFolder)` is already porcelain-parsed (030). A pull
request matches the entry whose `branch` is `refs/heads/<headRefName>`. The project folder is
itself one of the entries, so FR-006's "branch in the project folder" edge case needs no special
code.

A pull request from a fork (`isCrossRepository`) also has to show that the local branch really
is that pull request. Either the branch's upstream is a remote whose URL is the head repository's,
or the local branch contains `headRefOid` (`git merge-base --is-ancestor`). The second is what a
checkout by R5 satisfies. Without this check, a local `fix-typo` would claim somebody's fork's
`fix-typo`.

**Rationale**: No record is kept. Git is what knows which branch is where, and a worktree the
person made by hand counts too.

## R5 — Checking out an unmatched pull request (FR-007)

**Decision**: A new method, `pullRequests/checkout`, reuses 030's `prepare` for the path, the
exclude line and the name reservation. It differs in the branch:
- **Same repository**: `git fetch origin <head>`. Then either `git worktree add <path> <head>`
  when a local branch of that name exists and is not checked out, or `git worktree add --track -b
  <head> <path> origin/<head>`.
- **Fork**: `git fetch <headRepository.url> <head>:<head>`, then `git worktree add <path> <head>`.
  No remote or upstream is added. The push tool (R7) pushes to the head repository by URL, and R4
  matches the branch by the commit it contains.

The name comes from the head branch, not a prompt: `WorktreeName.from(branch:)`, which uses the
same rules as 030.

## R6 — What counts as a change, and firing once (FR-011, FR-013)

**Decision**: For each (workflow, pull request, trigger kind), the daemon remembers the **key**
of the last change it fired on. A change fires when its current key is not nil and differs from
the remembered one. The keys:

| Trigger | Holds when | Key |
|---|---|---|
| `pull-request-checks-failed` | at least one check run on the head commit has concluded `FAILURE`, `TIMED_OUT`, `CANCELLED`, `ACTION_REQUIRED` or `STARTUP_FAILURE`, or a status context is `FAILURE` or `ERROR` | `checks:<head oid>:<sorted failing ids>` |
| `pull-request-review-comments` | there is at least one *countable* item newer than the watermark | `comments:<newest countable item id>` |
| `pull-request-conflicts` | `mergeable == CONFLICTING` | `conflict:<base oid>` |

**Countable** (FR-011, FR-011a):
- The author is not the viewer, and not a bot.
- `authorAssociation` is `OWNER`, `MEMBER` or `COLLABORATOR`.
- The item is a review in state `CHANGES_REQUESTED`, or a review in state `COMMENTED` with a body,
  or a review-thread comment, or a pull request comment.

**The watermark** is the newest countable item already fired on, per workflow and pull request.
The first time a pull request is seen there is no watermark. In that case the items that count are
the ones newer than the viewer's own latest action on it: a comment by the viewer, or the head
commit's date when the viewer pushed it. That is what "unanswered comments still fire once after
a restart" means (spec edge case), and it doesn't bring up a year of settled review.

`mergeable == UNKNOWN` (GitHub computes it lazily) is no change, and is looked at again on the next
refresh. A pull request that disappears from the list (merged or closed) has its keys dropped.

**Rationale**: Keys make "fire once for each distinct change" a comparison of strings. The same
failing check run keeps its id, so it doesn't fire twice. A re-run, or a new commit that fails
again, gets new ids, so it does fire, and FR-023 is what bounds that.

## R7 — What the agent may do: two app tools, not the agent's own shell

**Decision**: The daemon serves two new app tools, next to `finish_turn` and `start_agent`:
- **`push_pull_request`** (no arguments). The daemon checks that the caller is in a run a
  pull-request trigger started (R9), and that the caller's `cwd` is that pull request's worktree.
  Then it runs `git push <head repository URL> HEAD:refs/heads/<headRefName>` in that worktree.
  It never passes `--force`, `--force-with-lease` or `+`, so git refuses a non-fast-forward, and the
  refusal goes back to the agent as text. On success it records the pushed oid (R8).
- **`reply_on_pull_request`** (`body`, and optionally `in_reply_to`, a review comment id). With
  `in_reply_to`, it posts `POST /repos/{o}/{r}/pulls/{n}/comments/{id}/replies`. Without it, it
  posts `POST /repos/{o}/{r}/issues/{n}/comments`. The id must be one of the comments on *that*
  pull request in the last fetched state. On success it records the new comment's id (R8).

Both are auto-allowed, like the app's other tools (`autoAllowed`), so an unattended run doesn't
stop on a permission question. Both are listed for every session, like `manage_workflows`. Outside
a pull-request run they refuse, with the sentence "Only a run started for a pull request can push
or reply; ask the person to do it." They are listed whether or not they can be used because the
MCP server's tool list is fixed when a session is made, and `triggering` and `standing` runs
resume sessions made long before (R9).

The workflow prompt (R10) tells the agent to use these two and not `git push` or `gh`. Those still
go through the runtime's own permission question, which nobody is there to answer. So a
babysitting agent that tries them waits for the person instead of acting.

**Rationale**:
- FR-022 and SC-004 become properties of the code rather than of the prompt. There is no tool that
  can force-push, push elsewhere, merge, close, approve or edit, and the one that pushes names its
  own destination.
- Unattended runs need a push that does not ask. Auto-allowing the agent's shell for `git push`
  would allow every form of it.
- Because the daemon does the pushing and commenting, it knows which commits and comments were
  babysitting's (R8), which the spec says it otherwise can't tell apart.

**Alternatives considered**:
- *Let the agent use `git` and `gh`, with instructions only.* Permission prompts would stop every
  unattended run, and nothing would enforce FR-022. Rejected.
- *Refuse matching shell commands with `autoRefused`.* That means parsing shell command lines, and
  aliases, scripts and `sh -c` get around it. Kept only as a possible hardening later.

## R8 — The babysitting count, and telling the person's hand from babysitting's (FR-023, FR-024)

**Decision**: For each pull request the daemon keeps:
- `consecutiveRuns`.
- `stoppedAt`.
- `pushedOids`: the heads that `push_pull_request` pushed, the last 20.
- `postedCommentIDs`: the comments `reply_on_pull_request` made, the last 50.
- `lastRunStartedAt`.

On each refresh, before any trigger is looked at, the count **resets to zero** and `stoppedAt`
clears if any of these is true:
- The head oid has changed to one that is not in `pushedOids`. Someone pushed who wasn't
  babysitting: the person by hand, a collaborator, or GitHub's own update-branch.
- There is a countable comment (R6) newer than `lastRunStartedAt`.
- The person chose Resume (`pullRequests/resume`).

A fire that would start a run when `consecutiveRuns >= 3` is refused with
`.babysittingStopped(runs: 3)`, and `stoppedAt` is set. Starting a run adds one.

**Rationale**:
- This settles a conflict in the spec. FR-024 says only someone *other than* the current user
  resets the count, but US3's independent test resets it by pushing by hand, as the current user.
  Because R7 records exactly what babysitting pushed, "not pushed by babysitting" can stand in for
  "someone else".
- For comments, the spec's rule stands as written. The person's own comments never fire and never
  reset (spec edge case). `postedCommentIDs` is used only so the prompt can leave babysitting's own
  replies out of "what changed".
- Three matches `Workflow.chainDepthLimit`, as the spec says.

## R9 — A run for one pull request

**Decision**: `WorkflowRun` gains `pullRequest: PullRequestRef?`, which holds the project folder,
number, head branch and worktree path. The in-flight table `DaemonCore.workflowRuns` is keyed by
`workflow.id` today. For pull-request runs the key becomes `workflow.id + "#<number>"`, so one
workflow can run on two pull requests at once (FR-014: in flight per pull request).
`WorkflowSummary.isRunning` becomes "any key for this workflow".

The mode (FR-017) is decided against the pull request's worktree instead of the project:
- **`new`**: `startRequest(settings:folder:)` with `folder` set to the worktree path, and the
  agent's `worktree` field set as 030 does it, so it files under its project.
- **`standing`**: `WorkflowState.standingAgentIDs: [Int: UUID]`, keyed by pull request number,
  alongside the existing single `standingAgentID`.
- **`triggering`**: the most recently active agent whose `cwd` is the worktree and that is not
  archived. If there is none, the refusal is `.noTriggeringAgent`, as 008 does it.

Before the refusal checks 008 already makes (`refusalIfBlocked`), a pull-request fire checks, in
this order:
1. A matched worktree exists → otherwise `.noWorktree`.
2. The babysitting count (R8) → otherwise `.babysittingStopped`.
3. `GitWorktrees.statusCount == 0` → otherwise `.worktreeDirty`.
4. No agent with that `cwd` is mid-turn (and for `triggering`, the one being resumed is not
   either) → otherwise `.worktreeBusy`.

All four are grey refusals (`needsAPerson == false`), except `.babysittingStopped`, which is
coloured: nothing resolves it without somebody acting. Repeated refusals collapse through
`WorkflowOutcome.following` as they do today, so a pull request with no worktree is one line that
counts up, not one line per refresh (spec edge case).

A change that arrives while a run is in flight is not recorded as fired. Its key stays unfired, so
the first refresh after `workflowRunFinished` fires it if it still holds (FR-014, R3).

## R10 — The prompt, and the starter workflow

**Decision**: `promptText(for:run:)` gains a branch for pull-request runs. It appends a block after
the file's own body, the same way lifecycle triggers append their sentence:

```
(You were started by the workflow "<name>" for pull request #<n>, "<title>", <url>.
Branch <head> into <base>, checked out here. <behind/diverged line if any>)

What changed:
- Check "<name>" failed: <detailsUrl>
  …or…
- <author> on <path>:<line> (comment <id>): > <quoted body>
  …or…
- It now conflicts with <base>.

Push with push_pull_request, and reply with reply_on_pull_request. Never force-push, and never
use git push or gh yourself.
```

Comment bodies are quoted (`> `), cut at 2,000 characters each, and introduced as what reviewers
wrote, not as instructions. The behind/diverged line comes from `git rev-list --left-right --count
HEAD...<upstream>` and tells the agent to merge or rebase onto the remote without discarding its
commits (spec edge case).

The starter (US4, FR-026) is written as `.agents/workflows/babysit-pull-requests.md`, through the
same write path `manage_workflows` uses, so the ceilings (FR-026, US4-3) are enforced where they
already are:

```markdown
---
name: Babysit my pull requests
on:
  - pull-request-checks-failed
  - pull-request-review-comments
  - pull-request-conflicts
agent: new
permission-mode: acceptEdits
---
<starter prompt: read what changed; fix what you can; run the build and tests you can; commit;
push with push_pull_request; reply to each comment with what you did or why not; if you cannot fix
it, say so in one reply and stop.>
```

"One like it already exists" (US4-2) means any workflow in the project, archived or not, with at
least one pull-request trigger. Then the section offers **Show babysitter** instead of adding one.

`permission-mode: acceptEdits`, never `bypassPermissions`: the prompt contains reviewers' words. The
agent may edit files without asking, and anything else (running a build, for instance) asks the
person. That question reaches the phone as any other does.

Alex confirmed this on 2026-09-24, knowing the cost: an unattended run stops at its first build,
test or commit and waits for an answer, usually from the phone. The starter file carries a comment
saying how to make it hands-off: allow those commands in the project's Claude settings, or change
`permission-mode` in the workflow file.

## R11 — Old readers

**Decision**:
- `WorkflowTrigger` gets a hand-written `Codable`. The three new cases encode in the same shape as
  `.unrecognised(name:keys:)`, and decode from it by name. An older Mac or phone reads a babysitting
  workflow as a trigger it doesn't know yet and lists it as inert, which is 008's rule for files
  from the future.
- The new `WorkflowRefusal` cases can't be made readable to an older build. An older phone fails to
  decode that workflow's summary until it is updated. This is accepted, because the Mac and phone
  are built from the same tree (Risks in plan.md).
- `PullRequestList` is new and only the Mac asks for it.

## R12 — Where the state lives

**Decision**: A new daemon file, `pull-requests.json`, next to `workflows.json`, written by a
`PullRequestStore` shaped like `WorkflowStore` (it reads leniently, and a file it cannot read reads
as empty). It holds the R6 keys and watermarks, the R8 counts, the last run and last refusal for
each pull request (FR-019), and the last good fetched list for each project (FR-009). The list is
cached so that a restarted daemon shows something at once, before its first refresh.
