#!/usr/bin/env python3
"""Count the parity table's rows by verdict and by tier, a line per screen (#2020, #2796).

  scripts/parity-counts.py

Each screen of specs/071-web-remote/walks/parity.md is a file of its own under parity/. A
row's verdict is its last cell: a row with any **delta** counts as delta, else one with
**by design** as by design, else **same**. A row's tier is its second cell: Core,
Mac + web or One client. The script fails on a row with no tier it knows.
"""

import glob
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SCREENS = os.path.join(ROOT, "specs", "071-web-remote", "walks", "parity", "*.md")
VERDICTS = ("same", "by design", "delta")
TIERS = ("Core", "Mac + web", "One client")


def verdict(row):
    last = row.rstrip().rstrip("|").split(" | ")[-1]
    for v in ("delta", "by design", "same"):
        if f"**{v}" in last:
            return v
    return None


def tier(row):
    cells = row.split(" | ")
    return cells[1].strip() if len(cells) > 1 else None


def main():
    totals = dict.fromkeys(VERDICTS + TIERS, 0)
    bad = []
    print("| Screen | Same | By design | Delta | Core | Mac + web | One client |")
    print("|---|---|---|---|---|---|---|")
    for path in sorted(glob.glob(SCREENS)):
        with open(path) as f:
            lines = f.read().splitlines()
        title = lines[0].removeprefix("# Parity: ")
        counts = dict.fromkeys(VERDICTS + TIERS, 0)
        for n, line in enumerate(lines, 1):
            if not line.startswith("| ") or not (v := verdict(line)):
                continue
            counts[v] += 1
            t = tier(line)
            if t in TIERS:
                counts[t] += 1
            else:
                bad.append(f"{os.path.relpath(path, ROOT)}:{n}: tier {t!r} is not one of {', '.join(TIERS)}")
        for k in counts:
            totals[k] += counts[k]
        print(f"| {title} | " + " | ".join(str(counts[k]) for k in VERDICTS + TIERS) + " |")
    print(f"\nOf {sum(totals[v] for v in VERDICTS)} rows: **{totals['same']} same**, "
          f"**{totals['by design']} by design**, **{totals['delta']} delta**; "
          f"**{totals['Core']} Core**, **{totals['Mac + web']} Mac + web**, "
          f"**{totals['One client']} One client**.")
    if bad:
        print("\n" + "\n".join(bad), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
