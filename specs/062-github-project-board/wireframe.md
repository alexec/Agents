# GitHub project board — wireframe

This is a project page section, not a separate destination: the board belongs to the
repository the selected project already represents. When a repository belongs to
multiple GitHub Projects, use the first one returned. Pull requests remain a separate
section.

## Project page

```text
┌──────────────────────────────────────────────────────────────┐
│ agents                                                       │
│ New session                                                  │
│ [ Start a session…                                      Send ]│
│                                                              │
│ Issues                                      [Open on GitHub ↗]│
│ alex/project · refreshed 2m ago                    [Refresh ↻]│
│                                                              │
│ READY · 3                                      IN PROGRESS · 2│
│ ┌────────────────────────┐                  ┌────────────────────────┐
│ │ #184 Add export button │                  │ #181 Fix import crash  │
│ │ Add CSV export to…     │                  │ Import fails on…       │
│ │ ● bug  ○ enhancement   │                  │ ● bug                  │
│ │                        │                  │                        │
│ │ [Assign to agent]    │                  │ ● Claude · working     │
│ │                        │                  │ branch: fix/import     │
│ │                        │                  │ worktree: fix-import ↗ │
│ └────────────────────────┘                  └────────────────────────┘
│ ┌────────────────────────┐                  ┌────────────────────────┐
│ │ #179 Document config   │                  │ #176 Add retry logic   │
│ │ Clarify the setup…     │                  │ ● Codex · waiting      │
│ │ ○ documentation        │                  │ branch: retry-logic    │
│ │ [Assign to agent]    │                  │ worktree: retry-logic ↗│
│ └────────────────────────┘                  └────────────────────────┘
│                                                              │
│ Pull requests                                                 │
│ …                                                            │
│ Workflows                                                     │
│ …                                                            │
│ Worktrees                                                     │
│ …                                                            │
└──────────────────────────────────────────────────────────────┘
```

At the app's current narrow project-page width, columns stack vertically instead
of squeezing cards. Only **Ready** and **In progress** are shown. “In progress” is
the board's status, while the agent's live state (“working” / “waiting”) remains a
separate, smaller signal.

## Assign an issue

```text
┌───────────────────────────────────────────┐
│ Assign #184 · Add export button            │
│ Choose an agent                            │
│                                           │
│ Start a new agent                          │
│   Runtime [Claude ▾]                       │
│   [Use issue title and description]        │
│                                           │
│ A branch and worktree will be created      │
│ branch: issue-184-add-export-button        │
│                                           │
│                         [Cancel] [Assign]  │
└───────────────────────────────────────────┘
```

Assignment creates a fresh agent and creates a worktree on a new branch for the issue.
The issue card moves to **In progress** once the repository's board reflects that
status; it shows the agent and branch/worktree relationship. The branch and worktree
are links to their existing project views. If assignment fails, keep the issue in
Ready and show the reason in the assignment sheet.
