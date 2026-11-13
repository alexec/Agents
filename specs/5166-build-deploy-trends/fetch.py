#!/usr/bin/env python3
"""Fetches the real data the boards draw: alexec/Agents' `ci` runs (main and pull requests) and
its `release` runs (the deploys: the image, the Mac build, TestFlight) for the last 90 days, with
their jobs and steps, from the GitHub API. The raw answers go to a cache in /tmp (not committed);
derive.py turns them into data.json beside this file.

python3 fetch.py, with gh signed in. One public repository only. The run list is asked in 3-day
windows, because the API gives at most 1,000 runs for one query. Jobs (with their steps) are
fetched for every run on main, for every release run, and for every 4th pull-request run.
"""
import concurrent.futures, datetime, json, subprocess, sys
from pathlib import Path

REPO = "alexec/Agents"
CACHE = Path("/tmp/bdt-cache")
CACHE.mkdir(exist_ok=True)
DAYS = 90
TODAY = datetime.date(2026, 11, 12)
WORKFLOWS = {"ci": "ci.yml", "release": "release.yml"}


def api(path):
    out = subprocess.check_output(["gh", "api", path], stderr=subprocess.DEVNULL)
    return json.loads(out)


def runs(workflow):
    got = {}
    start = TODAY - datetime.timedelta(days=DAYS)
    while start <= TODAY:
        end = min(start + datetime.timedelta(days=2), TODAY)
        page = 1
        while True:
            r = api(f"repos/{REPO}/actions/workflows/{WORKFLOWS[workflow]}/runs"
                    f"?created={start}..{end}&per_page=100&page={page}")
            for run in r["workflow_runs"]:
                got[run["id"]] = {k: run.get(k) for k in (
                    "id", "event", "head_branch", "head_sha", "created_at", "run_started_at", "updated_at",
                    "status", "conclusion", "run_attempt", "display_title", "html_url")}
                got[run["id"]]["prs"] = [p["number"] for p in run.get("pull_requests") or []]
            if len(r["workflow_runs"]) < 100:
                break
            page += 1
        print(f"{workflow} {start}..{end}: {len(got)}", file=sys.stderr)
        start = end + datetime.timedelta(days=1)
    return list(got.values())


def jobs(run_id):
    f = CACHE / f"jobs-{run_id}.json"
    if f.exists():
        return json.loads(f.read_text())
    r = api(f"repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100")
    keep = [{
        "name": j["name"], "labels": j.get("labels"), "created_at": j.get("created_at"),
        "started_at": j.get("started_at"), "completed_at": j.get("completed_at"),
        "conclusion": j.get("conclusion"),
        "steps": [{k: s.get(k) for k in ("name", "started_at", "completed_at", "conclusion")} for s in j.get("steps") or []],
    } for j in r["jobs"]]
    f.write_text(json.dumps(keep))
    return keep


def main():
    for wf in WORKFLOWS:
        f = CACHE / f"runs-{wf}.json"
        if not f.exists():
            f.write_text(json.dumps(runs(wf)))
    ci = json.loads((CACHE / "runs-ci.json").read_text())
    rel = json.loads((CACHE / "runs-release.json").read_text())
    pr = sorted((r for r in ci if r["event"] == "pull_request"), key=lambda r: r["created_at"])
    want = [r["id"] for r in ci if r["head_branch"] == "main" and r["event"] == "push"]
    want += [r["id"] for r in rel] + [r["id"] for r in pr[::4]]
    want = [i for i in want if not (CACHE / f"jobs-{i}.json").exists()]
    print(f"jobs to fetch: {len(want)}", file=sys.stderr)
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for n, _ in enumerate(pool.map(jobs, want)):
            if n % 200 == 0:
                print(f"  {n}", file=sys.stderr)


if __name__ == "__main__":
    main()
