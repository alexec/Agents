# Research: GitHub Project Issue Board

## R1 — Access GitHub Projects v2 through the existing GitHub client

**Decision**: Use the existing daemon `GitHubCLI.graphql` wrapper for Project v2 queries and
mutations. It runs the person's `gh` executable with prompts disabled and targets the remote's
GitHub host, matching the pull-request integration's credential handling.

**Rationale**: The app already finds the repository from `origin`, supports GitHub Enterprise
hosts, and keeps tokens inside GitHub CLI. A second credential store would add setup and security
surface without adding capability.

**Alternatives considered**: A new app-managed OAuth flow or REST-only integration. Neither is
needed for this feature; Projects v2 documents its board and status-field operations in GraphQL.

**Permissions**: GitHub's Projects API guide says reads need the `read:project` scope and edits
need the `project` scope for classic OAuth/PAT authentication. Fine-grained credentials need
equivalent Projects permissions and access to linked private repository issues. The app should
surface missing permissions with a command or explanation, not request/store a token itself.

Sources: [GitHub Projects API guide](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects),
[GraphQL repositories reference](https://docs.github.com/en/graphql/reference/repos),
[GitHub App permission choices](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app).

## R2 — Find one linked project and its Ready/In Progress items

**Decision**: Query the repository's `projectsV2` connection and choose its first returned
project. Read the project's items, issue content, field values, and field metadata. Recognize
the single-select Status field's Ready and In Progress option IDs by their labels; do not hard
code field or option IDs.

**Rationale**: The repository GraphQL schema exposes projects linked to a repository, and the
project schema exposes items and configurable fields. Status option IDs vary per project, so the
query must inspect the field configuration before classifying or moving items.

**Alternatives considered**: Listing every project under a user or organization and guessing
which one applies. The repository-linked connection directly answers the product question and
preserves the user's first-project choice.

**Constraints**: GitHub's connection does not promise a human-defined ordering in the schema;
"first" therefore means the first result in the connection response, as requested. Paginate
project items as needed. If no linked project or supported status option exists, show the
appropriate empty or unavailable state rather than treating every issue as Ready.

Source: [GitHub GraphQL Projects reference](https://docs.github.com/en/graphql/reference/projects).

## R3 — Set the issue's board status

**Decision**: After the agent starts successfully, update the existing project item using
`updateProjectV2ItemFieldValue` with its Status field ID and In Progress option ID. Do not add an
issue to a project as a side effect of assigning it.

**Rationale**: The spec says Ready issues are assigned and become In progress. GitHub documents
that the mutation changes a field on an existing Project item, and that adding an item and
updating its field cannot be done in the same call. The assignment is specifically for an
existing board issue, so no implicit add is needed.

**Failure behavior**: Starting an agent/worktree is local work that should not be stopped or
discarded because a later GitHub status mutation fails. Persist the association, show the update
as pending/failed, and offer a retry. A repeated retry must be safe if GitHub already applied the
first mutation but its response was lost.

Sources: [Managing Projects with the API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects),
[Projects GraphQL mutations](https://docs.github.com/en/graphql/reference/projects).

## R4 — Start a fresh issue agent in a named worktree

**Decision**: Use the ordinary daemon `agents/start` flow and its `.new` worktree semantics,
extended with a named-new-worktree choice whose name is derived from the issue number and
title. Store the issue reference alongside the agent assignment.

**Rationale**: The existing start path creates a worktree before launching the selected runtime,
records the actual branch/worktree on the agent, and already handles name collisions. The
current `.new` name is derived from prompt words, which is not a stable issue association, so
the added named choice and explicit persisted issue reference make the link dependable.

**Alternatives considered**: Infer the issue from the generated branch name. That can collide,
be edited by a person, or fail to carry a project/item identity; it is not a reliable durable
relationship.

Sources: `specs/030-agent-worktrees/contracts/worktrees.md`,
`Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`,
`Packages/AgentsKit/Sources/AgentsKit/Projects/GitWorktrees.swift`.

## R5 — Follow existing daemon-owned cache and UI patterns

**Decision**: Keep GitHub board data and assignments in daemon-owned stores, expose cached list,
refresh, assign, and status-retry operations through DaemonAPI, and notify the Mac when board
state changes. Render in a section adjacent to Pull requests with cached, stale, loading,
empty, and actionable error states.

**Rationale**: Pull requests already follow this project-folder-keyed cache and notification
pattern. Keeping GitHub I/O in the daemon lets the window remain a renderer and keeps GitHub CLI
available in the same host context as the project.

Sources: `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+PullRequests.swift`,
`Packages/AgentsKit/Sources/AgentsKit/GitHub/PullRequestStore.swift`,
`Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`,
`App/Sources/Projects/PullRequestsSection.swift`.

## Unresolved platform limitations

- A person needs both project access and access to the linked private repository's issues.
- Some fine-grained credential types may not expose Projects for every owner type. If `gh`
  cannot access the selected project, explain the permission limitation rather than attempting
  to bypass the person's configured authentication.
- Projects with a missing Status field or without the exact Ready/In Progress options cannot
  support the complete flow. The UI should say which board configuration is missing; assignment
  must be disabled when it cannot safely move the item into In Progress.
