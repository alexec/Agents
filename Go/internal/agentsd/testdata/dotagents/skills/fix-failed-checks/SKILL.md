---
name: fix-failed-checks
description: Find why a pull request's checks or a merge request's pipeline failed, fix it on its branch and push, or run the failed jobs again when the failure is not caused by the change. Use when the Fix failed checks workflow starts on checks.failed, or when someone asks you to fix failed checks.
---

# Fix failed checks

A pull request's checks (GitHub, Forgejo) or a merge request's pipeline (GitLab) failed.
You find why, and fix it on its own branch. The event's server says which forge: use the
`github`, `gitlab` or `forgejo` server's tools, not `gh` or `glab`.
On GitLab a merge request is `pr` in the event, and its number is its iid (`!12`).

| Step | GitHub (`github` server) | GitLab (`gitlab` server) | Forgejo or Gitea (`forgejo` server) |
|---|---|---|---|
| Read the failure | `get_job_logs` with `run_id` (the event's `run.id`) and `failed_only: true` | `failed_log` with `pipelineId` (the event's `run.id`) | `failed_log` with `runId` (the event's `run.id`) |
| See the change | `pull_request_read` (`method: get_diff`) | `git diff` of the branch against its target, after step 3 | `git diff` of the branch against its target, after step 3 |
| Run the failed jobs again | `actions_run_trigger` (`method: rerun_failed_jobs`, `run_id`) | `retry_pipeline` with `pipelineId` | `retry_pipeline` with `runId` |
| Comment | `add_issue_comment` on the pull request | `comment_on_merge_request` | `comment_on_pull_request` |

On Forgejo, a `run.id` of 0 is a check from another CI than Forgejo Actions (Woodpecker,
say): `failed_log` and `retry_pipeline` cannot read or run it. Read its page (`get_checks`
gives the address), and comment when you cannot get to the log. `failed_log` needs Forgejo
16 or Gitea 1.25, and `retry_pipeline` Forgejo 17 or Gitea 1.26; on an older server each
says so and gives the run's address.

1. **Read the failure.** Use the tools in the table.
2. **Decide.** When the failure is not caused by the change (a test that fails on the
   default branch too, a timeout, a runner or network problem), run the failed jobs again,
   comment to say why, and stop.
3. **Get the branch.** Use the app's `move_worktree` tool to move into a worktree on the
   branch (the event's `pr.branch`). When you do not have that tool, use
   `git worktree add` beside the folder. Pull it first, so that you have its
   newest commit.
4. **Fix it.** Change only what makes the check pass. Never turn off, skip or weaken a
   check or a test to make it pass. Run the check that failed, on your computer, when you
   can.
5. **Push.** Commit with a message that says which check you fixed, and push to the same
   branch. Never force-push.
6. **Tell the pull request or merge request.** Comment to say what failed and what you
   changed.

When the fix is not clear, or it needs a decision from a person, do not push. Comment to
say what you found, and stop. Never merge, approve or close the pull request or merge
request.
