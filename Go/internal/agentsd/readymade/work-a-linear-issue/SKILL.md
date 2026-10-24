---
name: work-a-linear-issue
description: Do the work that a Linear issue asks for, open a GitHub pull request for it, and link the two. Use when the Work a Linear issue workflow starts because a Linear issue got the `agent` label, or when someone asks you to work a Linear issue.
---

# Work a Linear issue

A Linear issue got the `agent` label. You do what it asks, on a branch of your own, open a
pull request on GitHub that fixes it, and link the pull request to the issue. Use Linear's
own MCP server (`mcp.linear.app`) for Linear and the `github` server's tools for GitHub.
The issue's identifier is its team key and number, such as `ENG-12`.

1. **Read the issue.** Use Linear's server to get the issue by its identifier from the
   event, with its description and comments. When you do not have Linear's server, use the
   event's data, and say in the pull request that you could read only the title. If the
   issue is not clear enough to do, ask one question in a comment on the issue, say that
   you stopped, and stop.
2. **Take it.** With Linear's server, assign the issue to the person who signed in to it and
   move it to the team's first started state (In Progress).
3. **Make a branch.** Use the app's `move_worktree` tool to move into a new worktree on a
   branch called `agent/<identifier>` in lower case (`agent/eng-12`), from the default
   branch. When you do not have that tool, use `git worktree add` beside the folder's
   folder. The identifier in the branch is how Linear's GitHub integration links them.
4. **Do the work.** Change only what the issue asks for. Follow the folder's own
   instructions (`AGENTS.md`, `CLAUDE.md` or `README.md`, when there is one). Run the
   folder's tests and linters for the files that you changed.
5. **Push.** Commit with a message that starts with the identifier (`ENG-12: …`), and push
   the branch with `git push -u origin agent/<identifier>`.
6. **Open the pull request.** Use `create_pull_request` in this folder's repository, with
   the default branch as `base`. The title starts with the identifier (`ENG-12: …`). The
   body says what you changed, how you tested it, and has the issue's url and
   `Fixes <identifier>`, so Linear closes the issue when the pull request merges.
7. **Tell the issue.** With Linear's server, comment on the issue with a link to the pull
   request, and attach the pull request's url to the issue when the server can.

Never merge, approve or close a pull request, and never push to the default branch.
