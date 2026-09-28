# Quickstart: GitHub Project Issue Board

This is a validation guide for implementation. It does not add or execute tests as part of
planning.

## Prerequisites

- A project folder whose `origin` is a GitHub or GitHub Enterprise repository.
- The `gh` CLI installed and authenticated to that host.
- For board reads, GitHub Projects read access and access to the linked repository's issues.
- For assigning issues, GitHub Projects write access and a repository with at least one commit
  so an issue branch/worktree can be created.
- A runtime installed and available to the project.

For classic token authentication, GitHub documents `read:project` for reading Projects and
`project` for editing them. If the existing `gh` session lacks access, the project board should
show the relevant repair command, for example:

```sh
gh auth refresh --hostname github.com --scopes project
```

Replace `github.com` with the repository's GitHub Enterprise host where appropriate.

## Build and package validation

```sh
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
swift test --package-path Packages/AgentsKit
```

Expected: the app and AgentsKit package build successfully; new query decoding, cache, status
mapping, duplicate assignment, and failure recovery tests pass.

## Manual walkthrough

1. Open a project for a repository linked to a GitHub Project containing Ready and In Progress
   issues, plus at least one item in another status.
2. Confirm the project page shows the first linked Project, with only Ready and In Progress
   lanes. Check title, number, description, labels, and GitHub issue links.
3. In an In Progress issue with an assignment from this app, check that the agent's current
   state, branch and worktree are shown and link to their existing app destinations.
4. Assign a Ready issue. Pick a runtime, review the issue-derived task, then confirm.
5. Confirm a fresh agent appears, its own issue-named branch/worktree exists, GitHub moves the
   issue to In Progress, and the card links the issue to that agent/worktree.
6. Cancel a different assignment before confirmation. Confirm no agent/worktree is created.
7. Exercise a branch-name collision and a GitHub status-write failure. Confirm the collision
   does not reuse a branch; when the status write fails after the agent starts, the agent remains
   active and the card offers a status retry without starting a duplicate agent.
8. Refresh, then make GitHub unavailable. Confirm cached rows remain visible with a stale
   indicator. Restore access and refresh to recover current rows.
9. Open a repository with no linked Project, and one without GitHub origin. Confirm the former
   gets an actionable no-project state and the latter has no board section.
10. Narrow the project window. Confirm Ready and In Progress stack without clipping the cards.

## Relevant references

- [Daemon API contract](contracts/daemon-api.md)
- [GitHub Projects contract](contracts/github-projects.md)
- [Data model](data-model.md)
- [Agreed wireframe](../062-github-project-board/wireframe.md)
