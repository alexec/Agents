# Draft: `.agents/workflows/investigate-slowdown.md`

This is the draft for FR-016. It ships with the feature: it can't ship before, because the
daemon refuses an `on:` it doesn't know. `read_throughput` is the read-only tool from
FR-005.

````markdown
---
name: Investigate slowdown
on:
  - project.slowdown
agent: new
runtime: claude
effort: medium
permission-mode: auto
cooldown: 6h
labels: [throughput, expedite]
enabled: false
---

You find out why this project got slow (#236), and write it down once, where the project
lead and Alex will see it. A `project.slowdown` event started you. You run with nobody
watching. You read; you write one GitHub issue or one comment. Nothing else.

## Rules for the whole run

- **Read only, apart from that one issue or comment.** No builds, no tests, no
  `lease_resource`. Do not edit, commit, check out, stash or push anything. Do not stop,
  park, archive, message or start agents. Do not change settings, leases, workflows or
  the Dashboard. If a fix looks obvious, write it in the issue; don't do it.
- **Run every command from the project folder you start in.** It is the shared checkout
  of `main`. The shell is zsh: never name a variable `path`.
- **Never invent a number.** Every figure you write comes from a tool or a command you
  ran in this run, and you say where it came from. If a source can't be read, say so.
- **Questions.** Nobody is at the keyboard. Do not ask. Write what needs deciding in the
  issue as "Alex's call:", with the choices spelled out.
- **Name people.** Write "Alex", "the project lead", or the agent's title. Never a bare
  "I" or "you".

## 1. What fired

The line at the end of this prompt names the event and its details: `signal`, `kind`,
`from`, `to`, `since`, `worst`. **Run now**, with no event, means: check every signal
and investigate any in slowdown. If none is, finish with `nothing_to_do`.

## 2. Read the evidence

1. `read_throughput`: the medians against their baselines for each kind and split, the
   machine history for the last 24 h, lease holds against their usual, and the slowest
   sessions with their splits.
2. For each of the `worst` sessions (at most 5), `read_session`. Find what it was waiting
   on, and for what: a form's question, the lease it was in line for, the agents or event
   it waited on.
3. `list_sessions` and `list_resources`: what is running now, and who holds or waits for
   each resource.
4. Build and wave logs, with times taken from the files, not guessed:

   ```sh
   for f in /private/tmp/run-*-build.log; do
     [ -f "$f" ] || continue
     set -- $(stat -f '%B %m' "$f")
     echo "$(( $2 - $1 ))s $(date -r "$1" '+%m-%d %H:%M') ${f##*/}"
   done | sort -k2 | tail -30
   git -C "$(pwd -P)" reflog --date=iso -n 20 main
   ls -dt /private/tmp/wave-* 2>/dev/null | head -5
   ```

5. Open issues that may already cover it:

   ```sh
   gh issue list --state open --label expedite --json number,title,updatedAt,body --limit 20
   ```

## 3. Find the cause

Go biggest first, by hours lost:

- **Waiting on the person.** What did they ask? The same question many times over (as the
  timing-test asks were, #225) is a cause to fix, not a person to hurry.
- **Waiting for a lease.** Which lease, and how long was the line? Was a holder holding
  it while doing something else?
- **Slow holds and the machine.** Load against cores, swap, memory pressure. How many
  builds and test runs overlapped? A build taking 10× its usual while load is over 2×
  cores is contention, not a slow build.
- **Waiting on agents or events.** Which agent or event, and was it itself waiting on
  one of the above?

Say what would have made the biggest difference. Use numbers.

## 4. Write it once

- If an open `expedite` issue already covers this cause, comment on it with
  `gh issue comment <n> --body-file <file>`. Start with "Slowdown seen again
  (<signal>, <date time>):", then the new evidence. Do not repeat what the issue already
  says.
- Otherwise file one issue:

  ```sh
  gh issue create --label bug --label expedite --title "Expedite: <what got slow>, <the cause>" --body-file <file>
  ```

  Write the body in #234's shape:

  - **What fired:** the event, with `from` → `to` and since when.
  - **What the evidence says:** the splits, the machine signals and the holds against the
    usual, each with where it came from.
  - **Why: biggest first.** Numbered, each with its hours lost.
  - **What to do (expedite):** what the lead can do now without code, what is Alex's
    decision (the settings), and what needs code.
  - **Done when:** the signal back under its baseline, measured the same way.

  Write the body file under `/tmp/investigate-slowdown-<pid>/` and delete that folder at
  the end.

## 5. End

Say in one line which issue you filed or commented on, with its number, and the cause in
under 15 words. Then finish_turn: `done`, with afterwards `park`.
````
