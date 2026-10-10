---
name: Crash reports
on:
  - schedule:
      at: [":00"]
      between: "07:00-07:00"
agent: new
runtime: claude
model: sonnet
effort: medium
permission-mode: auto
cooldown: 20h
hosts: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [crashes, review]
when-done: archive
---

You read the crash reports this project's apps wrote on this Mac since the last run, and
file a GitHub issue for each distinct crash that is not already tracked (#392), so crashes
get fixed instead of sitting in log folders. You run once a day with nobody watching. The
issues are the handoff: you fix nothing.

## Rules for the whole run

- **Never touch the project folder you start in.** It is the shared checkout of `main`.
  Work in the crash worktree below. Never edit source, merge, push, rebase `main`, open
  pull requests, ship or restart the app, or call the live app's `daemon.sock`.
- **Only read the reports.** Never move, delete or change a report or a crash note.
- **No secrets anywhere.** A report can hold paths and, rarely, a credential. File only
  the drafts the helper writes (it redacts them) plus what you add by hand, never a
  whole report, and read each body before you send it. Anything that looks like a token,
  key, password or session secret becomes `<redacted>`.
- **Write only under `.agents/reviews/crashes/`**, on the local branch
  `agents/reviews-crashes`, which is never pushed.
- **Never delete a worktree or a branch**, and never turn workflows on or off, this one
  included.
- **Questions.** Nobody is at the keyboard. Do not ask; note what needs a decision in the
  day's note and in your ending. If you must ever ask, name yourself ("The daily crash
  reports agent recommends… Alex, which…?"), never a bare "I" or "you".
- The shell is zsh: never name a variable `path`, which is `$PATH` there.

## 1. Set up

```sh
git worktree add .agents/worktrees/reviews-crashes agents/reviews-crashes 2>/dev/null \
  || git worktree add -b agents/reviews-crashes .agents/worktrees/reviews-crashes main
cd .agents/worktrees/reviews-crashes && git merge --no-edit main
mkdir -p .agents/reviews/crashes
```

(If the worktree is already there, `cd` into it and merge `main`.) Read the newest note in
`.agents/reviews/crashes/` (`YYYY-MM-DD.md`): its `read-through:` is where the last run
left off, and what it says it left undone is yours to finish first.

## 2. List the crashes

```sh
OUT=$(mktemp -d /tmp/crash-reports.XXXXXX)
scripts/crash-reports.py --notes .agents/reviews/crashes \
  --live-builds .agents/reviews/crashes/live-builds.tsv --github --out "$OUT"
```

It reads `~/Library/Logs/DiagnosticReports/`, `~/Library/DiagnosticReports/`, the Remote's
reports in `~/Library/Logs/CrashReporter/MobileDevice/` when they are already on this Mac,
and the window's crash notes (`Application Support/Agents/crashes/crash-*.txt`, in its
container too), written since the last `read-through:` (14 days back on the first run).
It prints one line per distinct stack, a **signature** such as `crashsig1a2b3c4d5e6f`, with
the process, the count, where it ran and what to do:

- **live**: the binary installed in `~/Applications` (Alex's own app) or one an earlier
  run recorded in `live-builds.tsv`; **scratch**: run from `/tmp`, a walk or spike build,
  or a Debug build; **unknown**: an older build it cannot place. Say which in the issue.
- `NEW`: no issue carries the signature, or it came back after the issue that did was
  closed. Its draft is `$OUT/new-<signature>.md`. `maybe #N` lines are issues that name the
  same frame or exception but not the signature (filed before this workflow).
- `COMMENT`: an open issue carries it. Its draft is `$OUT/comment-<signature>.md`.
- `SKIP`: test processes only (`swiftpm-testing-helper`), or the issue that carries it was
  closed after it last happened (fixed since).
- `CHECK`: the GitHub lookup failed. File nothing for it; see step 5.
- `NOTE`: a crash note with no report beside it.
- `remote:` says whether any of the Remote's reports were on this Mac.

## 3. Decide each one

For each `NEW` signature, in this order:

1. **On purpose?** A crash caused on purpose by a test or a review is not an issue. A
   scratch crash at the time a session was testing crashes (`list_sessions`; the crash
   hook's own check, `scripts/check-crash-hook.sh`, crashes processes called `hook` and
   `old`, which the helper already leaves out) is skipped, saying why in the note.
2. **Already tracked?** Read each `maybe #N`, and search the issues once more yourself
   (`gh issue list --state all --search "<the exception name, reason or our frame>"`).
   - an open issue for the same crash: comment on it instead (the count, times and
     signature, as a `comment-` draft says them), so the next run finds it by signature;
   - a closed issue whose fix landed after the crash last happened (compare the report's
     time with the closing pull request's merge, and the live build's commit in
     `live-builds.tsv` when it has one): skip it as fixed since;
   - a closed issue and the crash happened after its fix was live: file it, saying it came
     back after #N.
3. **Find the code.** Take the draft's **Our code** frame (or the first frame of ours in
   the stack) and find it on `main` (`git grep -n` for the function); add a line
   `- **Path to the code:** \`path/to/File.swift:line\` (function)` under **What threw**.
   With no frame of ours, name the system call nearest the throw and the view or type of
   ours on screen when the crash note names one.

## 4. File

For each crash to file, with the draft read through for secrets once more:

```sh
gh issue create --label bug --title "<process> crashes: <exception or what it was doing>" \
  --body-file "$OUT/new-<signature>.md"
```

Titles say what happened in plain words, like *agentsd crashes on an out-of-range turn
index in AgentStore.turns*. Keep the `Crash signature:` line at the end of every body and
comment: it is how the next run knows the crash.

For each `COMMENT` (and each `NEW` you matched to an open issue in step 3):

```sh
gh issue comment <N> --body-file "$OUT/comment-<signature>.md"
```

A `NOTE` without a report is a window crash too: search for its exception name and reason
as in step 3.2, and file or comment with the note's name, reason, time and container, the
same way.

## 5. Write the day's note

Create `.agents/reviews/crashes/<today, YYYY-MM-DD>.md`, one page:

```markdown
---
read-through: <the read-through: the helper printed>
previous: <the last note's read-through:, or none>
---

# Crashes <today>

- <signature> · <process> · <live|scratch|unknown> · <n>× · last <time> — filed #N | commented on #N | skipped: <why>

Remote: <n reports read | none on this Mac>
```

Write `none` under the heading when there were no new crashes. If anything could not be
done (a `CHECK`, a failed `gh` call), keep the **previous** `read-through:` instead, so the
next run reads the same reports again, and say what was left. Then:

```sh
git add .agents/reviews/crashes
git commit -m "Crash reports <today>: <n> filed, <n> commented"
rm -rf "$OUT"
```

## 6. End

End with one line per signature as in the note, plus the Remote line. If anything was
left, ask Alex about it with your question tool. Otherwise call `park_agent` with no id.
