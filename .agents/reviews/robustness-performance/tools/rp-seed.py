#!/usr/bin/env python3
# Seed a scratch root for the 2026-10-03 robustness/performance review.
# usage: rp-seed.py ROOT PROJECTS AGENTS_PER_PROJECT LIVE_PER_PROJECT EVENTS
import json, os, sys, uuid, datetime, random, subprocess
root, P, A, L, E = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
assert root.startswith("/tmp/run-")
repo = subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(__file__)), "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
fx = json.load(open(os.path.join(repo, "Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/archived-agent.json")))
now = datetime.datetime.now(datetime.timezone.utc)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond//1000:03d}Z"
os.makedirs(f"{root}/agents", exist_ok=True)
projects = []
filler = "Seeded words for a transcript of the right size. " * 40
for p in range(P):
    folder = f"{root}/p/proj{p:02d}"
    os.makedirs(folder, exist_ok=True)
    if not os.path.isdir(folder + "/.git"):
        subprocess.run(["git", "init", "-q", folder], check=True)
    url = "file://" + folder + "/"
    projects.append({"folder": url, "addedAt": iso(now - datetime.timedelta(days=30))})
    for i in range(A):
        live = i < L
        aid = str(uuid.uuid4()).upper()
        r = dict(fx)
        when = now - datetime.timedelta(minutes=1 + p * A + i)
        r.update(id=aid, title=f"P{p:02d} seeded {'live' if live else 'archived'} {i}", cwd=url,
                 createdAt=iso(when - datetime.timedelta(hours=1)), lastActivityAt=iso(when))
        if live:
            r.update(state="finished", endedReason="endTurn"); r.pop("archivedReason", None); r.pop("archivedAt", None)
        else:
            r.update(state="archived", archivedReason="byUser", archivedAt=iso(when))
        d = f"{root}/agents/{aid}"; os.makedirs(d, exist_ok=True)
        json.dump(r, open(d + "/agent.json", "w"), sort_keys=True)
        with open(d + "/transcript.jsonl", "w") as t:
            for n in range(2):
                t.write(json.dumps({"at": iso(when), "id": str(uuid.uuid4()).upper(), "kind": {"agentMessage": {"text": f"{n}: {filler}"}}}, sort_keys=True) + "\n")
json.dump(sorted(projects, key=lambda x: x["folder"]), open(f"{root}/projects.json", "w"), indent=1)
with open(f"{root}/events.jsonl", "w") as f:
    for n in range(E):
        p = projects[n % P]["folder"]
        f.write(json.dumps({"event": {"at": iso(now - datetime.timedelta(seconds=(E - n) * 30)), "chainDepth": 0, "consequences": [], "count": 1,
            "details": {"agent": str(uuid.uuid4()).upper(), "agent_title": f"seeded {n}", "outcome": "done"}, "name": "agent.finished",
            "position": n + 1, "scope": {"project": {"_0": p}}, "sentence": f"seeded event {n} finished: complete."}}, sort_keys=True) + "\n")
print("seeded", P, "projects", P * A, "agents", E, "events")
