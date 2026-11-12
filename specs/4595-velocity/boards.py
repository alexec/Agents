#!/usr/bin/env python3
"""Draws the boards of spec 4595 (Velocity, a Usage page of the PRs that landed) as SVG.

Run it from anywhere: it writes beside itself. Paper palette, light mode. The bars are real:
data.json, the PRs merged in Alex's repositories by day, which real-data.py fetches with gh
(Alex, 2026-11-10: use real data). The sidebar's other rows are scratch. The orange numbers
are the notes in spec.md.
"""
import datetime
import json
import math
from pathlib import Path

HERE = Path(__file__).parent
INK, SEC, TER = "#1C1D20", "#5B616B", "#8A9099"
GROUND, RAISED, RULE, FILL = "#F7F8F9", "#FFFFFF", "#DDE1E6", "#EEF0F3"
ACCENT, NOTE, FAIL, GREEN = "#0A6CDB", "#B35900", "#B42318", "#1A7F37"
FONT = "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"
DEFS = ('<defs><filter id="shadow" x="-5%" y="-5%" width="110%" height="115%">'
        '<feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity="0.18"/></filter></defs>')


class Board:
    def __init__(self, w, h, title, sub):
        self.w, self.h = w, h
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">',
                      DEFS, f'<rect width="{w}" height="{h}" fill="#E7EAEE"/>']
        self.text(24, 34, title, 15, INK, weight=600)
        self.text(24, 54, sub, 12, SEC)

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size, color=INK, weight=None, anchor=None, mono=False):
        a = []
        if weight: a.append(f'font-weight="{weight}"')
        if anchor: a.append(f'text-anchor="{anchor}"')
        if mono: a.append('font-variant-numeric="tabular-nums"')
        s = s.replace("&", "&amp;").replace("<", "&lt;")
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{color}" {" ".join(a)}>{s}</text>')

    def rect(self, x, y, w, h, fill=RAISED, stroke=None, rx=0, opacity=None, sw=1):
        a = f'rx="{rx}" fill="{fill}"'
        if stroke: a += f' stroke="{stroke}" stroke-width="{sw}"'
        if opacity is not None: a += f' opacity="{opacity}"'
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" {a}/>')

    def line(self, x1, y1, x2, y2, color=RULE, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="M{x1:.1f} {y1:.1f}L{x2:.1f} {y2:.1f}" stroke="{color}" stroke-width="1"{d}/>')

    def circle(self, cx, cy, r, fill, stroke=None):
        s = f' stroke="{stroke}"' if stroke else ""
        self.add(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r}" fill="{fill}"{s}/>')

    def note(self, n, x, y):
        self.circle(x, y, 9, NOTE)
        self.text(x, y + 4, str(n), 11, "#FFF", weight=700, anchor="middle")

    def caption(self, x, y, s):
        for i, ln in enumerate(s.split("\n")):
            self.text(x, y + i * 15, ln, 12, SEC, weight=600)

    def window(self, x, y, w, h):
        """A Mac window with its traffic lights. Returns the content top."""
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{GROUND}"/></g>')
        for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
            self.circle(x + 20 + i * 20, y + 20, 6, c)
        return y + 40

    def segmented(self, x, y, items, on, w=44, h=22):
        self.rect(x, y, w * len(items) + 4, h + 4, FILL, rx=7)
        for i, s in enumerate(items):
            if s == on:
                self.rect(x + 2 + i * w, y + 2, w, h, RAISED, stroke="#CCD1D7", rx=6)
            self.text(x + 2 + i * w + w / 2, y + 2 + h / 2 + 4, s, 12, INK if s == on else SEC, weight=600 if s == on else None, anchor="middle")

    def chart(self, x, y, w, h, values, labels, top, average=None, picked=None, ticks=None):
        """Bars of PRs: an axis on the right as the usage charts draw it, a dashed average, a
        picked bar (the rest dim), labels under the bars."""
        n = len(values)
        inner = w - 56
        step = inner / n
        yv = lambda v: y + h - v / top * (h - 8)
        for f in (0.5, 1):
            self.line(x, yv(top * f), x + inner, yv(top * f), RULE)
            self.text(x + inner + 6, yv(top * f) + 4, f"{top * f:.0f}", 11, TER)
        self.line(x, y + h, x + inner, y + h, "#C7CCD3")
        for i, v in enumerate(values):
            dim = picked is not None and picked != i
            self.rect(x + i * step + step * 0.15, yv(v), step * 0.7, y + h - yv(v), ACCENT, rx=2, opacity=0.35 if dim else None)
            if ticks is None or i % ticks == 0:
                self.text(x + i * step + step / 2, y + h + 15, labels[i], 11, TER, anchor="middle")
        if average is not None and picked is None:
            self.line(x, yv(average), x + inner, yv(average), SEC, dash="4 3")

    def shares(self, x, y, w, rows):
        for i, (name, value) in enumerate(rows):
            self.text(x, y + i * 22, name, 13, INK)
            self.text(x + w, y + i * 22, f"{value:,}", 13, INK, anchor="end", mono=True)

    def headline(self, x, y, label, figure, when):
        self.text(x, y, label, 11, SEC, weight=600)
        self.text(x, y + 30, figure, 26, INK, weight=600, mono=True)
        self.text(x, y + 50, when, 13, SEC)

    def write(self, name):
        self.add("</svg>")
        (HERE / name).write_text("\n".join(self.parts))
        print(name)


# --- the data: data.json, from real-data.py -----------------------------------------------
DATA = json.loads((HERE / "data.json").read_text())
TODAY = datetime.date.fromisoformat(DATA["fetched"][:10])


def repo_name(key):
    """github:alexec/agents as the page shows it: the forge prefix off."""
    return key.split(":", 1)[1]


class Range:
    """The last `days` days to today, as the usage charts bucket a W or M range."""
    def __init__(self, days):
        self.days = [TODAY - datetime.timedelta(days=i) for i in range(days - 1, -1, -1)]
        buckets = [DATA["days"].get(d.isoformat(), {}) for d in self.days]
        self.values = [sum(b["merged"] for b in day.values()) for day in buckets]
        self.reverts = sum(b["reverted"] for day in buckets for b in day.values())
        shares = {}
        for day in buckets:
            for repo, b in day.items():
                shares[repo] = shares.get(repo, 0) + b["merged"]
        self.shares = sorted(((repo_name(r), v) for r, v in shares.items()), key=lambda s: -s[1])
        self.total = sum(self.values)
        self.average = self.total / days
        self.top = math.ceil(max(self.values) / 50) * 50

    @property
    def when(self):
        first, last = self.days[0], self.days[-1]
        if first.month == last.month:
            return f"{first.day} – {last.day} {last:%b %Y}"
        return f"{first.day} {first:%b} – {last.day} {last:%b %Y}"


WEEK, MONTH = Range(7), Range(30)
PICKED = WEEK.values.index(max(WEEK.values))
reverts_line = lambda r: f"Including {r.reverts} reverts." if r.reverts else "No reverts."
prs_words = lambda v: f"{v:,.0f} PRs"


def sidebar(b, x, top, w, h):
    """The window's one sidebar (#145): Status, Machines and Usage at the top, then the folders."""
    b.rect(x, top - 40, w, h + 40, "#EEF0F3", rx=10)
    b.rect(x + w - 10, top - 40, 10, h + 40, "#EEF0F3")
    y = top + 8
    for head, rows in [("Status", ["Runtimes", "Events"]), ("Machines", ["This Mac", "Linux box"])]:
        b.text(x + 16, y + 12, head, 11, SEC, weight=600)
        y += 22
        for r in rows:
            b.text(x + 36, y + 12, r, 13, INK)
            y += 24
        y += 6
    b.text(x + 16, y + 12, "Usage", 11, SEC, weight=600)
    y += 22
    rows = [("×", "Multiplier"), ("$", "Cost"), ("#", "Tokens"), ("◴", "Time"), ("⑂", "Velocity")]
    for glyph, r in rows:
        on = r == "Velocity"
        if on:
            b.rect(x + 8, y - 2, w - 16, 26, ACCENT, rx=6)
        b.text(x + 18, y + 14, glyph, 12, "#FFF" if on else SEC, anchor="middle", weight=600)
        b.text(x + 36, y + 14, r, 13, "#FFF" if on else INK, weight=600 if on else None)
        y += 24
    vel_y = y - 24
    y += 6
    b.text(x + 16, y + 12, "Needs You", 11, SEC, weight=600)
    y += 22
    b.text(x + 36, y + 12, "Approve PR #4590 screenshots", 13, INK)
    y += 30
    b.text(x + 16, y + 12, "Agents", 11, SEC, weight=600)
    y += 22
    for r in ["Software Engineer · #4552", "Lead · #4551", "Product Owner · #4595"]:
        b.text(x + 36, y + 12, r, 13, INK)
        y += 24
    return vel_y


def page(b, x, y, w, picked=None, note_from=None):
    """The Velocity page in W: Range, the headline, the bars, the shares and the line under them."""
    n = note_from
    r = WEEK
    b.text(x, y + 20, "Velocity", 22, INK, weight=700)
    b.segmented(x, y + 40, ["D", "W", "M", "3M"], "W")
    if n: b.note(n + 1, x + 200, y + 53)
    hy = y + 90
    if picked is None:
        b.headline(x, hy, "PRS A DAY", prs_words(r.average), r.when)
    else:
        b.headline(x, hy, "TOTAL", prs_words(r.values[picked]), f"{r.days[picked]:%A} {r.days[picked].day} {r.days[picked]:%B}")
    if n: b.note(n + 2, x + 150, hy + 22)
    cy = hy + 70
    b.chart(x, cy, w, 170, r.values, [f"{d:%a}" for d in r.days], r.top, average=r.average, picked=picked)
    if n: b.note(n + 3, x + w - 2, cy + 10)
    if n and picked is None: b.note(n + 4, x + 12, cy + 170 - r.average / r.top * 162 - 12)
    sy = cy + 170 + 50
    b.shares(x, sy, w - 56, r.shares)
    if n: b.note(n + 5, x + w - 30, sy - 4)
    b.text(x, sy + 50, reverts_line(r), 11, SEC)
    if n: b.note(n + 6, x + 100, sy + 46)
    return sy + 60


def mac():
    b = Board(1240, 720, "The Mac window: Velocity, a Usage row after Time, and its page",
              f"Week, the daily average as the dashed line (left); the same page with {WEEK.days[PICKED]:%A} picked (right). "
              f"Real data: the PRs merged in alexec/Agents and alexec/agents-walk, from gh on {TODAY}.")
    x, y, w, h = 24, 76, 760, 610
    top = b.window(x, y, w, h)
    vel_y = sidebar(b, x, top, 236, h - 40)
    b.note(1, x + 236 + 12, vel_y + 11)
    page(b, x + 236 + 36, top - 6, 460, note_from=1)
    # The picked state, as a second detail column.
    px, pw = 820, 396
    b.rect(px, y, pw, h, GROUND, rx=10, stroke="#C7CCD3")
    b.text(px + 24, y + 30, "The same page, a bar picked", 12, SEC, weight=600)
    end = page(b, px + 24, y + 40, pw - 48, picked=PICKED)
    b.note(8, px + 24 + 150, y + 40 + 90 + 22)
    b.text(px + 24, end + 30, "A click on a bar reads its own figure; the rest dim and the", 12, SEC)
    b.text(px + 24, end + 46, "average line goes. A second click, or a new range, lets it go.", 12, SEC)
    b.note(9, px + 24 + 200, y + 40 + 160 + 10)
    b.caption(x, y + h + 24, "View ▸ Velocity opens the same page (note 1). The Remote has no Velocity page: tier Mac + web, as Cost, Tokens and Time (#2798).")
    b.write("velocity-mac.svg")


def web():
    r = MONTH
    b = Board(1240, 760, "The web page: Reports ▸ Usage with a fourth tab, Velocity",
              f"Month, wide (1100 px). The narrow page stacks as Usage's other tabs do. Real data, as the Mac board's, from gh on {TODAY}.")
    x, y, w, h = 24, 76, 1192, 640
    b.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{GROUND}"/></g>')
    # The bar of sections at the top of every page (#2141).
    b.rect(x, y, w, 44, RAISED, rx=8)
    b.line(x, y + 44, x + w, y + 44)
    sx = x + 24
    for s in ["Overview", "Agents", "Work", "Docs", "Messages", "Machines", "Workflows", "Reports", "Requests", "People", "Status", "Settings"]:
        on = s == "Reports"
        b.text(sx, y + 28, s, 13, INK if on else SEC, weight=600 if on else None)
        if on:
            b.rect(sx - 2, y + 41, len(s) * 7.2 + 4, 2, ACCENT)
        sx += len(s) * 7.2 + 26
    # The pages of Reports, in groups.
    lx, ly = x + 24, y + 70
    for head, pages in [("Reports", ["Spend", "Outcomes", "Time", "Value", "Runtimes", "Adoption", "Workflows", "Features"]),
                        ("Yours", ["Multiplier", "Usage"]), ("Records", ["Audit"]), ("Saved", ["Saved Views"])]:
        b.text(lx, ly + 12, head, 11, SEC, weight=600)
        ly += 22
        for p in pages:
            on = p == "Usage"
            if on:
                b.rect(lx - 8, ly - 2, 160, 26, FILL, rx=6)
            b.text(lx, ly + 14, p, 13, INK, weight=600 if on else None)
            ly += 24
        ly += 8
    b.line(x + 200, y + 44, x + 200, y + h)
    # The page.
    px = x + 232
    b.text(px, y + 94, "Usage", 22, INK, weight=700)
    tx = px
    for t in ["Cost", "Tokens", "Time", "Velocity"]:
        on = t == "Velocity"
        tw = len(t) * 8 + 24
        b.rect(tx, y + 112, tw, 28, RAISED if on else "none", stroke="#C7CCD3" if on else None, rx=6)
        b.text(tx + tw / 2, y + 131, t, 13, INK if on else SEC, weight=600 if on else None, anchor="middle")
        tx += tw + 6
    b.note(10, tx + 10, y + 126)
    # Range as a select (#2142).
    b.text(px, y + 174, "Range", 12, SEC)
    b.rect(px + 50, y + 158, 110, 24, RAISED, stroke="#C7CCD3", rx=6)
    b.text(px + 60, y + 175, "Month", 13, INK)
    b.text(px + 148, y + 175, "⌄", 13, SEC)
    b.note(11, px + 180, y + 170)
    b.headline(px, y + 216, "PRS A DAY", prs_words(r.average), r.when)
    cw = 700
    b.chart(px, y + 290, cw, 200, r.values, [str(d.day) for d in r.days], r.top, average=r.average, ticks=7)
    b.note(12, px + cw + 2, y + 300)
    b.shares(px, y + 540, cw - 56, r.shares)
    b.text(px, y + 590, reverts_line(r), 11, SEC)
    b.note(13, px + 100, y + 586)
    # The empty state, beside.
    ex = px + cw + 40
    b.rect(ex, y + 216, 190, 120, RAISED, stroke="#C7CCD3", rx=8)
    b.text(ex + 12, y + 236, "Empty", 11, SEC, weight=600)
    b.text(ex + 12, y + 262, "PRS A DAY", 11, SEC, weight=600)
    b.text(ex + 12, y + 288, "0 PRs", 22, INK, weight=600)
    b.text(ex + 12, y + 316, "No pull requests landed", 12, SEC)
    b.text(ex + 12, y + 330, "in this range.", 12, SEC)
    b.note(14, ex + 190 - 10, y + 216 + 10)
    b.caption(x, y + h + 24, "The URL #/r/usage opens Cost as now; #/a/velocity goes to the Velocity tab, as #/a/time goes to Time.")
    b.write("velocity-web.svg")


if __name__ == "__main__":
    mac()
    web()
