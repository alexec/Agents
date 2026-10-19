---
name: work-an-issue
description: Do the work that a GitHub issue asks for and open a pull request for it. Use when the Work an issue workflow starts because an issue got the `agent` label, or when someone asks you to work an issue.
---

# Work an issue

An issue got the `agent` label. You do what it asks, on a branch of your own, and open a
pull request that fixes it. You use the `github` server's tools for GitHub, not `gh`.

1. **Read the issue.** Use `issue_read` (`method: get`, then `method: get_comments`) with
   the repo and the issue number from the event. If the issue is not clear enough to do,
   use `add_issue_comment` to ask one question, say that you stopped, and stop. When the
   issue is not on GitHub (its url is not on github.com, as for a Linear issue), read it
   from the event's data, and open the pull request in the repository of this project.
2. **Make a branch.** Use the app's `move_worktree` tool to move into a new worktree on a
   branch called `agent/issue-<number>`, from the default branch.
3. **Do the work.** Change only what the issue asks for. Follow the project's own
   instructions (`AGENTS.md`, `CLAUDE.md` or `README.md`, when there is one). Run the
   project's tests and linters for the files that you changed.
4. **Push.** Commit with a message that names the issue (`Fixes #<number>`), and push the
   branch with `git push -u origin agent/issue-<number>`.
5. **Open the pull request.** Use `create_pull_request` with the default branch as `base`.
   The body says what you changed, how you tested it, and `Fixes #<number>`.
6. **Tell the issue.** On GitHub, use `add_issue_comment` on the issue with a link to the
   pull request.

Never merge, approve or close a pull request, and never push to the default branch.
