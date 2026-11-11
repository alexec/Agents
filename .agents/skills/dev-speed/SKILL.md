---
name: dev-speed
description: Find out where this folder's recent agent sessions spent their time (builds, tests, lint, the build lease's line, waits, CI, questions, the model's own time) from the app's session records, find the causes of the largest costs, and make development faster with one change on a pull request of its own and at most three issues for the rest. Never weaken a check. Use when Alex asks why development is slow, how to make lanes faster, or for a dev-speed check.
---

# Dev speed check

Lanes spend their time in five places: the model's own work (reading, thinking,
writing), tools (builds, tests, lint, walks, `gh`, `git`), waits inside a turn
(`wait_for_event` holds a turn for up to 45 s, a question card holds it until the person
answers), the line for the `build` lease, and the time between turns (CI, merges,
reviews, timers). This skill measures each from the app's own records and removes the
largest cost that a change in this repo can remove.

The `ci-speed` skill owns CI itself (`.github/workflows/ci.yml`). This skill owns what
happens on this Mac and in the sessions: scripts, skills, personas and the way lanes
use the lease, the waits and the tools. When CI is the largest cost, say so and point
to `ci-speed`; do not change `ci.yml` here.

## Rules for the whole run

- **Read only, until step 4.** The session records are the app's. Never write to
  `~/Library/Application Support/Agents`, and never stop, message or archive a session
  that is not yours.
- **Never touch the folder you start in.** It is the shared checkout of `main`. Make
  edits in a worktree of your own (step 4).
- **Never weaken a check.** No skipping or deleting tests, no dropping a lint, a scheme
  or `scripts/go-changed.sh` before a push, no `continue-on-error`. Making a check do
  the same work in less time (a cache, a filter by changed paths, running in parallel)
  is in scope.
- **A rule Alex made is Alex's.** A rule in `AGENTS.md` or a persona that names Alex and
  a date (for example the lane and open-PR limits), and a resource Alex declared (the
  `build` lease and how many may hold it), changes only with Alex's agreement. Put the measured cost and the
  proposal in an issue, and say in your ending that it waits for Alex.
- **The records are private; the repo is public.** Transcripts can hold Alex's data,
  tokens and other people's text. The report goes to
  `~/.agents/reviews/dev-speed/`, never into the repo. An issue or PR body gives only
  numbers, categories, script names and short commands, never transcript text, a
  session's prompt or a command's output.
- **One change per run.** One pull request with the change that saves the most, and at
  most three issues for the next ones. If an earlier PR from this skill (branch
  `agents/dev-speed-*`) is still open, open no other PR: file issues only.
- **The build lease.** Lease `build` for any build, test or lint you run to prove the
  change (step 4), and release it the moment the command ends.
- **Questions.** Ask only for a decision that is Alex's (above). Otherwise decide and
  tell (`AGENTS.md`, #1083).

## 1. Measure

1. Run the script from this skill's folder, for the last 7 days, and keep both forms:

   ```sh
   D=~/.agents/reviews/dev-speed; mkdir -p "$D"; T=$(date +%F)
   S=.agents/skills/dev-speed/time-spent.py
   python3 -I "$S" --days 7 --top 20 > "$D/$T.md"
   python3 -I "$S" --days 7 --top 50 --json > "$D/$T.json"
   ```

   It reads every session of this folder (and its worktrees) active in the window, in
   about 5 seconds, and writes:
   - **the totals:** running time, split into tool time and model time; how much of the
     tool time is waits that hold a turn open (the `wait:` rows); the time between turns;
   - **tool time by category,** with calls, total, share of running time, median, p90
     and failures;
   - **between turns, by what woke the session:** `event: checks.passed`,
     `event: lease.granted (build)` (the line for the lease), `wait timed out`,
     `check_again timer`, `person or agent message`, and the rest;
   - **the slowest calls, the commands run 3 or more times in one session,** and the
     longest-running sessions, with tokens and cost.

   `--days`, `--folder` and `--store` change the window, the folder and the records
   it reads.

2. If there is an earlier report in `~/.agents/reviews/dev-speed/`, compare: for each
   of the top 10 categories, the total per session then and now. A category that grew
   by more than half is a regression; look for the merge that started it
   (`git log --since=<last report> -- <the script or skill>`).

## 2. Find the causes

Take the largest costs first: the top 5 tool categories by total, the top 3 kinds of
time between turns, and any category with more than 5% failed calls. For each one,
look at 3 examples before you name a cause. Find them in the report's tables (session
title and id), then read the session: `read_session` with its id, or the transcript at
`~/Library/Application Support/Agents/agents/<id>/transcript.jsonl` (`toolCall` and
`toolCallUpdate` lines, matched by `toolCallID`; `stateChanged` lines for the turns).

Look first for these causes, in this order. Each names the place a fix goes.

1. **Work that need not run.** A full `scripts/lint.sh`, `go-changed.sh` or
   `swift test` run where the branch changed one file; the same check run before and
   after the commit with nothing changed between; a whole package's tests where
   `scripts/select-test-suites.sh` gives a filter; an `xcodebuild` for a scheme the
   branch does not touch. The fix goes in the script (skip what the diff does not
   touch) or in the skill or persona that runs it.
2. **Cold caches.** The p90 far above the median for a build or test (`xcodebuild`
   34 s median, 6 m p90) is usually a cold cache: a build not through
   `scripts/build-cache.sh`, a `-derivedDataPath` per worktree, a Go or npm cache
   per worktree, a container that pulls its image again. Read the slow calls' commands.
3. **The build lease's line.** Total `event: lease.granted (build)` time, against the
   time leases were held (the transcript's `Leased build` and `Released build`
   notes). A lease held while reading, editing or waiting, held for a whole walk, or
   taken for work that needs no lease (`gh`, `git`, reading a log) makes the line.
4. **Polling instead of an event.** `sleep` loops, `gh pr checks` or `gh run view`
   again and again, `check_again` with no event that would do: each poll is a turn of
   model time. The fix is the event (`checks.passed`, `pr.merged`, `agent.ended`) in the
   skill or persona that polls.
5. **Retries.** The "run 3 or more times" table and the failed counts: a flaky test run
   until it passes, a build that fails the same way, a tool call refused with the same
   error each time (a wrong argument in a skill's example, a missing label). The fix is
   the cause, or the skill's text that leads lanes into the error. A flaky test goes by
   `AGENTS.md` (`.flakyUnderLoad` and an issue).
6. **Waits inside a turn.** `wait: wait_for_event` calls × their median is time a turn
   is held open for nothing; many calls in one session mean a lane that waits on one
   event at a time where one call on several would do. `wait: question to the person`
   is Alex's time: a question that "Questions that already have an answer" in
   `AGENTS.md` answers is a cause; propose a line there for one that comes back.
7. **Model time.** A session whose model time is far above its tool time, or whose
   tokens are high, usually read too much: whole files where `grep` or a range would
   do, the same file again and again, large command output not cut with `tail`. The fix
   is a script that prints less, or the skill's text.
8. **Between turns.** `event: checks.passed` and `event: checks.failed` waits are CI:
   give their medians and point to `ci-speed`. `wait timed out` with a long median
   means waits that never got their event; check whether the event they named can
   happen (a filter that never matches).

For each cause, write down: the cost in the window (time and, where it applies, how
many sessions), what the fix is, where it goes, and the saving you expect per week.

## 3. Choose

Rank the causes by expected saving per week. Take the first one that a change in this
repo can fix with no rule of Alex's changed (rules, above): that is this run's pull
request. The next ones (at most three, Alex's rules included) become issues.

Before you file an issue, look for an open one on the same cause
(`gh issue list --search "<script or tool> in:title,body" --state open`) and add a
comment with the new numbers instead. A filed issue gets `task` (or `bug` for a
script that is wrong), one `size:` label from the rubric in
`.agents/personas/product-owner.md`, and the `feature:` label that fits
(`feature:capacity` for leases and lanes, `feature:performance` for builds and tests).
Its body says the measured cost, the cause with one or two example commands, the fix
and the expected saving.

## 4. Change it

1. Move into a worktree off the latest `main` through the app (#615): `git fetch
   origin`, fast-forward `main` here if it is behind (`git merge --ff-only
   origin/main`), then `move_worktree` with worktree `dev-speed-<YYYY-MM-DD>` and end
   your turn; you are started again in it, on `agents/dev-speed-<date>`.
2. Make the one change. Keep the file's own style, and say why in a comment for
   anything that is not obvious.
3. Prove it saves the time: run the slow command before and after the change, under the
   `build` lease, and note both times. A text change to a skill or persona cannot be
   timed; say which sessions it would have changed and how.
4. Lint what you touched (`scripts/lint.sh`, under the lease). Commit with the numbers
   (cost in the window, the cause, the before and after times) and end the message with
   `mac: docs only, remote: docs only, web: docs only` when no client changes.
5. Push, open the PR (`gh pr create`), and turn on squash auto-merge at once
   (`gh pr merge --auto --squash`). The body has the top of the report (the totals and
   the top 10 categories, numbers only), the cause and the measured saving. Then go on
   as the Software Engineer persona's steps 7 to 9 say: wait for it to merge, fix what
   fails, clean up.

## 5. Report

End with: the totals (running time, tool and model shares, the time between turns),
the three largest costs with their causes, the PR link and whether it is set to merge,
the issues filed or commented on, and the path of the report. If an issue waits for
Alex's decision, ask Alex with your question tool, naming the issue; otherwise call
`archive_session` (no id) once the PR has merged.
