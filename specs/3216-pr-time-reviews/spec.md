# Feature Specification: Reviews at PR time

**Issue**: #3216, "1.0: bring back the reviews at PR time (shift left)"

**Created**: 2026-11-01

**Status**: Draft. Parked for the 1.0 milestone. Nothing here is built before 1.0.

## Why this feature exists

Until 2026-11-01, five reviews ran once per release: security, performance, HADR, dead code
and usability. They read everything that merged since the last tag, so they found problems
after the problems were on `main`. The usability check alone found about 102 of the 296 bugs
filed from 2026-10-20 to 10-27. Every one of those bugs cost a second PR.

#3215 paused the five reviews until 1.0, because before 1.0 the product changes too fast for
them to pay back what they cost. At 1.0, Alex wants to lock in best practice (Alex,
2026-11-01). This spec brings the reviews back, but **on each pull request, before it
merges** (shift left), not when a release goes out.

## Decisions

These come from #3216 and the talk with Alex. Alex can overrule any of them.

- **D1. A review reads one PR's changes only.** It never reads all of `main`. It runs when the
  PR changes a path that the review owns (D2).
- **D2. Each review owns paths.** The paths are in one file, `.agents/review-paths`, in the
  same form as `.agents/areas`:

  | Review | Paths (first draft) | What it reads |
  |---|---|---|
  | usability | `App/Sources`, `Remote/Sources`, `Shared/UI`, `Web/src` | the #2811 screenshots, consistency within a client, parity with the other two (`parity.md`), iOS design |
  | performance | `Go/internal/agentsd`, `Packages/AgentsKit/Sources`, stores, events | main-thread work, growth without a bound, descriptors, polling, transcript size, start-up, reconnects |
  | security | tokens, `daemon.sock` roles, servers, the Keychain, git, `.github/workflows`, `deploy/` | the `security-review` method: exploitable problems with an attack path |
  | HADR | stores, writes, `deploy/`, backups | bounds, safe writes, backup and restore, single points of failure |

- **D3. Two levels: cheap checks on every PR, deep reviews only on risk.**
  - **Cheap checks** run on every PR in CI, with no model: lint rules and tests (D5, D6).
  - **Deep reviews** (an agent with a model) run only when the PR's `risk` label (#3040,
    `scripts/pr-risk.py`) is `risk:high`, or when the PR is a UI enhancement waiting for
    Alex (`needs-approval`, #2811). The usability review runs on each `needs-approval` PR,
    before Alex looks at the screenshots, so Alex sees its findings beside them.
- **D4. A deep review runs as a workflow in this folder, on `pr.opened` and `pr.synchronized`**,
  as `review-pull-requests` (#833) does now, one session for each review that the PR's paths
  name. It reads the PR's diff and the files around it. It never pushes, merges or changes a
  file. It reports by a commit status on the PR's head, `review/<name>`, and one comment
  (D7).
- **D5. Lint findings that match past bugs fail new code.** The rules in `scripts/lint.sh` that
  only report today, and that match bugs we filed, fail CI's `lint` job on the lines a PR
  changes (`LINT_BASE=origin/main`). They do not fail on old code.
- **D6. A finding that comes back becomes a rule or a test.** When a deep review finds the
  same kind of problem a second time, its lane adds a lint rule or a test for it, so the
  cheap checks find it next time and the deep review does not have to.
- **D7. What blocks a merge** (open question 1):
  - A **critical or high** finding sets `review/<name>` to failure. At 1.0, `main`'s ruleset
    requires the `review/*` statuses, so the PR cannot merge. The PR's lane fixes the
    finding and pushes. The review runs again on the new head.
  - A **medium or low** finding is a comment only. The status is success.
  - **Why:** "only high blocks" is already the release's rule (#1661). A comment that does
    not block is the same as no review for an agent that is not told to read it.
- **D8. Security findings are never public** (open question 2). The repository is public.
  - The security review posts **no details** on the PR: no comment text about the problem.
    It sets `review/security` to failure with the description "a security finding: see the
    advisory" and adds the label `security-hold`.
  - It writes the finding to a **draft security advisory** with
    `.agents/skills/release/scripts/advisory.py create` (as the paused security review did),
    and makes the advisory's private fork.
  - It sends the advisory's URL, and only the URL, to the PR's lane with `message_session`
    (the lane is a session in this folder: its label `P#<n>`). When no session owns the PR,
    it sends the URL to the Scrum Master.
  - The lane fixes it on the PR's branch with a commit message that names no attack, and
    writes `Fixed by <commit>` on the advisory. The review runs again and takes the label
    off.
- **D9. A time and token budget** (open question 3):
  - Each deep review has **10 minutes**. The reviews of one PR run at the same time as CI, so
    a PR waits for the slowest of them, not for their sum.
  - At most **two deep reviews run at once** in the folder. The others wait in a queue, and
    their statuses say "queued".
  - A review that runs past 10 minutes stops. Its status is **success**, with the
    description "not reviewed: out of time", and it posts a comment that says so. It never
    blocks a merge for being slow. The release's short check (D10) reads what it missed.
  - **Why:** the open-PR limit is 6 (2026-11-01). A review that blocks for longer than CI
    holds a place that another lane needs.
- **D10. The release keeps a short check across PRs** for what no one PR shows: dead code
  (a symbol whose last caller left in another PR), a HADR restore on a scratch set-up, and
  the PRs whose review ran out of time (D9). It runs the `dead-code-review` and
  `hadr-review` skills, on the changes since the last tag, with a 2-hour limit.
- **D11. The five skills come back, not new ones.** `security-audit`, `performance-review`,
  `hadr-review`, `dead-code-review` and `usability-check` get a "PR mode" that reads one
  PR's diff. Their release mode stays for D10. #3215's "Paused until 1.0" lines go.

## What a person sees

- On a PR: one status for each review the PR's paths name (`review/usability`,
  `review/performance`, …), with a short description. A failing one blocks the merge.
- One `<!-- agent -->` comment for each review, with its findings by severity, each with
  `file:line` and why. No comment for security (D8).
- Alex's list of PRs that wait for approval (#2811) shows the usability review's comment
  beside the screenshots.

## Out of scope

- Reviews before a PR is opened (in a lane's own worktree).
- A machine account and CODEOWNERS for the agents (#2811 names that as a later option).
- Reviews of pull requests from people outside the repository.

## Done when

1. `.agents/review-paths` names each review's paths, and CI checks that every path it names
   is there.
2. A `risk:high` PR that changes `Go/internal/agentsd` gets `review/performance` within 10
   minutes, and a high finding blocks its merge.
3. A security finding on a PR makes a draft advisory, the `security-hold` label and a failing
   status, and puts no detail on the PR.
4. A review that runs out of time passes with "not reviewed: out of time".
5. The lint rules that D5 names fail CI on new lines only.
6. The release runs only the short check (D10).
7. `main`'s ruleset requires the `review/*` statuses. That change is Alex's.
