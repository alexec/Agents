---
name: fix-failed-checks
description: Find why a pull request's checks failed, fix it on the PR's branch and push, or run the failed jobs again when the failure is not caused by the change. Use when the Fix failed checks workflow starts on checks.failed, or when someone asks you to fix a PR's failed checks.
---

# Fix failed checks

A pull request's checks failed. You find why, and fix it on the pull request's own branch.
You use the `github` server's tools for GitHub, not `gh`.

1. **Read the failure.** Use `get_job_logs` with the repo, `run_id` (the event's `run.id`)
   and `failed_only: true`. Use `pull_request_read` (`method: get_diff`) to see what the
   pull request changes.
2. **Decide.** When the failure is not caused by the change (a test that fails on the
   default branch too, a timeout, a runner or network problem), use `actions_run_trigger`
   with `method: rerun_failed_jobs` and `run_id`, use `add_issue_comment` on the pull
   request to say why, and stop.
3. **Get the branch.** Use the app's `move_worktree` tool to move into a worktree on the
   pull request's branch (the event's `pr.branch`). Pull it first, so that you have its
   newest commit.
4. **Fix it.** Change only what makes the check pass. Never turn off, skip or weaken a
   check or a test to make it pass. Run the check that failed, on your computer, when you
   can.
5. **Push.** Commit with a message that says which check you fixed, and push to the same
   branch. Never force-push.
6. **Tell the pull request.** Use `add_issue_comment` on the pull request to say what
   failed and what you changed.

When the fix is not clear, or it needs a decision from a person, do not push. Use
`add_issue_comment` to say what you found, and stop. Never merge, approve or close the
pull request.
