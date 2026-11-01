---
name: hadr-review
description: Review what changed on main since the last release tag (the whole system in the first run) for high availability, disaster recovery and bounded data (store bounds, safe writes, backup and restore, single points of failure, store copies and handovers, several copies over a bucket, the docs), try a restore on a scratch set-up, write the findings under .agents/reviews/hadr/, and have a helper fix the most severe critical or high one on a branch for Alex. Use when the HADR review workflow runs in a release (#1557), or when Alex asks for an HA/DR or bounded-data review.
---

Paused until 1.0 (#3215).

# HADR review

This is the method of the HADR review workflow (`.agents/workflows/hadr-review.md`,
#1557). The workflow says what the method is for and starts it. A person or an agent can
also follow it by hand. Where it says that nobody is at the keyboard, that is true only of
a run of the workflow.

Alex (2026-10-19): a store that does not roll its files or cap its growth is a bug. HA/DR
is a release check, so that the bugs are found before GA, not by a full disk or a lost VM.

## Rules for the whole run

- **Never touch the folder you start in.** It is the shared checkout of `main`.
  Do everything in the review worktree below, and have helpers work in their own.
- **Never** merge, push, rebase `main`, open pull requests, file GitHub issues, ship or
  restart the app, or call the live app's `daemon.sock`. The Release run files the issues
  from your findings (its step 3).
- **Never touch the live control plane** (control.agentloops.dev, the GCP folder, its
  VM, disk and bucket) or a real host's data. Read `deploy/`; never run `up.sh`, `down.sh`,
  `move.sh` or `gcloud`. Every drill runs on a scratch set-up.
- **Never copy real agent records** into a scratch root (`~/.agents`, `~/Library/Application
  Support/Agents`): a scratch daemon resumes them live. Seed synthetic ones.
- **Never delete a worktree or a branch**, yours or a helper's. Alex reads them.
- **Never turn workflows on or off**, this one included.
- **Write only under `.agents/reviews/hadr/`.** Never change another review's folder.
- **The build lease.** Before any xcodebuild, swift build, swift test, go build, a scratch
  app or control plane, scripts/web.sh build or ship.sh, lease the resource "build" with
  lease_resource (minutes sized to the job, at most 60), and release it with
  release_resource the moment the command or the drill ends. Never hold it while reading,
  editing or waiting on the screen. If you're told you're in line, keep reading or end
  your turn; you'll be started when it's yours. Take "build" before "screen" when you
  need both.
- **Close every scratch process you started** (the run-app skill's "When you are done",
  `stop.sh` for each root) before you commit or end, also when the drill failed.
- **Questions.** Nobody is at the keyboard. Do not ask; record the finding as
  "needs a decision" with the choice spelled out. If you must ever ask, name yourself
  ("The HADR review agent recommends… Alex, which…?"), never a bare "I" or "you".
- Keep the review cheap: read and grep. The restore drill (step 3) is the only thing you
  run. Proving fixes is the helper's job.

## 1. Set up and scope

1. Move into the review worktree, on the local branch `agents/reviews-hadr`, through the
   app, so it shows where you work (#615):
   - `.agents/worktrees/reviews-hadr` is there: move_worktree with its absolute path.
   - Only the branch `agents/reviews-hadr` is there: `git worktree add
     .agents/worktrees/reviews-hadr agents/reviews-hadr`, then move_worktree with its
     absolute path.
   - Neither: move_worktree with worktree `reviews-hadr`.

   End your turn; you are started again in it. There, `git merge --no-edit main`. This
   branch holds `.agents/reviews/hadr/` and nothing else of its own; it is never pushed.
2. Read every file in `.agents/reviews/hadr/`. The newest run file (`YYYY-MM-DD.md`) has
   `reviewed-through:` (a commit of `main`, your last-run marker) in its front matter.
   `findings.md` there is the running list of every HADR finding ever recorded.
3. Read what is already known, so nothing is reported twice: the open and closed issues
   that name a store or a backup (`gh issue list --state all --search "retention OR rolled
   OR unbounded OR backup OR restore in:title"`), and the bound lines of
   `.agents/reviews/performance/findings.md` on `agents/reviews-performance` (`growth`).
   A finding that an issue already tracks is recorded with that issue's number.
4. **Scope** is:
   - the diff `git diff <last tag>..main`, where the last tag is
     `git describe --tags --abbrev=0 origin/main` (#1462), read for every check in step 2;
   - **until a run has reviewed the whole system** (no run file in `.agents/reviews/hadr/`
     has `whole-system: done` in its front matter), the whole system too, because nothing
     was reviewed before. Start from the findings already recorded (the seed findings of
     #1557 were checked again in the first run, 2026-10-21) and check each one again.

## 2. Review

The checks. Give each finding the check's name as its kind.

1. `bounds`: **every store has a bound.** Each file or store prefix that grows (agent
   records, transcripts and `turns.jsonl`, logs such as `daemon.log`, events, attachments,
   usage history, caches, archives, the control plane's store prefixes such as `v1/copies/`)
   has a size or age limit that the code **enforces**, and a test that proves the limit.
   A store with no enforced bound is at least medium.
2. `writes`: **writes are safe.** Records are written atomically (temp file, fsync,
   rename, then fsync of the folder); an append that is cut short leaves a file that still
   reads (the last line is dropped, not the file); secrets and keys (TLS certificate and
   key, the host key, tokens) are never written in place.
3. `backup`: **backup and restore.** Each store that cannot be rebuilt (the control plane
   store, provider secrets, the APNs key, agent records and transcripts on a host) has a
   backup, and its restore is tried in step 3. Give the RTO (the time the restore took)
   and the RPO (what was lost).
4. `spof`: **single points of failure** in `deploy/`: the VM, its disk and volumes, the
   zone and region, the KMS key, DNS and the certificates. For each one, say what its loss
   costs (every host and device pairs again, transcripts lost, a day of downtime).
5. `copies`: **moves and copies.** `agents-control store copy` (`Go/cmd/agents-control`)
   and the handover carry every store prefix and every secret that the control plane needs.
   Compare the prefixes the store writes with the prefixes the copy reads.
6. `mesh`: **several copies.** The multi-copy mesh over a bucket still works (the walk
   compose file, `deploy/compose.yaml`: `deploy/make-secrets.sh`, then `docker compose -p
   hadr-walk -f deploy/compose.yaml up -d --build`, and `down -v --rmi local` and
   `rm -rf deploy/secrets` after), and the store's If-Match probe and its test pass
   (`Go/scripts/go.sh test -count=1 -run 'Probe|CopyStore' ./internal/controlplane/s3store/
   ./internal/controlplane/`, from `Go/`).
7. `docs`: `docs/explanation/control-plane.md` and `docs/reference/agents-folder.md`
   say what is backed up, what is not, and how to restore.

For each finding, give **severity**:
- critical: data is lost, or the system stops, in normal use (a disk that fills, a write
  that a crash leaves unreadable);
- high: one failure that is likely (a VM, a disk, a zone) loses data that cannot be
  rebuilt, or makes every person set up again;
- medium: a store with no enforced bound, a copy that drops a prefix, a backup that is
  missing for data that can be set up again by hand;
- low: the rest (a missing fsync where a crash loses only the last line).

Also give **evidence** (`file:line` and the code, and how it grows: per agent, per turn,
per event, per day), **the cost** in one or two sentences (what is lost, and what a person
must do again), and **a fix** with the test or the drill that would prove it. Drop anything
already recorded (steps 1.2 and 1.3) unless it got worse; then say what changed.

## 3. Restore drill

Try the restore of each store that cannot be rebuilt, on a scratch set-up only. Use the
run-app skill (`.agents/skills/run-app/SKILL.md`, a scratch root with its own control
plane and host) or the test-servers skill (a Linux host in `agents-devbox`). Lease "build"
for the whole drill and release it when the last scratch process is closed.

For the control plane store, the minimum drill is:

1. Launch a scratch root (`launch.sh`, or `agents-control serve --home <scratch>/control`
   and `agentsd` on `<scratch>` as the run-app skill does). Seed a synthetic agent. Note the
   paired host and its agents.
2. Take a backup the way the docs say (or, when the docs say nothing, `agents-control
   store copy --from file://<scratch>/control/store --to file://<backup>/store`; a bare
   path is refused). Note the time T1.
3. Make one more change (a second synthetic agent, or `agents-control code --client
   --home <scratch>/control`), then lose the control plane: kill the pid in
   `<scratch>/control/control.pid` and move its home away.
4. Restore from the backup into a new home, start the control plane on it with the same
   `serve` arguments (`ps -o command= -p <pid>` before step 3 shows them), and time how
   long it takes until the host is joined again (a new `uplink: connected` line in
   `<scratch>/logs/daemon.log`) and its agents are listed (the RTO). Try the store alone
   first, then with what the backup says it holds besides the store. In the first run
   (2026-10-21, #2137) the store alone was refused ("another key"), and the store with the
   home's `control-key`, `secrets-key` and `tls/` came back in 26 s.
5. Say what the restore lost (the RPO): the change after T1, any prefix or secret that the
   copy did not carry, and whether the host or the window had to pair again.

Do the same for host data when a backup for it exists. When a store has no backup, say so;
that is the finding, and the drill is "not possible: no backup". Close everything you
started (the run-app skill's "When you are done").

## 4. Write it down

In the review worktree:
- Create `.agents/reviews/hadr/<today, YYYY-MM-DD>.md`, with front matter
  `reviewed-through: <git rev-parse main>`, `base: <the last tag>`, `previous: <last run's
  reviewed-through, or none>`, `whole-system: done` or `partial` (step 1.4), then the drill (each store: the steps, RTO and RPO, or why it
  was not possible), then one section per finding with an id `H<YYYYMMDD>-<n>` and the
  fields above. A run that finds nothing still writes the file, saying what it read and
  what it restored.
- Append one line per new finding to `.agents/reviews/hadr/findings.md`:
  `- H…-n · severity · kind · title · status`, where status starts as `open`, or
  `filed #NNN` when an issue already tracks it.
- Commit both on `agents/reviews-hadr` ("HADR review <date>: <n> findings").

## 5. Fix the critical and high ones

Only **critical** and **high** findings are fixed; medium and low stay recorded, and the
Release run files the medium ones.

- A finding whose fix changes the live set-up (a snapshot policy or a bucket on the GCP
  folder, a second VM, DNS) costs money or changes an outside account. That is Alex's:
  record it as "needs a decision: <the choice, and what it costs>", and start no helper
  for it.
- For the others, at most **1 helper per run**. Take the most severe finding. Call
  `list_sessions` with `started_by: me` first and start it only if a running place is free
  (the folder's helper limits are 3 running and 5 not archived unless Alex changed them).
  Every other critical or high finding is recorded as "needs a decision: no helper place
  this run" and is picked up next run.
- Start it with `start_session`: runtime Claude, permission mode no looser than yours, a
  **new worktree** off `main` on the branch `agents/review-fix-<finding id>`, and this
  prompt, filled in:

  > You are fixing finding <id> from the HADR review (issue #1557): <title, severity,
  > kind, evidence, cost, proposed fix and the test or drill that proves it>.
  > You are in your own worktree off main. Stay there.
  > 1. Write a failing test first that shows the fault (the store that grows past its
  >    limit, the write that a cut leaves unreadable, the prefix the copy drops). If no
  >    test can show it, say why in the commit.
  > 2. Fix it, in small commits. Match the surrounding code.
  > 3. Prove it: the test from step 1 passes, the tests of the packages you touched pass
  >    (`swift test`, or `Go/scripts/go.sh test` for Go), and the restore drill of the
  >    hadr-review skill (step 3) on a scratch set-up when the fix touches a backup or a
  >    copy. The test suite is flaky under load: compare runs, never one run against one
  >    run.
  > 4. Leave the branch unmerged for Alex. Never merge, push, ship, file issues or
  >    delete a worktree or branch. Never call the live app's daemon.sock, never touch the
  >    live control plane, never copy real agent records.
  > Before any xcodebuild, swift build, swift test, go build, a scratch app,
  > scripts/web.sh build or ship.sh, lease the resource "build" with lease_resource
  > (minutes sized to the job, at most 60), and release it with release_resource the
  > moment the command ends. Never hold it while reading, editing or waiting on the
  > screen. If you're told you're in line, keep editing or end your turn; you'll be
  > started when it's yours. Take "build" before "screen" when you need both.
  > If you must ask Alex something, use your question tool and name yourself: "The
  > HADR-fix agent for <id> recommends… Alex, which…?", never a bare "I" or "you".
  > If you start helpers of your own, archive each with archive_session when its work is
  > done, and never delete its worktree.
  > End with a last message naming the branch, the commits, the test that failed first
  > and what you proved, or why you could not.

- Then call `wait_for_event` with `agents` naming the helper you started and
  `until_minutes: 240`. You will be started again when it has finished, or when the
  time runs out; if it is still working then, wait again the same way.

## 6. Report

When the helper is done (or if none was started):
1. Read how it ended and check its branch: `git log main..<branch>` has commits, and
   its report names the test that failed first. A claim without one is
   `needs a decision: unproven`, not fixed.
2. Update each finding's status in `findings.md` and in the run file: `fixed on
   <branch> (<commits>)`, `needs a decision: <the choice>`, `won't fix: <why>`,
   `filed #NNN`, or `recorded` (medium and low). Commit on `agents/reviews-hadr`.
3. Archive the helper you started with `archive_session`. Never delete its worktree or
   branch yourself: the work is there for Alex.
4. End with the drill's RTO and RPO per store, then one line per finding:
   `<id> <severity> <title> — fixed on <branch> | needs a decision: … | won't fix: … | filed #NNN | recorded`,
   then the review file `.agents/reviews/hadr/<date>.md` on branch `agents/reviews-hadr`.
   If any finding needs a decision, ask Alex with your question tool.
