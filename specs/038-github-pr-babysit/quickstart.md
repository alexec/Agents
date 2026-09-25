# Quickstart: Proving 038 Works

The methods and tools are in [contracts/pull-requests.md](contracts/pull-requests.md). The
records are in [data-model.md](data-model.md).

## Prerequisites

- `gh auth status` shows a signed-in account for `github.com`.
- A **throwaway GitHub repository** the person owns, for example `alexec/agents-babysit-sandbox`.
  It needs:
  - A GitHub Actions check that fails when a file `FAIL` exists.
  - A second account, or a collaborator, who can leave review comments.

  Pushing and commenting on it is outward-facing, so Alex creates it or approves it once.
- The app built from this branch, run on a scratch root with the run-app skill. It never uses the
  real daemon.

## 1. Unit and integration (no network)

```bash
cd Packages/AgentsKit && swift test --filter 'PullRequest|GitHub|WorkflowTrigger|Babysit'
```

These show:
- `GitHubRepository` accepts `github.com` and `github.example.com`, in HTTPS and scp form, and
  refuses `gitlab.com` (FR-001).
- A recorded GraphQL response decodes to the right checks, review and conflict state.
  `authorAssociation: NONE` comments are dropped (FR-011a). Pull requests are sorted newest
  first.
- Change keys: the same response twice fires once. A new failing check id fires again. `UNKNOWN`
  mergeability does not fire (FR-013).
- First sight: only comments newer than the viewer's own last action count (R6).
- The babysitting count: three runs, then `.babysittingStopped`. A head oid that babysitting did
  not push resets it. A pushed oid does not. Resume resets it (FR-023, FR-024).
- The refusal order: no worktree, then stopped, then dirty, then busy (R9). Repeats collapse.
- The workflow file with the three names round-trips. An old-shape reader sees `.unrecognised`
  (R11).
- Against a real temporary repo, with a fake `gh` script on PATH that prints recorded JSON:
  - A pull request is matched to the project folder and to a worktree.
  - `checkout` makes a worktree on the existing branch.
  - `push_pull_request` pushes to a local bare "remote" and refuses a non-fast-forward.
  - A fire starts a fake runtime whose `cwd` is the worktree and whose prompt names the pull
    request, the check and its log URL.

## 2. The list, on a scratch app (US1)

1. Clone the sandbox as a project in the scratch app. Open two pull requests as yourself, one with
   `FAIL` committed. Have the collaborator open a third.
2. Open the project. **Expect** a Pull requests section within 5 s (SC-001):
   - Exactly the two pull requests, newest first.
   - The failing one shows ✕ checks.
   - Neither is matched yet, and each offers **Check out into a worktree**.
3. Check one out. **Expect** its row to name the new worktree.
4. Add a project with no GitHub remote. **Expect** no section (SC-006).
5. Run `gh auth logout --hostname github.com` with a scratch `GH_CONFIG_DIR` in the daemon's
   environment. **Expect** the one line from FR-003.

Screenshot the section. **This is the layout gate**: settle it with Alex before Phase 4.

## 3. Babysitting, live (US2, US3)

1. On the project page, choose **Babysit my pull requests**. **Expect**:
   - `.agents/workflows/babysit-pull-requests.md` exists, and its row lists the three triggers in
     words.
   - The button now reads **Show babysitter**.
2. Push a commit adding `FAIL` to the checked-out pull request's branch, and wait for the check to
   fail. **Expect**, within 6 minutes and with nobody touching the Mac (SC-002):
   - An agent in that worktree, whose prompt names #n, the check and its log.
   - It removes `FAIL`, commits, and calls `push_pull_request`.
   - A new commit is on the branch.
   - Both the pull request's row and the workflow row say it ran.
3. As the collaborator, leave a line comment. **Expect** a run whose prompt quotes it with the file
   and line, and a reply under the comment from the agent.
4. As a non-collaborator (or through a test-only override of the association), comment. **Expect**
   no run (FR-011a).
5. Make the check fail for a reason no commit fixes, for example a workflow step that always exits
   1. **Expect** three runs, and then the row says "Babysitting stopped after 3 tries" with Resume.
   Push by hand. **Expect** the count to reset.
6. Leave uncommitted changes in the worktree, then trigger. **Expect** "Did not run — #n's worktree
   has uncommitted changes".

## 4. Never

Across section 3, use `gh api repos/<o>/<r>/events` and the branch's reflog to check (SC-004):
- No force-push.
- No push to any branch but the pull request's.
- No merge, close, approve, or title or body edit.
