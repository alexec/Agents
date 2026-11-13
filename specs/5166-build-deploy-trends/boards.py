#!/usr/bin/env python3
"""Draws the boards of spec 5166, Build trends, as SVG, from data.json (derive.py).

Paper palette, light mode, as specs/4595-velocity/boards.py. The figures are real: alexec/Agents'
ci and release runs of the last 90 days, from the GitHub API. The sidebar rows, the Mac's PR page
around its Pipeline line and the empty states' repositories are scratch. The orange numbers are
the notes in spec.md.

python3 fetch.py && python3 derive.py && python3 boards.py
"""
import datetime
import json
import math
import statistics
import zoneinfo
from pathlib import Path

HERE = Path(__file__).parent
TZ = zoneinfo.ZoneInfo("America/Los_Angeles")
INK, SEC, TER = "#1C1D20", "#5B616B", "#8A9099"
GROUND, RAISED, RULE, FILL = "#F7F8F9", "#FFFFFF", "#DDE1E6", "#EEF0F3"
ACCENT, NOTE, FAIL, GREEN = "#0A6CDB", "#B35900", "#B42318", "#1A7F37"
QUEUE = "#9AA1AB"
TURN = "#D3D7DD"  # waiting its turn: the run before it on main still going (ci.yml's concurrency group)
FONT = "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"
DEFS = ('<defs><filter id="shadow" x="-5%" y="-5%" width="110%" height="115%">'
        '<feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity="0.18"/></filter>'
        # Queue time is hatched grey: waiting, not work.
        f'<pattern id="queue" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
        f'<rect width="6" height="6" fill="#E3E6EA"/><rect width="2.4" height="6" fill="{QUEUE}"/></pattern></defs>')

DATA = json.loads((HERE / "data.json").read_text())
TODAY = datetime.date.fromisoformat(DATA["fetched"][:10]) - datetime.timedelta(days=1)  # the last full day


def t(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def local(s):
    return t(s).astimezone(TZ)


def mins(sec):
    if sec is None:
        return "–"
    if sec < 90:
        return f"{sec:.0f} s"
    if sec >= 3600:
        return f"{int(sec // 3600)} h {int(sec % 3600 // 60)} min"
    return f"{sec / 60:.1f} min"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Board:
    def __init__(self, w, h, title, sub):
        self.w, self.h = w, h
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">',
                      DEFS, f'<rect width="{w}" height="{h}" fill="#E7EAEE"/>']
        self.text(24, 34, title, 15, INK, weight=600)
        for i, ln in enumerate(sub.split("\n")):
            self.text(24, 54 + i * 16, ln, 12, SEC)

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size, color=INK, weight=None, anchor=None, mono=False, italic=False, strike=False):
        a = []
        if weight: a.append(f'font-weight="{weight}"')
        if anchor: a.append(f'text-anchor="{anchor}"')
        if mono: a.append('font-variant-numeric="tabular-nums"')
        if italic: a.append('font-style="italic"')
        if strike: a.append('text-decoration="line-through"')
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{color}" {" ".join(a)}>{esc(s)}</text>')

    def rect(self, x, y, w, h, fill=RAISED, stroke=None, rx=0, opacity=None, sw=1, dash=None):
        a = f'rx="{rx}" fill="{fill}"'
        if stroke: a += f' stroke="{stroke}" stroke-width="{sw}"'
        if dash: a += f' stroke-dasharray="{dash}"'
        if opacity is not None: a += f' opacity="{opacity}"'
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 0):.1f}" height="{max(h, 0):.1f}" {a}/>')

    def line(self, x1, y1, x2, y2, color=RULE, dash=None, sw=1):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="M{x1:.1f} {y1:.1f}L{x2:.1f} {y2:.1f}" stroke="{color}" stroke-width="{sw}"{d}/>')

    def path(self, d, color, sw=1.5, dash=None):
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}"{da}/>')

    def circle(self, cx, cy, r, fill, stroke=None, opacity=None):
        s = f' stroke="{stroke}"' if stroke else ""
        o = f' opacity="{opacity}"' if opacity is not None else ""
        self.add(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r}" fill="{fill}"{s}{o}/>')

    def tri(self, cx, cy, up, color):
        d = f"M{cx - 5:.1f} {cy + 4:.1f}L{cx + 5:.1f} {cy + 4:.1f}L{cx:.1f} {cy - 5:.1f}Z" if up else \
            f"M{cx - 5:.1f} {cy - 4:.1f}L{cx + 5:.1f} {cy - 4:.1f}L{cx:.1f} {cy + 5:.1f}Z"
        self.add(f'<path d="{d}" fill="{color}"/>')

    def note(self, n, x, y):
        self.circle(x, y, 9, NOTE)
        self.text(x, y + 4, str(n), 11, "#FFF", weight=700, anchor="middle")

    def caption(self, x, y, s):
        for i, ln in enumerate(s.split("\n")):
            self.text(x, y + i * 15, ln, 12, SEC, weight=600)

    def select(self, x, y, label, value, w=150):
        self.text(x, y + 16, label, 12, SEC)
        lx = x + len(label) * 6.6 + 8
        self.rect(lx, y, w, 24, RAISED, stroke="#C7CCD3", rx=6)
        self.text(lx + 10, y + 17, value, 13, INK)
        self.text(lx + w - 14, y + 16, "⌄", 13, SEC)
        return lx + w + 18

    def segmented(self, x, y, items, on, w=64, h=22):
        self.rect(x, y, w * len(items) + 4, h + 4, FILL, rx=7)
        for i, s in enumerate(items):
            if s == on:
                self.rect(x + 2 + i * w, y + 2, w, h, RAISED, stroke="#CCD1D7", rx=6)
            self.text(x + 2 + i * w + w / 2, y + 2 + h / 2 + 4, s, 12, INK if s == on else SEC, weight=600 if s == on else None, anchor="middle")

    def tile(self, x, y, w, label, figure, when, delta=None, delta_bad=None):
        self.rect(x, y, w, 92, RAISED, stroke=RULE, rx=8)
        self.text(x + 14, y + 22, label, 11, SEC, weight=600)
        self.text(x + 14, y + 52, figure, 24, INK, weight=600, mono=True)
        self.text(x + 14, y + 74, when, 12, SEC)
        if delta:
            self.text(x + w - 14, y + 52, delta, 12, FAIL if delta_bad else GREEN, weight=600, anchor="end")

    def window(self, x, y, w, h):
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{GROUND}"/></g>')
        for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
            self.circle(x + 20 + i * 20, y + 20, 6, c)
        return y + 40

    def web_frame(self, x, y, w, h, nav=True):
        """The web page's frame: the bar of sections (#2141) and Reports' pages on the left."""
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{GROUND}"/></g>')
        self.rect(x, y, w, 44, RAISED, rx=8)
        self.line(x, y + 44, x + w, y + 44)
        sx = x + 24
        for s in ["Overview", "Agents", "Work", "Docs", "Messages", "Machines", "Workflows", "Reports", "Requests", "People", "Status", "Settings"]:
            on = s == "Reports"
            self.text(sx, y + 28, s, 13, INK if on else SEC, weight=600 if on else None)
            if on:
                self.rect(sx - 2, y + 41, len(s) * 7.2 + 4, 2, ACCENT)
            sx += len(s) * 7.2 + 26
        if not nav:
            return x + 24
        lx, ly = x + 24, y + 70
        for head, pages in [("Reports", ["Spend", "Outcomes", "Time", "Runtimes", "Adoption", "Workflows", "Planning", "  Builds"]),
                            ("Yours", ["Multiplier", "Usage"]), ("Saved", ["Saved Views"])]:
            self.text(lx, ly + 12, head, 11, SEC, weight=600)
            ly += 22
            for p in pages:
                on = p.strip() == "Builds"
                if on:
                    self.rect(lx - 8, ly - 2, 176, 26, FILL, rx=6)
                self.text(lx + (12 if p.startswith("  ") else 0), ly + 14, p.strip(), 13, INK, weight=600 if on else None)
                ly += 24
            ly += 8
        self.line(x + 210, y + 44, x + 210, y + h)
        return x + 240

    def write(self, name):
        self.add("</svg>")
        (HERE / name).write_text("\n".join(self.parts))
        print(name)


# --- what the boards draw ------------------------------------------------------------------
TREND = DATA["trend"]["main"]
DAYS = [TODAY - datetime.timedelta(days=i) for i in range(29, -1, -1)]
RUNS = DATA["mainRuns"]


def runs_between(a, b):
    return [r for r in RUNS if a <= local(r["created"]).date() <= b]


def med(rows, k):
    v = [r[k] for r in rows]
    return statistics.median(v) if v else None


def p90(rows, k):
    v = sorted(r[k] for r in rows)
    return v[int(0.9 * (len(v) - 1))] if v else None


LAST7 = runs_between(TODAY - datetime.timedelta(days=6), TODAY)
PREV7 = runs_between(TODAY - datetime.timedelta(days=13), TODAY - datetime.timedelta(days=7))
TAGS30 = [g for g in DATA["tags"] if DAYS[0] <= datetime.datetime.fromisoformat(g["at"]).astimezone(TZ).date() <= TODAY]
POINTS30 = [p for p in DATA["changePoints"] if local(p["at"]).date() >= DAYS[0]]
PICK = next(p for p in DATA["changePoints"] if p["job"] == "go-darwin" and p["at"].startswith("2026-11-09"))


def pctline(a, b):
    if not a or not b:
        return None
    return f"{(a / b - 1) * 100:+.0f} % on the 7 days before"


# --- board 1: the trend ----------------------------------------------------------------------
def trend():
    b = Board(1240, 900, "1 · The trend: Reports ▸ Planning ▸ Builds, the last 30 days, all jobs, main",
              f"Real data: alexec/Agents, {len(RUNS):,} green ci runs on main (first attempts) and its release tags, from the GitHub API on "
              f"{DATA['fetched'][:10]}. Run time is blue; waiting for a runner is hatched; waiting its turn is light grey.")
    x, y, w, h = 24, 92, 1192, 740
    px = b.web_frame(x, y, w, h)
    pw = x + w - px - 24
    b.text(px, y + 74, "Planning ›", 12, ACCENT)
    b.text(px, y + 100, "Builds", 22, INK, weight=700)
    fy = y + 118
    nx = b.select(px, fy, "Repository", "alexec/Agents", 130)
    nx = b.select(nx, fy, "Range", "The last 30 days", 130)
    nx = b.select(nx, fy, "Workflow", "ci", 70)
    nx = b.select(nx, fy, "Job", "All jobs", 90)
    nx = b.select(nx, fy, "Branch", "main", 76)
    b.note(1, nx - 4, fy + 12)
    # The headline tiles: the last 7 days against the 7 before.
    ty, tw = y + 158, (pw - 36) / 4
    w7, q7, r7 = med(LAST7, "wall"), med(LAST7, "queue"), med(LAST7, "run")
    b.tile(px, ty, tw, "TIME TO GREEN · MEDIAN", mins(w7), f"P90 {mins(p90(LAST7, 'wall'))} · {len(LAST7)} runs, last 7 days",
           f"{(w7 / med(PREV7, 'wall') - 1) * 100:+.0f} %", w7 > med(PREV7, "wall"))
    b.tile(px + tw + 12, ty, tw, "RUN TIME · MEDIAN", mins(r7), "Jobs running. Points to a commit.",
           f"{(r7 / med(PREV7, 'run') - 1) * 100:+.0f} %", r7 > med(PREV7, "run"))
    # A small base makes a silly percentage (7 s to 79 s is +1,000 %): queue time says seconds.
    t7 = med(LAST7, "pending")
    b.tile(px + 2 * (tw + 12), ty, tw, "QUEUE TIME · MEDIAN", mins(q7), f"{mins(t7)} its turn, {mins(max(q7 - t7, 0))} a runner. Load.",
           f"{q7 - med(PREV7, 'queue'):+.0f} s", q7 > med(PREV7, "queue"))
    b.tile(px + 3 * (tw + 12), ty, tw, "GREEN RUNS ON MAIN", f"{len(LAST7)}",
           f"Last 7 days · {DATA['reruns']['main']} re-runs in 90 days")
    b.note(2, px + tw - 8, ty + 10)
    b.note(3, px + 2 * (tw + 12) + tw - 8, ty + 10)
    # Chart A: time to green by day, stacked: run (blue), queue (hatched); P90 as a line of dots.
    cx, cy, cw, ch = px, ty + 140, pw - 250, 230
    b.text(cx, cy - 14, "Time to green on main, by day", 13, INK, weight=600)
    b.segmented(cx + cw - 190, cy - 32, ["Median", "P90"], "Median", w=70)
    top = 30 * 60
    yv = lambda v: cy + ch - min(v, top) / top * (ch - 6)
    for f in (0.5, 1):
        b.line(cx, yv(top * f), cx + cw - 40, yv(top * f))
        b.text(cx + cw - 34, yv(top * f) + 4, f"{top * f / 60:.0f} min", 11, TER)
    b.line(cx, cy + ch, cx + cw - 40, cy + ch, "#C7CCD3")
    inner = cw - 40
    step = inner / len(DAYS)
    xd = lambda d: cx + (d - DAYS[0]).days * step + step / 2
    p90pts = []
    for i, d in enumerate(DAYS):
        k = d.isoformat()
        if k not in TREND["run"]:
            continue
        r, q = TREND["run"][k]["median"], TREND["queue"][k]["median"]
        turn = min(TREND["pending"][k]["median"], q)
        bx = cx + i * step + step * 0.18
        bw = step * 0.64
        b.rect(bx, yv(r), bw, cy + ch - yv(r), ACCENT, rx=1.5)
        b.rect(bx, yv(r + q - turn), bw, yv(r) - yv(r + q - turn), "url(#queue)")
        b.rect(bx, yv(r + q), bw, yv(r + q - turn) - yv(r + q), TURN)
        p90pts.append((xd(d), yv(TREND["wall"][k]["p90"])))
        if i % 5 == 4 or i == len(DAYS) - 1:
            b.text(xd(d), cy + ch + 15, f"{d.day} {d:%b}", 11, TER, anchor="middle")
    b.path("M" + "L".join(f"{a:.1f} {c:.1f}" for a, c in p90pts), SEC, 1, dash="2 3")
    for a, c in p90pts:
        b.circle(a, c, 2, SEC)
    b.text(p90pts[-1][0] - 4, p90pts[-1][1] - 8, "P90", 10, SEC, anchor="end", weight=600)
    b.note(4, p90pts[-1][0] + 14, p90pts[-1][1] - 10)
    # Releases: a dashed line through both charts at each tag.
    last_label = -1e9
    for g in TAGS30:
        at = datetime.datetime.fromisoformat(g["at"]).astimezone(TZ)
        gx = cx + ((at.date() - DAYS[0]).days + at.hour / 24) * step
        minor = g["tag"].endswith(".0")
        b.add(f'<g opacity="{1 if minor else 0.35}">')
        b.line(gx, cy - 2, gx, cy + ch, "#7E57C2", dash="3 3")
        b.add("</g>")
        if minor and gx - last_label > 46:
            b.text(gx + 3, cy + 6, g["tag"], 9, "#7E57C2", weight=600)
            last_label = gx
    b.note(5, cx + 10, cy + 2)
    # The changes found, one job at a time: a lane under the chart.
    ly = cy + ch + 50
    b.text(cx, ly - 12, "Changes found, each job's own run time", 11, SEC, weight=600)
    b.line(cx, ly, cx + inner, ly, RULE)
    used = []
    for p in POINTS30:
        at = local(p["at"])
        px_ = cx + ((at.date() - DAYS[0]).days + at.hour / 24) * step
        up = p["runAfter"] > p["runBefore"]
        row = 0
        while any(abs(px_ - u) < 60 and r == row for u, r in used):
            row += 1
        used.append((px_, row))
        yy = ly + row * 26
        picked = p is PICK
        if picked:
            b.rect(px_ - 34, yy - 10, 86, 22, "#FDECEA", stroke=FAIL, rx=6)
        b.tri(px_ - 24, yy, up, FAIL if up else GREEN)
        b.text(px_ - 16, yy + 4, f"{p['job']} {(p['runAfter'] / p['runBefore'] - 1) * 100:+.0f}%", 10, INK, weight=600 if picked else None)
    b.note(6, cx + 240, ly - 16)
    b.text(cx, ly + 3 * 26 + 6, "A dashed purple line is a release tag: a marker only. Deploys are out of this epic (Alex, 2026-11-13).", 11, SEC)
    # The right column: what the two colours mean, and the changes as a list.
    rx = cx + cw + 14
    rw = pw - cw - 14
    b.rect(rx, cy - 30, rw, 262, RAISED, stroke=RULE, rx=8)
    b.rect(rx + 14, cy - 12, 14, 14, ACCENT, rx=2)
    b.text(rx + 36, cy, "Run time", 13, INK, weight=600)
    for i, ln in enumerate(["The jobs ran. A rise that stays", "points to a commit: the culprit", "finder looks here, on main."]):
        b.text(rx + 14, cy + 20 + i * 15, ln, 12, SEC)
    b.rect(rx + 14, cy + 70, 14, 14, "url(#queue)", rx=2)
    b.text(rx + 36, cy + 82, "Waiting for a runner", 13, INK, weight=600)
    for i, ln in enumerate(["A job waited for a machine:", "xcode-27 and macos-latest are", "few. Load, never a culprit."]):
        b.text(rx + 14, cy + 102 + i * 15, ln, 12, SEC)
    b.rect(rx + 14, cy + 152, 14, 14, TURN, rx=2)
    b.text(rx + 36, cy + 164, "Waiting its turn", 13, INK, weight=600)
    for i, ln in enumerate(["The run before it on main was", "still going. Load from merges,", "never a culprit."]):
        b.text(rx + 14, cy + 184 + i * 15, ln, 12, SEC)
    b.note(7, rx + rw - 12, cy - 18)
    ly2 = cy + 256
    b.text(rx, ly2, "Changes in this range", 13, INK, weight=600)
    for i, p in enumerate(sorted(POINTS30, key=lambda p: p["at"], reverse=True)[:4]):
        up = p["runAfter"] > p["runBefore"]
        yy = ly2 + 24 + i * 40
        if p is PICK:
            b.rect(rx - 6, yy - 14, rw + 6, 38, "#FDECEA", rx=6)
        b.tri(rx + 6, yy - 4, up, FAIL if up else GREEN)
        b.text(rx + 18, yy, f"{p['job']} {'slower' if up else 'faster'}, {local(p['at']):%-d %b}", 12, INK, weight=600)
        b.text(rx + 18, yy + 16, f"{mins(p['runBefore'])} → {mins(p['runAfter'])} · {len(p['commits'])} commit{'s' if len(p['commits']) != 1 else ''} ›", 11, SEC)
    b.note(8, rx + rw - 12, ly2 - 4)
    b.caption(x, y + h + 22, "A change picked, in the lane or the list, opens board 2. The Job select draws one job's queue and run; with All jobs the bars are whole runs,\n"
                             "and the changes are still each job's own: a whole run's time mixes in which jobs ran (ci.yml's select job).")
    b.write("board-1-trend.svg")


# --- board 2: a change picked ----------------------------------------------------------------
def change():
    p = PICK
    b = Board(1240, 820, f"2 · A change picked: {p['job']} on main, slower from {local(p['at']):%-d %B %H:%M}",
              f"Real data: the {len(p['series'])} green main runs that ran {p['job']} around the change, and every commit on main between the last fast run and the first slow one.")
    x, y, w, h = 24, 76, 1192, 700
    px = b.web_frame(x, y, w, h, nav=False)
    b.text(px, y + 74, "Planning › Builds ›", 12, ACCENT)
    up = (p["runAfter"] / p["runBefore"] - 1) * 100
    b.text(px, y + 102, f"{p['job']} slower from {local(p['at']):%-d %B}: {mins(p['runBefore'])} → {mins(p['runAfter'])} ({up:+.0f} %)", 22, INK, weight=700)
    b.text(px, y + 124, f"Run time on main, the median of the 25 runs before and after. Runner: {p['runner']}. "
                        f"Queue time: {mins(p['queueBefore'])} before, {mins(p['queueAfter'])} after, so not load: look at the commits.", 13, SEC)
    b.note(1, px + 760, y + 96)
    # The event the change made (ci.slowed), so a workflow can start on it.
    b.rect(px + 800, y + 84, 230, 24, "#FFF4E5", stroke=NOTE, rx=12)
    b.text(px + 815, y + 101, f"ci.slowed sent {local(p['at']):%-d %b %H:%M}", 12, NOTE, weight=600, mono=True)
    b.note(6, px + 1044, y + 96)
    # Left: each run's job time, before and after, with the two medians as steps.
    cx, cy, cw, ch = px, y + 170, 560, 250
    b.text(cx, cy - 12, f"{p['job']}: each green run on main", 13, INK, weight=600)
    s = p["series"]
    top = 10 * 60
    t0, t1 = t(s[0]["created"]), t(s[-1]["created"])
    xv = lambda c: cx + (t(c) - t0).total_seconds() / (t1 - t0).total_seconds() * (cw - 50)
    yv = lambda v: cy + ch - min(v, top) / top * (ch - 6)
    for f in (0.5, 1):
        b.line(cx, yv(top * f), cx + cw - 50, yv(top * f))
        b.text(cx + cw - 44, yv(top * f) + 4, f"{top * f / 60:.0f} min", 11, TER)
    b.line(cx, cy + ch, cx + cw - 50, cy + ch, "#C7CCD3")
    ax = xv(p["at"])
    b.rect(xv(p["before"]["created"]), cy, ax - xv(p["before"]["created"]) + 2, ch, "#FDECEA")
    for r in s:
        after = r["created"] >= p["at"]
        b.circle(xv(r["created"]), yv(r["run"]), 3, ACCENT, opacity=1 if after else 0.55)
        b.rect(xv(r["created"]) - 1.5, yv(r["queue"]) - 1.5, 3, 3, QUEUE)
    b.path(f"M{cx:.1f} {yv(p['runBefore']):.1f}L{ax:.1f} {yv(p['runBefore']):.1f}L{ax:.1f} {yv(p['runAfter']):.1f}L{cx + cw - 50:.1f} {yv(p['runAfter']):.1f}", FAIL, 2)
    b.text(cx + 6, yv(p["runBefore"]) - 6, f"median {mins(p['runBefore'])}", 11, FAIL)
    b.text(cx + cw - 56, yv(p["runAfter"]) - 6, f"median {mins(p['runAfter'])}", 11, FAIL, anchor="end")
    b.text(cx + 6, cy + ch - 8, "queue, each run (grey): flat", 11, SEC)
    for d in (t0, t0 + (t1 - t0) / 2, t1):
        b.text(xv(d.isoformat()), cy + ch + 15, f"{d.astimezone(TZ):%-d %b}", 11, TER, anchor="middle")
    b.note(2, ax + 10, cy + 10)
    # Right: the commits between the last fast run and the first slow one.
    lx, lw = px + 600, x + w - px - 600 - 24
    b.text(lx, cy - 12, "Between the last fast run and the first slow one", 13, INK, weight=600)
    rows = [{"sha": p["before"]["sha"], "title": p["before"]["title"], "ran": True, "jobRun": None, "conclusion": "success", "kind": "before"}] + p["commits"]
    first_slow = next(c for c in p["commits"] if c["ran"] and c["jobRun"])
    for i, c in enumerate(rows):
        yy = cy + 16 + i * 44
        kind = c.get("kind")
        culprit = c is first_slow
        if culprit:
            b.rect(lx - 6, yy - 16, lw + 6, 42, "#FDECEA", stroke=FAIL, rx=6)
        dim = not c["ran"] and kind is None
        b.text(lx, yy, c["sha"][:7], 12, TER if dim else INK, mono=True)
        title = c["title"] if len(c["title"]) < 62 else c["title"][:60] + "…"
        b.text(lx + 64, yy, title, 12, TER if dim else INK, weight=600 if culprit else None)
        if kind == "before":
            what = f"Last fast run: {p['job']} {mins(next(r['run'] for r in s if r['created'] == p['before']['created']))}"
        elif c["conclusion"] == "cancelled":
            what = "Its run was cancelled for a newer push; the next run tested it too"
        elif not c["ran"]:
            what = f"Did not run {p['job']}: its paths did not select it"
        else:
            what = f"{p['job']} {mins(c['jobRun'])}" + (" · the run failed" if c["conclusion"] == "failure" else "")
        b.text(lx + 64, yy + 16, what, 11, FAIL if culprit else SEC)
        if culprit:
            b.text(lx + lw - 8, yy + 16, "First slow run", 11, FAIL, weight=700, anchor="end")
    b.note(3, lx + lw - 6, cy - 16)
    b.note(4, lx - 16, cy + 16 + rows.index(first_slow) * 44)
    # Bottom: the run before and the run after, and the way to compare them.
    by = cy + ch + 60
    for i, (lab, r) in enumerate([("RUN BEFORE", p["before"]), ("RUN AFTER", p["after"])]):
        bx = px + i * 290
        b.rect(bx, by, 270, 110, RAISED, stroke=RULE, rx=8)
        b.text(bx + 14, by + 22, lab, 11, SEC, weight=600)
        b.text(bx + 14, by + 46, f"{r['sha'][:7]} · {local(r['created']):%-d %b %H:%M}", 14, INK, weight=600, mono=True)
        b.text(bx + 14, by + 68, f"The whole run: time to green {mins(r['wall'])}", 12, INK)
        b.text(bx + 14, by + 86, f"run {mins(r['run'])} · queue {mins(r['queue'])}", 12, SEC)
        b.text(bx + 14, by + 102, "Open the run on GitHub ↗", 11, ACCENT)
    b.rect(px + 590, by + 38, 210, 32, ACCENT, rx=7)
    b.text(px + 695, by + 59, "Compare the two runs", 13, "#FFF", weight=600, anchor="middle")
    b.note(5, px + 810, by + 54)
    b.text(px, by + 124, "The cards are the whole run: its queue is mostly waiting its turn on main, which the change finder never looks at.", 12, SEC)
    b.text(px, by + 140, "Only run time on main is searched for changes. A pull request's runs are its author's own: they are in the trend (Branch ▸ Pull requests),", 12, SEC)
    b.text(px, by + 156, "not in the culprit finder. A change in queue time is said under the chart as load, with no commits list.", 12, SEC)
    b.caption(x, y + h + 22, "Back (the browser's, or Planning › Builds) goes to the trend with the same filters. The address names the change: …/builds?job=go-darwin&change=2026-11-09T00:51Z.")
    b.write("board-2-change.svg")


# --- board 3: the drill-down -----------------------------------------------------------------
def gantt(b, x, y, w, rows, ghost=None, label_steps=True, row_h=34, top=None):
    """Jobs as rows: hatched from queued to started, solid with step ticks from started to ended;
    the run before's job as an outline under it. Returns the bottom."""
    end = top or max(r["ended"] for r in rows)
    scale = (w - 150) / end
    gx = x + 150
    for m in range(0, int(end // 60) + 1, 2 if end < 1200 else 10 if end < 4000 else 20):
        mx = gx + m * 60 * scale
        b.line(mx, y - 6, mx, y + len(rows) * row_h, FILL)
        b.text(mx, y - 10, f"{m} min", 10, TER, anchor="middle")
    ghosts = {g["name"]: g for g in ghost or []}
    first = min(r["queued"] for r in rows)
    b.text(x, y + 14, "the run", 12, SEC, weight=600)
    b.text(x, y + 27, "its turn on main", 10, TER)
    b.rect(gx, y + 4, first * scale, 14, TURN, rx=2)
    if first * scale > 70:
        b.text(gx + 4, y + 15, f"waiting its turn, {mins(first)}", 9, INK)
    y += row_h
    for i, r in enumerate(rows):
        yy = y + i * row_h
        b.text(x, yy + 14, r["name"], 12, INK, weight=600)
        b.text(x, yy + 27, r["runner"], 10, TER)
        b.rect(gx + r["queued"] * scale, yy + 4, (r["started"] - r["queued"]) * scale, 14, "url(#queue)", rx=2)
        b.rect(gx + r["started"] * scale, yy + 4, (r["ended"] - r["started"]) * scale, 14, ACCENT if r["conclusion"] == "success" else FAIL, rx=2)
        for s in r["steps"]:
            sx = gx + s["start"] * scale
            b.line(sx, yy + 4, sx, yy + 18, "#FFFFFF")
            if label_steps and (s["end"] - s["start"]) * scale > 60:
                b.text(sx + 4, yy + 15, s["name"][:14], 9, "#FFF")
        g = ghosts.get(r["name"])
        if g:
            b.rect(gx + g["started"] * scale, yy + 21, (g["ended"] - g["started"]) * scale, 6, "none", stroke=SEC, rx=1, dash="2 2")
    return y + len(rows) * row_h


def drill():
    p = PICK
    before, after = p["ganttBefore"], p["ganttAfter"]
    b = Board(1240, 1000, f"3 · The drill-down: run {p['after']['sha'][:7]}, its jobs and steps, against run {p['before']['sha'][:7]}",
              "Real data: the GitHub API's jobs and steps for the two runs either side of board 2's change, and for the main run of the 90 days whose job waited longest for a runner.")
    x, y, w, h = 24, 76, 1192, 880
    px = b.web_frame(x, y, w, h, nav=False)
    pw = x + w - px - 24
    b.text(px, y + 74, f"Planning › Builds › {p['job']} slower from {local(p['at']):%-d %B} ›", 12, ACCENT)
    title = p["after"]["title"]
    b.text(px, y + 100, f"{p['after']['sha'][:7]} · {title[:70]}{'…' if len(title) > 70 else ''}", 20, INK, weight=700)
    b.text(px, y + 122, f"ci on main, {local(p['after']['created']):%-d %B %H:%M} · time to green {mins(p['after']['wall'])} (run {mins(p['after']['run'])}, queue {mins(p['after']['queue'])}) · "
                        f"against {p['before']['sha'][:7]}, {mins(p['before']['wall'])}", 13, SEC)
    b.text(px + pw - 4, y + 100, "Open on GitHub ↗", 12, ACCENT, anchor="end")
    # The Gantt.
    gy = y + 176
    b.text(px, gy - 26, "Jobs and steps", 13, INK, weight=600)
    b.rect(px + 160, gy - 37, 12, 10, "url(#queue)")
    b.text(px + 176, gy - 28, "waiting for a runner", 11, SEC)
    b.rect(px + 300, gy - 37, 12, 10, ACCENT)
    b.text(px + 316, gy - 28, "running; a white tick starts a step", 11, SEC)
    b.rect(px + 520, gy - 34, 22, 5, "none", stroke=SEC, dash="2 2")
    b.text(px + 548, gy - 28, "the run before, the same job", 11, SEC)
    b.rect(px + 730, gy - 37, 12, 10, TURN)
    b.text(px + 746, gy - 28, "waiting its turn", 11, SEC)
    end = gantt(b, px, gy, pw, after, ghost=before, top=max(max(r["ended"] for r in after), max(r["ended"] for r in before)))
    b.note(1, px + pw - 10, gy - 30)
    gd = next(r for r in after if r["name"] == p["job"])
    b.note(2, px + 150 + gd["ended"] * (pw - 150) / max(max(r["ended"] for r in after), max(r["ended"] for r in before)) + 14,
           gy + (after.index(gd) + 1) * 34 + 11)
    # The step diff.
    dy = end + 40
    b.text(px, dy, f"Steps that changed most, against the run before: {p['job']} first", 13, INK, weight=600)
    bb = {(r["name"], s["name"]): s["end"] - s["start"] for r in before for s in r["steps"]}
    diffs = []
    for r in after:
        for s in r["steps"]:
            k = (r["name"], s["name"])
            if k in bb:
                diffs.append((r["name"], s["name"], bb[k], s["end"] - s["start"]))
    # The picked job's steps first, then the rest: the change came from board 2's job.
    diffs.sort(key=lambda d: (d[0] != p["job"], -abs(d[3] - d[2])))
    cols = [px, px + 110, px + 420, px + 510, px + 600]
    hy = dy + 26
    for c, s in zip(cols, ["Job", "Step", "Before", "After", "Change"]):
        b.text(c, hy, s, 11, SEC, weight=600)
    b.line(px, hy + 8, px + 760, hy + 8)
    for i, (job, step, a, z) in enumerate(diffs[:7]):
        yy = hy + 28 + i * 24
        slower = z > a
        b.text(cols[0], yy, job, 12, INK, weight=600 if job == p["job"] else None)
        b.text(cols[1], yy, step[:40], 12, INK)
        b.text(cols[2], yy, mins(a), 12, SEC, mono=True)
        b.text(cols[3], yy, mins(z), 12, INK, mono=True)
        b.text(cols[4], yy, f"{z - a:+.0f} s", 12, FAIL if slower else GREEN, weight=600, mono=True)
        bar = min(abs(z - a), 200) * 0.6
        b.rect(cols[4] + 60, yy - 9, bar, 10, FAIL if slower else GREEN, opacity=0.6, rx=2)
    b.note(3, px + 400, dy - 4)
    b.text(px, hy + 28 + 7 * 24, "Each step's time is GitHub's own. A job that ran in only one of the two runs is listed under the table, not compared.", 11, SEC)
    # The run that waited longest: queue as context.
    q = DATA["mostQueued"]
    qx, qw = px + 800, pw - 800
    b.rect(qx, dy - 24, qw, 286, RAISED, stroke=RULE, rx=8)
    b.text(qx + 14, dy, "Queue time is load, not code", 13, INK, weight=600)
    waited = max(DATA["mostQueuedGantt"], key=lambda r: r["started"] - r["queued"])
    for i, ln in enumerate([f"On {local(q['created']):%-d %B}, {waited['name']} waited {mins(waited['started'] - waited['queued'])}",
                            f"for an {waited['runner']} runner, then ran",
                            f"{mins(waited['ended'] - waited['started'])}. Nothing in its commit",
                            "could make it wait (#594)."]):
        b.text(qx + 14, dy + 22 + i * 16, ln, 12, SEC)
    mini = [r for r in DATA["mostQueuedGantt"]]
    end2 = max(r["ended"] for r in mini)
    sc = (qw - 100) / end2
    for i, r in enumerate(mini[:8]):
        yy = dy + 98 + i * 18
        b.text(qx + 14, yy + 9, r["name"][:10], 10, INK)
        b.rect(qx + 86 + r["queued"] * sc, yy, (r["started"] - r["queued"]) * sc, 10, "url(#queue)", rx=1)
        b.rect(qx + 86 + r["started"] * sc, yy, max((r["ended"] - r["started"]) * sc, 1.5), 10, ACCENT, rx=1)
    b.text(qx + 14, dy + 254, f"0 → {mins(end2)}. The trend shows its wait;", 11, SEC)
    b.text(qx + 14, dy + 268, "the change finder never looks at it.", 11, SEC)
    b.note(4, qx + qw - 12, dy - 12)
    b.caption(x, y + h + 22, "A pull request's run opens here too (from its PR, or a bar of Branch ▸ Pull requests), against the run before on its own branch, or on main when it has none.")
    b.write("board-3-drill.svg")


# --- board 4: empty, and no CI data ----------------------------------------------------------
def empty():
    b = Board(1240, 560, "4 · Empty states, a forge with no CI data, and the way in from Planning",
              "The repositories on these cards are scratch. The Delivery row's first card is today's (#4555); the link under it is new.")
    y = 90
    cards = [
        ("Loading", ["Loading…"], None),
        ("No runs in the range", ["No ci runs on main finished in", "the last 7 days.", "", "Try a longer range, or Branch ▸", "Pull requests."], None),
        ("No CI data from the forge", ["alexec/agents-walk has no GitHub", "Actions runs. Builds", "come from the forge's CI runs."], None),
        ("A forge Agents does not read CI from", ["Forgejo: Agents does not read", "its CI runs yet, so there is", "nothing to draw for", "codeberg.org/scratch/app."], None),
    ]
    cw = (1240 - 48 - 3 * 14) / 4
    for i, (head, lines, _) in enumerate(cards):
        cx = 24 + i * (cw + 14)
        b.rect(cx, y, cw, 210, RAISED, stroke="#C7CCD3", rx=8)
        b.text(cx + 12, y + 22, head, 11, SEC, weight=600)
        if i in (1, 2, 3):
            b.text(cx + 12, y + 50, "TIME TO GREEN · MEDIAN", 10, SEC, weight=600)
            b.text(cx + 12, y + 76, "–", 22, INK, weight=600)
        for j, ln in enumerate(lines):
            b.text(cx + 12, y + (50 if i == 0 else 104) + j * 16, ln, 12, SEC)
        b.note(i + 1, cx + cw - 12, y + 12)
    # The way in from Planning: the Delivery row's CI card and a link.
    wy = 340
    b.text(24, wy, "Reports ▸ Planning, the Delivery row (#4555), with the way in", 13, INK, weight=600)
    b.rect(24, wy + 14, 760, 150, GROUND, stroke=RULE, rx=8)
    b.text(40, wy + 40, "Delivery", 15, INK, weight=700)
    names = [("CI TIME TO GREEN", mins(med(LAST7, "wall"))), ("DEPLOYMENT FREQUENCY", f"{len(TAGS30) / 30 * 7:.1f} a week"), ("LEAD TIME", "…"), ("CHANGE FAILURE RATE", "…")]
    for i, (n, v) in enumerate(names):
        cx = 40 + i * 182
        b.rect(cx, wy + 54, 170, 76, RAISED, stroke=RULE, rx=6)
        b.text(cx + 10, wy + 72, n, 10, SEC, weight=600)
        b.text(cx + 10, wy + 98, v, 18, INK, weight=600)
        if i == 0:
            b.text(cx + 10, wy + 120, "Build trends ›", 12, ACCENT, weight=600)
    b.note(5, 40 + 170 - 8, wy + 116)
    b.text(40, wy + 152, "The link names the repository and the range: #/reports/value/builds?repo=github:alexec/agents&range=month.", 11, SEC)
    b.text(820, wy + 40, "With no CI data in any repository of the scope,", 12, SEC)
    b.text(820, wy + 56, "the card says so and the link still opens the page", 12, SEC)
    b.text(820, wy + 72, "(card 3 says why there is nothing).", 12, SEC)
    b.caption(24, 540, "Loading is the Reports pages' own Loading…; an error is their hint line. No toast, no modal.")
    b.write("board-4-empty.svg")


# --- board 5: the Mac link -------------------------------------------------------------------
def mac():
    b = Board(1240, 680, "5 · The Mac link: Build trends on the Pipeline line of a pull request's or release's Work page (Web + Mac link, #4937)",
              "The PR page around the line is scratch; the line is the Pipeline line of #3588. The link draws nothing on the Mac but itself.")
    x, y, w, h = 24, 80, 700, 520
    top = b.window(x, y, w, h)
    b.text(x + 110, y + 25, "Work ▸ Pull requests", 13, SEC)
    b.text(x + 28, top + 30, "An agent's gh and git fall back to the person's own login when", 17, INK, weight=700)
    b.text(x + 28, top + 52, "GitHub refuses the App (#4154)", 17, INK, weight=700)
    b.rect(x + 28, top + 68, 58, 20, "#E9E1F7", rx=10)
    b.text(x + 57, top + 82, "Merged", 11, "#5B3FA0", weight=600, anchor="middle")
    b.text(x + 96, top + 82, "alexec/Agents · agents/4077 → main · $3.12", 12, SEC)
    # The Pipeline line.
    ly = top + 120
    b.line(x + 28, ly - 16, x + w - 28, ly - 16, RULE)
    # #4154 merged after v0.18.0 was tagged and no tag has carried it yet, so its line has no release.
    words = [("Fixes #4077", ACCENT), ("·", TER), ("CI run", ACCENT)]
    lx = x + 28
    for s, c in words:
        b.text(lx, ly, s, 13, c)
        lx += len(s) * 7.1 + 8
    b.text(lx, ly, "·", 13, TER)
    lx += 14
    b.rect(lx - 6, ly - 16, 130, 24, "#E6F0FC", rx=6)
    b.text(lx, ly, "Build trends ↗", 13, ACCENT, weight=600)
    b.note(1, lx + 134, ly - 4)
    # Its tooltip.
    b.rect(lx - 20, ly + 14, 290, 44, "#2B2D31", rx=6)
    b.text(lx - 8, ly + 32, "Build trends on the web page,", 11, "#FFF")
    b.text(lx - 8, ly + 47, "at this pull request's last run on main", 11, "#FFF")
    b.line(x + 28, ly + 80, x + w - 28, ly + 80, RULE)
    for i, ln in enumerate(["The body, the files and the comments, as today."]):
        b.text(x + 28, ly + 110 + i * 18, ln, 13, TER, italic=True)
    b.text(x + 28, y + h - 60, "With no web page this Mac can open (no control plane, or no page", 12, SEC)
    b.text(x + 28, y + h - 44, "served), the line has no Build trends and the Mac has no trends.", 12, SEC)
    b.note(2, x + w - 30, y + h - 52)
    # What it opens.
    bx, bw = 760, 456
    b.add(f'<g filter="url(#shadow)"><rect x="{bx}" y="{y}" width="{bw}" height="{h}" rx="10" fill="{GROUND}"/></g>')
    b.rect(bx, y, bw, 40, RAISED, rx=10)
    b.rect(bx + 14, y + 9, bw - 28, 22, FILL, rx=11)
    b.text(bx + 26, y + 24, "…/#/reports/value/builds?repo=github:alexec/agents&range=month&run=…", 10, SEC)
    b.note(3, bx + bw - 14, y + 20)
    b.text(bx + 20, y + 72, "Planning ›", 12, ACCENT)
    b.text(bx + 20, y + 96, "Builds", 18, INK, weight=700)
    b.text(bx + 20, y + 120, "Repository alexec/Agents · The last 30 days · ci · main", 11, SEC)
    # A small copy of the trend, the run marked.
    cy, ch, cw = y + 150, 120, bw - 40
    days = [d for d in DAYS if d.isoformat() in TREND["run"]]
    st = cw / len(DAYS)
    for d in days:
        i = DAYS.index(d)
        r, q = TREND["run"][d.isoformat()]["median"], TREND["queue"][d.isoformat()]["median"]
        hh = lambda v: min(v, 1800) / 1800 * ch
        b.rect(bx + 20 + i * st + st * 0.2, cy + ch - hh(r), st * 0.6, hh(r), ACCENT, rx=1)
        b.rect(bx + 20 + i * st + st * 0.2, cy + ch - hh(r + q), st * 0.6, hh(r + q) - hh(r), TURN)
    rd = local(PICK["after"]["created"]).date()
    mx = bx + 20 + DAYS.index(rd) * st + st / 2
    b.line(mx, cy - 6, mx, cy + ch, INK, sw=1.5)
    b.text(mx - 4, cy - 8, f"this PR's run, {rd:%-d %b}", 10, INK, weight=600, anchor="end")
    b.text(bx + 20, cy + ch + 40, "The page opens at the trend, with the run marked; a click on the", 12, SEC)
    b.text(bx + 20, cy + ch + 56, "mark opens its drill-down (board 3). A release's line opens the", 12, SEC)
    b.text(bx + 20, cy + ch + 72, "range around its tag, the tag marked.", 12, SEC)
    b.text(bx + 20, cy + ch + 104, "Signed in as Open in Browser does: on this Mac's control plane", 12, SEC)
    b.text(bx + 20, cy + ch + 120, "it pairs the browser the first time; elsewhere, the page's own", 12, SEC)
    b.text(bx + 20, cy + ch + 136, "sign-in keeps the address. The link carries no code or token.", 12, SEC)
    b.note(4, bx + bw - 14, cy + ch + 52)
    b.caption(x, y + h + 26, "The Remote has nothing (tier Web + Mac link). The web's own PR page (Work ▸ a PR) gets the same Build trends link, as a link inside the page.")
    b.write("board-5-mac-link.svg")


if __name__ == "__main__":
    trend()
    change()
    drill()
    empty()
    mac()
