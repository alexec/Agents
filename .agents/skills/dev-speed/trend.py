#!/usr/bin/env python3
"""Add one line to the dev-speed trend file and say which limits are crossed (#4833).

Reads the JSON that time-spent.py writes (--json), counts the pull requests merged
in the same window with `gh`, appends one line to trend.jsonl, and prints one line
per limit crossed. It prints nothing when no limit is crossed; the exit code is 0
either way (1 only for a bad input).

The limits:
  (a) running hours per merged PR is 20% or more above the median of the last 14
      trend lines (no earlier line: this limit is not checked);
  (b) one category that is not a wait (`wait: ...`) takes more than 10% of the
      running time, or its p90 is twice or more its median p90 in the last 14 lines.

Usage: trend.py REPORT.json [--trend PATH] [--merged N] [--date YYYY-MM-DD]
"""

import argparse
import datetime
import json
import os
import statistics
import subprocess
import sys

HISTORY = 14
RATIO_LIMIT = 1.2
SHARE_LIMIT = 0.10
P90_LIMIT = 2.0


def merged_prs(days: float) -> int:
    since = (datetime.date.today() - datetime.timedelta(days=days)).isoformat()
    r = subprocess.run(["gh", "pr", "list", "--state", "merged", "--limit", "1000",
                        "--search", f"merged:>={since}", "--json", "number"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"trend.py: gh pr list failed: {r.stderr.strip()}")
    return len(json.loads(r.stdout))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--trend", default=os.path.expanduser("~/.agents/reviews/dev-speed/trend.jsonl"))
    ap.add_argument("--merged", type=int, help="merged PRs in the window (default: ask gh)")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    args = ap.parse_args()

    with open(args.report) as f:
        rep = json.load(f)
    hours = rep["running_s"] / 3600
    merged = args.merged if args.merged is not None else merged_prs(rep["days"])
    tools = [c for c in rep["categories"] if not c["category"].startswith("wait: ")]
    tools.sort(key=lambda c: c["total_s"], reverse=True)
    top = [{"category": c["category"],
            "share": round(c["total_s"] / rep["running_s"], 4) if rep["running_s"] else 0,
            "p90_s": round(c["p90_s"], 1)} for c in tools[:5]]
    line = {"date": args.date, "running_h": round(hours, 2), "merged_prs": merged,
            "running_h_per_pr": round(hours / merged, 3) if merged else None, "top": top}

    history = []
    if os.path.exists(args.trend):
        with open(args.trend) as f:
            history = [json.loads(x) for x in f if x.strip()][-HISTORY:]

    crossed = []
    ratios = [h["running_h_per_pr"] for h in history if h.get("running_h_per_pr")]
    if ratios and line["running_h_per_pr"]:
        med = statistics.median(ratios)
        if line["running_h_per_pr"] >= RATIO_LIMIT * med:
            crossed.append(f"(a) running hours per merged PR {line['running_h_per_pr']:.2f} "
                           f">= {RATIO_LIMIT:.1f} x median {med:.2f}")
    for c in top:
        if c["share"] > SHARE_LIMIT:
            crossed.append(f"(b) {c['category']} takes {c['share']:.0%} of running time")
        past = [t["p90_s"] for h in history for t in h.get("top", []) if t["category"] == c["category"]]
        if past and c["p90_s"] >= P90_LIMIT * statistics.median(past) > 0:
            crossed.append(f"(b) {c['category']} p90 {c['p90_s']:.0f}s >= {P90_LIMIT:.0f} x "
                           f"median {statistics.median(past):.0f}s")

    os.makedirs(os.path.dirname(args.trend), exist_ok=True)
    with open(args.trend, "a") as f:
        f.write(json.dumps(line) + "\n")
    for c in crossed:
        print(c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
