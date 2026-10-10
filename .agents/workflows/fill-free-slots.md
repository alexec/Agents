---
name: Fill free slots
on:
  - project.idle
  - schedule:
      at: [":00", ":30"]
      between: "00:00-23:30"
agent: new
runtime: claude
model: sonnet
effort: low
permission-mode: auto
cooldown: 15m
hosts: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [lead, intake]
when-done: archive
---

You keep this project's agents busy. You run with nobody watching. You find out whether
there are free slots for agents in this project and, if there are, start an agent on each
open GitHub issue nobody is working on, until the slots are full. Nothing else: no
clean-up, no parking, archiving or stopping agents, no merging, no builds or tests.

## 1. Free slots

- Read the limits from `.agents/project.json` (`helperLimits.running` is how many agents
  may run at once in this project).
- Count the agents running now: `list_sessions` with `limit: 100`, paging with `after`
  until no more follow; count every session whose status is running or working (not
  `Done`, `Parked`, `Archived`, `Retired`, `Needs you`, `Blocked` or `Paused`). Do not
  count yourself.
- Free slots = the running limit minus that count. If it is 0 or less, say "No free slots:
  N of N running." and park with `park_agent` (no id).

## 2. Issues nobody is working on

An issue is being worked on when it is assigned to anyone. Take the open, unassigned
issues that are not labelled `parked`:

```sh
gh issue list --state open --search "no:assignee -label:parked" --limit 100 \
  --json number,title,labels,createdAt
```

Order them: `bug` first, then everything else; within each, oldest first. If there are
none, say "No unassigned issues to start." and park with `park_agent` (no id).

## 3. Start one agent per free slot

For each of the first (free slots) issues, in order:

1. Assign it first, so no other run picks it up: `gh issue edit <n> --add-assignee alexec`.
2. start_agent with a new worktree named `fix-github-issue-<n>` (for a bug) or
   `work-github-issue-<n>` (otherwise), titled `#<n>: <issue title>`, and this prompt:

   > Work on GitHub issue #<n> (`gh issue view <n>`). Follow AGENTS.md: verify only what
   > you touch, building through scripts/build-cache.sh with the "build" lease, and say
   > in each UI commit what the other two clients do. Commit, push, open a pull request
   > that says "Fixes #<n>", and turn on auto-merge (squash) at once. Then call
   > move_worktree with leave_worktree: remove, and park_agent with no id.

3. If start_agent refuses because the limit is reached, unassign that issue
   (`gh issue edit <n> --remove-assignee alexec`) and stop starting more.

## 4. Report

One line per agent started: `#<n> <title>: started`, and one per issue that could not be
started, with why, then a line like "Started 2 agents on #427 and #432; 4 of 4 slots
now in use." Then park with `park_agent` (no id).
