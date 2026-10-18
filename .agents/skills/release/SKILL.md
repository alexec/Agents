---
name: release
description: Take main to a new version with nobody watching (#914). Run the six reviews and checks once each on what changed since the last tag, have the high findings fixed (and the medium ones while time is left, within a day) through the Scrum Master's lanes, check the gate, choose the version, check its milestone, write the notes, tag and push, check the GitHub release and both TestFlight builds, and close the milestone. Use when the Release workflow runs, or when Alex asks for a release. Not for installing on Alex's Mac or devices (ship-app), and never for App Review.
---

# Release

A release takes `main` to a new version on the GitHub release page (Agents Host, the Linux
agentsd) and on TestFlight (the Mac window and the Remote, one Universal app). The tag does
the publishing: `.github/workflows/release.yml` builds, signs and uploads when a `v*` tag
is pushed. This skill decides when the tag is pushed, and what it says.

Alex decided (2026-10-13, #914):

- **It runs on its own.** When the gate passes, push the tag. Do not ask for approval.
- **Version:** minor when an `enhancement` merged since the last tag, otherwise patch.
  1.0 and major versions only when Alex says.
- **Every release runs the six reviews and checks once each** (#1462): security,
  performance, runtimes, usability, competitors and the feature matrix.
- **Scope is what changed** (#1462): the reviews read only `main` since the last tag, and
  only what this release found or filed counts (step 3). Older open issues are not
  this release's.
- **Time is one day** (#1462), from the start of the run (T0): the reviews and the fixes
  fit in it.
- **Priority is a label:** `priority:high` and `priority:medium`. Within each, security
  goes before performance, before usability, before runtimes, before the rest.
- **High always blocks.** Medium is worked only once no high is open, while the day
  lasts; at T0 + 1 day the release goes out, and the medium ones still open are listed
  as known issues. Low is recorded and not worked.
- **A version has a milestone** (#1348): `0.5.0` is the milestone whose title starts
  with `0.5 `. A patch version has none. The milestone is done when its release has
  shipped, and this skill closes it then (step 9).
- **Security findings stay private** until they ship: a draft GitHub security advisory
  per finding, fixed on its private fork. The notes say only "Security fixes".

## Rules for the whole run

- Never push to `main`, never merge, never start lanes. Fix lanes are the Scrum Master's
  (`.agents/personas/scrum-master.md`). You file and label issues, and you wait.
- Never submit to App Review, and never change an App Store Connect record.
- Never write a security finding anywhere public: not in an issue, a pull request, a
  commit, the notes or a message to another session. Use its id (`S20261011-2`) only in
  the draft advisory.
- Never write on the review branches (`agents/reviews-*`). They are the reviews' own.
- Run every command from the project folder. Change no file in it: you only read, tag
  and push the tag. Write the notes in `$TMPDIR`.
- Questions: nobody is watching, and every choice here is already made. Do not ask;
  put what stopped you in the report. If you must ever ask, use your question tool and
  name yourself ("Claude (Release) recommends… Alex, do you want…?").

## 1. Is a release due?

1. Note the time T0, then `git fetch --quiet --tags origin main`.
2. `.agents/skills/release/scripts/release-plan.py`. It prints the last tag and the next
   version. If it says nothing merged since the last tag, end with `nothing_to_do`.

## 2. Reviews and checks, once each

Six workflows run exactly once per release, and only here (#1462). None has a schedule.

| Order | Workflow | It writes |
|---|---|---|
| 1 | `security-review` | `.agents/reviews/security/` on `agents/reviews-security` |
| 1 | `performance-review` | `.agents/reviews/performance/` on `agents/reviews-performance` |
| 2 | `nightly-runtimes` (Runtime check) | `~/Library/Caches/Agents Nightly Runtimes/runs/latest/report.md` |
| 2 | `usability-check` | `.agents/reviews/usability/` on `agents/reviews-usability` |
| 3 | `competitor-check` | `~/.agents/reviews/competitors/` |
| 4 | `feature-matrix` | a pull request on `agents/feature-matrix-<date>` |

Start every one of them once per release. The only one to skip is one that already ran
for this release: its report (or pull request) is newer than the last tag, as when an
earlier run of this skill ended `partly_done`. Never start one again in the same release.
An agent cannot press Run now, so read the workflow with `manage_workflows read`, and call `start_session` with its prompt
(the text under its front matter) and its `runtime:`, `model:` and `permission-mode:`.
Start them by order, at most two at a time: the reviews take turns on the "build" lease,
and the feature matrix reads the competitor check's report. Wait with `wait_for_event`,
naming the sessions in `agents`, `until_minutes` 240 or the time left to T0 + 1 day,
whichever is less. As each one finishes, archive it with `archive_session` and do step 3
for its findings at once, so their fixes start while the others still run. One that
failed, or is still running at T0 + 1 day (stop it with `stop_session`), is a note in
your report, not a reason to stop, and it is not started again until the next release.

## 3. Have high and medium fixed

Collect the open findings with severity high or critical (both are "high" here) or
medium **that this release's runs recorded**: the ones in their run files (front matter
`base:` is the last tag), not older lines of `findings.md`. In order:

- **Security:** lines in `.agents/reviews/security/findings.md` on
  `agents/reviews-security` whose status is not `fixed` on main, `won't fix` or
  `recorded` as low. These are private: see "Security findings" below.
- **Performance:** the same in
  `git show agents/reviews-performance:.agents/reviews/performance/findings.md`. A status
  `fixed on <branch>` is fixed only when that branch is merged; until then it is open,
  and the issue names the branch so the lane can push it.
- **Usability:** the same in `.agents/reviews/usability/findings.md` on
  `agents/reviews-usability`. Most already say `filed #NNN`.
- **Runtimes:** open issues the runtime check filed in this release (their titles start with
  the cause it found); count each as medium.
- **Issues:** every open issue labelled `priority:high` or `priority:medium` that was
  opened since the last tag (`gh issue list --search "created:>=<the tag's date>"`).

For each finding that is not security:

1. Search the issues, open and closed, for its id (`gh issue list --state all --search
   "P20261011-1 in:body"`). If there is one, make sure it is open and has the label.
2. If there is none, file one: title `Performance (high): <title>` (or `Usability`,
   `Runtime`), the finding's fields in the body with its id, the label `priority:high` or
   `priority:medium`, `bug`, and its `area:<name>` from `.agents/areas` when its files
   have one.

Then send the Scrum Master one message (`list_sessions`, then `message_session` to the
session titled Scrum Master): the issues in priority order (high before medium; within
each, security, performance, usability, runtimes, the rest), that the release waits for
the high ones, and that the medium ones are worked only once no high is open, until
T0 + 1 day. If no Scrum Master is running, go on to step 4 and say so in the report: the
issues are labelled, and the next Scrum Master takes them.

### Security findings

For each open high or medium security finding:

1. Look for its advisory: `gh api repos/alexec/Agents/security-advisories?state=draft`,
   matching the finding's id in `summary`.
2. If there is none, make it, and its private fork:

   ```sh
   gh api -X POST repos/alexec/Agents/security-advisories --input - <<'EOF'
   {"summary": "<id>: <short title>", "description": "<the finding's fields, and its fix branch if the review made one>",
    "severity": "<critical, high or medium>", "vulnerabilities": [{"package": {"ecosystem": "swift", "name": "Agents"}}]}
   EOF
   gh api -X POST repos/alexec/Agents/security-advisories/<ghsa_id>/forks
   ```

3. Send the Scrum Master the advisory's URL only (it is private). Its lane fixes the
   finding on the advisory's private fork, then opens the pull request on `main` with a
   title and body that name no attack ("Harden token comparison"), and writes
   `Fixed by <merge commit> on main.` at the end of the advisory's description
   (`gh api -X PATCH …/security-advisories/<ghsa_id>`).

An advisory is fixed when its description says `Fixed by <commit>` and that commit is on
`origin/main`. Leave the advisory a draft: publishing it after the release is Alex's.

## 4. Wait for the fixes

Until the gate can pass:

- Recount what is still open of what step 3 collected: its issues, and its security
  advisories without their fix on `origin/main`.
- Go on when nothing high is open, and nothing medium is open or T0 + 1 day has come.
  The medium ones still open go into the notes as known issues.
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
   advisories is without its fix.
3. **Walks:** `gh issue list --label needs-walk --state open` holds at most five.
   More than five: end with `partly_done`, naming them; walks are the Scrum Master's to start.

## 6. Version and notes

1. Run `release-plan.py` again. Its `next:` is the version.
2. **Milestone:** for a minor version, find its milestone
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
   both `agentsd-linux-*.tar.gz` and `SHA256SUMS`.
3. **TestFlight:** the `testflight` job passed. It has already waited for both builds to
   reach VALID (`scripts/asc-builds.swift`). To look again from this Mac:
   `swift scripts/asc-builds.swift <version> <the run number>`.
4. If the `testflight` job failed at "The App Store secrets are there", the secrets are
   still Alex's to add: say which, from its log, and that the GitHub release is out.
   Any other failure: name the step and the first error.

## 9. Close the milestone

When step 8 found the GitHub release and both TestFlight builds, close the version's
milestone (none for a patch version):
`gh api -X PATCH repos/alexec/Agents/milestones/<number> -f state=closed`.
Its open issues stay open in it. Then the next milestone's work can merge to `main`.
If step 8 failed, leave the milestone open and say so in the report.

## 10. Report

End with `done` and a short table: version, tag, the GitHub release URL, the iOS and
macOS builds' states, the milestone and whether it is closed, the reviews you ran, the issues fixed for this release, the known
issues, and the advisories that are fixed and ready for Alex to publish.
