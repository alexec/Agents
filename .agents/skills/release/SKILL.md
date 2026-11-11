---
name: release
description: Take main to a new version with nobody watching (#914), started by Alex. Every release is a minor (x.y.0), with no patch after it (#3212). Run the three checks once each (runtimes, competitors, the feature matrix; the five reviews are not part of a release, #3215), read the Dependabot alerts, have the high issues fixed through the Scrum Master's lanes, check the gate, choose the version, write the notes with the milestones finished, tag and push, check the GitHub release and both TestFlight builds, deploy the live control plane, close the finished milestones, and review how the release went. Use when the Release workflow runs, or when Alex asks for a release. Not for installing on Alex's Mac or devices (ship-app), and never for App Review.
---

# Release

A release takes `main` to a new version on the GitHub release page (Agents Host, the Linux
agentsd) and on TestFlight (the Mac window and the Remote, one Universal app). The tag does
the publishing: `.github/workflows/release.yml` builds, signs and uploads when a `v*` tag
is pushed. This skill decides when the tag is pushed, and what it says.

Alex decided (2026-10-13, #914):

- **When the gate passes, push the tag.** Do not ask for approval. Alex has already started the release.
- **Version:** every release is a minor, x.y.0 (Alex, 2026-11-01, #3212). There are no
  patch releases and no patch milestones (#3212 replaces #2801 and #2779): bugs have no
  milestone, a standing bug lane fixes them, and a release ships what is on `main`.
  1.0 and major versions only when Alex says. An enhancement counts only when its files
  change a client's UI, the host or daemon, or the capability list (#2857); the plan lists
  a tooling, workflow or docs enhancement as `[tooling]`.
- **Every release runs three checks once each** (#1462): runtimes, competitors and the
  feature matrix, and reads the open Dependabot alerts. **The five reviews are paused
  until 1.0** (Alex, 2026-11-01, #3215): security, performance, HADR, dead code and
  usability. Before 1.0 the product changes too fast for release-time reviews to pay back
  what they cost; #3216 brings them back at 1.0, at PR time. Their skills and workflows
  stay, turned off, except the dead-code review, which runs on its own schedule (#3715).
- **Scope is what changed** (#1462): the checks read only `main` since the last tag.
  Step 3 also carries forward the draft security advisories that earlier reviews made.
  Older open issues are not this release's.
- **Time is one day** (#1462), from the start of the run (T0): the checks and the fixes
  fit in it.
- **Priority is a label:** `priority:high` and `priority:medium`. Within each, security
  goes before runtimes, before the rest.
- **Only high blocks** (Alex, 2026-10-19, #1661). The release tags as soon as no high is
  open; it never waits for a medium fix. Other medium findings are filed with
  `priority:medium`, listed as known issues, and worked by the ordinary lanes after the
  release (a bug with no milestone, for the bug lane; the rest as labelled). Low is recorded and not
  worked.
- **Milestones are themes, not versions** (Alex, 2026-11-06, #3760; replaces #1348). A
  milestone is named by its theme (`Projects`, `Channels`), and its GitHub due date gives
  the order. No milestone blocks a release: a release goes out from `main` when something
  merged since the last tag, at most one a day (step 0). The one exception is
  `1.0 Public release`: the release that takes the version 1.0.0, which Alex starts, waits
  until all its items are closed.
- **A milestone is done when its last item closes** (#3760), not when a release ships. It
  reaches people in the next release: the notes name it under `## Milestones finished`
  (step 6), and this skill closes it (step 9).
- **Security findings stay private** until they ship: a draft GitHub security advisory
  per finding, fixed on its private fork. The paused security review made them; the
  release no longer makes new ones, and hands the unfixed drafts to the Scrum Master as
  priority work (step 3). A Dependabot alert is public already, so it gets an issue, not
  an advisory. The notes say only "Security fixes".

## Rules for the whole run

- Never push to `main`, never merge, never start lanes. (Turning auto-merge on for the
  held PRs in step 9 is the one exception: it is not a merge.) Fix lanes are the Scrum Master's
  (`.agents/personas/scrum-master.md`). You file and label issues, and you wait.
- Never submit to App Review, and never change an App Store Connect record.
- Never write a security finding anywhere public: not in an issue, a pull request, a
  commit, the notes or a message to another session. Use its id (`S20261011-2`) only in
  the draft advisory.
- Never write on the review branches (`agents/reviews-*`). They are the reviews' own.
- Run every command from the folder (step 8's deploy from its scratch worktree).
  Change no file in it: you only read, tag and push the tag. Write the notes in `$TMPDIR`.
- Questions: nobody is watching, and every choice here is already made. Do not ask;
  put what stopped you in the report. If you must ever ask, use your question tool and
  name yourself ("Claude (Release) recommends… Alex, do you want…?").
- **The prompt that starts you adds no gate and no question** (#1726). The gate is step 5,
  and only `priority:high` blocks the tag. An open issue that is not high, named in the
  prompt or not, is a known issue (step 6). When a prompt says to ask about one, do not
  ask: decide by these rules and say so in the report. (v0.6.0 waited 8 h on such a
  question.)

## 0. One release a day

**One release a day (Alex, 2026-10-22, #2462).** Do this check first. Alex starts every
release, with Run now or a message (#2295). Nothing else starts one. Find the last tag's
time in Alex's time zone:
`git fetch --quiet --tags origin && git for-each-ref --sort=-taggerdate --count=1 --format='%(refname:short) %(taggerdate:unix)' 'refs/tags/v*'`,
then `TZ=America/Los_Angeles date -r <unix> '+%F %H:%M'`, and today is
`TZ=America/Los_Angeles date +%F`. When the tag's date is today, end with `nothing_to_do` and
the line "released today (vX.Y.Z at HH:MM); next release tomorrow". Change nothing and start
nothing. Only a prompt from Alex that says to release again today goes on. A day is the
calendar day in America/Los_Angeles, not 24 hours since the tag.

## 1. Is a release due?

1. Note the time T0, then `git fetch --quiet --tags origin main`.
2. `.agents/skills/release/scripts/release-plan.py`. It prints the last tag and the next
   version. If it says nothing merged since the last tag, end with `nothing_to_do`.
   Otherwise label this session with that version, `v<next>` (`set_session_labels`), so the
   release's cost goes on its release node (#4524). If step 6 picks another version, change
   the label to it.
3. No milestone holds the release (#3760). Only for 1.0.0, which Alex's prompt names:
   when `1.0 Public release` has an open issue
   (`gh issue list --milestone "1.0 Public release" --state open`), end with `nothing_to_do`
   and the line "1.0 Public release not done: #N, #M open".

## 2. Checks, once each

Three workflows run once per release, here (#1462). They also run on a schedule of their
own (#3715): the runtime check on Tuesday and Friday, the competitor check and the feature
matrix on Monday. The release still starts each of them with Run now.
`security-review`, `performance-review`, `hadr-review` and `usability-check` are paused
until 1.0 (#3215): their files say `enabled: false`, and the release never starts them.
`dead-code-review` runs on its own schedule (Tuesday, Thursday and Saturday), never from
the release.

| Order | Workflow | It writes |
|---|---|---|
| 1 | `nightly-runtimes` (Runtime check) | `~/Library/Caches/Agents Nightly Runtimes/runs/latest/report.md` |
| 1 | `competitor-check` | `~/.agents/reviews/competitors/` |
| 2 | `feature-matrix` | a pull request on `agents/feature-matrix-<date>` |

Start every one of them once per release. The only one to skip is one that already ran
for this release: its report (or pull request) is newer than the last tag, as when an
earlier run of this skill ended `partly_done`. Never start one again in the same release.
Run each with `manage_workflows run`. When that is refused (the workflow is turned off, or waits for Alex's OK), read the workflow with
`manage_workflows read`, and call `start_session` with its prompt (the text under its front matter) and its `runtime:`, `model:` and `permission-mode:`.
Start them by order, at most two at a time: the feature matrix reads the competitor check's report. Wait with `wait_for_event`,
naming the sessions in `agents`, `until_minutes` 240 or the time left to T0 + 1 day,
whichever is less. As each one finishes, archive it with `archive_session` and do step 3
for its findings at once, so their fixes start while the others still run. One that
failed, or is still running at T0 + 1 day (stop it with `stop_session`), is a note in
your report, not a reason to stop, and it is not started again until the next release.

## 3. Have the high ones fixed, and file the medium ones

Collect, in order:

- **Dependabot alerts** (#1910, #3215): every open alert,
  `gh api --paginate 'repos/alexec/Agents/dependabot/alerts?state=open'`. An alert is public
  already, so it gets an issue, not an advisory. Each **critical or high** alert gets a bug
  for the bug lane (#3212), unless an issue is open for it already (`gh issue list --search
  "<ghsa_id> in:body"`): title `Dependency (<severity>): <package> <advisory title>`, a body
  with the alert's number and link, the advisory (`security_advisory.ghsa_id`), the
  manifest, the first patched version, and Dependabot's own pull request if any (`gh pr
  list --author app/dependabot --search <package>`); the labels `bug`, `security`,
  `dependencies`, `priority:high`. No milestone. A medium or low alert gets no issue: Dependabot's own
  pull requests take it. Never dismiss an alert: that is Alex's.
- **Draft security advisories** from earlier releases: see "Security findings" below.
- **Runtimes:** open issues the runtime check filed in this release (their titles start with
  the cause it found); count each as medium.
- **Issues:** every open issue labelled `priority:high` or `priority:medium` that was
  opened since the last tag (`gh issue list --search "created:>=<the tag's date>"`), the
  Dependabot bugs above too.

For each runtime finding with no issue yet, file one: title `Runtime (<severity>): <title>`,
the finding's fields in the body, the labels `priority:medium` and `bug`. No milestone.

Then send the Scrum Master one message (`list_sessions`, then `message_session` to the
session not archived whose title has "scrum master" in it, any case, and that is labelled
`lead`): the high issues in priority order (security, runtimes, the rest), then the
unfixed draft security advisory URLs as priority work. Say that the release waits for
high issues and never waits for a draft advisory. Other medium issues go to the ordinary
lanes after the release as their label and milestone say (a bug to the bug lane).

**No Scrum Master running, and work to hand over** (#1908; in v0.7.0 the highs sat
40 minutes with no owner): start one when there are high issues or unfixed draft
security advisories. Call `start_session` with the persona in
`.agents/personas/scrum-master.md` (its prompt, `runtime:` and `labels:`), the title
`<x.y> scrum master` for the version being released, and a prompt that names the version,
the high issues in the order above, then the draft security advisory URLs as priority
work, that the release waits for high issues but not for draft advisories, and that it
reports to the release session (this one, by its id). The release still starts no fix
lane itself: the Scrum Master does. With nothing to hand over, start none, and say so in
the report.

### Security findings

The paused security review (#3215) left draft advisories behind. The release makes no new
ones. For each draft advisory
(`gh api --paginate 'repos/alexec/Agents/security-advisories?state=draft'`):

1. Look for its fix on main (#1727): its description ends with `Fixed by <commit>` and that
   commit is on `origin/main`, or `findings.md` on `agents/reviews-security` says `fixed on
   <branch>` and `git merge-base --is-ancestor <branch> origin/main` passes, or a merged
   pull request came from that branch (`gh pr list --state merged --head <branch>`). If it
   is fixed and the description does not say so yet, run
   `python3 .agents/skills/release/scripts/advisory.py fixed <ghsa_id> <merge commit>`.
   `.claude/settings.json` allows it, and no other change to an advisory. Do not hand it
   off.
2. Otherwise leave it a draft and send its URL only (it is private) to the Scrum Master as
   priority work. Its lane fixes the finding on the advisory's private fork, then opens
   the pull request on `main` with a title and body that name no attack ("Harden token
   comparison"), and runs `advisory.py fixed <ghsa_id> <merge commit>`. A draft advisory
   never blocks the release.
3. In the report, list each advisory by its id only, and say whether it is fixed. Never
   write a finding id, summary, title or attack details in a message or the report.

Leave every advisory a draft: publishing it after the release is Alex's.

## 4. Wait for the fixes

Until the gate can pass:

- Recount what is still open of what step 3 collected: its issues.
- Go on as soon as nothing high is open. Never wait for a medium one or a draft advisory:
  the medium issues still open go into the notes as known issues.
- Otherwise wait with `wait_for_event` for `issue.closed` and `pr.merged`, `where:
  {"issue": [<the open high issues>], "any": true}`, with `until_minutes` at most the time
  left to T0 + 1 day. `any: true` is for `pr.merged`: any merge moves `main` (#3797).
- High always blocks. At T0 + 1 day with a high one still open, end with `partly_done`,
  naming what is open. The next run is a new day (a new T0); it skips the checks that
  already ran (step 2) and picks up the same issues.

## 5. Gate

All of these, on the commit you will tag: `<sha>`, the pin, is `git rev-parse origin/main`
(fetched again now) when the gate starts. The tag goes on the pin, so every item below,
and step 6's plan and notes, is about the pin, not about the newest main.

**The pin stays while lanes land** (#3045). A PR that lands while an item waits does not
restart the gate: lanes keep merging during a milestone, and each restart cost a new cold
dry run (up to an hour); v0.14.1's gate took about two hours this way. Each time you look
again and `origin/main` has moved, run `release-plan.py --after <sha>`:

- `verdict: keep the pin`: go on with the same `<sha>`. What merged after it goes out in the
  next release.
- `verdict: start over on origin/main`: a PR after the pin fixes a blocking issue
  (`priority:high`), so the tag must hold
  it. Re-pick the newest main and start the gate over on it from item 1. A dry run on the
  old pin may go on or be cancelled; neither is a failure.

An issue whose closing PR merged after the pin is still open in what you tag: count it as
open for item 2 and for the notes' known issues (`git merge-base --is-ancestor <merge commit>
<sha>` fails for it). `branch.moved` is never raised for `main`, the default branch;
`pr.merged` is what wakes a wait instead.

1. **CI is green on it:** `gh run list --branch main --commit <sha> --json name,conclusion`
   shows every run `success` (or `skipped`). If one is still running, wait for it: a push
   to `main` is never a pull request, so `checks.failed` and `checks.passed` (a PR's own
   runs) never fire for it. Wait instead with `wait_for_event` on the `github` server's
   `run.completed`, `where: {"branch": "main"}` (#3444), `until_minutes: 10`. Do not add
   `pr.merged` to this wait: one `where` goes to every event that takes its keys, and
   `branch` on `pr.merged` means a PR *from* `main` (#3797). A PR landing moves main past
   `<sha>` and starts a run on main, so its runs wake this wait too; look again however it
   woke (run `--after` as above if it did move).
   A newer push never cancels a running run on `main` (#2218), but it replaces a pending
   one: when the pin's CI was replaced and never ran, start over on the newest main. If a
   run on `<sha>` failed, end with `partly_done`; main broken is fixed by its own PR,
   through the Scrum Master.
2. **No open high:** none of step 3's high issues is open at the pin (for 1.0.0, none of
   `1.0 Public release`'s issues either, step 1, item 3). When one closed by a PR that
   merged after the pin, start over on the newest main from item 1.
3. **No tag today** (#2462): look again as in step 0. The release can run past midnight, so a
   tag pushed today by another run ends this one with `nothing_to_do` and "released today
   (vX.Y.Z at HH:MM); next release tomorrow", unless Alex's prompt says to release again today.
4. **The archives build on a cold cache** (#2780): `gh workflow run release-dry-run.yml -f
   ref=<sha>`, then find its run (`gh run list --workflow release-dry-run.yml --json
   databaseId,displayTitle,status --jq '.[] | select(.displayTitle == "release dry run <sha>")'`)
   and wait until it is `completed` (it takes up to an hour). It runs by
   `workflow_dispatch`, not a pull request, so `checks.*` never fire for it: wait with
   `wait_for_event` on the `github` server's `run.completed`, with `pr.merged` beside it,
   `where: {"run": <id>, "any": true}` (#3444; `any` is for `pr.merged`, #3797) and
   `until_minutes: 20` as a back-stop. The event's
   `run.conclusion` is the result. However it woke, look again (run `--after` as above if
   main moved meanwhile; with `keep the pin`, the same run goes on). Never wait on a
   background shell or a timer alone: a background shell ends with the session's process. It runs release.yml's `mac` and `testflight` archives as dry runs on a
   runner with an empty build cache, which no lane or merge wave does (#2773 spent
   v0.12.0's tag). A run of it on a pull request does not count: run it on `<sha>`. If it
   failed, end with `partly_done`, naming the job and its first error; the fix goes through
   the Scrum Master as for main broken.

   **A job that no runner took is not a failure** (#3445). GitHub can cancel a job before
   it starts ("The job was not acquired by Runner of type hosted even after multiple
   attempts"), and the run then ends `failure`; v0.16.0's `host` job did this. Look at
   each job that is not `success`:

   ```sh
   gh run view <id> --json jobs --jq '.jobs[] | select(.conclusion != "success" and .conclusion != "skipped") | [.databaseId, .name, .conclusion, (.steps | length)] | @tsv'
   gh api repos/alexec/Agents/check-runs/<job id>/annotations --jq '.[].message'
   ```

   A job that is `cancelled` with no steps run, or whose annotation says that no runner
   took it, did not run: run `gh run rerun <id> --failed` once, wait again as above, and
   look again. Only a job that ran and failed (or is in this state a second time) ends the
   release with `partly_done`. A job cancelled because the pin moved is not a failure
   either (see the pin, above).

## 6. Version and notes

1. Run `release-plan.py --ref <sha>` again, so the plan lists what the pin holds and nothing
   merged after it. Its `next:` is the version (1.0.0 only when Alex's prompt says).
2. **Milestones finished:** each `finished:` line of the plan is an open milestone whose
   items are all closed (#3760). Its last item closed since the last tag, as this skill
   closes each finished milestone in step 9. An item whose closing PR merged after the pin
   is not in the tag: then the milestone is not finished in this release (`git merge-base
   --is-ancestor <merge commit> <sha>`).
3. Write the notes in Markdown, in plain short sentences:
   - `## Milestones finished`, first, when step 2 found any: a line per milestone, its
     title and link, `- [Projects](https://github.com/alexec/Agents/milestone/N)`;
   - one heading per kind that has changes, in this order: `## New` (the plan's
     `[enhancement]`), `## Fixed` (`[bug]`) and `## Changed` (the rest, `[tooling]` too), with a line per
     change, from the pull requests the plan lists. A line names the pull request:
     `- The sidebar shows … (#698)`. A pull request whose body has a `Release note:`
     paragraph gives that paragraph as its line, as written: it says what a person has to
     do, such as how to go back to the Swift Linux host. Leave out changes only agents see (CI, scripts,
     workflows) unless they change what a person does;
   - `## Security fixes` with only "This release fixes security problems found by our
     own review." when an advisory was fixed since the last tag. Nothing more;
   - `## Known issues`: the medium issues still open, one line each with its number.
   - `## Capabilities`, as `python3 .agents/skills/release/scripts/capability-changes.py
     <last tag> <sha>` writes it: the capabilities added, deprecated and removed (#1748,
     `docs/explanation/versions.md`). Nothing when it writes nothing. A minor before 1.0 may
     remove a capability number.

## 7. Tag and push

```sh
git tag -a --cleanup=verbatim v<version> <sha> -F "$TMPDIR/release-notes.md"
git push origin v<version>
```

`release.yml` uses the tag's message as the release notes. If the push is refused, end
with `partly_done` and the error; do not change or delete a tag that is already there.
A tag that already exists for this version means another release ran: end with
`nothing_to_do`.

## 8. Check

1. Wait for the release run: find it with `gh run list --workflow release.yml --branch
   v<version>`, then wait with `wait_for_event` on the `github` server's `run.completed`,
   `where: {"workflow": "release.yml", "branch": "v<version>"}` (#3444), `until_minutes: 30`
   as a back-stop. The event's `run.conclusion` is the result; however it woke, look again
   with `gh run view <id> --json status,conclusion,jobs`. Never wait on a background
   `gh run watch`: it ends with the session's process, and nothing wakes the release.
   A job that no runner took is not a failure: look and run it again once, as in step 5,
   item 4 (#3445). Only a job that ran and failed goes to items 2–4.
2. **GitHub:** `gh release view v<version> --json assets` has the `.dmg`, the `.zip`,
   both `agentsd-linux-*.tar.gz` and `SHA256SUMS`. Macs update Agents Host from the `.zip`
   and `SHA256SUMS` by these names (#2178): a release without them updates no Mac.
   **The image** (#2140): the `image` job passed, and
   `docker buildx imagetools inspect ghcr.io/alexec/agents-control:<version>` lists
   `linux/amd64` and `linux/arm64`. If the job failed, name
   the step and the first error: the `mac` job waits for it, so there is no GitHub release
   either.
   **The parts agree** (#1748): each asset's name says `<version>`, and so does the
   `testflight` job's version. On this Mac, make the scratch worktree at the tag under the
   home folder, never under `$TMPDIR` or `/tmp` (Go runs in a container that sees only the
   home folder, #2221):

   ```sh
   git worktree add --detach ~/.agents/scratch/release-v<version> v<version>
   ```

   `scripts/version.sh` there prints `<version>`, the version every build
   script stamps (agentsd, agents-control, the Linux host's `VERSION`).
3. **TestFlight:** the `testflight` job passed. It has already waited for both builds to
   reach VALID (`scripts/asc-builds.swift`). To look again from this Mac:
   `swift scripts/asc-builds.swift <version> <the run number>`.
4. If the `testflight` job failed at "The App Store secrets are there", the secrets are
   still Alex's to add: say which, from its log, and that the GitHub release is out.
   Any other failure: name the step and the first error.
5. **Deploy the control plane** (#2100). When steps 2 and 3 found the GitHub release and
   both TestFlight builds, put the version on the live control plane,
   control.agentloops.dev. Alex approved its restart for every release's deploy (2026-10-22).
   In the scratch worktree of step 2 (`~/.agents/scratch/release-v<version>`), lease "build" (30 minutes), run

   ```sh
   AGENTS_VERSION=<version> deploy/gcp/up.sh
   ```

   and release "build" the moment it ends. It acts as `~/.agents/secrets/gcp-agents-control.json`
   and keeps the store and the APNs key. Then check, from this Mac:
   - `curl -fsS https://control.agentloops.dev/healthz` says `ok`;
   - the version it serves, the one Settings ▸ Control plane shows, is `<version>`. `up.sh`
     checks it last and prints `agents-control <version> (go)`; to look again:
     `CLOUDSDK_CONFIG=~/.agents/gcloud/agents-control CLOUDSDK_CORE_PROJECT=agents-control gcloud compute ssh agents-control --zone us-west1-b --command 'cd /opt/agents && sudo docker compose -f deploy/compose.public.yaml exec -T control /agents-control version'`.

   If `up.sh` or a check fails, never roll back the store and never run `down.sh`. File a
   bug: title `Release v<version>: the control plane deploy failed`, labels `bug`,
   `priority:high`, with no milestone, with the step and its first
   error (never a secret). Say it in the report. It does not hold step 9: the release is
   out.
6. **Remove the scratch worktree** when the deploy and its checks are done, also when they
   failed: `git worktree remove --force ~/.agents/scratch/release-v<version>`.
7. **Integration videos** (#1857): `scripts/video/make.sh --changed <the last tag> v<version>`
   lists the integration scenes whose integration this release changed. If it lists any,
   run the `integration-videos` workflow with `manage_workflows run`, with those ids as
   its note. Do not wait for it: it is not part of the gate, and its result is not in
   your report.

## 9. Close the finished milestones

When step 8 found the GitHub release and both TestFlight builds, close each milestone
that the notes name under `## Milestones finished` (#3760):

1. Look again that it has no open issue (#2455):
   `gh issue list --milestone "<title>" --state open --json number --jq '.[].number'`
   is empty. A milestone never closes with open issues: nothing schedules an issue in a
   closed milestone. If one was added since the plan, leave the milestone open and say so
   in the report.
2. Close it: `gh api -X PATCH repos/alexec/Agents/milestones/<number> -f state=closed`.

Make no new milestone. The next milestone is the open one with the earliest due date. Its
work did not wait for this release (#3465), so there is nothing to unpark. The Scrum Master may not read a message from you
until Alex speaks to it (#1728), so do the rest yourself:

3. **Lift a hold:** there should be none, as nothing is held for a milestone (#3465) or a
   patch (#3212). For each open pull request
   still labelled `hold:v<major.minor>` (for v0.6.0, `hold:v0.6`) or `hold:v<version>`:
   `gh pr edit N --remove-label <the label>`. A PR that still carries
   `needs-approval` (AGENTS.md, "A UI enhancement waits for Alex") is still waiting on
   Alex's screenshot approval: leave its auto-merge off, and name it in the report
   instead. For every other one, `gh pr merge N --auto --squash`. Turning auto-merge on
   is not merging: CI and the branch rules still decide. A stacked PR whose base is not
   `main` refuses auto-merge; leave it, and name it in the report.
4. Tell the Scrum Master (`message_session`) that the release shipped, which PRs you
   released and which you could not.

If step 8 failed, leave the milestones open and say so in the report.

## 10. Review the release

Decided in #1659: every release reviews itself, briefly, while its times are still in
this session. Write `~/.agents/reviews/releases/v<version>.md` (outside the folder, so
nothing is pushed): a timeline from T0 (checks done, highs fixed, gate, tag, GitHub
release, TestFlight, milestones closed), and a table of each step where a person did
something, why, and the issue that would make it run without one. Search the issues
first (`gh issue list --state all --search "<words> in:title"`); file a new one, at most
three, only for a step that has no issue yet, with no milestone. Name no security
finding. `.agents/reviews/releases/v0.6.0.md` is the first, and the model.

## 11. Report

End with `done` and a short table: version, tag, the GitHub release URL, the iOS and
macOS builds' states, the control plane deploy (healthz, the version served, its bug if it failed), the milestones finished and whether each is closed, the checks you ran, the issues fixed for this release, the known
issues, the advisories that are fixed and ready for Alex to publish, the held PRs you
released, and the release review's file and issues.
