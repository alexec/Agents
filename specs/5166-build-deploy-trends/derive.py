#!/usr/bin/env python3
"""Turns fetch.py's cache (/tmp/bdt-cache) into data.json, the figures boards.py draws.

The terms (spec.md, "The terms"):
  - time to green: a run's creation to its last job's end (wall time), for a run that passed.
  - queue: the part of that wall time when a job of the run waited for a runner and no job ran.
  - run: the rest, when at least one job ran. queue + run = wall.
  - a job's queue is its creation to its start; its run is its start to its end.
Change points are found per job, on that job's run time in main's passed runs (not the queue
time, and not a run's total, which mixes in which jobs ran), by binary
segmentation on log seconds (the idea of E-divisive, as Apache Otava uses it, made simple): split
where the shift in mean is largest, keep it when the shift is at least 15 % and its t-like score
is over 5, at least 25 runs each side (then shown only when the median moved by 30 s and 20 %
and the score is 8 or more), and look again inside each side.
"""
import collections, datetime, json, math, re, statistics, zoneinfo
from pathlib import Path

HERE = Path(__file__).parent
CACHE = Path("/tmp/bdt-cache")
TZ = zoneinfo.ZoneInfo("America/Los_Angeles")


def t(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def day(dt):
    return dt.astimezone(TZ).date().isoformat()


def pct(v, p):
    v = sorted(v)
    if not v:
        return None
    k = (len(v) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def union(intervals):
    total, end = 0.0, None
    for a, b in sorted(intervals):
        if end is None or a > end:
            total += (b - a).total_seconds()
            end = b
        elif b > end:
            total += (b - end).total_seconds()
            end = b
    return total


def jobs_of(run_id):
    f = CACHE / f"jobs-{run_id}.json"
    return json.loads(f.read_text()) if f.exists() else None


def runner(job):
    labels = job.get("labels") or []
    return labels[0] if labels else "?"


def shape(run):
    """A run's figures, from its jobs when the cache has them."""
    created = t(run["created_at"])
    js = jobs_of(run["id"])
    out = {"id": run["id"], "event": run["event"], "branch": "main" if run["head_branch"] == "main" else "pr",
           "created": run["created_at"], "conclusion": run["conclusion"], "attempt": run["run_attempt"],
           "sha": run["head_sha"][:9], "title": (run["display_title"] or "")[:90], "prs": run["prs"]}
    if js is None:
        end = t(run["updated_at"])
        out["wall"] = (end - created).total_seconds()
        return out
    done = [j for j in js if j["started_at"] and j["completed_at"] and j["conclusion"] not in ("skipped",)]
    ran = [(t(j["started_at"]), t(j["completed_at"])) for j in done if t(j["completed_at"]) > t(j["started_at"])]
    if not ran:
        out["wall"] = (t(run["updated_at"]) - created).total_seconds()
        return out
    end = max(b for _, b in ran)
    wall = (end - created).total_seconds()
    running = union(ran)
    # Waiting its turn: the run's creation to its first job's creation. ci.yml's concurrency group
    # keeps one run on main going and one pending, so a run on main waits for the one before it.
    pending = max(0.0, (min(t(j["created_at"]) for j in done) - created).total_seconds())
    out.update(wall=wall, run=running, queue=max(0.0, wall - running), pending=min(pending, max(0.0, wall - running)), jobs={
        j["name"]: {"runner": runner(j), "queue": (t(j["started_at"]) - t(j["created_at"])).total_seconds(),
                    "run": (t(j["completed_at"]) - t(j["started_at"])).total_seconds(), "conclusion": j["conclusion"]}
        for j in done})
    return out


def gantt(run):
    """One run's jobs and steps, as offsets in seconds from the run's creation."""
    created = t(run["created_at"])
    rows = []
    for j in jobs_of(run["id"]) or []:
        if not j["started_at"] or not j["completed_at"] or j["conclusion"] == "skipped":
            continue
        rows.append({
            "name": j["name"], "runner": runner(j), "conclusion": j["conclusion"],
            "queued": (t(j["created_at"]) - created).total_seconds(),
            "started": (t(j["started_at"]) - created).total_seconds(),
            "ended": (t(j["completed_at"]) - created).total_seconds(),
            "steps": [{"name": s["name"], "start": (t(s["started_at"]) - created).total_seconds(),
                       "end": (t(s["completed_at"]) - created).total_seconds(), "conclusion": s["conclusion"]}
                      for s in j["steps"] if s["started_at"] and s["completed_at"]]})
    rows.sort(key=lambda r: r["queued"])
    return rows


def segments(vals, lo, hi, found, depth=0):
    """Binary segmentation on vals[lo:hi] (log seconds)."""
    n = hi - lo
    if n < 50 or depth > 4:
        return
    best, at = 0.0, None
    pre = [0.0]
    for v in vals[lo:hi]:
        pre.append(pre[-1] + v)
    sd = statistics.pstdev(vals[lo:hi]) or 1e-9
    for k in range(25, n - 25):
        ml = pre[k] / k
        mr = (pre[n] - pre[k]) / (n - k)
        score = abs(mr - ml) / sd * math.sqrt(k * (n - k) / n)
        if score > best:
            best, at = score, k
    if at is None:
        return
    ml = pre[at] / at
    mr = (pre[n] - pre[at]) / (n - at)
    shift = math.exp(mr - ml) - 1
    if best > 5 and abs(shift) >= 0.15:
        found.append((lo + at, shift, best))
        segments(vals, lo, lo + at, found, depth + 1)
        segments(vals, lo + at, hi, found, depth + 1)


def daily(rows, key):
    by = collections.defaultdict(list)
    for r in rows:
        if r.get(key) is not None:
            by[day(t(r["created"]))].append(r[key])
    return {d: {"n": len(v), "median": statistics.median(v), "p90": pct(v, 0.9)} for d, v in sorted(by.items())}


def main():
    ci = json.loads((CACHE / "runs-ci.json").read_text())
    rel = json.loads((CACHE / "runs-release.json").read_text())
    shaped = sorted((shape(r) for r in ci if r["status"] == "completed"), key=lambda r: r["created"])
    # A re-run (attempt 2 or more) is left out of the time figures: the jobs API gives the latest
    # attempt's jobs, so its span runs from the first attempt to the re-run, and the wait between
    # is a person's or an agent's choice, not a queue. Re-runs are counted as such (failed rounds).
    green_main = [r for r in shaped if r["branch"] == "main" and r["conclusion"] == "success" and "run" in r and r["attempt"] == 1]
    green_pr = [r for r in shaped if r["branch"] == "pr" and r["conclusion"] == "success" and r["attempt"] == 1]

    # The trend: by day, median and p90, queue and run, for main; wall for pull requests.
    trend = {
        "main": {"wall": daily(green_main, "wall"), "queue": daily(green_main, "queue"), "run": daily(green_main, "run"), "pending": daily(green_main, "pending")},
        "pr": {"wall": daily(green_pr, "wall"), "queue": daily([r for r in green_pr if "queue" in r], "queue"),
               "run": daily([r for r in green_pr if "run" in r], "run")},
    }
    # Per job on main: by day, the median of its queue and its run.
    names = collections.Counter(n for r in green_main for n in r["jobs"])
    jobs = {}
    for name, _ in names.most_common():
        rows = [{"created": r["created"], "queue": r["jobs"][name]["queue"], "run": r["jobs"][name]["run"]}
                for r in green_main if name in r["jobs"]]
        jobs[name] = {"runner": next(r["jobs"][name]["runner"] for r in green_main if name in r["jobs"]),
                      "queue": daily(rows, "queue"), "run": daily(rows, "run")}

    # Change points, one job at a time, on that job's run time on main: a run's wall time mixes
    # in which jobs ran (ci.yml's select job runs only the jobs a change's paths need), so a docs
    # PR after an app PR would look like a speed-up.
    points = []
    for name in jobs:
        runs_with = [r for r in green_main if name in r["jobs"] and r["jobs"][name]["conclusion"] == "success"]
        if len(runs_with) < 100:
            continue
        vals = [math.log(max(r["jobs"][name]["run"], 1)) for r in runs_with]
        found = []
        segments(vals, 0, len(vals), found)
        for i, shift, score in sorted(found):
            before, after = runs_with[i - 1], runs_with[i]
            lo, hi = max(0, i - 25), min(len(runs_with), i + 25)
            jr = lambda r: r["jobs"][name]["run"]
            jq = lambda r: r["jobs"][name]["queue"]
            between = [r for r in shaped if r["branch"] == "main" and before["created"] < r["created"] <= after["created"]]
            points.append({
                "job": name, "runner": jobs[name]["runner"], "index": i, "at": after["created"], "shift": shift, "score": score,
                "runBefore": statistics.median(jr(r) for r in runs_with[lo:i]),
                "runAfter": statistics.median(jr(r) for r in runs_with[i:hi]),
                "queueBefore": statistics.median(jq(r) for r in runs_with[lo:i]),
                "queueAfter": statistics.median(jq(r) for r in runs_with[i:hi]),
                "series": [{"created": r["created"], "run": jr(r), "queue": jq(r)} for r in runs_with[max(0, i - 60):i + 60]],
                "before": {k: before[k] for k in ("id", "created", "sha", "title", "wall", "run", "queue", "pending")},
                "after": {k: after[k] for k in ("id", "created", "sha", "title", "wall", "run", "queue", "pending")},
                "commits": [{"sha": r["sha"], "title": r["title"], "created": r["created"], "conclusion": r["conclusion"],
                             "ran": name in r.get("jobs", {}), "jobRun": r.get("jobs", {}).get(name, {}).get("run")} for r in between],
                "ganttBefore": gantt(next(r for r in ci if r["id"] == before["id"])),
                "ganttAfter": gantt(next(r for r in ci if r["id"] == after["id"])),
            })
    # Keep the ones a person should look at: the median moved by 30 s and 20 % or more, with a
    # score of 8 or more. The rest are noise on a short job (select, lint) or a one-run blip.
    points = [p for p in points if abs(p["runAfter"] - p["runBefore"]) >= 30
              and abs(p["runAfter"] / p["runBefore"] - 1) >= 0.2 and p["score"] >= 8]
    points.sort(key=lambda p: p["at"])

    # A run that waited for runners: the main run whose jobs waited longest for a runner (not
    # for the run before it), for the drill-down's note on queue time.
    loaded = max(green_main, key=lambda r: r["queue"] - r["pending"])

    # Deploys: the release workflow's runs and their jobs.
    deploys = []
    for r in sorted(rel, key=lambda r: r["created_at"]):
        if r["status"] != "completed":
            continue
        s = shape(r)
        deploys.append({"id": r["id"], "created": r["created_at"], "conclusion": r["conclusion"], "title": s["title"],
                        "branch": r["head_branch"], "event": r["event"], "wall": s["wall"], "run": s.get("run"),
                        "queue": s.get("queue"), "jobs": s.get("jobs", {})})
    tags = []
    import subprocess
    for line in subprocess.check_output(["git", "-C", str(HERE), "tag", "--format=%(refname:short) %(creatordate:iso-strict)"], text=True).splitlines():
        name, when = line.split(" ", 1)
        if re.match(r"v\d+\.\d+\.\d+$", name):
            tags.append({"tag": name, "at": when})
    tags.sort(key=lambda x: x["at"])

    data = {
        "repo": "alexec/Agents", "fetched": datetime.datetime.now(TZ).isoformat(timespec="minutes"),
        "timeZone": "America/Los_Angeles",
        "counts": {"ciRuns": len(shaped), "mainGreen": len(green_main), "prGreen": len(green_pr),
                   "prWithJobs": sum(1 for r in green_pr if "run" in r), "releaseRuns": len(deploys),
                   "mainAll": sum(1 for r in shaped if r["branch"] == "main"),
                   "failed": sum(1 for r in shaped if r["conclusion"] == "failure"),
                   "cancelled": sum(1 for r in shaped if r["conclusion"] == "cancelled")},
        "trend": trend, "jobs": jobs, "changePoints": points,
        "mainRuns": [{"created": r["created"], "run": r["run"], "queue": r["queue"], "pending": r["pending"], "wall": r["wall"]} for r in green_main],
    "reruns": {"main": sum(1 for r in shaped if r["branch"] == "main" and r["attempt"] > 1),
               "pr": sum(1 for r in shaped if r["branch"] == "pr" and r["attempt"] > 1)},
        "mostQueued": {k: loaded[k] for k in ("id", "created", "title", "wall", "run", "queue", "pending")},
        "mostQueuedGantt": gantt(next(r for r in ci if r["id"] == loaded["id"])),
        "deploys": deploys, "tags": tags,
    }
    (HERE / "data.json").write_text(json.dumps(data, indent=0, separators=(",", ":")) + "\n")
    print(json.dumps(data["counts"]))
    for p in points:
        print(f"change point {p['job']} {p['at']} shift {p['shift']:+.0%} score {p['score']:.1f} run {p['runBefore']/60:.1f}m -> {p['runAfter']/60:.1f}m, "
              f"queue {p['queueBefore']/60:.1f}m -> {p['queueAfter']/60:.1f}m, {len(p['commits'])} commits")


if __name__ == "__main__":
    main()
