#!/usr/bin/env python3
"""Candidate lessons from the last day of sessions (the lessons skill, #4834).

Reads the app's own session records (the same store and reader as the
dev-speed skill's time-spent.py), for the sessions of one folder active in the
last N hours, and prints three lists of candidates for the model to judge:

- corrections: the person's messages that came after the agent had acted in
  the session (not the session's first prompt), with what the agent did just
  before, and whether the text has a correction cue ("no", "don't", "instead",
  "I said", ...). A message is the person's when the record says
  `from: person`; `app` (events, timers) and `agent` (other sessions) are not;
- failures: the same command, check or tool failing in --min-sessions or more
  sessions (by dev-speed's category and repeat key);
- measurements: the person's messages, and the agent's own text, that ask for
  a number ("why is X slow", "how often", "how many", "how long").

The output holds transcript text: it is private. Write it only under
~/.agents/reviews/lessons/, never into the repo.

Read only. Standard library only, so it runs with `python3 -I`.
Usage: lessons.py [--hours 24] [--folder PATH] [--store PATH] [--min-sessions 3] [--json]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "time_spent", os.path.join(HERE, "..", "dev-speed", "time-spent.py"))
ts = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ts)

CUE = re.compile(
    r"\b(no|not|don'?t|do not|never|stop|instead|wrong|again|why did|why do you|i said|i asked|"
    r"please don'?t|should(?:n'?t| not)|rather|undo|revert)\b", re.I)
MEASURE = re.compile(
    r"\b(why is .{0,40}\b(slow|long|late)|how (often|many|much|long|fast)|what share|"
    r"nothing (measures|reports|counts)|no (number|figure|measure)s?)\b", re.I)
CUT = 400


def read_messages(d: str, since: datetime) -> list[dict]:
    """The session's messages in order: the person's, other agents', and its own text."""
    out: list[dict] = []
    agent_text: dict[str, dict] = {}
    try:
        f = open(os.path.join(d, "transcript.jsonl"))
    except OSError:
        return out
    with f:
        for line in f:
            try:
                o = json.loads(line)
                k = next(iter(o["kind"]))
                v = o["kind"][k]
                at = ts.parse_at(o["at"])
            except (ValueError, KeyError, StopIteration):
                continue
            if at < since:
                continue
            if k == "userMessage":
                out.append({"at": at, "from": v.get("from") or "?", "text": v.get("_0") or ""})
            elif k == "agentMessage":
                mid = v.get("messageID") or ""
                m = agent_text.get(mid)
                if m is None:
                    m = agent_text[mid] = {"at": at, "from": "self", "text": ""}
                    out.append(m)
                m["text"] += v.get("text") or ""
            elif k in ("toolCall",):
                u = v.get("_0", {})
                out.append({"at": at, "from": "tool", "text": u.get("title") or ""})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--folder", default=None, help="folder whose sessions to read (default: this repo's main checkout)")
    ap.add_argument("--store", default=ts.STORE)
    ap.add_argument("--min-sessions", type=int, default=3)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    folder = os.path.abspath(args.folder or ts.default_folder())
    since = datetime.now(timezone.utc) - timedelta(hours=args.hours)
    corrections, measures = [], []
    fails: dict[tuple[str, str], dict] = defaultdict(lambda: {"sessions": set(), "count": 0})
    n = 0
    for name in os.listdir(args.store):
        d = os.path.join(args.store, name)
        try:
            if datetime.fromtimestamp(os.path.getmtime(d), timezone.utc) < since:
                continue
        except OSError:
            continue
        s = ts.read_session(d, since)
        if not s:
            continue
        where = s["folder"] or s["cwd"]
        if where != folder and not where.startswith(folder + "/"):
            continue
        n += 1
        title = s["title"][:60]
        for c in s["calls"]:
            if c["status"] == "failed":
                key = (ts.category(c["title"], c["kind"]), ts.repeat_key(c["title"])[:80])
                fails[key]["sessions"].add(s["id"])
                fails[key]["count"] += 1

        msgs = read_messages(d, since)
        acted = False
        last = ""
        for m in msgs:
            if m["from"] in ("tool", "self"):
                acted = True
                last = ("tool: " + ts.category(m["text"], None)) if m["from"] == "tool" else "reply"
            text = " ".join(m["text"].split())
            if m["from"] in ("person", "self") and MEASURE.search(text):
                measures.append({"session": s["id"], "title": title, "at": m["at"].isoformat(),
                                 "who": m["from"], "text": text[:CUT]})
            if m["from"] == "person" and acted:
                corrections.append({"session": s["id"], "title": title, "at": m["at"].isoformat(),
                                    "after": last, "cue": bool(CUE.search(text)), "text": text[:CUT]})

    repeated = sorted(({"category": k[0], "command": k[1], "sessions": len(v["sessions"]), "failures": v["count"]}
                       for k, v in fails.items() if len(v["sessions"]) >= args.min_sessions),
                      key=lambda r: -r["sessions"])
    corrections.sort(key=lambda r: (not r["cue"], r["at"]))
    result = {"since": since.isoformat(), "folder": folder, "sessions": n,
              "corrections": corrections, "failures": repeated, "measurements": measures}
    if args.json:
        json.dump(result, sys.stdout, indent=1)
        print()
        return 0

    print(f"# Lessons candidates since {since:%Y-%m-%d %H:%M} UTC\n")
    print(f"{n} sessions of {folder}. Private: transcript text below.\n")
    print(f"## Corrections ({len(corrections)}; {sum(r['cue'] for r in corrections)} with a cue)\n")
    for r in corrections:
        print(f"- {'**cue** ' if r['cue'] else ''}{r['at'][:16]} {r['title']} (`{r['session']}`), after {r['after']}: {r['text']}")
    print(f"\n## Failures in {args.min_sessions}+ sessions ({len(repeated)})\n")
    print("| Sessions | Failures | Category | Command |\n|---:|---:|---|---|")
    for r in repeated:
        print(f"| {r['sessions']} | {r['failures']} | {r['category']} | `{r['command'].replace('|', '/')}` |")
    print(f"\n## Asked for a number ({len(measures)})\n")
    for r in measures:
        print(f"- {r['at'][:16]} {r['who']} in {r['title']} (`{r['session']}`): {r['text']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
