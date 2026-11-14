#!/usr/bin/env python3
"""Reads the real deploy data of agentloops-dev/Agents for the boards of spec 5239 into data.json.

- every GitHub Deployment of the last 30 days (all environments), with its statuses for the
  release and app-store environments, and the github-pages ones of the last 7 days;
- the version tags, with when each was made;
- the PRs in each release, from the squash titles' "(#n)" between version tags (local git).

The raw answers stay in /tmp/deploy-model-cache. python3 fetch.py && python3 boards.py
"""
import datetime
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
REPO = "agentloops-dev/Agents"
CACHE = Path("/tmp/deploy-model-cache")
CACHE.mkdir(exist_ok=True)
NOW = datetime.datetime.now(datetime.timezone.utc)


def gh(path):
    key = CACHE / (re.sub(r"[^A-Za-z0-9]+", "_", path) + ".json")
    if key.exists():
        return json.loads(key.read_text())
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=True).stdout
    key.write_text(out)
    return json.loads(out)


def t(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True, cwd=HERE).stdout


deploys = []
for env, days in [("release", 30), ("app-store", 30), ("github-pages", 7)]:
    page = 1
    while True:
        rows = gh(f"repos/{REPO}/deployments?environment={env}&per_page=100&page={page}")
        keep = [d for d in rows if NOW - t(d["created_at"]) <= datetime.timedelta(days=days)]
        for d in keep:
            st = gh(f"repos/{REPO}/deployments/{d['id']}/statuses")
            job = ""
            m = re.search(r"/job/(\d+)", (st[0].get("log_url") or "") if st else "")
            if m and env != "github-pages":
                job = gh(f"repos/{REPO}/actions/jobs/{m.group(1)}")["name"]
            deploys.append({"id": d["id"], "environment": env, "job": job, "ref": d["ref"], "sha": d["sha"],
                            "created": d["created_at"],
                            "statuses": [{"state": s["state"], "at": s["created_at"]} for s in reversed(st)]})
        if len(keep) < len(rows) or len(rows) < 100:
            break
        page += 1

tags = []
for line in git("for-each-ref", "--sort=creatordate", "--format=%(refname:short) %(creatordate:iso-strict) %(objectname:short)",
                "refs/tags/v*").splitlines():
    name, at, sha = line.split()
    if re.fullmatch(r"v\d+\.\d+\.\d+", name):
        tags.append({"name": name, "at": at, "sha": sha})
tags = [g for g in tags if NOW - t(g["at"]) <= datetime.timedelta(days=40)]

prs = {}
for a, b in zip(tags, tags[1:]):
    rows = []
    for line in git("log", "--format=%H%x09%cI%x09%s", f"{a['name']}..{b['name']}").splitlines():
        sha, at, subject = line.split("\t", 2)
        m = re.search(r"\(#(\d+)\)\s*$", subject)
        if m:
            row = {"pr": int(m.group(1)), "merged": at}
            if b["name"] == tags[-1]["name"]:
                row["title"] = subject[: m.start()].strip()  # only the latest release's titles are drawn
            rows.append(row)
    prs[b["name"]] = rows

# What a machine runs (board 6): origin/main's build, as scripts/version.sh names it, and its changes
# since the last tag. Run `git fetch origin` first.
root = git("rev-parse", "--show-toplevel").strip()
head = git("rev-parse", "--short=9", "origin/main").strip()
last = tags[-1]["name"]
since = git("log", "--format=%h%x09%cI%x09%s", f"{last}..origin/main").splitlines()
main_prs = []
for line in since:
    sha, at, subject = line.split("\t", 2)
    m = re.search(r"\(#(\d+)\)\s*$", subject)
    if m:
        main_prs.append({"pr": int(m.group(1)), "merged": at, "title": subject[: m.start()].strip()})
major, minor, patch = (int(x) for x in last[1:].split("."))
main = {"sha": head, "at": git("show", "-s", "--format=%cI", "origin/main").strip(), "last": last,
        "version": f"{major}.{minor}.{patch + 1}-dev.{len(since)}+g{head}", "commits": len(since),
        "prs": len(main_prs), "newest": main_prs[:6]}

(HERE / "data.json").write_text(json.dumps({"fetched": NOW.isoformat(timespec="seconds"), "repo": REPO,
                                            "deploys": deploys, "tags": tags, "prs": prs, "main": main}, separators=(",", ":")))
print(len(deploys), "deploys,", len(tags), "tags,", sum(len(v) for v in prs.values()), "PRs")
