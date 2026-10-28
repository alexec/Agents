---
name: release
description: Take main to a new version with nobody watching (#914), started by Alex. A minor (x.y.0) is followed by a bugs-only patch (x.y.1) that skips the reviews (#2801). For a minor, run the eight reviews and checks once each on what changed since the last tag, have the high findings fixed through the Scrum Master's lanes (medium security advisories get one release of grace, then go to the Scrum Master as priority work), check the gate, choose the version, check its milestone, write the notes, tag and push, check the GitHub release and both TestFlight builds, deploy the live control plane, close the milestone, make the patch milestone after a minor or unpark the next minor after a patch, and review how the release went. Use when the Release workflow runs, or when Alex asks for a release. Not for installing on Alex's Mac or devices (ship-app), and never for App Review.
---

# Release

A release takes `main` to a new version on the GitHub release page (Agents Host, the Linux
agentsd) and on TestFlight (the Mac window and the Remote, one Universal app). The tag does
the publishing: `.github/workflows/release.yml` builds, signs and uploads when a `v*` tag
is pushed. This skill decides when the tag is pushed, and what it says.

Alex decided (2026-10-13, #914):

- **When the gate passes, push the tag.** Do not ask for approval. Alex has already started the release.
- **Version:** minor when an `enhancement` merged since the last tag, otherwise patch.
  1.0 and major versions only when Alex says.
- **Every minor release runs the eight reviews and checks once each** (#1462, #1557, #2161):
  security, performance, HADR, dead code, runtimes, usability, competitors and the feature
  matrix.
- **Two paths: minor and patch** (Alex, 2026-10-27, #2801). `release-plan.py`'s `path:` says
  which. A **minor** (x.y.0) does every step. A **patch** (x.y.z, z > 0) only fixes bugs: it
  skips steps 2, 3 and 4 (the reviews and checks, and their fixes), and keeps the rest: one
  release a day, the gate, the notes, the tag, the GitHub release, both TestFlight builds,
  the control plane deploy, closing the milestone and the release review. Every minor is
  followed by one patch, x.y.1 (step 9).
- **Scope is what changed** (#1462): the reviews read only `main` since the last tag.
  Step 3 also carries forward open medium security advisories from earlier releases.
  Older open issues are not this release's.
- **Time is one day** (#1462), from the start of the run (T0): the reviews and the fixes
  fit in it.
- **Priority is a label:** `priority:high` and `priority:medium`. Within each, security
  goes before performance, before HADR, before usability, before runtimes, before the rest.
- **Only high blocks** (Alex, 2026-10-19, #1661). The release tags as soon as no high is
  open; it never waits for a medium fix. Other medium findings are filed with
  `priority:medium`, listed as known issues, and worked by the ordinary lanes after the
  release (a bug in the next milestone, the rest as labelled). Low is recorded and not
  worked.
- **A version has a milestone** (#1348): `0.5.0` is the milestone whose title starts
  with `0.5 `, and `0.12.3` the one whose title starts with `0.12.3 ` (#2801). The milestone
  is done when its release has shipped, and this skill closes it then (step 9).
- **Security findings stay private** until they ship: a draft GitHub security advisory
  per finding, fixed on its private fork. Medium advisories get one release of grace,
  then go to the Scrum Master as priority work. The notes say only "Security fixes".

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
2. `.agents/skills/release/scripts/release-plan.py`. It prints the last tag, the next
   version and the path. If it says nothing merged since the last tag, end with
   `nothing_to_do`.
3. **A patch** (`path: patch`, #2801): go to step 5. It runs no reviews or checks, and has
   no findings to fix. When the plan prints `differs:` because an enhancement merged, ask
   Alex now, as in step 6; when Alex picks the minor version, take the minor path.

## 2. Reviews and checks, once each

Eight workflows run exactly once per release, and only here (#1462). None has a schedule.

| Order | Workflow | It writes |
|---|---|---|
| 1 | `security-review` | `.agents/reviews/security/` on `agents/reviews-security` |
| 1 | `performance-review` | `.agents/reviews/performance/` on `agents/reviews-performance` |
| 1 | `hadr-review` | `.agents/reviews/hadr/` on `agents/reviews-hadr` |
| 1 | `dead-code-review` | `.agents/reviews/dead-code/` on `agents/reviews-dead-code` |
| 2 | `nightly-runtimes` (Runtime check) | `~/Library/Caches/Agents Nightly Runtimes/runs/latest/report.md` |
| 2 | `usability-check` | `.agents/reviews/usability/` on `agents/reviews-usability` |
| 3 | `competitor-check` | `~/.agents/reviews/competitors/` |
| 4 | `feature-matrix` | a pull request on `agents/feature-matrix-<date>` |

Start every one of them once per release. The only one to skip is one that already ran
for this release: its report (or pull request) is newer than the last tag, as when an
earlier run of this skill ended `partly_done`. Never start one again in the same release.
Run each with `manage_workflows run`. When that is refused (the workflow is turned off, or waits for Alex's OK), read the workflow with
`manage_workflows read`, and call `start_session` with its prompt (the text under its front matter) and its `runtime:`, `model:` and `permission-mode:`.
Start them by order, at most two at a time: the reviews take turns on the "build" lease,
and the feature matrix reads the competitor check's report. Wait with `wait_for_event`,
naming the sessions in `agents`, `until_minutes` 240 or the time left to T0 + 1 day,
whichever is less. As each one finishes, archive it with `archive_session` and do step 3
for its findings at once, so their fixes start while the others still run. One that
failed, or is still running at T0 + 1 day (stop it with `stop_session`), is a note in
your report, not a reason to stop, and it is not started again until the next release.

## 3. Have the high ones fixed, and file the medium ones

Collect the open findings with severity high or critical (both are "high" here) or
medium **that this release's runs recorded**: the ones in their run files (front matter
`base:` is the last tag), not older lines of `findings.md`. In order:

- **Security:** lines in `.agents/reviews/security/findings.md` on
  `agents/reviews-security` whose status is not `fixed` on main, `won't fix` or
  `recorded` as low. These are private: see "Security findings" below. Also collect
  carried-over draft medium advisories as described there.
- **Performance:** the same in
  `git show agents/reviews-performance:.agents/reviews/performance/findings.md`. A status
  `fixed on <branch>` is fixed only when that branch is merged; until then it is open,
  and the issue names the branch so the lane can push it.
- **HADR:** the same in
  `git show agents/reviews-hadr:.agents/reviews/hadr/findings.md` (#1557). A line that
  says `filed #NNN` is that issue. A line that says `needs a decision` is for Alex (a
  change that costs money or changes the live set-up): name it in the report, and file
  it as for the others.
- **Usability:** the same in `.agents/reviews/usability/findings.md` on
  `agents/reviews-usability`. Most already say `filed #NNN`.
- **Runtimes:** open issues the runtime check filed in this release (their titles start with
  the cause it found); count each as medium.
- **Issues:** every open issue labelled `priority:high` or `priority:medium` that was
  opened since the last tag (`gh issue list --search "created:>=<the tag's date>"`).

For each finding that is not security:

1. Search the issues, open and closed, for its id (`gh issue list --state all --search
   "P20261011-1 in:body"`). If there is one, make sure it is open and has the label.
2. If there is none, file one: title `Performance (high): <title>` (or `HADR`,
   `Usability`, `Runtime`), the finding's fields in the body with its id, the label `priority:high` or
   `priority:medium`, `bug`, and its `area:<name>` from `.agents/areas` when its files
   have one.

Then send the Scrum Master one message (`list_sessions`, then `message_session` to the
session not archived whose title has "scrum master" in it, any case, and that is labelled
`lead`): the high issues in priority order (security, performance, HADR, usability, runtimes,
the rest), then carried-over medium security advisory URLs as priority work. Say that the
release waits for high issues and never waits for a medium advisory. Other medium issues
go to the ordinary lanes after the release as their label and milestone say.

**No Scrum Master running, and work to hand over** (#1908; in v0.7.0 the highs sat
40 minutes with no owner): start one when there are high issues or carried-over medium
security advisories. Call `start_session` with the persona in
`.agents/personas/scrum-master.md` (its prompt, `runtime:` and `labels:`), the title
`<x.y> scrum master` for the version being released, and a prompt that names the milestone,
the high issues in the order above, then the carried-over medium security advisory URLs as
priority work, that the release waits for high issues but not medium advisories, and that
it reports to the release session (this one, by its id). The release still starts no fix
lane itself: the Scrum Master does. With nothing to hand over, start none, and say so in
the report.

### Security findings

For each open high or medium security finding recorded by this release, and each
carried-over draft medium advisory from an earlier release:

1. Look for its advisory: `gh api --paginate 'repos/alexec/Agents/security-advisories?state=draft'`,
   matching the finding's id in `summary`.
2. Look for its fix on main (#1727): when `findings.md` says `fixed on <branch>` and
   `git merge-base --is-ancestor <branch> origin/main` passes, or a merged pull request
   came from that branch (`gh pr list --state merged --head <branch>`), the finding is
   fixed. Make its advisory all the same (step 3), with `Fixed by <merge commit> on main.`
   at the end of the description, and send the Scrum Master nothing for it. It does not
   block. (In v0.6.0 both high fixes were on main an hour before their advisories.)
3. If there is no advisory, make it, and its private fork. Write the JSON with a quoted
   heredoc or from Python, never with `echo` (zsh's `echo` breaks the escapes). Use
   `.agents/skills/release/scripts/advisory.py`, which sends only these fields.
   `.claude/settings.json` allows it, and no other change to an advisory, so auto mode
   does not refuse it:

   ```sh
   python3 .agents/skills/release/scripts/advisory.py create <<'EOF'
   {"summary": "<id>: <short title>", "description": "<the finding's fields, and its fix branch if the review made one>",
    "severity": "<critical, high or medium>", "vulnerabilities": [{"package": {"ecosystem": "swift", "name": "Agents"}}]}
   EOF
   python3 .agents/skills/release/scripts/advisory.py fork <ghsa_id>
   ```

4. For a high one, send the Scrum Master the advisory's URL only (it is private). Its lane fixes the
   finding on the advisory's private fork, then opens the pull request on `main` with a
   title and body that name no attack ("Harden token comparison"), and writes
   `Fixed by <merge commit> on main.` at the end of the advisory's description
   (`python3 .agents/skills/release/scripts/advisory.py fixed <ghsa_id> <merge commit>`).

5. Collect older draft medium advisories with
   `gh api --paginate 'repos/alexec/Agents/security-advisories?state=draft'`. Match each
   summary to its finding id. An advisory with `created_at` before this release's T0 is
   from an earlier release. Skip advisories created in this run; a medium advisory gets
   one release of grace and is collected here in a later release if it remains open.
   For each older advisory, check for `Fixed by <commit>` and verify that commit is on
   `origin/main`. Also check a recorded `fixed on <branch>` fix as in step 2: the branch
   is fixed when it is an ancestor of `origin/main` or a merged pull request came from
   it. If fixed, run `advisory.py fixed` with the merge commit and do not hand it off.
   Leave an unfixed advisory as a draft, then send its URL to the Scrum Master as
   priority work. Its lane fixes it on the advisory's private fork as in step 4. Never
   include the finding or title in the message or report.

6. In the report, list each carried-over advisory by advisory id only, and say whether it
   is fixed. Do not include a finding id, summary, title or attack details. Do not send a
   medium advisory made in this release to the Scrum Master until the next release.

An advisory is fixed when its description says `Fixed by <commit>` and that commit is on
`origin/main`, or its fix branch is merged to `origin/main`, directly or by a merged PR
from that branch. Leave the advisory a draft: publishing it after the release is Alex's.

## 4. Wait for the fixes

Until the gate can pass:

- Recount what is still open of what step 3 collected: its issues, and its security
  advisories without their fix on `origin/main`.
- Go on as soon as nothing high is open. Never wait for a medium one: those still open
  go into the notes as known issues.
- Otherwise wait with `wait_for_event` for `issue.closed` and `pr.merged`, with
  `until_minutes` at most the time left to T0 + 1 day.
- High always blocks. At T0 + 1 day with a high one still open, end with `partly_done`,
  naming what is open. The next run is a new day (a new T0); it skips the reviews that
  already ran (step 2) and picks up the same findings.

## 5. Gate

All of these, on the commit you will tag (`git rev-parse origin/main`, fetched again now):

1. **CI is green on it:** `gh run list --branch main --commit <sha> --json name,conclusion`
   shows every run `success` (or `skipped`). If one is still running, wait for it with
   `wait_for_event` (`checks.failed`, or `until_minutes: 30`) and look again. If one
   failed, end with `partly_done`; main broken is fixed by its own PR, through the Scrum
   Master.
2. **No open high:** none of step 3's high issues is open, and none of its high security
   advisories is without its fix. **For a patch** (#2801), instead: no `priority:high` or
   `priority:medium` bug is open in its milestone. Two days after the last tag
   (America/Los_Angeles), the patch goes out with what is still open, as known issues; a low
   bug never holds it. Before then, wait as in step 4 for `issue.closed` and `pr.merged`,
   until the two days are up.
3. **Walks:** `gh issue list --label needs-walk --state open` holds at most five.
   More than five: end with `partly_done`, naming them; walks are the Scrum Master's to start.
4. **No tag today** (#2462): look again as in step 0. The release can run past midnight, so a
   tag pushed today by another run ends this one with `nothing_to_do` and "released today
   (vX.Y.Z at HH:MM); next release tomorrow", unless Alex's prompt says to release again today.
5. **The archives build on a cold cache** (#2780): `gh workflow run release-dry-run.yml -f
   ref=<sha>`, then find its run (`gh run list --workflow release-dry-run.yml --json
   databaseId,displayTitle,status --jq '.[] | select(.displayTitle == "release dry run <sha>")'`)
   and wait for it as in item 1 (it takes up to an hour). It runs release.yml's `mac` and
   `testflight` archives as dry runs on a runner with an empty build cache, which no lane
   or merge wave does (#2773 spent v0.12.0's tag). A run of it on a pull request does not
   count: run it on `<sha>`. If it failed, end with `partly_done`, naming the job and its
   first error; the fix goes through the Scrum Master as for main broken.

## 6. Version and notes

1. Run `release-plan.py` again. Its `next:` is the version, when it agrees with the open
   milestone's version beside it. When the plan prints `differs:` (#2779), stop before the
   tag and ask Alex by form which version to use, with the `differs:` line's reason (an
   enhancement merged, a capability removed). Renumber the milestones only when Alex says.
2. **Milestone:** find the version's milestone
   (`gh api 'repos/alexec/Agents/milestones?state=open' --jq '.[]|[.number,.title]|@tsv'`)
   and its open issues (`gh issue list --milestone "<title>" --state open`). Open issues
   do not stop the release: each one goes into the notes as a known issue.
3. Write the notes in Markdown, in plain short sentences:
   - one heading per kind that has changes, in this order: `## New` (the plan's
     `[enhancement]`), `## Fixed` (`[bug]`) and `## Changed` (the rest), with a line per
     change, from the pull requests the plan lists. A line names the pull request:
     `- The sidebar shows … (#698)`. A pull request whose body has a `Release note:`
     paragraph gives that paragraph as its line, as written: it says what a person has to
     do, such as how to go back to the Swift Linux host. Leave out changes only agents see (CI, scripts,
     workflows) unless they change what a person does;
   - `## Security fixes` with only "This release fixes security problems found by our
     own review." when an advisory was fixed since the last tag. Nothing more;
   - `## Known issues`: the medium issues still open and the milestone's open issues,
     one line each with its number.
   - `## Capabilities`, as `python3 .agents/skills/release/scripts/capability-changes.py
     <last tag> <sha>` writes it: the capabilities added, deprecated and removed (#1748,
     `docs/explanation/versions.md`). Nothing when it writes nothing. A minor before 1.0 may
     remove a capability number; a patch never does: a patch whose list has `Removed` stops
     the release with `partly_done`.

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

1. Wait for the release run: `gh run list --workflow release.yml --branch v<version>`;
   `gh run watch <id> --exit-status` (run it in the background, then wait with
   `wait_for_event` and `until_minutes: 30`, and look again).
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
   `priority:high`, `area:control-plane`, in the next milestone, with the step and its first
   error (never a secret). Say it in the report. It does not hold step 9: the release is
   out.
6. **Remove the scratch worktree** when the deploy and its checks are done, also when they
   failed: `git worktree remove --force ~/.agents/scratch/release-v<version>`.
7. **Integration videos** (#1857): `scripts/video/make.sh --changed <the last tag> v<version>`
   lists the integration scenes whose integration this release changed. If it lists any,
   run the `integration-videos` workflow with `manage_workflows run`, with those ids as
   its note. Do not wait for it: it is not part of the gate, and its result is not in
   your report.

## 9. Close the milestone

When step 8 found the GitHub release and both TestFlight builds, close the version's
milestone:

0. **The next milestone** (#2801):
   - **After a minor** (x.y.0), it is the patch milestone `x.y.1 Bug fixes`. Make it when it
     is not there:
     `gh api repos/alexec/Agents/milestones -f title="x.y.1 Bug fixes" -f description="Patch: the bugs found in and after vx.y.0, and nothing else (#2801)"`.
   - **After a patch** (x.y.z), it is the next minor milestone: the open one with the next
     lowest version. Only when a `priority:high` bug is still open in this milestone, make
     `x.y.<z+1> Bug fixes` as above, and that is the next milestone instead.
1. Move its open bugs to the next milestone first (#1570):
   `gh issue list --milestone "<title>" --state open --label bug --json number --jq '.[].number'`,
   then `gh issue edit N --milestone "<next>"` for each one.
2. Move every other open issue to the backlog (#2455):
   `gh issue list --milestone "<title>" --state open --json number --jq '.[].number'`,
   then `gh issue edit N --remove-milestone` for each one. A milestone never closes with
   open issues: nothing schedules an issue in a closed milestone. A non-bug goes to the
   backlog, not the next milestone, because an issue gets a milestone only when it serves
   that milestone's goal (#1340). Alex starts the release by hand, so a non-bug can still
   be open here.
3. Look again: the list in 2 is empty. Then close it:
   `gh api -X PATCH repos/alexec/Agents/milestones/<number> -f state=closed`.

Then the next milestone becomes the
open one and its work can start (#2309), and you open the gate for it yourself (#1729). The Scrum Master may not read a message
from you until Alex speaks to it (#1728), so do not leave this to it:

4. **Lift the hold:** for a minor there should be none, as nobody works the next milestone
   before this one ships (#2309). For a patch, the enhancement PRs that waited for it are
   labelled `hold:v<version>` (for v0.12.3, `hold:v0.12.3`, #2801). For each open pull
   request still labelled `hold:v<major.minor>` (for v0.6.0, `hold:v0.6`) or
   `hold:v<version>`: `gh pr edit N --remove-label <the label>`, then
   `gh pr merge N --auto --squash`. Turning auto-merge on is not merging: CI and the
   branch rules still decide. A stacked PR whose base is not `main` refuses auto-merge;
   leave it, and name it in the report.
5. **Unpark the new open milestone:** the open milestone is now the next milestone of item 0
   (AGENTS.md, "Work by milestone"). Take `parked` off its open issues, and only its:
   `gh issue edit N --remove-label parked`. Every later milestone keeps `parked` (#2309).
   After a minor, that is the patch milestone, and the next minor keeps `parked` until the
   patch ships (#2801).
6. Tell the Scrum Master (`message_session`) that the release shipped, which PRs you
   released and which you could not.

If step 8 failed, leave the milestone open and say so in the report.

## 10. Review the release

Decided in #1659: every release reviews itself, briefly, while its times are still in
this session. Write `~/.agents/reviews/releases/v<version>.md` (outside the folder, so
nothing is pushed): a timeline from T0 (reviews done, highs fixed, gate, tag, GitHub
release, TestFlight, milestone closed), and a table of each step where a person did
something, why, and the issue that would make it run without one. Search the issues
first (`gh issue list --state all --search "<words> in:title"`); file a new one, at most
three, only for a step that has no issue yet, with no milestone. Name no security
finding. `.agents/reviews/releases/v0.6.0.md` is the first, and the model.

## 11. Report

End with `done` and a short table: version, tag, the GitHub release URL, the iOS and
macOS builds' states, the control plane deploy (healthz, the version served, its bug if it failed), the milestone and whether it is closed, the reviews you ran, the issues fixed for this release, the known
issues, the advisories that are fixed and ready for Alex to publish, the held PRs you
released, and the release review's file and issues.
