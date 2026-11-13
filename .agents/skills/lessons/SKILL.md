---
name: lessons
description: Read the last day of this folder's agent sessions from the app's records, find corrections Alex gave more than once, failures repeated across lanes, and numbers someone needed that nothing measures, then write at most 5 memories and file at most 3 issues. Writes no product code and changes no rule. Use when the Lessons learned workflow runs, or when Alex asks what the agents learnt today.
---

# Lessons learned

Agents learn things in a session and lose them when it ends, unless they write a
memory then. Once a day this skill looks back over the last 24 hours and keeps what
must last: a correction Alex gave more than once becomes a memory, a failure in many
lanes becomes an issue, and a number that someone needed but nothing measured becomes
an issue for a measurement (as #4833 did for development speed).

## Rules for the whole run

- **Read only, until step 3.** The session records are the app's. Never write to
  `~/Library/Application Support/Agents`, and never stop, message or archive a session
  that is not yours.
- **The records are private; the repo is public.** Transcripts hold Alex's data and
  other people's text. The candidates and the report go to `~/.agents/reviews/lessons/`,
  never into the repo. A repo memory, an issue or a PR gives only the lesson in our own
  words, with numbers, categories and script names: never transcript text, a session's
  prompt or a command's output. A fact about Alex or this Mac goes only to
  `~/.agents/memory/`.
- **Limits per run:** at most **5 memories** (added or updated, both folders together)
  and at most **3 issues**. Take the ones that cost the most first.
- **No rule changes.** Change nothing in `AGENTS.md`, a persona or a skill. A proposed
  rule goes into an issue for Alex. Write no product code.
- **Nothing to learn, nothing made.** When no candidate passes step 2, write the report
  and end: no pull request, no issue, no question.
- **Questions.** None. Decide and tell (`AGENTS.md`, #1083).

## 1. Read

```sh
D=~/.agents/reviews/lessons; mkdir -p "$D"; T=$(date +%F)
python3 -I .agents/skills/lessons/lessons.py --hours 24 > "$D/$T-candidates.md"
```

It reads every session of this folder and its worktrees active in the window (about
5 s for 200 sessions), with the reader of `dev-speed`'s `time-spent.py`, and lists:

- **corrections:** Alex's messages (`from: person` in the record) that came after the
  agent had acted, with what the agent did just before. Those with a correction cue
  ("no", "don't", "instead", "I said", "again", …) come first;
- **failures:** the same category and command failing in 3 or more sessions;
- **asked for a number:** Alex's or an agent's text that asks "why is X slow", "how
  often", "how many", "how long".

Read `.agents/memory/MEMORY.md` and `~/.agents/memory/MEMORY.md` too, in full.

## 2. Judge

Read only the candidates' own lines first; open a session (`read_session` with its id)
only to see what the agent did before a correction.

- **A correction** is Alex saying that what the agent did, or was about to do, was
  wrong, and saying what is right. An answer to a question, an approval ("LGTM", "1"),
  a new request and a message on a different topic are not corrections: a cue word alone
  is not enough. Keep a correction only when **two or more sessions** got the same
  point. One that a memory or a rule in `AGENTS.md` already says is a sign that the
  text is not found or not clear: update that memory to be clearer, or, for a rule,
  propose a clearer line in an issue.
- **A failure** counts when its cause is the same in the sessions: look at the failed
  calls' output in two of them. A tool refused with the same error in many sessions
  (a wrong argument, a missing label) is a cause in a skill's or a brief's text; a
  test that fails on main too goes by `AGENTS.md` (`.flakyUnderLoad` and an issue).
  Skip failures that are a lane's normal work (a build that fails, then is fixed).
- **A missing measurement** counts when no script, report or workflow answers it: look
  in `scripts/`, `.agents/skills/*/`, `.agents/workflows/` and `~/.agents/reviews/`.

## 3. Act

1. **Memories (at most 5).** For each kept lesson, first look for the file that covers
   it (`grep -ril <word> .agents/memory ~/.agents/memory`). Update that file, or
   delete one that is wrong, rather than add a second; else add one file, one fact,
   with the frontmatter of the files beside it and a line in that folder's
   `MEMORY.md`.
   - About Alex or this Mac: write it in `~/.agents/memory/` directly.
   - About this repo (its code, tools, process): on a branch of its own. Move into a
     worktree off the latest `main` with `move_worktree`, worktree
     `lessons-<YYYY-MM-DD>`, and end your turn; you are started again there. Commit
     the memory files only, ending with `mac: docs only, remote: docs only, web: docs
     only`, push, open the PR (`gh pr create`, body: the lessons in one line each and
     where they came from in numbers only), and turn on `gh pr merge --auto --squash`.
     Then follow the Software Engineer persona's steps 7 to 9: wait for it to merge,
     fix what fails, clean up.
2. **Issues (at most 3).** Search first (`gh issue list --search "<words>
   in:title,body" --state all`); on a match, add a comment with the new numbers
   instead. A new issue gets `task` (or `bug` for a script or skill that is wrong),
   one `size:` label from the rubric in `.agents/personas/product-owner.md`, and the
   `feature:` label that fits. A missing measurement's issue names the number, where
   it comes from (records, `gh`, a log), and the limit that must start an agent, as
   #4833 does for speed. A proposed rule's issue says the rule, the sessions' count,
   and that it waits for Alex.

## 4. Report

Write `~/.agents/reviews/lessons/<date>.md`: the counts (sessions, candidates per
list), each kept lesson and where it went (memory file, PR or issue link), and each
dropped candidate kind with why, in a line. The `-candidates.md` file stays beside it.

End with the counts, the memory files written, the PR link and whether it is set to
merge, and the issues filed or commented on. Then call `archive_session` (no id) once
the PR has merged, or at once when there is no PR.
