---
name: fill-free-slots
description: Find the free agent slots in this folder and start an agent on each open, unassigned GitHub issue until the slots are full. High issues, then UI changes (bugs first), then open-milestone issues and bugs go first (never the next milestone), walk lanes go first while more than five issues need a walk, spare slots go to polish and competitor issues by RICE, then to the backlog, and only one lane works in each area. Nothing else. Use when the Fill free slots workflow runs, or when Alex asks to fill the free slots.
---

# Fill free slots

This is the method of the Fill free slots workflow
(`.agents/workflows/fill-free-slots.md`). The workflow says what the method is for and
starts it. A person or an agent can also follow it by hand. Where it says that nobody is
at the keyboard, that is true only of a run of the workflow.

## 1. Free slots

- Read the limits from `.agents/folder.json` (`helperLimits.running` is how many agents
  may run at once in this folder).
- Count the agents running now: `list_sessions` with `limit: 100`, paging with `after`
  until no more follow; count every session whose status is running or working (not
  `Done`, `Archived`, `Retired`, `Needs you`, `Blocked` or `Paused`). Do not
  count yourself.
- Free slots = the running limit minus that count. If it is 0 or less, say "No free slots:
  N of N running." and call `archive_session` (no id).

## 2. Issues nobody is working on

An issue is being worked on when it is assigned to anyone. Take the open, unassigned
issues that are not labelled `parked`:

```sh
gh issue list --state open --search "no:assignee -label:parked" --limit 100 \
  --json number,title,labels,milestone,createdAt
```

Order them by AGENTS.md, "Work by milestone" (#2309): issues in the open milestone first,
`bug` before the rest, oldest first. Only the open milestone is workable: never start work
for the next milestone, whose issues keep `parked` until the open one ships. Then the
standing issues below, then the backlog (issues with no milestone that are not standing):
`bug` first, then by RICE, highest first.

**UI changes first (#2337).** Before the order above, put the `priority:high` issues, then
the **UI changes**: issues whose change alters what a client shows (`App/Sources`,
`Remote/Sources`, `Shared/UI`, `Web/src`, as their text, area or `.agents/areas` says), from
the open milestone and the backlog alike, `bug` before the rest. Then the rest, in the order
above. A UI issue takes a free slot before a non-UI one. When slots run short, a non-UI lane
waits, never a UI one. Why: a person must review each UI change, so it must get to
`main` and TestFlight early (Alex, 2026-10-22).

**Standing work (#1570, #1604).** The open issues labelled `polish` or `competitor`
with no milestone are standing issues; order them by RICE, highest first. Keep at least
one standing lane running: if no running agent works on a standing issue, the first free
slot goes to the first standing issue whose area is free. Slots left after every
workable milestone issue has an agent also go to standing issues, in RICE order, and
slots left after those go to the backlog. A standing or backlog issue never takes a slot
that an open-milestone issue can fill.

**Untried work first (#611).** Count the issues labelled `needs-walk` (merged UI changes
nobody has run): `gh issue list --state all --label needs-walk --json number,title,assignees`.
While there are more than 5, start no enhancements: after the bugs, take the unassigned
`needs-walk` issues instead, oldest first, as walk lanes (step 3).

**One lane per area (#873).** An issue's area is its `area:<name>` label. If it has
none, guess one from its text and the paths in `.agents/areas`, and add it
(`gh issue edit <n> --add-label area:<name>`); leave it without one if none fits. An area
is held by an open pull request with that label
(`gh pr list --state open --json number,labels`), by the issue of a running agent (its
`#<n>` session label), and by an issue you start in this run. Skip an issue whose area
is held and take the next one. A skipped issue is started by a later run, by a new agent of
its own, once the area is free: it is never handed to the lane that holds the area, and no
running lane is messaged to take it (#2504). An issue without an area is never held.

If there is nothing to start, say "No unassigned issues to start." and call
`archive_session` (no id).

## 3. Start one agent per free slot

Every issue gets its own agent, worktree and pull request (#2504); an agent never takes a
second issue. For each of the first (free slots) issues, in order:

1. Assign it first, so no other run picks it up: `gh issue edit <n> --add-assignee alexec`.
2. Start the lane with the prompt and labels from
   `.agents/personas/software-engineer.md`. Put `#<n>: <issue title>` on the first line
   of the prompt, followed by a blank line and the persona's instructions. Do not put
   code or a preamble before the issue number and title. Do not set a runtime; the lane
   uses the available default. Use a new worktree
   named `fix-github-issue-<n>` (for a bug) or `work-github-issue-<n>` (otherwise), and
   title the session `#<n>: <issue title>`.

   For a walk lane, name the worktree `walk-github-issue-<n>`, title it
   `Walk #<n>: <issue title>`, and use this prompt instead:

   > #<n>: <issue title>
   >
   > This issue's UI change has merged but nobody has run it (`gh issue view <n>`; its
   > pull request says what changed). Walk it on main with the run-app skill (the web page
   > in headless Chrome; Remote screens only by building, never a simulator), on a scratch
   > root, never the real app. Follow AGENTS.md for the "build" lease. If the Mac is
   > locked, leave everything as it is and end your turn. If it works, comment on the issue what you
   > ran and saw, and remove the `needs-walk` label. If not, file a bug for each problem,
   > linked to #<n>, then remove the label. Then close the scratch app (run-app's "When
   > you are done", which deletes the worktree's build output), call move_worktree with
   > leave_worktree: remove, and archive_session with no id.

3. If start_session refuses because the limit is reached, unassign that issue
   (`gh issue edit <n> --remove-assignee alexec`) and stop starting more.

## 4. Report

One line per agent started: `#<n> <title>: started`, and one per issue that could not be
started, with why (for a held area: `#<n> <title>: skipped, area:<name> held by #<m>`), then a line like "Started 2 agents on #427 and #432; 4 of 4 slots
now in use." Then call `archive_session` (no id).
