#!/usr/bin/env python3
"""Backtest forecasts of when an epic or a milestone lands (#4523).

    python3 specs/4533-forecasting/fetch.py alexec/Agents /tmp/issues.json
    python3 specs/4533-forecasting/backtest.py /tmp/issues.json

Prints aggregate figures only. Each method forecasts at a cut-off, from what
was known then, and is scored against when the last child merged.
"""
import json
import random
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

DAY = 86400.0
HOUR = 3600.0
DRAWS = 1000
WINDOW = 14


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else None


def landed(i):
    """When an issue landed: its first merged PR, else its close; None when it did not."""
    if not i["completed"]:
        return None
    return ts(i["mergedAt"]) or ts(i["closedAt"])


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def load(path):
    issues = json.load(open(path))
    for i in issues:
        i["start"], i["land"] = ts(i["createdAt"]), landed(i)
    return issues


class Folder:
    def __init__(self, issues):
        self.issues = issues
        self.by = {i["number"]: i for i in issues}
        self.kids = defaultdict(list)
        for i in issues:
            if i["parent"]:
                self.kids[i["parent"]].append(i)
        # Throughput: issues that landed with a merged PR, per UTC day. Epics are not work.
        self.daily = defaultdict(int)
        self.hourly = defaultdict(int)
        for i in issues:
            if i["mergedAt"] and i["completed"] and "epic" not in i["labels"]:
                self.daily[int(i["land"] // DAY)] += 1
                self.hourly[int(i["land"] // HOUR)] += 1
        self.first_day = min(self.daily)

    def window(self, at, days=None):
        d = int(at // DAY)
        return [self.daily.get(x, 0) for x in range(max(self.first_day, d - (days or WINDOW)), d)]

    def hours(self, at, days=None):
        h = int(at // HOUR)
        lo = max(self.first_day * 24, h - 24 * (days or WINDOW))
        return [self.hourly.get(x, 0) for x in range(lo, h)]

    def landed_between(self, a, b):
        return sum(self.hourly.get(x, 0) for x in range(int(a // HOUR), int(b // HOUR) + 1))

    def cycles_before(self, at, days=None):
        lo = at - days * DAY if days else 0
        return [i["land"] - i["start"] for i in self.issues
                if i["land"] and i["mergedAt"] and lo <= i["land"] < at and "epic" not in i["labels"]]

    def steps(self, kids):
        """Each child's step: 0 when no sibling blocks it, else 1 + its blockers' step."""
        nums = {k["number"] for k in kids}
        memo = {}

        def step(n, seen=()):
            if n in memo:
                return memo[n]
            bs = [b for b in self.by[n]["blockedBy"] if b in nums and b not in seen]
            memo[n] = 1 + max(step(b, seen + (n,)) for b in bs) if bs else 0
            return memo[n]
        return {k["number"]: step(k["number"]) for k in kids}


def mc_throughput(window, share, n, rng, cap=365):
    """Days until n items land, each day a resampled day of the window, thinned by share."""
    out = []
    for _ in range(DRAWS):
        done, days = 0, 0
        while done < n and days < cap:
            t = rng.choice(window)
            done += sum(1 for _ in range(t) if rng.random() < share)
            days += 1
        out.append(days)
    return out


def mc_hours(window, share, n, rng, cap=24 * 120):
    """As mc_throughput, an hour at a time; returns days."""
    out = []
    for _ in range(DRAWS):
        done, hours = 0, 0
        while done < n and hours < cap:
            t = rng.choice(window)
            done += sum(1 for _ in range(t) if rng.random() < share)
            hours += 1
        out.append(hours / 24)
    return out


def mc_velocity(rates, n, rng):
    """Days for n items at a past group's items-per-day, drawn per draw."""
    return [n / rng.choice(rates) for _ in range(DRAWS)]


def mc_steps(cycles, steps_of, rng):
    """Today's estimate.go: per draw, each step takes its longest child; the steps add up."""
    out = []
    for _ in range(DRAWS):
        per = defaultdict(float)
        for s in steps_of:
            per[s] = max(per[s], rng.choice(cycles))
        out.append(sum(per.values()) / DAY)
    return out


def score(rows, name):
    errs = [abs(r["p50"] - r["actual"]) for r in rows]
    ratio = [max(r["p50"], 0.25) / max(r["actual"], 0.25) for r in rows]
    ratio = [max(x, 1 / x) for x in ratio]
    held = sum(1 for r in rows if r["actual"] <= r["p85"])
    late = sum(1 for r in rows if r["actual"] > r["p50"])
    print(f"  {name:<34} n={len(rows):>3}  median |err| {statistics.median(errs):5.1f} d"
          f"  ×{statistics.median(ratio):4.2f}  P85 held {100 * held / len(rows):3.0f}%"
          f"  late vs P50 {100 * late / len(rows):3.0f}%")


def backtest(folder, groups, label, prior_shares, rng, at_half=False, prior_rates=None,
             prior_hourly=None, prior_growth=None):
    """groups: list of (start, items). Forecast at start (or when half landed) each method."""
    res = defaultdict(list)
    for start, items in groups:
        done = sorted(i["land"] for i in items if i["land"])
        if len(done) < 2:
            continue
        end = done[-1]
        at = start
        if at_half:
            at = done[len(done) // 2 - 1]
        remaining = [i for i in items if i["land"] and i["land"] > at]
        if not remaining:
            continue
        n = len(remaining)
        actual = (end - at) / DAY
        win = folder.window(at)
        if len(win) < 7 or sum(win) == 0:
            continue
        span_days = max(1, int(end // DAY) - int(at // DAY) + 1)
        span_total = sum(folder.daily.get(d, 0) for d in range(int(at // DAY), int(at // DAY) + span_days))
        oracle = min(1.0, n / max(span_total, 1))
        prior = statistics.median(prior_shares(at)) if prior_shares(at) else oracle
        known = [i for i in remaining if i["start"] <= at + DAY]
        cyc_all = folder.cycles_before(at)
        cyc14 = folder.cycles_before(at, WINDOW)
        steps = folder.steps(remaining)
        base = {"actual": actual}

        def add(name, draws):
            res[name].append(dict(base, p50=pct(draws, .5), p85=pct(draws, .85)))

        med = statistics.median(cyc_all) / DAY
        res["A. start + cycle median (one issue)"].append(dict(base, p50=med, p85=pct(cyc_all, .85) / DAY))
        add("B. today: steps of cycle draws", mc_steps(cyc_all, steps.values(), rng))
        add("C. throughput, share=oracle", mc_throughput(win, oracle, n, rng))
        add("D. throughput, share=prior", mc_throughput(win, prior, n, rng))
        if known:
            add("E. D, scope known at cut-off", mc_throughput(win, prior, len(known), rng))
        tp = mc_throughput(win, prior, n, rng)
        st = mc_steps(cyc14 or cyc_all, steps.values(), rng)
        add("F. max(D, steps of 14-day cycles)", [max(a, b) for a, b in zip(tp, st)])
        add("G. steps of 14-day cycle draws", st)
        hshare = prior_hourly(at) if prior_hourly else None
        if hshare:
            add("H. hourly throughput, share=prior", mc_hours(folder.hours(at), statistics.median(hshare), n, rng))
        horacle = min(1.0, n / max(folder.landed_between(at, end), 1))
        add("H0. hourly throughput, share=oracle", mc_hours(folder.hours(at), horacle, n, rng))
        if at_half:
            own = min(1.0, (len(done) - n) / max(folder.landed_between(start, at), 1))
            add("K. hourly throughput, own share so far", mc_hours(folder.hours(at), own, n, rng))
        growth = prior_growth(at) if prior_growth and not at_half else None
        if hshare and known and growth:
            g = statistics.median(growth)
            add("J. H on known scope x past growth", mc_hours(
                folder.hours(at), statistics.median(hshare), round(len(known) * g), rng))
        rates = prior_rates(at) if prior_rates else None
        if rates and len(rates) >= 5:
            add("I. past groups' items per day", mc_velocity(rates, n, rng))
        res["_meta"].append({"n": n, "known": len(known), "depth": 1 + max(steps.values()),
                             "oracle": oracle, "prior": prior, "actual": actual})
    print(f"\n{label}")
    for k in sorted(res):
        if k != "_meta":
            score(res[k], k)
    m = res["_meta"]
    print(f"  items median {statistics.median(x['n'] for x in m)}, known at cut-off "
          f"{100 * sum(x['known'] for x in m) / sum(x['n'] for x in m):.0f}%, steps median "
          f"{statistics.median(x['depth'] for x in m)}, share oracle median "
          f"{statistics.median(x['oracle'] for x in m):.2f} prior median "
          f"{statistics.median(x['prior'] for x in m):.2f}, actual median "
          f"{statistics.median(x['actual'] for x in m):.1f} d")
    return res


def main():
    global WINDOW
    folder = Folder(load(sys.argv[1]))

    def priors(groups):
        """For each closed group: when it landed, its share of the folder's throughput
        (by day and by hour) over its life, and its items per day."""
        out = []
        for start, items in groups:
            done = sorted(i["land"] for i in items if i["land"])
            if not done:
                continue
            d0, d1 = int(start // DAY), int(done[-1] // DAY)
            tot = sum(folder.daily.get(d, 0) for d in range(d0, d1 + 1))
            out.append({"end": done[-1], "day": len(done) / max(tot, 1),
                        "hour": min(1.0, len(done) / max(folder.landed_between(start, done[-1]), 1)),
                        "rate": len(done) / max((done[-1] - start) / DAY, 1 / 24),
                        "growth": len(done) / max(1, sum(1 for i in items if i["land"]
                                                         and i["start"] <= start + DAY))})
        return out

    def run(groups, label, at_half=False, quiet=False):
        pr = priors(groups)
        before = lambda key: lambda at: [x[key] for x in pr if x["end"] < at]  # noqa: E731
        if quiet:
            import contextlib
            import io
            with contextlib.redirect_stdout(io.StringIO()):
                return backtest(folder, groups, label, before("day"), random.Random(4523), at_half,
                                before("rate"), before("hour"), before("growth"))
        return backtest(folder, groups, label, before("day"), random.Random(4523), at_half,
                        before("rate"), before("hour"), before("growth"))

    # Epics: every closed epic with children; forecast when it was filed.
    epics = [e for e in folder.issues if e["completed"] and folder.kids.get(e["number"])]
    egroups = [(e["start"], folder.kids[e["number"]]) for e in epics]
    run(egroups, "EPICS, forecast when the epic was filed")
    run(egroups, "EPICS, re-forecast when half the children had landed", True)
    big = [g for g in egroups if len(g[1]) >= 8]
    run(big, "EPICS with 8 or more children, at filing")

    # Milestones: closed ones, from their first issue's filing.
    ms = defaultdict(list)
    for i in folder.issues:
        if i["milestone"] and "epic" not in i["labels"]:
            ms[i["milestone"]].append(i)
    mgroups = [(min(i["start"] for i in items), items) for items in ms.values()
               if all(i["closedAt"] for i in items)]
    run(mgroups, "MILESTONES, forecast at the first issue")
    run(mgroups, "MILESTONES, re-forecast at half", True)

    print("\nWINDOW (epics at filing)")
    for w in (7, 14, 28):
        WINDOW = w
        r = run(egroups, "", quiet=True)
        for k in ("G. steps of 14-day cycle draws", "H. hourly throughput, share=prior"):
            score(r[k], f"{k[:2]} window {w} days")
    WINDOW = 14
    win = list(folder.daily.values())
    print(f"\nthroughput per day: median {statistics.median(win)}, "
          f"P10 {pct(win, .1)}, P90 {pct(win, .9)}, days {len(win)}")


if __name__ == "__main__":
    main()
