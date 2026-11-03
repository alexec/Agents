---
name: work-a-jira-issue
description: Do the work that a Jira issue asks for, open a GitHub pull request for it, and link the two. Use when the Work a Jira issue workflow starts because a Jira issue got the `agent` label, or when someone asks you to work a Jira issue.
---

# Work a Jira issue

A Jira issue got the `agent` label. You do what it asks, on a branch of your own, open a
pull request on GitHub that fixes it, and link the pull request to the issue. Use
Atlassian's own MCP server (`mcp.atlassian.com`) for Jira and the `github` server's tools for
GitHub. The issue's key is its project key and number, such as `PROJ-12`.

1. **Read the issue.** Use Atlassian's server to get the issue by its key from the event,
   with its description and comments. When you do not have Atlassian's server, use the
   `jira` server's `show_issue_details` for the description, and say in the pull request
   that you could not read the comments. If the issue is not clear enough to do, ask one
   question in a comment on the issue, say that you stopped, and stop.
2. **Take it.** With Atlassian's server, assign the issue to the person who signed in to it
   and move it to the project's first In Progress status.
3. **Make a branch.** Use the app's `move_worktree` tool to move into a new worktree on a
   branch called `agent/<key>` (`agent/PROJ-12`), from the default branch. When you do not
   have that tool, use `git worktree add` beside the folder's folder. The key in the branch
   is how Jira's development panel links them.
4. **Do the work.** Change only what the issue asks for. Follow the folder's own
   instructions (`AGENTS.md`, `CLAUDE.md` or `README.md`, when there is one). Run the
   folder's tests and linters for the files that you changed.
5. **Push.** Commit with a message that starts with the key (`PROJ-12: …`), and push the
   branch with `git push -u origin agent/<key>`.
6. **Open the pull request.** Use `create_pull_request` in this folder's repository, with
   the default branch as `base`. The title starts with the key (`PROJ-12: …`). The body says
   what you changed, how you tested it, and has the issue's url.
7. **Tell the issue.** With Atlassian's server, comment on the issue with a link to the pull
   request.

Never merge, approve or close a pull request, and never push to the default branch.
