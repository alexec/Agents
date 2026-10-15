---
name: release
description: Take main to a new version with nobody watching (#914). Run the reviews that are stale, have every high and medium finding fixed through the Scrum Master's lanes, check the gate, choose the version, write the notes, tag and push, and check the GitHub release and both TestFlight builds. Use when the Release workflow runs, or when Alex asks for a release. Not for installing on Alex's Mac or devices (ship-app), and never for App Review.
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
- **A review is stale** when its last report is older than **7 days**.
- **Priority is a label:** `priority:high` and `priority:medium`.
- **High always blocks.** Wait for open medium fixes for **1 day**, then release and
  list the medium ones still open as known issues.
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

1. `git fetch --quiet --tags origin main`.
2. `.agents/skills/release/scripts/release-plan.py`. It prints the last tag and the next
   version. If it says nothing merged since the last tag, end with `nothing_to_do`.
3. When the run was started by its schedule (the event you were given is a schedule, not
   Run now or a message from Alex), and the last tag is less than 13 days old, end with
   `nothing_to_do`: the schedule is weekly, and a release is due every two weeks.

## 2. Reviews, if stale

| Review | Its last report | Its workflow |
|---|---|---|
| Security | newest `YYYY-MM-DD.md` on `agents/reviews-security` under `.agents/reviews/security/` | `security-review` |
| Performance | the same on `agents/reviews-performance` under `.agents/reviews/performance/` | `performance-review` |
| Runtimes | the time of `~/Library/Application Support/Agents Nightly Runtimes/runs/latest/report.md` | `nightly-runtimes` |
| Usability | the same on `agents/reviews-usability` under `.agents/reviews/usability/` | `usability-check` |

List a branch's reports with
`git ls-tree --name-only agents/reviews-security .agents/reviews/security/`. A missing
branch or file counts as stale.

For each stale review, start it now. An agent cannot press Run now, so read the workflow
with `manage_workflows read`, and call `start_session` with its prompt (the text under its
front matter) and its `runtime:`, `model:` and `permission-mode:`. Start at most two at a
time: the reviews take turns on the "build" lease. Wait with `wait_for_event`, naming the
sessions in `agents`, `until_minutes: 240`. Archive each with `archive_session` when it
has finished. A review that failed is a note in your report, not a reason to stop.

## 3. Have high and medium fixed

Collect the open findings with severity high or critical (both are "high" here) or
medium:

- **Performance:** lines in `git show agents/reviews-performance:.agents/reviews/performance/findings.md`
  whose status is not `fixed` on main, `won't fix` or `recorded` as low. A status
  `fixed on <branch>` is fixed only when that branch is merged; until then it is open,
  and the issue names the branch so the lane can push it.
- **Usability:** the same in `.agents/reviews/usability/findings.md` on
  `agents/reviews-usability`. Most already say `filed #NNN`.
- **Runtimes:** open issues the runtime check filed (their titles start with the cause
  it found); count each as medium.
- **Security:** the same in `.agents/reviews/security/findings.md` on
  `agents/reviews-security`. These are private: see "Security findings" below.
- **Issues:** every open issue labelled `priority:high` or `priority:medium`.

For each finding that is not security:

1. Search the issues, open and closed, for its id (`gh issue list --state all --search
   "P20261011-1 in:body"`). If there is one, make sure it is open and has the label.
2. If there is none, file one: title `Performance (high): <title>` (or `Usability`,
   `Runtime`), the finding's fields in the body with its id, the label `priority:high` or
   `priority:medium`, `bug`, and its `area:<name>` from `.agents/areas` when its files
   have one.

Then send the Scrum Master one message (`list_sessions`, then `message_session` to the
session titled Scrum Master): the issues, highest first, and that the release waits for
them. If no Scrum Master is running, go on to step 4 and say so in the report: the
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

Note the time T when step 3 ended. Then, until the gate can pass:

- Recount what is still open: issues labelled `priority:high` or `priority:medium`, and
  security advisories without their fix on `origin/main`.
- Go on when nothing high is open, and nothing medium is open or T is a day ago. The
  medium ones still open go into the notes as known issues.
- Otherwise wait with `wait_for_event` for `issue.closed` and `pr.merged`, with
  `until_minutes` at most the time left to T + 1 day (1440 when only high is open).
- High always blocks. After 7 days with a high one still open, end with `partly_done`,
  naming what is open: the next scheduled run starts again from step 1.

## 5. Gate

All of these, on the commit you will tag (`git rev-parse origin/main`, fetched again now):

1. **CI is green on it:** `gh run list --branch main --commit <sha> --json name,conclusion`
   shows every run `success` (or `skipped`). If one is still running, wait for it with
   `wait_for_event` (`checks.failed`, or `until_minutes: 30`) and look again. If one
   failed, end with `partly_done`; main broken is fixed by its own PR, through the Scrum
   Master.
2. **No open high:** `gh issue list --label priority:high --state open` is empty, and so
   is the list of high security advisories without their fix.
3. **Walks:** `gh issue list --label needs-walk --state open` holds at most five.
   More than five: end with `partly_done`, naming them; walks are the Scrum Master's to start.

## 6. Version and notes

1. Run `release-plan.py` again. Its `next:` is the version.
2. Write the notes in Markdown, in plain short sentences:
   - one heading per kind that has changes, in this order: `## New` (the plan's
     `[enhancement]`), `## Fixed` (`[bug]`) and `## Changed` (the rest), with a line per
     change, from the pull requests the plan lists. A line names the pull request:
     `- The sidebar shows … (#698)`. Leave out changes only agents see (CI, scripts,
     workflows) unless they change what a person does;
   - `## Security fixes` with only "This release fixes security problems found by our
     own review." when an advisory was fixed since the last tag. Nothing more;
   - `## Known issues`: the medium issues still open, one line each with its number.

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

## 9. Report

End with `done` and a short table: version, tag, the GitHub release URL, the iOS and
macOS builds' states, the reviews you ran, the issues fixed for this release, the known
issues, and the advisories that are fixed and ready for Alex to publish.
