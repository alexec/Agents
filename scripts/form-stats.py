#!/usr/bin/env python3
"""Count the forms agents asked Alex, before and after a cut-off (#1092).

Reads every session's transcript.jsonl under the app's agents folder and pairs
each elicitationAsked with its elicitationAnswered. A question counts as
"recommended" when the answer starts with the choice whose title says
"(Recommended)"; a form counts as "all recommended" when every question with
choices took it.

    scripts/form-stats.py [--cut 2026-10-16T01:53:58Z] [--start 2026-10-08T07:00:00Z]

The default cut is when PR #1093 (decide and tell, #1083) merged.
"""

import argparse
import datetime as dt
import glob
import json
import os
import statistics

ROOT = os.path.expanduser("~/Library/Application Support/Agents/agents")


def when(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def choice_questions(asked):
    form = ((asked.get("mode") or {}).get("form") or {}).get("_0", {})
    return [p for p in form.get("properties", []) if (p.get("kind", {}).get("string") or {}).get("choices")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--start", default="2026-10-08T07:00:00Z")
    ap.add_argument("--cut", default="2026-10-16T01:53:58Z")
    ap.add_argument("--end", default=dt.datetime.now(dt.timezone.utc).isoformat())
    args = ap.parse_args()
    start, cut, end = when(args.start), when(args.cut), when(args.end)

    sessions = {"before": 0, "after": 0}
    for f in glob.glob(os.path.join(args.root, "*", "agent.json")):
        try:
            t = when(json.load(open(f))["createdAt"])
        except (OSError, ValueError, KeyError):
            continue
        if start <= t < end:
            sessions["before" if t < cut else "after"] += 1

    asked, answered = {}, {}
    for f in glob.glob(os.path.join(args.root, "*", "transcript.jsonl")):
        for line in open(f, errors="replace"):
            if "elicitation" not in line:
                continue
            try:
                record = json.loads(line)
                kind = record["kind"]
            except (ValueError, KeyError):
                continue
            if not isinstance(kind, dict):
                continue
            if "elicitationAsked" in kind:
                a = kind["elicitationAsked"]["_0"]
                asked[a["id"]] = (a, when(record["at"]))
            elif "elicitationAnswered" in kind:
                a = kind["elicitationAnswered"]
                answered[a["id"]] = (a, when(record["at"]))

    keys = ("forms", "answered", "all_recommended", "no_recommended", "questions", "took_recommended", "took_other")
    stats = {p: dict.fromkeys(keys, 0) | {"waits": [], "all_recommended_wait": 0.0} for p in ("before", "after")}
    for form_id, (a, t) in asked.items():
        if not start <= t < end:
            continue
        s = stats["before" if t < cut else "after"]
        s["forms"] += 1
        if form_id not in answered:
            continue
        reply, t_answer = answered[form_id]
        wait = (t_answer - t).total_seconds() / 3600
        s["answered"] += 1
        s["waits"].append(wait)
        answers = {x.get("question"): x.get("answer") for x in reply.get("answers", [])}
        questions = choice_questions(a)
        all_recommended, any_recommended = bool(questions), False
        for q in questions:
            s["questions"] += 1
            rec = [c["title"] for c in q["kind"]["string"]["choices"] if "recommended" in c.get("title", "").lower()]
            if not rec:
                all_recommended = False
                continue
            any_recommended = True
            answer = answers.get(q["title"])
            if isinstance(answer, str) and answer.startswith(rec[0]):
                s["took_recommended"] += 1
            else:
                s["took_other"] += 1
                all_recommended = False
        if not any_recommended:
            s["no_recommended"] += 1
        if all_recommended:
            s["all_recommended"] += 1
            s["all_recommended_wait"] += wait

    spans = {"before": (cut - start).total_seconds() / 86400, "after": (end - cut).total_seconds() / 86400}
    for period, s in stats.items():
        days, waits = spans[period], s.pop("waits")
        print(f"{period}: {days:.1f} days, {sessions[period]} sessions")
        print(f"  forms {s['forms']} ({s['forms'] / days:.1f}/day, {100 * s['forms'] / max(sessions[period], 1):.1f} per 100 sessions)")
        print(f"  answered {s['answered']}, all recommended {s['all_recommended']} ({s['all_recommended'] / days:.1f}/day), "
              f"no recommended option {s['no_recommended']}")
        print(f"  questions {s['questions']}: took recommended {s['took_recommended']}, took another {s['took_other']}")
        if waits:
            print(f"  waited {sum(waits):.1f} h in all (median {60 * statistics.median(waits):.1f} min), "
                  f"{s['all_recommended_wait']:.1f} h on all-recommended forms")


if __name__ == "__main__":
    main()
