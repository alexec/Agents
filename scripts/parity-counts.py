#!/usr/bin/env python3
"""Count the parity table's rows by verdict, a line per screen (#2020).

  scripts/parity-counts.py

Each screen of specs/071-web-remote/walks/parity.md is a file of its own under parity/. A
row's verdict is its last cell: a row with any **delta** counts as delta, else one with
**by design** as by design, else **same**.
"""

import glob
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SCREENS = os.path.join(ROOT, "specs", "071-web-remote", "walks", "parity", "*.md")
VERDICTS = ("same", "by design", "delta")


def verdict(row):
    last = row.rstrip().rstrip("|").split(" | ")[-1]
    for v in ("delta", "by design", "same"):
        if f"**{v}" in last:
            return v
    return None


def main():
    totals = dict.fromkeys(VERDICTS, 0)
    print("| Screen | Same | By design | Delta |")
    print("|---|---|---|---|")
    for path in sorted(glob.glob(SCREENS)):
        with open(path) as f:
            lines = f.read().splitlines()
        title = lines[0].removeprefix("# Parity: ")
        counts = dict.fromkeys(VERDICTS, 0)
        for line in lines:
            if line.startswith("| ") and (v := verdict(line)):
                counts[v] += 1
        for v in VERDICTS:
            totals[v] += counts[v]
        print(f"| {title} | " + " | ".join(str(counts[v]) for v in VERDICTS) + " |")
    print(f"\nOf {sum(totals.values())} rows: **{totals['same']} same**, "
          f"**{totals['by design']} by design**, **{totals['delta']} delta**.")


if __name__ == "__main__":
    main()
