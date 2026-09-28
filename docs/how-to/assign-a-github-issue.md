---
diataxis: how-to
description: Start a fresh agent from an issue on a repository's GitHub Project board.
devices: [mac]
---

# Assign a GitHub issue to an agent

On a project page for a GitHub repository, the **GitHub Project** section shows issues in
**Ready** and **In progress** from the first Project v2 linked to that repository.

## Before you start

- Install and sign in to the GitHub CLI (`gh`) for the repository's host.
- Give `gh` permission to read the project. For classic token authentication, this is the
  `read:project` scope.
- To assign an issue, allow project edits (`project` scope), and have an available agent runtime.
- The repository needs a commit to create an issue worktree.

If access is missing, the board shows the command needed to refresh GitHub CLI access. For
example:

```sh
gh auth refresh --hostname github.com --scopes project
```

## Start an agent

1. Choose **Assign to agent** on a Ready issue.
2. Select an available runtime and review or edit the task prompt.
3. Choose **Start agent**.

The app creates a fresh agent and a worktree on an `agents/issue-<number>-<title>` branch,
then moves the issue to **In progress**. The card links to the agent and shows its branch.
The agent's edits stay in that worktree until you merge them.

If GitHub cannot update the status after the agent starts, the app keeps the agent and its
issue link. Choose **Retry status** on the card to retry only the GitHub update.

The app uses the GitHub CLI's existing sign-in; it does not keep a GitHub token in the app.
The first linked project is selected when a repository belongs to more than one.

## Related

- [Projects, hosts and worktrees](../explanation/projects-hosts-worktrees.md)
- [GitHub Project issue board specification](../../specs/063-github-project-board/spec.md)
- [Issue board wireframe](../../specs/062-github-project-board/wireframe.md)
