---
name: security-audit
description: Review what changed on main since the last release tag for security threats (tokens, socket roles, servers, foreign files, git, Keychain, logs) and read the open Dependabot alerts, write the findings under .agents/reviews/security/ and never publish them (an alert, which is public already, goes to an issue), and have helpers fix the critical and high ones on branches for Alex. Use when the Security review workflow runs in a release (#1462), or when Alex asks for this folder's security audit. It is not the general security-review skill, but it uses the method of that skill.
---

Paused until 1.0 (#3215).

# Security audit

This is the method of the Security review workflow
(`.agents/workflows/security-review.md`). The workflow says what the method is for and
starts it. A person or an agent can also follow it by hand. Where it says that nobody is
at the keyboard, that is true only of a run of the workflow.

## Rules for the whole run

- **Never touch the folder you start in.** It is the shared checkout of `main`.
  Do everything in the review worktree below, and have helpers work in their own.
- **Never** merge, push, rebase `main`, open pull requests, file GitHub issues, ship or
  restart the app, or call the live app's `daemon.sock`. The repository is public and
  a security finding must not be published before it is fixed. The one exception is a
  Dependabot alert (step 1.4, `dependencies`): its advisory is public already, so it gets
  an issue (step 3). Never dismiss an alert yourself: that changes the repository, and it
  is Alex's to decide.
- **Never delete a worktree or a branch**, yours or a helper's. Alex reads them.
- **Never turn workflows on or off**, this one included.
- **Write only under `.agents/reviews/security/`.** Never change
  `.agents/reviews/performance/`; it is the Performance review's.
- **The build lease.** Before any xcodebuild, swift build, swift test, scripts/web.sh
  build or ship.sh, lease the resource "build" with lease_resource (minutes sized to the
  job, at most 60), and release it with release_resource the moment the command ends.
  Never hold it while reading, editing or waiting on the screen. If you're told you're
  in line, keep editing or end your turn; you'll be started when it's yours. Take
  "build" before "screen" when you need both.
- **Questions.** Nobody is at the keyboard. Do not ask; record the finding as
  "needs a decision" with the choice spelled out. If you must ever ask, name yourself
  ("The security review agent recommends… Alex, which…?"), never a bare "I" or
  "you".
- Keep the review cheap: read and grep; do not build or run tests yourself. Proving
  fixes is the helpers' job.

## 1. Set up and scope

1. Move into the review worktree, on the local branch `agents/reviews-security`, through the app, so it
   shows where you work (#615):
   - `.agents/worktrees/reviews-security` is there: move_worktree with its absolute path.
   - Only the branch `agents/reviews-security` is there: `git worktree add .agents/worktrees/reviews-security
     agents/reviews-security`, then move_worktree with its absolute path.
   - Neither: move_worktree with worktree `reviews-security`.

   End your turn; you are started again in it. There, `git merge --no-edit main`. This branch
   holds `.agents/reviews/security/` and nothing else of its own; it is never pushed.
2. Read every file in `.agents/reviews/security/`. The newest run file
   (`YYYY-MM-DD.md`) has `reviewed-through:` (a commit of `main`, your last-run marker)
   in its front matter. `findings.md` there is the running list of every
   security finding ever recorded.
3. Read what is already known, so nothing is reported twice:
   - if the local branch `agents/reviews` exists (the combined review before the
     split), the security lines of `git show agents/reviews:.agents/reviews/findings.md`
     and, when you have no run file of your own yet, the `reviewed-through:` of its
     newest run file as your starting point;
   - if the local branch `security-review` exists,
     `git show security-review:specs/security-review/review.md` (S2 plugins, S3 git
     fsmonitor and the rest);
   - `specs/071-web-remote/walks/security-review.md`, including "What #42 must add when
     #61 serves the page publicly".
4. **Scope** is:
   - the diff `git diff <last tag>..main`, where the last tag is
     `git describe --tags --abbrev=0 origin/main` (#1462), read for every threat below.
     Nothing older is in scope: code the diff does not change is not reviewed,
     even when it looks wrong. The threats:
     1. `tokens`: relay and pairing tokens, browser session keys: where they are made,
        stored, compared and sent (Relay, Control, ControlDial, Go/internal/controlplane,
        Remote pairing, Web/src);
     2. `socket-roles`: which daemon.sock calls each kind of client (control, agent,
        device, browser, stranger) may make, and how a caller is identified
        (Go/internal/agentsd: roles.go, rpc.go; Host/PeerCheck, the signature checks);
     3. `servers`: server ssh and credentials: host keys, known_hosts, what is passed on
        a command line or written to the server (Go/internal/controlplane/hostinstall,
        server install);
     4. `foreign-files`: plugin, skill and workflow files from someone else: what runs
        or is trusted before a person approved it (Catalog, plugin installs, Workflows);
     5. `git`: hooks, fsmonitor and config: any git command run in a folder the app did
        not make;
     6. `keychain`: access groups, and what is stored outside the Keychain that should
        be in it;
     7. `logs`: what gets into logs, events, crash notes and transcripts: tokens,
        prompts, file contents, paths with secrets.
   - `dependencies` (#1910): every **open** Dependabot alert, whatever the diff touches:
     `gh api --paginate 'repos/alexec/Agents/dependabot/alerts?state=open'`. That is every
     manifest (`Web/`, `Go/`, `App/Resources/toolsets/*`). For each alert, note its number,
     the package and manifest, its severity (`security_advisory.severity`), the advisory
     (`security_advisory.ghsa_id`), the first patched version
     (`security_vulnerability.first_patched_version`) and Dependabot's own pull request,
     if any (`gh pr list --author app/dependabot --search <package>`). Whether the
     vulnerable code is reached helps say how urgent it is: the govulncheck lines of
     `scripts/lint.sh` for Go, and `npm audit --omit=dev` in `Web/` for the page. That is
     optional, and never lowers the alert's severity on its own.

## 2. Review

Apply the method of the `security-review` skill: high-confidence, exploitable problems
with a concrete attack path; no style nits, no theoretical hardening.

A Dependabot alert is a finding with the alert's own severity. Its evidence is the
manifest and the advisory, its attack is the advisory's summary, and its fix is the
patched version (or Dependabot's pull request). One whose package has no patched version,
or whose vulnerable code the app cannot reach, is still a finding: say why, and record it
as "needs a decision: dismiss alert <n> as <no_bandwidth | tolerable_risk | inaccurate |
not_used>?". Only Alex dismisses one (`gh api -X PATCH
repos/alexec/Agents/dependabot/alerts/<n> -f state=dismissed -f dismissed_reason=…`).

For each finding, give **severity** (critical, high, medium, low), **evidence**
(`file:line` and the code), **the attack** in one or two sentences (who, from where,
gets what), and **a fix**. Drop anything already recorded (step 1.2 and 1.3), unless it
has got worse; then say what changed.

## 3. Write it down

In the review worktree:
- Create `.agents/reviews/security/<today, YYYY-MM-DD>.md`, with front matter
  `reviewed-through: <git rev-parse main>`, `base: <the last tag>`, `previous: <last
  run's reviewed-through>`, then one section per finding with an id `S<YYYYMMDD>-<n>`
  and the fields above. A run that finds nothing still writes the file, saying what it
  read.
- Append one line per new finding to `.agents/reviews/security/findings.md`:
  `- S…-n · severity · title · status`, where status starts as `open`.
- Commit both on `agents/reviews-security` ("Security review <date>: <n> findings").
- **Dependency alerts** go in the run file only, in a section `## Dependency alerts`
  with ids `D<YYYYMMDD>-<n>`, not in `findings.md`: that list is the private findings the
  release keeps as draft advisories, and an alert is public already. Each critical, high
  or medium alert gets an issue, unless one is open for it already (`gh issue list
  --search "<ghsa_id> in:body"`): title `Dependency (<severity>): <package> <advisory
  title>`, a body with the alert's number and link, the advisory, the manifest, the
  patched version, Dependabot's pull request if any, and the finding's id; the labels
  `priority:high` (critical and high) or `priority:medium`, `bug`, `dependencies`, and its
  `area:<name>` from `.agents/areas` when the manifest has one. The release (its step 3)
  collects these issues with its other high and medium ones, so a high alert blocks the
  release as any high finding does, and the Scrum Master's lanes fix it: they bump the
  dependency, or land Dependabot's own pull request when it is green. A low alert is only
  recorded. The run file says each alert's issue (`filed #NNN`).

## 4. Fix the critical and high ones

Only **critical** and **high** findings are fixed during the security audit. A medium
security finding stays private as a draft advisory for one release. If it is still open
in the next release, the release gives its advisory URL to the Scrum Master as priority
work; the release does not wait for the fix. Low findings stay recorded and are not
worked. A dependency alert is not given a helper: its issue goes to the Scrum Master's
lanes through the release (step 3).

- At most **2 helpers per run**. Call `list_sessions` with `started_by: me` first and start no more than
  the free running places allow (the folder's helper limits are 3 running and 5 not
  archived unless Alex changed them). A finding without a helper is recorded as
  "needs a decision: no helper place this run" and is picked up next run.
- Start each with `start_session`: runtime Claude, permission mode no looser than yours,
  a **new worktree** off `main` on the branch `agents/review-fix-<finding id>`, and this
  prompt, filled in:

  > You are fixing finding <id> from the security review (issue #42): <title,
  > severity, evidence, attack, proposed fix>.
  > You are in your own worktree off main. Stay there.
  > 1. Write a failing test first that shows the attack, where a test can show it. If
  >    none can, say why in the commit.
  > 2. Fix it, in small commits. Match the surrounding code.
  > 3. Prove it: the test from step 1 passes, `swift test` for the packages you touched,
  >    and the run-app skill on a scratch root if it touches the UI.
  > 4. Leave the branch unmerged for Alex. Never merge, push, ship, file issues or
  >    delete a worktree or branch. Never call the live app's daemon.sock. Never
  >    describe the finding anywhere public.
  > Before any xcodebuild, swift build, swift test, scripts/web.sh build or ship.sh,
  > lease the resource "build" with lease_resource (minutes sized to the job, at most
  > 60), and release it with release_resource the moment the command ends. Never hold it
  > while reading, editing or waiting on the screen. If you're told you're in line, keep
  > editing or end your turn; you'll be started when it's yours. Take "build" before
  > "screen" when you need both.
  > If you must ask Alex something, use your question tool and name yourself: "The
  > security-fix agent for <id> recommends… Alex, which…?", never a bare "I" or "you".
  > If you start helpers of your own, archive each with archive_session when its work is
  > done, and never delete its worktree.
  > End with a last message naming the branch, the commits and what you proved, or why you
  > could not.

- Then call `wait_for_event` with `agents` naming the helpers you started and
  `until_minutes: 240`. You will be started again when they have all finished, or when
  the time runs out; if any is still working then, wait again the same way.

## 5. Report

When the helpers are done (or if none were started):
1. For each helper, read how it ended and check its branch: `git log main..<branch>`
   has commits, and its report names the test that failed first and the proof.
2. Update each finding's status in `findings.md` and in the run file: `fixed on
   <branch> (<commits>)`, `needs a decision: <the choice>`, `won't fix: <why>`, or
   `recorded` (medium for its one release of grace, and low). Commit on `agents/reviews-security`. A dependency alert's
   status is its issue (`filed #NNN`), or `needs a decision: dismiss …`.
3. Archive each helper you started with `archive_session`. Never delete its worktree or
   branch yourself: the work is there for Alex. (Archiving lets the app tidy away a
   worktree it made once everything in it is committed; the unmerged branch stays.)
4. End with one line per finding, dependency alerts included:
   `<id> <severity> <title> — fixed on <branch> | filed #NNN | needs a decision: … | won't fix: … | recorded`,
   then the review file `.agents/reviews/security/<date>.md` on branch `agents/reviews-security`.
   If any finding needs a decision, ask Alex with your question tool.
