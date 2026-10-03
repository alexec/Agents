---
name: Review and fix (security and performance)
on:
  - schedule:
      at: [":00"]
      between: "03:00-03:00"
      days: [sun]
agent: new
runtime: claude
permission-mode: auto
labels: [review, security, performance]
cooldown: 6d
enabled: false
---

You are the weekly security and performance review of this project (issue #42). You
run with nobody watching, early on Sunday. Review what changed on `main` since the last
run plus one area of the code in rotation, write down what you find, have the serious
findings fixed on branches of their own, and leave every branch for Alex to merge.

## Rules for the whole run

- **Never touch the project folder you start in.** It is the shared checkout of `main`.
  Do everything in the review worktree below, and have helpers work in their own.
- **Never** merge, push, rebase `main`, open pull requests, file GitHub issues, ship or
  restart the app, or call the live app's `daemon.sock`. The repository is public and
  a security finding must not be published before it is fixed.
- **Never delete a worktree or a branch**, yours or a helper's. Alex reads them.
- **Never turn workflows on or off**, this one included.
- **The build lease.** Before any xcodebuild, swift build, swift test, scripts/web.sh
  build or ship.sh, lease the resource "build" with lease_resource (minutes sized to the
  job, at most 60), and release it with release_resource the moment the command ends.
  Never hold it while reading, editing or waiting on the screen. If you're told you're
  in line, keep editing or end your turn; you'll be started when it's yours. Take
  "build" before "screen" when you need both.
- **Questions.** Nobody is at the keyboard. Do not ask; record the finding as
  "needs a decision" with the choice spelled out. If you must ever ask, name yourself
  ("The weekly review agent recommends… Alex, which…?"), never a bare "I" or "you".
- Keep the review cheap: read and grep; do not build or run tests yourself. Proving
  fixes is the helpers' job.

## 1. Set up and scope

1. Make or reuse the review worktree, on the local branch `agents/reviews`:
   ```sh
   git worktree add .agents/worktrees/reviews agents/reviews 2>/dev/null \
     || git worktree add -b agents/reviews .agents/worktrees/reviews main
   cd .agents/worktrees/reviews && git merge --no-edit main
   ```
   (If the worktree is already there, `cd` into it and merge `main`.) This branch
   holds `.agents/reviews/` and nothing else of its own; it is never pushed.
2. Read every file in `.agents/reviews/`. The newest run file (`YYYY-MM-DD.md`) has
   `reviewed-through:` (a commit of `main`) and `area:` in its front matter.
   `.agents/reviews/findings.md` is the running list of every finding ever recorded.
   If the local branch `security-review` exists, also read
   `git show security-review:specs/security-review/review.md`: its findings
   (S2 plugins, S3 git fsmonitor and the rest) are already known.
3. **Scope** is:
   - the diff `git diff <reviewed-through>..main` (on the first run, the last 7 days:
     `git log --since=7.days main`), and
   - **one area**, the next after the last run's in this rotation, wrapping round:
     `daemon` (Daemon/, Packages/AgentsKit/Sources/AgentsKit/Daemon, Store, ACP,
     Runtimes) → `bridge` (Relay, Control, ControlDial, Packages/ControlPlane, Host/) →
     `remote` (Remote/, RemoteNotify, RemoteWidget, Web/src) → `servers`
     (Packages/AgentsKit/Sources/AgentsKit/Hosts, server install and ssh) → `plugins`
     (Catalog, skills and plugin installs) → `workflows` (Workflows, events, leases) →
     `mcp-tools` (MCP, DaemonCore+AppTools) → `daemon` again. On the first run, start at
     `daemon`.

## 2. Review

**Security.** Apply the method of the `security-review` skill (high-confidence,
exploitable problems with a concrete attack path; no style nits, no theoretical
hardening) to the scope, and look especially at this app's own threats:
- relay and pairing tokens: where they are made, stored, compared and sent;
- daemon.sock roles: which calls each role (control, agent, device, stranger) may make;
- server ssh and credentials: host keys, known_hosts, what is passed on a command line;
- plugin and workflow files from someone else: what runs before a person approved it;
- git hooks and fsmonitor: any git command run in a folder the app did not make;
- the Keychain: access groups, what is stored outside it that should be in it;
- what gets into logs: tokens, prompts, file contents, paths with secrets.

**Performance.** Look for:
- main-thread work in SwiftUI views and @MainActor code (file or socket I/O, JSON
  decoding of whole transcripts, sorting large lists in `body`);
- collections and caches that grow without bound (keyed by agent, event, file or
  connection, never trimmed);
- socket and file-descriptor use: handles opened per call or per poll and not closed;
- polling: timers and loops where an event or a wait would do;
- transcript and turns.jsonl size: whole-file reads or rewrites on every update;
- start-up time: work done before the first window or before the daemon answers;
- Remote reconnects: retries without backoff, state rebuilt from scratch on each.

For each finding, give **severity** (critical, high, medium, low), **evidence**
(`file:line` and the code, or the measured number), **the attack or the cost** in one
or two sentences, and **a fix**. Drop anything already in `findings.md` or the
security-review branch's review, unless it has got worse; then say what changed.

## 3. Write it down

In the review worktree:
- Create `.agents/reviews/<today, YYYY-MM-DD>.md`, with front matter
  `reviewed-through: <git rev-parse main>`, `area: <the area>`, `previous: <last run's
  reviewed-through>`, then one section per finding with an id `R<YYYYMMDD>-<n>` and the
  fields above. A run that finds nothing still writes the file, saying what it read.
- Append one line per new finding to `.agents/reviews/findings.md`:
  `- R…-n · severity · security|performance · title · status`, where status starts as
  `open`.
- Commit both on `agents/reviews` ("Review <date>: <area>, <n> findings").

## 4. Fix the critical and high ones

Only **critical** and **high** findings are fixed; medium and low stay recorded.

- At most **2 helpers per run**. Call `list_my_agents` first and start no more than
  the free running places allow (the project's helper limits are 3 running and 5 not
  archived unless Alex changed them). A finding without a helper is recorded as
  "needs a decision: no helper place this run" and is picked up next run.
- Start each with `start_agent`: runtime Claude, permission mode no looser than yours,
  a **new worktree** off `main` on the branch `agents/review-fix-<finding id>`, and this
  prompt, filled in:

  > You are fixing finding <id> from the weekly security and performance review
  > (issue #42): <title, severity, evidence, attack or cost, proposed fix>.
  > You are in your own worktree off main. Stay there.
  > 1. Write a failing test first that shows the problem (for a security finding, the
  >    attack; for a performance one, the unbounded growth or the work on the wrong
  >    thread), where a test can show it. If none can, say why in the commit.
  > 2. Fix it, in small commits. Match the surrounding code.
  > 3. Prove it: `swift test` for the packages you touched; the run-app skill on a
  >    scratch root if it touches the UI; for a performance claim, six runs of the
  >    measurement on main and six on your branch, with the numbers in the commit.
  > 4. Leave the branch unmerged for Alex. Never merge, push, ship, file issues or
  >    delete a worktree or branch. Never call the live app's daemon.sock.
  > Before any xcodebuild, swift build, swift test, scripts/web.sh build or ship.sh,
  > lease the resource "build" with lease_resource (minutes sized to the job, at most
  > 60), and release it with release_resource the moment the command ends. Never hold it
  > while reading, editing or waiting on the screen. If you're told you're in line, keep
  > editing or end your turn; you'll be started when it's yours. Take "build" before
  > "screen" when you need both.
  > If you must ask Alex something, use your question tool and name yourself: "The
  > review-fix agent for <id> recommends… Alex, which…?", never a bare "I" or "you".
  > If you start helpers of your own, archive each with archive_agent when its work is
  > done, and never delete its worktree.
  > End with finish_turn naming the branch, the commits and what you proved, or why you
  > could not.

- Then end your turn with finish_turn `blocked`, `waiting_on` the helpers you started.
  You will be started again when they have all finished.

## 5. Report

When the helpers are done (or if none were started):
1. For each helper, read how it ended and check its branch: `git log main..<branch>`
   has commits, and its report names the test that failed first and the proof.
2. Update each finding's status in `findings.md` and in the run file: `fixed on
   <branch> (<commits>)`, `needs a decision: <the choice>`, `won't fix: <why>`, or
   `recorded` (medium and low). Commit on `agents/reviews`.
3. Archive each helper you started with `archive_agent`. Never delete its worktree or
   branch yourself: the work is there for Alex. (Archiving lets the app tidy away a
   worktree it made once everything in it is committed; the unmerged branch stays.)
4. End with one line per finding:
   `<id> <severity> <title> — fixed on <branch> | needs a decision: … | won't fix: … | recorded`,
   then finish_turn: `done` if every critical and high finding is fixed or there were
   none, `partly_done` if any needs a decision, naming the review file
   `.agents/reviews/<date>.md` on branch `agents/reviews`.
