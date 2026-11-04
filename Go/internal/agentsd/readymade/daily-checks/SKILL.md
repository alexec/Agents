---
name: daily-checks
description: Look at the folders on this machine that had no work since the last check (failing CI on the default branch, pull requests stale or in conflict, issues assigned to the person with no session, a missed scheduled workflow), keep each finding that needs the person as a suggestion with check_folders, and end. Read only; never act. Use when the Daily checks workflow runs.
---

# Daily checks

Between daily summaries, you look at the folders that nobody worked in and find what waits
there. You only read. Do not push, comment, message, start a session or change a file, also
when a fix looks easy: the person decides. The `check_folders` tool keeps what you find, and
the next daily summary lists it.

1. **Get the facts.** Call `check_folders` with `action: collect`. For each quiet folder it
   lists what looks wrong, each with its link. When it says nothing looks wrong, end.
2. **Decide.** For each finding, decide if it needs the person. You can read more to decide
   (git, `gh`, a connector), but only read. Leave out a finding that a pull request or a
   session already fixes.
3. **Keep each one.** Call `check_folders` with `action: suggest`, and:
   - `folder`: the folder's path, as the facts give it;
   - `title`: what is wrong, in one short line, such as "CI fails on main";
   - `prompt`: what a new session in that folder is told to do, such as "Find why the
     Build workflow fails on main since 14:02 and fix it on a branch: <link>";
   - `link`: the finding's link;
   - `urgent: true` only when it should not wait for the summary, such as a broken default
     branch or a release that cannot ship.
   Put findings of one kind in one folder together as one suggestion.
4. **End.** Say in one line how many suggestions you kept. Do not ask anything.
