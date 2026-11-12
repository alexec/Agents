#!/usr/bin/env python3
"""Fetches the real data the boards draw: the PRs merged in Alex's repositories, by day, in
America/Los_Angeles, with the merged reverts. Writes data.json beside itself.

python3 real-data.py, with gh signed in. The windows keep each ask under gh's 1,000 limit.
A velocity/history (#4596) answers the same shape from the lineage store, with hours too.
"""
import collections, datetime, json, subprocess, zoneinfo
from pathlib import Path

HERE = Path(__file__).parent
TZ = zoneinfo.ZoneInfo("America/Los_Angeles")
REPOS = ["alexec/Agents", "alexec/agents-walk"]
# gh searches merged: in UTC, so the last window is open-ended: a PR merged this evening in
# Los Angeles is tomorrow in UTC.
WINDOWS = ["2026-10-10..2026-10-20", "2026-10-21..2026-10-31", ">=2026-11-01"]


def merged(repo, window):
    out = subprocess.check_output(["gh", "pr", "list", "--repo", repo, "--state", "merged", "--search", f"merged:{window}",
                                   "--json", "number,title,mergedAt,headRefName", "--limit", "1000"])
    return json.loads(out)


days = collections.defaultdict(lambda: collections.defaultdict(lambda: {"merged": 0, "reverted": 0}))
seen = set()
for repo in REPOS:
    for window in WINDOWS:
        pulls = merged(repo, window)
        assert len(pulls) < 1000, f"{repo} {window} hit gh's limit; split the window"
        for p in pulls:
            if (repo, p["number"]) in seen:
                continue
            seen.add((repo, p["number"]))
            day = datetime.datetime.fromisoformat(p["mergedAt"].replace("Z", "+00:00")).astimezone(TZ).date().isoformat()
            bucket = days[day][f"github:{repo}"]
            bucket["merged"] += 1
            if p["title"].lower().startswith("revert"):
                bucket["reverted"] += 1

data = {"fetched": datetime.datetime.now(TZ).isoformat(timespec="minutes"), "timeZone": "America/Los_Angeles",
        "days": {d: dict(r) for d, r in sorted(days.items())}}
(HERE / "data.json").write_text(json.dumps(data, indent=1) + "\n")
total = sum(b["merged"] for r in days.values() for b in r.values())
print(f"data.json: {len(days)} days, {total} PRs, {len(seen)} seen")
