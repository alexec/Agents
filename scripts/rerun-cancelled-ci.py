#!/usr/bin/env python3
"""Rerun a pull request's cancelled ci run once, and say so loudly the second time (#897).

  scripts/rerun-cancelled-ci.py run <run-id> <attempt> [--dry-run]
  scripts/rerun-cancelled-ci.py selftest

A required job that ends Cancelled (a job timeout, a runner lost) leaves its pull request
BLOCKED with auto-merge on and nothing red to see: PRs #879 and #895 sat like that until
someone reran them by hand. .github/workflows/ci-cancelled.yml runs `run` when a ci run
completes Cancelled. A cancellation is left alone when it is not a pull request's, or when
a newer run or push replaced it (the concurrency group cancels those on purpose). Else the
first cancelled attempt has its cancelled and failed jobs rerun; a later one gets a comment
on the pull request naming the jobs and why, and this exits 1 so the run shows red.

--dry-run reads everything and prints what it would do, and changes nothing.
"""

import json
import os
import subprocess
import sys

WORKFLOW = "ci.yml"
# Attempts that are rerun by this script. One: a second cancellation is not luck.
RERUNS = 1


def gh(*args):
    out = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    return out.stdout


def gh_json(*args):
    return json.loads(gh(*args) or "null")


def decide(run, attempt, newest_run_id, pr):
    """What to do about one completed attempt of a ci run.

    run: the run's fields (id, event, conclusion of this attempt, head_sha);
    newest_run_id: the newest ci run on the run's branch for pull requests;
    pr: the open pull request for the branch ({number, headRefOid}) or None.
    Returns (action, reason) with action one of skip, rerun, report.
    """
    if run["event"] != "pull_request":
        return "skip", f"a {run['event']} run, not a pull request's"
    if run["conclusion"] != "cancelled":
        return "skip", f"attempt {attempt} ended {run['conclusion']}"
    if newest_run_id != run["id"]:
        return "skip", f"run {newest_run_id} replaced it"
    if pr is None:
        return "skip", "no open pull request for its branch"
    if pr["headRefOid"] != run["head_sha"]:
        return "skip", f"PR #{pr['number']} has moved on to {pr['headRefOid'][:8]}"
    if attempt <= RERUNS:
        return "rerun", f"PR #{pr['number']}: attempt {attempt} was cancelled with no newer run"
    return "report", f"PR #{pr['number']}: attempt {attempt} was cancelled again"


def cancelled_jobs(repo, run_id, attempt):
    """Each job of the attempt that did not pass, with GitHub's words for why."""
    jobs = gh_json("api", f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs",
                   "--jq", ".jobs")
    found = []
    for job in jobs or []:
        if job.get("conclusion") not in ("cancelled", "failure", "timed_out"):
            continue
        why = []
        try:
            notes = gh_json("api", f"repos/{repo}/check-runs/{job['id']}/annotations")
            why = [n["message"].splitlines()[0] for n in notes or []
                   if n.get("annotation_level") == "failure"]
        except subprocess.CalledProcessError:
            pass
        found.append((job["name"], job["conclusion"], why[0] if why else ""))
    return found


def run_command(repo, run_id, attempt, dry_run):
    run = gh_json("api", f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}")
    run = {"id": run["id"], "event": run["event"], "conclusion": run["conclusion"],
           "head_sha": run["head_sha"], "head_branch": run["head_branch"],
           "html_url": run["html_url"]}
    newest = gh_json("api", "-X", "GET", f"repos/{repo}/actions/workflows/{WORKFLOW}/runs",
                     "-f", f"branch={run['head_branch']}", "-f", "event=pull_request",
                     "-f", "per_page=1", "--jq", ".workflow_runs[0].id")
    prs = gh_json("pr", "list", "--repo", repo, "--head", run["head_branch"],
                  "--state", "open", "--json", "number,headRefOid")
    pr = prs[0] if prs else None

    action, reason = decide(run, attempt, newest, pr)
    print(f"run {run_id} attempt {attempt}: {action} ({reason})")
    if action == "skip":
        return 0

    jobs = cancelled_jobs(repo, run_id, attempt)
    for name, conclusion, why in jobs:
        print(f"  {name}: {conclusion}{' — ' + why if why else ''}")

    if action == "rerun":
        if dry_run:
            print(f"dry run: would run `gh run rerun {run_id} --failed`")
            return 0
        gh("run", "rerun", str(run_id), "--failed", "--repo", repo)
        print(f"::notice::Reran the cancelled jobs of run {run_id} for PR #{pr['number']}.")
        return 0

    lines = [f"CI run {run['html_url']} was cancelled on attempt {attempt}, with no newer run, "
             f"after one automatic rerun (#897). Auto-merge waits on its required checks, so "
             f"this pull request is stuck until someone reruns or fixes it.", ""]
    lines += [f"- `{name}`: {conclusion}{' — ' + why if why else ''}" for name, conclusion, why in jobs]
    body = "\n".join(lines)
    if dry_run:
        print("dry run: would comment on PR #%d:\n%s" % (pr["number"], body))
    else:
        gh("pr", "comment", str(pr["number"]), "--repo", repo, "--body", body)
    print(f"::error::Run {run_id} was cancelled again on attempt {attempt}; PR #{pr['number']} is stuck.")
    return 1


def selftest():
    run = {"id": 7, "event": "pull_request", "conclusion": "cancelled", "head_sha": "abc"}
    pr = {"number": 879, "headRefOid": "abc"}
    cases = [
        (dict(run, event="push"), 1, 7, pr, "skip"),
        (dict(run, conclusion="success"), 1, 7, pr, "skip"),
        (dict(run, conclusion="failure"), 1, 7, pr, "skip"),
        (run, 1, 8, pr, "skip"),                                  # a newer run replaced it
        (run, 1, 7, None, "skip"),                                # the PR is closed or merged
        (run, 1, 7, dict(pr, headRefOid="def"), "skip"),          # pushed, run not made yet
        (run, 1, 7, pr, "rerun"),                                 # #879 and #895
        (run, 2, 7, pr, "report"),                                # cancelled again
        (run, 3, 7, pr, "report"),                                # a hand rerun cancelled too
    ]
    bad = 0
    for given_run, attempt, newest, given_pr, want in cases:
        got, reason = decide(given_run, attempt, newest, given_pr)
        mark = "ok " if got == want else "BAD"
        bad += got != want
        print(f"{mark} attempt {attempt}: {got} ({reason})")
    return 1 if bad else 0


def main(argv):
    if argv[:1] == ["selftest"]:
        return selftest()
    if len(argv) >= 3 and argv[0] == "run":
        repo = os.environ.get("GH_REPO") or gh("repo", "view", "--json", "nameWithOwner",
                                               "--jq", ".nameWithOwner").strip()
        return run_command(repo, int(argv[1]), int(argv[2]), "--dry-run" in argv[3:])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
