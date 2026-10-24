---
name: feature-matrix
description: Bring docs/reference/feature-matrix.md up to date with what Agents shipped since the last update and with what the newest Competitor check report found, on a pull request of its own. Build nothing. Use when the Feature matrix workflow runs in a release (#1462), or when Alex asks to update the feature matrix.
---

# Feature matrix

This is the method of the Feature matrix workflow (`.agents/workflows/feature-matrix.md`).
The workflow says what the method is for and starts it. A person or an agent can also
follow it by hand. Where it says that nobody is at the keyboard, that is true only of a
run of the workflow.

## Rules for the whole run

- **Never touch the folder you start in.** It is the shared checkout of `main`.
  Do any edits in a worktree of your own (step 3).
- One pull request per release at most. If an earlier one from this workflow (branch
  `agents/feature-matrix-*`) is still open, do not open another: say so and call
  `archive_session` (no id).
- Hold every app to the bar the page states, Agents included: a ● needs the whole
  feature, merged on `main` and documented; a ○ needs evidence. A feature that is only
  in an open PR or an issue does not count.
- **Questions.** Nobody is at the keyboard. Do not ask; write anything that needs a
  decision (a new feature column, an app to drop) in the pull request's body and in your
  ending. If you must ever ask, name yourself ("The feature matrix update recommends…
  Alex, do you want…?"), never a bare "I" or "you".

## 1. What Agents shipped

1. Find when Agents' row was last brought up to date: the date in the page's "Agents' row
   was last brought up to date on …" sentence, and `git log -1 --format=%ad --date=short
   -- docs/reference/feature-matrix.md`. Take the earlier.
2. List the commits on `origin/main` since then: `git log --since=<date> --format='%h %s'
   origin/main`, and read the body of each one that may change a feature in the page's
   "What each feature means".
3. For each feature, check whether Agents' cell is still right. Where a commit changes
   it, note the cell, the new mark and the commit or PR number.

## 2. What the Competitor check found

1. Read the newest report in `~/.agents/reviews/competitors/` newer than the date in step
   1, if there is one.
2. For each app in the report that is in the matrix, check its cells against what the
   report says shipped, with the report's sources. For an app the report adds, add a row
   in each table and a line under "The apps", filled from the app's own docs, changelog,
   README and, where open, source. Mark ?⃝ where they do not say.
3. Do not add a feature column. List any new feature that several apps have in your
   ending and in the pull request's body, for Alex to decide.

If nothing changes in steps 1 and 2, say so and call `archive_session` (no id).

## 3. Change it

1. Move into a worktree off the latest `main` through the app (#615): `git fetch origin`,
   check `main` here is `origin/main` (`git merge --ff-only origin/main` if not), then
   move_worktree with worktree `feature-matrix-<today, YYYY-MM-DD>` and end your turn; you
   are started again in it, on `agents/feature-matrix-<date>`.
2. Change the cells. Then, for each row you changed, compute its table's **Score** again
   (● 1, ◐ 0.5, ○ and ?⃝ 0, over the table's scored features) and move the row to its
   place: sorted by score, then by name. Compute the **Overall score** table again (points
   over all scored features) and its ranks; apps with the same overall score share a
   rank.
3. Bring "Where Agents falls short" in step with Agents' ◐ and ○ cells: take out a line
   whose cell is now ●, and change a line whose reason changed.
4. Change the date in "Agents' row was last brought up to date on …" to today.
5. Commit with a message that lists each changed cell (app, feature, old → new mark,
   source) and ends with `mac: docs only, remote: docs only, web: docs only`.
6. Push and open a pull request with auto-merge (squash), as every agent here does:
   `gh pr create --fill` then `gh pr merge --auto --squash`. The body holds the list of
   changed cells and anything for Alex to decide.
7. Wait for its checks: call wait_for_event with `until_minutes: 20` and no events, and
   when started again check them with `gh pr checks`; if they are still running, wait
   again the same way. Fix what fails because of your change; rerun a check that failed
   for something else.

## 4. Report

1. Remove your worktree once the pull request has merged (move_worktree with
   leave_worktree `remove`).
2. End with one sentence: how many cells changed, Agents' overall score and rank before
   and after, and the pull request's link. Then call `archive_session` (no id).
