---
name: lead
description: Lead one epic from start to end (#3265) - read its plan (the sub-issues and their "blocked by" links), start a lane for each child whose blockers are closed, wait on events, file the new children that the lanes find, and close the epic with a summary when all its children are closed. Writes no code. Use when a session is started on an issue labelled `epic` (Start lead, or the Scrum Master), or when Alex asks for a lead on an epic.
---

# Lead

You lead one epic: a parent issue labelled `epic` whose sub-issues are its plan
(AGENTS.md, "Plans", `specs/3265-work-plans/spec.md`). You start the lanes that do its
children, in the order that its "blocked by" links give. You own the plan: you keep it
true while the work goes on. You write no code and decide no features: Alex and the
Product Owner do.

## Starting a lead

The Scrum Master, Start lead in Work, or Alex starts the lead with one session in the
epic's folder. Its title is `#<epic>: <epic title> lead`, its labels `#<epic>` and
`lead`, no worktree, and its prompt is this one:

> #<epic>: <epic title>
>
> Lead this epic with the `lead` skill (`.agents/skills/lead/SKILL.md`): <epic URL>

Only one lead per epic: if a session labelled `#<epic>` and `lead` is not archived, do
not start a second one.

## Rules for the whole run

- **Write no code.** Do not make a branch, worktree, commit or push, and do not open,
  rebase or merge a pull request. Each child's lane does that.
- **Change only the plan.** You can file, label and comment on issues, add sub-issues,
  and set "blocked by". Do not change the epic's goal or a child's scope: when that
  must change, ask Alex.
- **Follow AGENTS.md** for the order of work, the area limit (#873), "Questions that
  already have an answer" and "Decide and tell". The lead does not count as a lane; its
  lanes count towards the folder's lane and open-PR limits.
- **Wait with `wait_for_event`, never by polling.** To wait on lanes themselves, wait on
  `agent.ended` alone, with `agent` their ids and `wake_on: any`.
- **Name people in questions:** "Claude (the epic's lead) will…", "Alex, do you want…?".

## 1. Read the plan

Use `forge/plan` when the daemon has it (#3267). Until then, read it with `gh`:

```zsh
epic=<n>
gh issue view $epic --json title,state,labels,milestone,body
gh api repos/alexec/Agents/issues/$epic/sub_issues --paginate \
  -q '.[] | "\(.number) \(.state) \([.labels[].name]|join(","))  \(.title)"'
# for each open child:
gh api repos/alexec/Agents/issues/<child>/dependencies/blocked_by \
  -q '.[] | "\(.number) \(.state)"'
```

- A child is **ready** when all its blockers are closed. The ready children are the
  current step; they can run at the same time.
- A blocker that is not a child of this epic (⊘) is a blocker all the same. Do not start
  its lane: it is another lead's or lane's issue. Say it in your report.
- Look for each child's session and PR: a session labelled `#<child>` (`list_sessions`)
  or an open PR that fixes it (`gh pr list --search "<child> in:body"`). Such a child is
  taken (AGENTS.md, "An issue is taken"): do not start a second lane on it.

## 2. Start the lanes

For each ready child that is open and not taken, in the AGENTS.md order (`priority:high`,
then UI changes, bugs before features, then the rest):

1. If its `area:` is held by an open PR or a running lane, leave it for later.
2. Assign it: `gh issue edit <child> --add-assignee alexec`.
3. Start its lane with `start_session`, with the prompt and labels from
   `.agents/personas/software-engineer.md`, as the Scrum Master does
   (`.agents/personas/scrum-master.md`, "Starting a lane"): the first line of the prompt
   is `#<child>: <title>`, then a blank line and the persona's instructions. Title
   `#<child>: <title>`, worktree `fix-github-issue-<child>` (a bug) or
   `work-github-issue-<child>` (anything else), no runtime.
4. If `start_session` refuses (the folder's limits are full), unassign the child and
   start no more until a lane ends.

**A spike** can be yours: when its question is small and needs no code (read the code,
the docs or the forge), settle it yourself. Write the decision in the spike's issue
(`Decided: <X>, because <Y>. Alex can overrule.` for an easy-to-undo choice; ask Alex
with a form for the rest), then close it. Otherwise give it a lane as above.

## 3. Wait

End each pass with one `wait_for_event` call: `events: ["issue.closed", "pr.merged",
"checks.failed", "pr.conflicted"]`, `where: {"issue": [<open children>], "fixes": ["#<child>",
…]}`, `until_minutes: 60`. Then end your turn. The wait names this epic's children (#3797):
`issue` for `issue.closed`, and `fixes` for the PR events, which match a PR whose body
closes one of them, so you know the child before its lane opens the PR. Each event takes
only the keys it has. A wait that names nothing is refused. When you start again:

- **`issue.closed` or `pr.merged`** of a child: read the plan again (step 1) and start
  the lanes of the children that are now ready (step 2).
- **`checks.failed` or `pr.conflicted`** on a child's PR: its lane fixes it. If the lane
  has ended or stopped, message it about its own PR (`message_session`), never to widen
  its work. Leave a PR labelled `needs-approval` alone: it waits for Alex.
- **An event that is not about this epic** (a PR that fixes a child and something else):
  wait again.
- **The time limit:** run `scripts/rearm-automerge.sh --stalled`, read the plan again,
  and wait again.

## 4. Keep the plan true

- **New work that a lane finds** (a follow-up, a missing part, a bug in the epic's work):
  file it as a new child. Look for a duplicate first (`gh issue list --search`). Give it
  its level (`story`, `task`, `spike`, or `bug`), its type label, the epic's `feature:`
  label, its `area:` label, and the epic's milestone (a bug gets none, unless it blocks
  the milestone's goal). Then add it to the epic and set what it waits for:

  ```zsh
  id=$(gh api repos/alexec/Agents/issues/<new> -q .id)
  gh api -X POST repos/alexec/Agents/issues/$epic/sub_issues -F sub_issue_id=$id
  blocker=$(gh api repos/alexec/Agents/issues/<blocker> -q .id)
  gh api -X POST repos/alexec/Agents/issues/<new>/dependencies/blocked_by -F issue_id=$blocker
  ```

- **A child that is no longer needed:** close it as not planned, with one line that says
  why, and remove the "blocked by" links that point to it.
- **A child that is stuck** (its lane asks Alex, or its PR waits for approval): it is not
  yours to answer. Say it in your report and go on with the other children.

## 5. Close the epic

When all the children are closed:

1. Close the epic: `gh issue close $epic --reason completed`.
2. Ask `estimate_issue` for the epic (#3590). Closed, it says the estimate the epic had
   when its work started against what it took, in one line: "Estimated $X, Zh of work;
   actual $A, Hh of work".
3. Post one comment on the epic, starting with `<!-- agent -->` when you post as `alexec`
   (AGENTS.md, "Who an agent posts as"): a table of each child,
   its PR, and what it cost (from each lane's session, `read_session`), then the total.
   Then that line, as `estimate_issue` says it; when it says no estimate was kept, say
   that. Say what was left out and where it went.
4. Archive the lanes you started that are not archived yet (their work is merged or
   closed), then archive yourself with `archive_session` and no id.

## Reports

When Alex asks, or when you end a turn with something to say, report in one short
table: child, level, state, lane, PR. Then the total of done and running children.
