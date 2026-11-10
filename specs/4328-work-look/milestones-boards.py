#!/usr/bin/env python3
"""Draws the boards of milestones.md (#4334): python3 milestones-boards.py, in this folder.

Scratch data. The symbols come from pull-request-mac.svg and lists-remote.svg, so the
glyphs are the shared parts' (#4328).
"""
import re
from pathlib import Path

HERE = Path(__file__).parent
INK, SEC, FAINT, LINE, BG2, PAGE = "#1C1D20", "#5B616B", "#8A9099", "#E0E3E7", "#F6F7F8", "#E7EAEE"
ACC, GREEN, PURPLE, GREY, RED, AMBER, NOTE = "#0A6CDB", "#1A7F37", "#8250DF", "#6E7781", "#CF222E", "#9A6700", "#B35900"
MONO = "SF Mono, Menlo, monospace"


def defs():
    seen, out = set(), []
    for name in ("pull-request-mac.svg", "lists-remote.svg"):
        for m in re.finditer(r'<symbol id="([a-z]+)".*?</symbol>', (HERE / name).read_text(), re.S):
            if m.group(1) not in seen:
                seen.add(m.group(1))
                out.append("    " + m.group(0))
    out.append('    <symbol id="box" viewBox="0 0 16 16"><path d="M8 1.8l5.6 3v6.4L8 14.2l-5.6-3V4.8z M2.4 4.8L8 7.8l5.6-3M8 7.8v6.4" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></symbol>')
    out.append('    <symbol id="stream" viewBox="0 0 16 16"><path d="M1.5 11h13M3.5 11c1.5 0 1.5-5 3-5h3c1.5 0 1.5 5 3 5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></symbol>')
    out.append('    <symbol id="epic" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M8 2a6 6 0 0 1 6 6H8z" fill="currentColor"/></symbol>')
    return "\n".join(out)


class Board:
    def __init__(self, w, h, title, sub):
        self.w, self.h, self.o = w, h, []
        self.rect(0, 0, w, h, fill=PAGE)
        self.text(24, 34, title, 15, weight=600)
        self.text(24, 54, sub, 12, SEC)

    # primitives
    def raw(self, s):
        self.o.append("  " + s)

    def rect(self, x, y, w, h, rx=0, fill="none", stroke=None, sw=1, op=None, dash=None):
        a = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        a += f' fill-opacity="{op}"' if op is not None else ""
        a += f' stroke-dasharray="{dash}"' if dash else ""
        self.raw(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{a}/>')

    def line(self, x1, y1, x2, y2, stroke=LINE, sw=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.raw(f'<path d="M{x1} {y1}L{x2} {y2}" stroke="{stroke}" stroke-width="{sw}" fill="none" stroke-linecap="round"{d}/>')

    def path(self, d, stroke, sw=2, dash=None, fill="none", op=None):
        a = f' stroke-dasharray="{dash}"' if dash else ""
        a += f' opacity="{op}"' if op is not None else ""
        self.raw(f'<path d="{d}" stroke="{stroke}" stroke-width="{sw}" fill="{fill}" stroke-linecap="round"{a}/>')

    def circle(self, cx, cy, r, fill="none", stroke=None, sw=1.5):
        s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        self.raw(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"{s}/>')

    def text(self, x, y, s, size=13, fill=INK, weight=None, anchor=None, family=None, op=None):
        a = f' font-weight="{weight}"' if weight else ""
        a += f' text-anchor="{anchor}"' if anchor else ""
        a += f' font-family="{family}"' if family else ""
        a += f' opacity="{op}"' if op is not None else ""
        self.raw(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}"{a}>{s}</text>')

    def use(self, sym, x, y, size=16, color=INK):
        self.raw(f'<use href="#{sym}" x="{x}" y="{y}" width="{size}" height="{size}" color="{color}"/>')

    def group(self, x, y, shadow=True, op=None):
        f = ' filter="url(#shadow)"' if shadow else ""
        o = f' opacity="{op}"' if op is not None else ""
        self.raw(f'<g transform="translate({x},{y})"{f}{o}>')

    def end(self):
        self.raw("</g>")

    # parts
    def note(self, n, x, y):
        self.circle(x, y, 9 if len(str(n)) < 3 else 12, NOTE)
        self.text(x, y + 4, str(n), 11, "#FFF", 700, "middle")

    def chip(self, x, y, s, color, size=11):
        w = width(s, size) + 12
        self.rect(x, y, w, 18, 9, fill=color, op=0.14)
        self.rect(x, y, w, 18, 9, stroke=color, sw=0.8)
        self.text(x + 6, y + 13, s, size, darken(color), 500)
        return w

    def pill(self, x, y, s, fill, sym=None):
        w = width(s, 12.5, 600) + (36 if sym else 20)
        self.rect(x, y, w, 24, 12, fill=fill)
        if sym:
            self.use(sym, x + 8, y + 5, 14, "#FFF")
        self.text(x + (26 if sym else 10), y + 16.5, s, 12.5, "#FFF", 600)
        return w

    def bar(self, x, y, w, frac, color=GREEN, h=6):
        self.rect(x, y, w, h, h / 2, fill=LINE)
        if frac > 0:
            self.rect(x, y, max(h, w * frac), h, h / 2, fill=color)

    def menu(self, x, y, s, set_=False):
        w = width(s, 12.5) + 22
        self.text(x, y + 15, s, 12.5, ACC if set_ else SEC, 500 if set_ else None)
        self.use("chev", x + w - 16, y + 7, 10, ACC if set_ else FAINT)
        return w + 10

    def capsule(self, x, y, s, set_=False):
        w = width(s, 13) + 34
        self.rect(x, y, w, 30, 15, fill="#DCEBFC" if set_ else "#EEF0F3")
        self.text(x + 12, y + 20, s, 13, ACC if set_ else INK, 500 if set_ else None)
        self.use("chev", x + w - 20, y + 10, 10, ACC if set_ else FAINT)
        return w + 8

    def search(self, x, y, w, s, h=28):
        self.rect(x, y, w, h, 7, fill="#FFFFFF", stroke="#C7CCD3")
        self.use("search", x + 8, y + h / 2 - 7, 14, FAINT)
        self.text(x + 28, y + h / 2 + 4.5, s, 12.5, FAINT)

    def button(self, x, y, s, primary=False, sym=None, h=28, color=ACC):
        w = width(s, 12.5, 500) + (40 if sym else 24)
        if primary:
            self.rect(x, y, w, h, 6, fill=color)
        else:
            self.rect(x, y, w, h, 6, fill="#FFFFFF", stroke="#C7CCD3")
        c = "#FFF" if primary else INK
        if sym:
            self.use(sym, x + 10, y + h / 2 - 7, 14, c)
        self.text(x + (30 if sym else 12), y + h / 2 + 4.5, s, 12.5, c, 500)
        return w

    def placeholder(self, x, y, w):
        self.circle(x + 8, y + 10, 8, "#E6E8EB")
        self.rect(x + 26, y + 2, w * 0.55, 10, 5, fill="#E6E8EB")
        self.rect(x + 26, y + 20, w * 0.35, 8, 4, fill="#EEF0F2")

    def window(self, x, y, w, h, crumbs, title_ix=None, refresh=True, nav=None):
        """A Mac window; the content is drawn at (x, y) + offsets by the caller after this."""
        self.group(x, y)
        self.rect(0, 0, w, h, 12, fill="#FFFFFF")
        self.raw(f'<path d="M12 0h{w-24}a12 12 0 0 1 12 12v40H0V12A12 12 0 0 1 12 0z" fill="{BG2}"/>')
        self.line(0, 52, w, 52)
        for i, c in enumerate(("#FF5F57", "#FEBC2E", "#28C840")):
            self.circle(20 + 20 * i, 20, 6, c)
        self.use("sidebar", 84, 18, 16, SEC)
        self.use("back", 116, 18, 16, SEC)
        self.use("fwd", 136, 18, 16, "#C7CCD3")
        cx = 166
        for i, c in enumerate(crumbs):
            last = i == len(crumbs) - 1
            self.text(cx, 32, c, 14, INK if last else SEC, 600 if last else None)
            cx += width(c, 14, 600 if last else None) + 10
            if not last:
                self.use("chevr", cx - 2, 22, 10, FAINT)
                cx += 18
        if nav:
            self.use("up", w - 168, 18, 16, SEC)
            self.text(w - 124, 31, nav, 12.5, SEC, anchor="middle")
            self.use("down", w - 96, 18, 16, SEC)
        if refresh:
            self.rect(w - 50, 14, 28, 24, 6, fill="#EDEFF2")
            self.use("refresh", w - 44, 18, 16, "#4A5059")

    def phone(self, x, y, back=None, title=None, w=390, h=844, large=True):
        self.group(x, y)
        self.rect(-12, -12, w + 24, h + 24, 54, fill="#1C1D20")
        self.rect(0, 0, w, h, 44, fill="#FFFFFF")
        self.rect(w / 2 - 62, 11, 124, 36, 18, fill="#1C1D20")
        self.text(34, 34, "9:41", 15, INK, 600)
        if back:
            self.use("back", 14, 66, 20, ACC)
            self.text(36, 82, back, 17, ACC)
        if title and large:
            self.text(20, 128, title, 32, INK, 700)
        elif title:
            self.text(w / 2, 82, title, 17, INK, 600, "middle")

    def write(self, name):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" '
                "font-family=\"-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif\">\n  <defs>\n"
                '    <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">\n'
                '      <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#20242A" flood-opacity="0.14"/>\n'
                f"    </filter>\n{defs()}\n  </defs>\n")
        (HERE / name).write_text(head + "\n".join(self.o) + "\n</svg>\n")


def width(s, size, weight=None):
    s = re.sub(r"<[^>]+>", "", s).replace("&amp;", "&").replace("&#8201;", " ")
    return round(len(s) * size * (0.55 if weight and int(weight) >= 600 else 0.5), 1)


def darken(hex_):
    r, g, b = (int(hex_[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02X%02X%02X" % (int(r * 0.55), int(g * 0.55), int(b * 0.55))


# Scratch data -------------------------------------------------------------------------------
MILESTONES = [
    # title, due words, due colour, open, closed, cost, sessions, line words
    ("Projects", "Due Fri 14 Nov", SEC, 18, 46, "$41.20", 37, "A project holds folders, repos and people"),
    ("Channels", "Due Fri 21 Nov", SEC, 22, 9, "$8.10", 6, "Agents talk on Slack, Discord and mail as MCP servers"),
    ("Runtime assessments", "Due Fri 28 Nov", SEC, 7, 2, "$1.90", 3, "Each runtime scored on the app's own tools"),
    ("Lineage and value", "Past due by 2 days", RED, 1, 40, "$63.75", 52, "What each piece of work cost and what it made"),
    ("1.0 Public release", "No due date", FAINT, 31, 12, "$12.40", 11, "App Review, docs and the public page"),
]
RELEASES = [
    # name, chip, when, prs, cost, pipeline
    ("0.43.0", ("Draft", GREY), "draft · saved 30 min ago", 6, "$3.10", None),
    ("0.42.0", ("Latest", GREEN), "released 2 h ago by alexec", 23, "$18.40", "TestFlight"),
    ("0.41.0", None, "released 1 d ago by alexec", 31, "$26.05", "TestFlight"),
    ("0.40.0", None, "released 2 d ago by alexec", 27, "$22.80", "TestFlight"),
    ("0.40.0-rc.1", ("Pre-release", AMBER), "released 3 d ago by alexec", 4, "$1.20", None),
]
ITEMS = [
    # glyph, colour, title, chips, line 2, cost
    ("open", GREEN, "Projects: a folder can join two projects", [("enhancement", "#A2EEEF"), ("feature:projects", "#1D76DB")], "#4371 · opened 5 h ago by alexec · ✦ Claude · $0.84"),
    ("pr", GREEN, "Projects: the project picker in New Session", [("enhancement", "#A2EEEF")], "#4388 · opened 2 h ago by claude-agent · ✦ Claude · $1.12"),
    ("open", GREEN, "Projects: Settings ▸ Projects lists each project's people", [("story", "#0E8A16"), ("feature:projects", "#1D76DB")], "#4360 · opened 1 d ago by alexec"),
    ("done", PURPLE, "Projects: the project store and its wire types", [("task", "#C5DEF5")], "#4301 · closed 1 d ago · ✦ Codex · $2.40"),
]


def ms_row(b, x, y, w, m, closed=False, short=False):
    title, due, due_c, op, cl, cost, ses, desc = m
    frac = cl / (op + cl)
    glyph_c = PURPLE if closed else GREEN
    b.use("flag", x + 12, y + 12, 16, glyph_c)
    b.text(x + 38, y + 25, title, 14, INK, 600)
    b.text(x + 46 + width(title, 14, 600), y + 25, desc, 12.5, FAINT)
    # progress at the trailing edge
    b.bar(x + w - 220, y + 18, 140, frac, PURPLE if closed else GREEN)
    b.text(x + w - 16, y + 25, f"{round(frac * 100)}%", 12.5, SEC, 600, "end")
    due_txt = "Closed 3 d ago" if closed else due
    tail = f'<tspan fill="#C2410C">✦</tspan> {cost}' if short else f'<tspan fill="#C2410C">✦</tspan> Claude, Codex · {cost} · {ses} sessions'
    b.text(x + 38, y + 46, f'<tspan fill="{SEC if closed else due_c}">{due_txt}</tspan> · {op} open · {cl} closed · {tail}', 12, SEC)
    b.line(x, y + 62, x + w, y + 62)


def rel_row(b, x, y, w, r, ver_tag=True):
    name, chip, when, prs, cost, pipe = r
    b.use("box", x + 12, y + 12, 16, GREY if chip and chip[0] == "Draft" else INK)
    b.text(x + 38, y + 25, name, 14, INK, 600)
    cx = x + 46 + width(name, 14, 600)
    if chip:
        b.chip(cx, y + 12, chip[0], chip[1])
    b.text(x + 38, y + 46, f'<tspan font-family="{MONO}">v{name}</tspan> · {when} · {prs} pull requests · '
           f'<tspan fill="#C2410C">✦</tspan> {cost}', 12, SEC)
    if pipe:
        b.use("tick", x + w - 110, y + 16, 14, GREEN)
        b.text(x + w - 16, y + 28, pipe, 12.5, SEC, anchor="end")
    elif chip and chip[0] == "Draft":
        b.text(x + w - 16, y + 28, "Not published", 12.5, FAINT, anchor="end")
    b.line(x, y + 62, x + w, y + 62)


def item_row(b, x, y, w, it, compact=False):
    glyph, c, title, chips, l2 = it
    b.use(glyph, x + 12, y + 11, 16, c)
    b.text(x + 38, y + 24, title, 13.5, INK, 600)
    if not compact:
        cx = x + 46 + width(title, 13.5, 600)
        for name, col in chips:
            cx += b.chip(cx, y + 11, name, col) + 4
    b.text(x + 38, y + 44, l2.replace("✦", '<tspan fill="#C2410C">✦</tspan>'), 12, SEC)
    b.line(x, y + 58, x + w, y + 58)


def panel(b, x, y, sections, w=220):
    for head, rows in sections:
        b.text(x, y, head, 12, SEC, 600)
        y += 22
        for r in rows:
            if isinstance(r, tuple) and r[0] == "bar":
                b.bar(x, y - 8, w - 40, r[1], r[2])
                y += 12
                continue
            b.text(x, y, r, 12.5, INK)
            y += 20
        b.line(x, y - 4, x + w, y - 4)
        y += 18
    return y


# Board 1: Milestones on the Mac -------------------------------------------------------------
def mac_milestones():
    b = Board(1240, 1470, "Milestones (#4334): the Mac window",
              "The list and a milestone's page, with the shared parts of #4328. Orange numbers are the notes in milestones.md. Scratch data. Paper palette, light mode.")
    W = 1180
    b.window(24, 76, W, 560, ["Milestones"])
    b.note(1, W - 36, 64)
    b.text(24, 92, "Milestones", 21, INK, 600)
    b.search(24, 108, 220, "Filter milestones")
    mx = 264
    mx += b.menu(mx, 112, "Project: Agents", True)
    mx += b.menu(mx, 112, "Open")
    mx += b.menu(mx, 112, "Repo")
    b.menu(W - 140, 112, "Sort: Due date")
    b.note(2, 24 + 230, 104)
    b.line(0, 148, W, 148)
    y = 148
    for i, m in enumerate(MILESTONES):
        if i == 1:
            b.rect(0, y, W, 62, fill="#F3F5F8")
        ms_row(b, 0, y, W, m)
        y += 62
    b.note(3, 760, 172)
    b.note(4, W - 240, 172)
    b.note(5, 760, 172 + 62 * 3 + 22)
    b.note(6, 760, 172 + 62 * 4 + 22)
    # the Sort menu, open
    b.raw(f'<g transform="translate({W - 172},140)">')
    b.rect(0, 0, 160, 120, 8, fill="#FFFFFF", stroke=LINE)
    for i, s in enumerate(("Due date", "Most complete", "Recently updated", "Cost")):
        if i == 0:
            b.use("tick", 10, 12, 12, INK)
        b.text(30, 22 + 26 * i, s, 12.5)
    b.raw("</g>")
    b.text(W / 2, y + 30, "5 milestones", 12, FAINT, anchor="middle")
    b.end()

    # the page
    b.window(24, 676, W, 770, ["Milestones", "Projects"], nav="1 of 5")
    b.note(7, 100, 64)
    b.text(24, 92, "Projects", 21, INK, 600)
    b.use("ext", W - 140, 78, 14, ACC)
    b.text(W - 24, 90, "Open on GitHub", 12.5, ACC, anchor="end")
    pw = b.pill(24, 106, "Open", GREEN, "flag")
    b.text(34 + pw, 123, '<tspan fill="' + SEC + '">Due Fri 14 Nov</tspan> · 72% complete · 18 open · 46 closed · updated 20 min ago', 12.5, SEC)
    b.note(8, 10, 118)
    b.bar(24, 142, 860, 46 / 64, GREEN, 8)
    b.note(9, 10, 146)
    b.line(24, 166, W - 24, 166)
    # description
    b.rect(24, 182, 860, 76, 6, fill="#FFFFFF", stroke=LINE)
    b.text(40, 208, "A project holds folders, repos and people. This milestone is the Projects theme;", 13.5)
    b.text(40, 228, "its due date is only for the order (#1340).", 13.5)
    b.note(10, 10, 220)
    # the items
    b.search(24, 274, 220, "Filter issues and pull requests")
    b.text(266, 293, '<tspan font-weight="600" fill="' + INK + '">◉ 18 Open</tspan>    ✓ 46 Closed', 13, SEC)
    mx = 470
    mx += b.menu(mx, 278, "Kind: All")
    mx += b.menu(mx, 278, "Label")
    mx += b.menu(mx, 278, "Assignee")
    b.menu(800, 278, "Sort")
    b.note(11, 254, 270)
    b.line(24, 314, 884, 314)
    # epics first
    b.text(24, 336, "EPICS", 11, FAINT, 600)
    b.note(12, 10, 332)
    yy = 344
    for t, n, of, _c in (("Projects: folders, repos and people in one place", "#4250", "11 of 16", "#1D76DB"),
                        ("Projects: the project's own page", "#4318", "3 of 9", "#1D76DB")):
        b.use("epic", 36, yy + 11, 16, GREEN)
        b.text(62, yy + 24, t, 13.5, INK, 600)
        b.bar(640, yy + 15, 120, int(of.split()[0]) / int(of.split()[2]), GREEN)
        b.text(884 - 12, yy + 24, of, 12.5, SEC, anchor="end")
        b.text(62, yy + 44, f"{n} · lead running · ✦ $9.80 · closes about Thu evening", 12, SEC)
        b.line(24, yy + 58, 884, yy + 58)
        yy += 58
    b.text(24, yy + 22, "ISSUES AND PULL REQUESTS", 11, FAINT, 600)
    yy += 30
    for it in ITEMS[:3]:
        item_row(b, 24, yy, 860, it)
        yy += 58
    b.text(454, yy + 26, "Loading more…  · 3 of 18 shown", 12, FAINT, anchor="middle")
    b.note(13, 10, yy - 140)
    # panel
    panel(b, 912, 192, [
        ("Due date", ["Fri 14 Nov 2026"]),
        ("Progress", [("bar", 46 / 64, GREEN), "46 of 64 closed · 72%"]),
        ("Repo", ["alexec/Agents"]),
        ("Released in", ["0.41.0 · 12 closed items", "0.42.0 · 9 closed items"]),
        ("Lineage", ['<tspan fill="#C2410C">✦</tspan> Claude, Codex · $41.20', "37 sessions · 2 running"]),
    ], 240)
    b.note(14, 1160, 186)
    b.note(15, 1160, 378)
    b.note(16, 1160, 458)
    b.end()
    b.write("milestones-mac.svg")


# Board 2: Releases on the Mac ---------------------------------------------------------------
def mac_releases():
    b = Board(1240, 1460, "Releases (#4334): the Mac window",
              "The list and a release's page. Orange numbers are the notes in milestones.md. Scratch data. Paper palette, light mode.")
    W = 1180
    b.window(24, 76, W, 520, ["Releases"])
    b.text(24, 92, "Releases", 21, INK, 600)
    b.search(24, 108, 220, "Filter releases")
    mx = 264
    mx += b.menu(mx, 112, "Project: Agents", True)
    mx += b.menu(mx, 112, "Kind: All")
    mx += b.menu(mx, 112, "Repo")
    b.menu(W - 140, 112, "Sort: Newest")
    b.note(17, 254, 104)
    b.line(0, 148, W, 148)
    y = 148
    for r in RELEASES:
        rel_row(b, 0, y, W, r)
        y += 62
    b.note(18, 640, 172)
    b.note(19, 640, 234)
    b.note(20, W - 130, 234)
    b.note(21, 640, 172 + 62 * 4)
    b.text(W / 2, y + 30, "28 releases", 12, FAINT, anchor="middle")
    b.end()

    b.window(24, 636, W, 800, ["Releases", "0.42.0"], nav="2 of 28")
    b.text(24, 92, "0.42.0", 21, INK, 600)
    b.chip(110, 76, "Latest", GREEN, 12)
    b.use("ext", W - 140, 78, 14, ACC)
    b.text(W - 24, 90, "Open on GitHub", 12.5, ACC, anchor="end")
    b.note(22, 10, 84)
    b.text(24, 124, f'<tspan font-weight="600" fill="{INK}">alexec</tspan> released this 2 h ago · '
           f'<tspan font-family="{MONO}" fill="{INK}">v0.41.0…v0.42.0</tspan> · 23 pull requests · 2 milestones finished', 12.5, SEC)
    b.note(23, 10, 120)
    b.line(24, 142, W - 24, 142)
    # notes
    b.rect(24, 158, 860, 250, 6, fill="#FFFFFF", stroke=LINE)
    b.raw(f'<path d="M24 164a6 6 0 0 1 6-6h848a6 6 0 0 1 6 6v26H24z" fill="{BG2}"/>')
    b.line(24, 190, 884, 190)
    b.text(36, 179, "Release notes", 12, SEC, 600)
    b.note(24, 10, 176)
    yy = 216
    for s, sz, wgt in (("Milestones finished", 15, 600), ("•  Lineage and value", 13.5, None), ("•  Work ▸ Timeline", 13.5, None),
                       ("What's new", 15, 600), ("•  Work ▸ Timeline: the epics on a time axis, with Now in the centre (#4173)", 13.5, None),
                       ("•  Forge: one interface for every forge (#4352)", 13.5, None), ("Fixes", 15, 600),
                       ("•  The Remote's sidebar keeps its place after a reconnect (#4296)", 13.5, None)):
        b.text(40, yy, s, sz, INK, wgt)
        yy += 24 if wgt else 22
    # what went in
    b.text(24, 438, "PULL REQUESTS IN THIS RELEASE", 11, FAINT, 600)
    b.note(25, 10, 434)
    b.search(24, 448, 220, "Filter pull requests")
    mx = 264
    mx += b.menu(mx, 452, "Label")
    mx += b.menu(mx, 452, "Milestone")
    b.menu(780, 452, "Sort")
    b.line(24, 488, 884, 488)
    yy = 488
    for t, ch, l2 in (("Work ▸ Timeline: the epics in time on the Mac", [("enhancement", "#A2EEEF"), ("feature:work", "#1D76DB")], "#4188 · merged 1 d ago · ✦ Claude · $4.10"),
                      ("Forge interface: Forge, forgeCaps and the registry", [("task", "#C5DEF5")], "#4411 · merged 5 h ago · ✦ Codex · $2.35"),
                      ("Remote: the sidebar keeps its place after a reconnect", [("bug", "#D73A4A")], "#4296 · merged 7 h ago · ✦ Claude · $0.62"),
                      ("Lineage: the cost of a release on its page", [("enhancement", "#A2EEEF")], "#4290 · merged 9 h ago · ✦ Claude · $1.05")):
        item_row(b, 24, yy, 860, ("merged", PURPLE, t, ch, l2))
        yy += 58
    b.text(454, yy + 26, "4 of 23 shown · the next ones load as you scroll", 12, FAINT, anchor="middle")
    py = panel(b, 912, 168, [
        ("Tag", [f'<tspan font-family="{MONO}">v0.42.0</tspan> · bf6f4dd']),
        ("Compared with", [f'<tspan font-family="{MONO}">v0.41.0</tspan> · 23 pull requests']),
        ("Milestones finished", ["⚑ Lineage and value", "⚑ Work ▸ Timeline"]),
        ("Pipeline", ["✓ CI run 14m", "✓ TestFlight · build 512", "◦ App Store · not sent"]),
        ("Assets", ["3 files · Open on GitHub"]),
        ("Lineage", ['<tspan fill="#C2410C">✦</tspan> Claude, Codex · $18.40', "41 sessions · lead time 19 h"]),
    ], 240)
    b.note(26, 1160, 162)
    b.note(27, 1160, 162 + 2 * 62 + 4)
    b.note(28, 1160, 162 + 3 * 62 + 24)
    b.note(29, 1160, py - 72)
    b.end()
    b.write("milestones-releases-mac.svg")


# Timeline ---------------------------------------------------------------------------------
EPICS = [
    # label, colour, lane (−3..3), start x, end x, dots, forecast end, waits
    ("Work look: the look of every Work page  #4327 · 5 of 9", "#AF52DE", -3, 120, None, [180, 260, 330, 420, 470], 690, False),
    ("forge interface  #4352 · 2 of 6", "#34C759", -2, 210, None, [300, 455], 760, False),
    ("Projects: folders, repos and people  #4250 · 11 of 16", "#007AFF", -1, 40, None, [90, 160, 240, 300, 380, 440], 640, False),
    ("more git hosts  #3606 · 46 of 47", "#FF2D55", 1, 40, 360, [120, 200, 300, 360], None, False),
    ("every integration on a real account  #3420 · 2 of 16", "#5856D6", 2, 40, None, [140], None, True),
    ("full autonomy  #3905 · 16 of 21", "#FF9500", 3, 150, None, [230, 350, 460], 820, False),
]


def timeline_plot(b, x, y, w, h, now=500, forecast=True, card=True):
    trunk = y + h / 2
    lane = h / 8
    b.rect(x + now, y, w - now, h, fill="#F6F7F8")
    for i in range(0, w, 100):
        b.line(x + i, y, x + i, y + h, "#EEF0F2")
    b.line(x, trunk, x + w, trunk, "#B8BDC4", 3)
    for rx, tag in ((260, "v0.41.0"), (430, "v0.42.0")):
        b.circle(x + rx, trunk, 7, "#FFFFFF", INK, 2.5)
        b.rect(x + rx - 30, trunk + 10, 60, 20, 10, fill=INK)
        b.text(x + rx, trunk + 24, tag, 11, "#FFF", 600, "middle")
    for label, c, ln, sx, ex, dots, fx, waits in EPICS:
        ly = trunk + ln * lane
        end = ex if ex else now
        b.path(f"M{x+sx-30} {trunk} C{x+sx-10} {trunk} {x+sx-20} {ly} {x+sx} {ly} L{x+end} {ly}"
               if sx > 60 else f"M{x+sx-40} {ly} L{x+end} {ly}", c, 2.5)
        if ex:
            b.path(f"M{x+ex} {ly} C{x+ex+20} {ly} {x+ex+10} {trunk} {x+ex+30} {trunk}", c, 2.5)
            b.circle(x + ex + 30, trunk, 6, c)
        for d in dots:
            b.circle(x + d, ly, 4.5, c)
        if not ex and forecast and fx:
            b.rect(x + fx - 60, ly - 6, 140, 12, 6, fill=c, op=0.15)
            b.path(f"M{x+now} {ly} L{x+fx} {ly} C{x+fx+20} {ly} {x+fx+10} {trunk} {x+fx+30} {trunk}", c, 2, "5 5")
            b.circle(x + (now + fx) / 2, ly, 4.5, "#FFFFFF", c, 2)
            b.circle(x + fx + 30, trunk, 6, "#FFFFFF", c, 2.5)
        if waits and forecast:
            b.path(f"M{x+now} {ly} L{x+now+40} {ly}", c, 2, "5 5")
            b.rect(x + now + 44, ly - 11, 120, 22, 11, fill="#FF9500")
            b.text(x + now + 104, ly + 4, "3 wait for Alex", 11.5, "#FFF", 600, "middle")
        if not forecast and not ex:
            b.path(f"M{x+now} {ly} L{x+w} {ly}", c, 2.5, op=0.0)
        name, rest = label.split("  ")
        b.text(x + max(sx, 40) + 4 - (0 if sx > 60 else 0), ly - 8,
               f'{"← " if sx <= 60 else ""}{name} <tspan fill="{FAINT}">{rest}</tspan>', 12.5, c, 600)
    b.line(x + now, y, x + now, y + h, "#FF3B30", 1.5)
    b.rect(x + now - 28, y + h + 4, 56, 20, 10, fill="#FF3B30")
    b.text(x + now, y + h + 18, "2:40 pm", 11, "#FFF", 600, "middle")
    for i, t in enumerate(("6 am", "8 am", "10 am", "12 pm", "2 pm", "4 pm", "6 pm", "8 pm", "10 pm")):
        if x + 40 + i * 100 < x + w:
            b.text(x + 50 + i * 100, y + h + 18, t, 11.5, FAINT, anchor="middle")
    if card:
        cx, cy = x + 700, trunk + 18
        b.rect(cx, cy, 340, 82, 8, fill="#FFFFFF", stroke=LINE)
        b.use("epic", cx + 12, cy + 12, 16, GREEN)
        b.text(cx + 36, cy + 25, "Projects: folders, repos and people", 13, INK, 600)
        b.chip(cx + 36, cy + 34, "epic", "#3E4B9E")
        b.chip(cx + 76, cy + 34, "feature:projects", "#1D76DB")
        b.text(cx + 36, cy + 70, "#4250 · 11 of 16 · closes about 5 pm · 3–9 pm, 8 in 10", 11.5, SEC)
    return trunk


def timeline():
    b = Board(1680, 980, "Timeline (#4334): the Mac window and the web page at 390 px",
              "What works stays (#4170, specs/time-stream/): the plot, the lines, the forecast. The bar, the hover card and the states take the shared parts. Not on the Remote (Alex, by design). Scratch data.")
    W = 1180
    b.window(24, 76, W, 860, ["Timeline"])
    b.note(30, W - 36, 64)
    b.text(24, 92, "Timeline", 21, INK, 600)
    b.text(124, 92, "alexec/Agents · 6 epics in these 2 days", 13, SEC)
    # the bar
    mx = 24
    mx += b.menu(mx, 112, "Project: Agents", True)
    mx += b.menu(mx, 112, "Board")
    b.note(31, 18, 104)
    sx = W - 400
    b.rect(sx, 108, 210, 26, 7, fill="#EEF0F3")
    b.rect(sx + 70, 110, 70, 22, 6, fill="#FFFFFF", stroke=LINE)
    for i, s in enumerate(("1 Day", "2 Days", "Week")):
        b.text(sx + 35 + 70 * i, 125, s, 12, INK, 600 if i == 1 else None, "middle")
    b.button(sx + 222, 107, "Now", h=28)
    b.rect(sx + 290, 113, 16, 16, 4, fill=ACC)
    b.use("tick", sx + 291, 114, 14, "#FFF")
    b.text(sx + 312, 126, "Forecast", 12.5, INK)
    b.note(32, sx - 14, 104)
    b.line(0, 148, W, 148)
    timeline_plot(b, 40, 190, 1100, 560)
    b.note(33, 40 + 700 + 350, 190 + 280 + 30)
    b.note(34, 40 + 430 + 40, 190 + 280 + 22)
    b.note(35, 40 + 500 + 190, 190 + 280 + 140)
    # legend
    b.line(0, 806, W, 806)
    for i, (s, kind) in enumerate((("Issue closed", "f"), ("Forecast", "h"), ("8 times in 10", "band"), ("Release", "r"), ("Now", "now"))):
        lx = 40 + 190 * i
        if kind == "f":
            b.circle(lx + 6, 834, 5, ACC)
        elif kind == "h":
            b.circle(lx + 6, 834, 5, "#FFF", ACC, 2)
        elif kind == "band":
            b.rect(lx, 828, 24, 12, 6, fill=ACC, op=0.15)
        elif kind == "r":
            b.circle(lx + 6, 834, 6, "#FFF", INK, 2.5)
        else:
            b.line(lx + 6, 824, lx + 6, 844, "#FF3B30", 1.5)
        b.text(lx + 32, 838, s, 12.5, SEC)
    b.end()

    # web at 390: the epics as a list
    b.phone(1250, 88, back=None, title=None)
    b.rect(0, 50, 390, 44, fill=BG2)
    b.text(16, 77, "☰  Agents", 15, INK, 600)
    b.use("refresh", 352, 64, 18, "#4A5059")
    b.text(20, 132, "Timeline", 28, INK, 700)
    b.note(36, 150, 122)
    cx = 16
    cx += b.capsule(cx, 148, "Project: Agents", True)
    cx += b.capsule(cx, 148, "2 Days")
    b.capsule(cx, 148, "Board")
    b.text(20, 208, "NOW · 2:40 PM", 11, "#FF3B30", 700)
    b.line(0, 216, 390, 216, "#FF3B30", 1)
    yy = 226
    for label, c, _ln, _sx, ex, _dots, fx, waits in sorted(EPICS, key=lambda e: (e[4] is not None, e[6] or 9999)):
        name, rest = label.split("  ")
        n, prog = rest.split(" · ")
        a, _, t = prog.split()
        b.rect(16, yy + 6, 4, 62, 2, fill=c)
        b.text(30, yy + 24, name if len(name) < 34 else name[:33] + "…", 14, INK, 600)
        b.bar(30, yy + 34, 200, int(a) / int(t), c)
        b.text(240, yy + 41, f"{a} of {t}", 12, SEC)
        if ex:
            when = "joined 9:40 am"
        elif waits:
            when = '<tspan fill="#C25E00">3 wait for Alex</tspan>'
        else:
            when = {640: "closes about 5 pm · 3–9 pm", 690: "closes about 6 pm · 4–11 pm",
                    760: "closes about 9 pm · tonight–tomorrow", 820: "closes about 11 pm · tomorrow"}[fx]
        b.text(30, yy + 62, f"{n} · {when}", 12, SEC)
        b.line(16, yy + 76, 374, yy + 76)
        yy += 80
    b.text(20, yy + 26, "Under 700 px the plot is a list of the epics, in the", 12, FAINT)
    b.text(20, yy + 44, "order they close. A tap opens the epic's Plan.", 12, FAINT)
    b.end()
    b.write("milestones-timeline.svg")


# Remote --------------------------------------------------------------------------------------
def remote():
    b = Board(1760, 1940, "Milestones and Releases (#4334): the Remote, iPhone and iPad",
              "The same Shared/UI views as the Mac. iPhone: the compact rows, the panel as rows; iPad: the wide page. The Remote has no Timeline (Alex, #4170). Scratch data.")
    # 1 milestones list
    b.phone(36, 92, "Work", "Milestones")
    b.search(16, 144, 358, "Filter milestones", 36)
    cx = 16
    for s, st in (("Project: Agents", True), ("Open", False), ("Repo", False), ("Sort", False)):
        cx += b.capsule(cx, 192, s, st)
    yy = 236
    for m in MILESTONES:
        title, due, due_c, op, cl, cost, ses, _ = m
        b.use("flag", 16, yy + 14, 16, GREEN)
        b.text(42, yy + 28, title, 15, INK, 600)
        b.text(374, yy + 28, f"{round(cl / (op + cl) * 100)}%", 13, SEC, 600, "end")
        b.bar(42, yy + 40, 332, cl / (op + cl), GREEN)
        b.text(42, yy + 66, f'<tspan fill="{due_c}">{due.replace("Due ", "")}</tspan> · {op} open · {cost}', 13, SEC)
        b.line(16, yy + 82, 390, yy + 82)
        yy += 84
    b.end()
    b.note(40, 36 + 200, 80)
    # 2 milestone page
    b.phone(456, 92, "Milestones", None)
    b.text(20, 128, "Projects", 28, INK, 700)
    pw = b.pill(20, 142, "Open", GREEN, "flag")
    b.text(30 + pw, 159, "Due Fri 14 Nov · 72%", 13, SEC)
    b.bar(20, 180, 350, 46 / 64, GREEN, 8)
    b.text(20, 210, "18 open · 46 closed", 13, SEC)
    b.rect(16, 224, 358, 132, 10, fill=BG2)
    for i, (k, v) in enumerate((("Repo", "alexec/Agents"), ("Released in", "0.41.0, 0.42.0"), ("Lineage", "✦ $41.20 · 37 sessions"))):
        b.text(30, 254 + 44 * i, k, 14, INK)
        b.text(344, 254 + 44 * i, v.replace("✦", '<tspan fill="#C2410C">✦</tspan>'), 14, SEC, anchor="end")
        b.use("chevr", 352, 245 + 44 * i, 10, FAINT)
        if i < 2:
            b.line(30, 270 + 44 * i, 374, 270 + 44 * i)
    b.rect(16, 370, 358, 32, 8, fill="#EEF0F3")
    b.rect(18, 372, 177, 28, 7, fill="#FFFFFF")
    b.text(106, 391, "18 Open", 13, INK, 600, "middle")
    b.text(284, 391, "46 Closed", 13, SEC, anchor="middle")
    b.text(20, 432, "EPICS", 11, FAINT, 600)
    yy = 440
    for t, of in (("Projects: folders, repos and people", (11, 16)), ("Projects: the project's own page", (3, 9))):
        b.use("epic", 16, yy + 12, 16, GREEN)
        b.text(42, yy + 26, t, 14.5, INK, 600)
        b.bar(42, yy + 38, 260, of[0] / of[1], GREEN)
        b.text(374, yy + 45, f"{of[0]} of {of[1]}", 12, SEC, anchor="end")
        b.line(16, yy + 60, 390, yy + 60)
        yy += 62
    b.text(20, yy + 22, "ISSUES AND PULL REQUESTS", 11, FAINT, 600)
    yy += 30
    for it in ITEMS[:3]:
        glyph, c, title, chips, l2 = it
        b.use(glyph, 16, yy + 12, 16, c)
        b.text(42, yy + 26, title if len(title) < 36 else title[:35] + "…", 14.5, INK, 600)
        cx = 42
        for name, col in chips:
            cx += b.chip(cx, yy + 34, name, col) + 4
        b.text(42, yy + 72, l2.split(" · ")[0] + " · " + l2.split(" · ")[1].replace("opened ", "").replace(" ago", "").split(" by")[0], 13, SEC)
        b.line(16, yy + 86, 390, yy + 86)
        yy += 88
    b.end()
    b.note(41, 456 + 200, 80)
    # 3 releases list
    b.phone(876, 92, "Work", "Releases")
    b.search(16, 144, 358, "Filter releases", 36)
    cx = 16
    for s, st in (("Project: Agents", True), ("Kind: All", False), ("Sort", False)):
        cx += b.capsule(cx, 192, s, st)
    yy = 236
    for r in RELEASES:
        name, chip, when, prs, cost, pipe = r
        b.use("box", 16, yy + 14, 16, GREY if chip and chip[0] == "Draft" else INK)
        b.text(42, yy + 28, name, 15, INK, 600)
        if chip:
            b.chip(50 + width(name, 15, 600), yy + 15, chip[0], chip[1])
        if pipe:
            b.use("tick", 354, yy + 16, 14, GREEN)
        short = when.replace("released ", "").replace(" ago by alexec", "")
        b.text(42, yy + 52, f"{short} · {prs} PRs · {cost}", 13, SEC)
        b.line(16, yy + 68, 390, yy + 68)
        yy += 70
    b.end()
    b.note(42, 876 + 200, 80)
    # 4 release page
    b.phone(1296, 92, "Releases", None)
    b.text(20, 128, "0.42.0", 28, INK, 700)
    b.chip(124, 108, "Latest", GREEN, 12)
    b.text(20, 156, "alexec · 2 h · 23 pull requests", 13, SEC)
    b.rect(16, 172, 358, 176, 10, fill=BG2)
    for i, (k, v) in enumerate((("Tag", "v0.42.0"), ("Milestones finished", "2"), ("Pipeline", "✓ TestFlight"), ("Lineage", "✦ $18.40"))):
        b.text(30, 202 + 44 * i, k, 14, INK)
        b.text(344, 202 + 44 * i, v.replace("✦", '<tspan fill="#C2410C">✦</tspan>').replace("✓", f'<tspan fill="{GREEN}">✓</tspan>'), 14, SEC, anchor="end")
        b.use("chevr", 352, 193 + 44 * i, 10, FAINT)
        if i < 3:
            b.line(30, 218 + 44 * i, 374, 218 + 44 * i)
    b.text(20, 382, "Milestones finished", 17, INK, 600)
    b.text(20, 408, "•  Lineage and value", 14.5)
    b.text(20, 430, "•  Work ▸ Timeline", 14.5)
    b.text(20, 466, "What's new", 17, INK, 600)
    b.text(20, 492, "•  Work ▸ Timeline: the epics on a time", 14.5)
    b.text(34, 512, "axis, with Now in the centre (#4173)", 14.5)
    b.text(20, 534, "•  Forge: one interface for every forge", 14.5)
    b.rect(16, 560, 358, 44, 10, fill=BG2)
    b.text(30, 588, "Pull requests", 14, INK)
    b.text(344, 588, "23", 14, SEC, anchor="end")
    b.use("chevr", 352, 579, 10, FAINT)
    b.text(20, 640, "The notes first; the pull requests are a", 12, FAINT)
    b.text(20, 658, "row that pushes their list.", 12, FAINT)
    b.end()
    b.note(43, 1296 + 200, 80)
    # iPad landscape: milestone page wide
    b.group(36, 1000)
    W, H = 1180, 820
    b.rect(-14, -14, W + 28, H + 28, 30, fill="#1C1D20")
    b.rect(0, 0, W, H, 18, fill="#FFFFFF")
    b.rect(0, 0, 300, H, fill=BG2)
    b.text(20, 40, "Work", 13, SEC, 600)
    for i, (s, sym) in enumerate((("Issues", "open"), ("Pull requests", "pr"), ("Features", "spark"), ("Milestones", "flag"), ("Releases", "box"))):
        if i == 3:
            b.rect(10, 56 + 40 * i, 280, 34, 8, fill=ACC)
        col = "#FFF" if i == 3 else INK
        b.use(sym, 24, 65 + 40 * i, 16, "#FFF" if i == 3 else ACC)
        b.text(50, 78 + 40 * i, s, 15, col)
    b.text(20, 290, "No Timeline row on the Remote", 12, FAINT)
    b.text(20, 308, "(Alex, #4170).", 12, FAINT)
    b.use("back", 316, 24, 18, ACC)
    b.text(338, 38, "Milestones", 16, ACC)
    b.text(740, 38, "Projects", 16, INK, 600, "middle")
    b.use("refresh", W - 40, 22, 18, ACC)
    b.text(320, 96, "Projects", 24, INK, 700)
    pw = b.pill(320, 110, "Open", GREEN, "flag")
    b.text(330 + pw, 127, "Due Fri 14 Nov · 72% complete · 18 open · 46 closed", 13, SEC)
    b.bar(320, 148, 600, 46 / 64, GREEN, 8)
    yy = 176
    b.text(320, yy + 16, "EPICS", 11, FAINT, 600)
    yy += 24
    for t, of in (("Projects: folders, repos and people in one place", (11, 16)), ("Projects: the project's own page", (3, 9))):
        b.use("epic", 324, yy + 11, 16, GREEN)
        b.text(350, yy + 24, t, 14, INK, 600)
        b.bar(760, yy + 15, 110, of[0] / of[1], GREEN)
        b.text(918, yy + 24, f"{of[0]} of {of[1]}", 12.5, SEC, anchor="end")
        b.line(320, yy + 56, 920, yy + 56)
        yy += 58
    yy += 10
    for it in ITEMS:
        item_row(b, 320, yy, 600, (it[0], it[1], it[2] if len(it[2]) < 46 else it[2][:45] + "…", it[3][:1], it[4]))
        yy += 58
    panel(b, 944, 100, [("Due date", ["Fri 14 Nov 2026"]), ("Repo", ["alexec/Agents"]),
                        ("Released in", ["0.41.0", "0.42.0"]), ("Lineage", ['<tspan fill="#C2410C">✦</tspan> $41.20', "37 sessions"])], 210)
    b.end()
    b.note(44, 36 + 600, 988)
    b.write("milestones-remote.svg")


# Web ------------------------------------------------------------------------------------------
def web():
    b = Board(1380, 1880, "Milestones and Releases (#4334): the web page, wide and 390 px",
              "Web/src/views/Work.tsx with the same parts in CSS, at the break points of #4328 (700 px and 900 px). Scratch data.")
    W, H = 1280, 760
    b.group(24, 76)
    b.rect(0, 0, W, H, 10, fill="#FFFFFF")
    b.rect(0, 0, W, 40, fill="#EEF0F3")
    b.rect(120, 8, 640, 24, 12, fill="#FFFFFF")
    b.text(136, 25, "agents.local/#/work/releases/alexec%2FAgents/v0.42.0", 12, SEC, family=MONO)
    b.rect(0, 40, 220, H - 40, fill=BG2)
    b.text(20, 72, "WORK", 11, FAINT, 600)
    for i, (s, sym) in enumerate((("Issues", "open"), ("Pull requests", "pr"), ("Features", "spark"), ("Milestones", "flag"), ("Releases", "box"), ("Timeline", "stream"))):
        if i == 4:
            b.rect(10, 84 + 34 * i, 200, 30, 6, fill="#DCEBFC")
        b.use(sym, 22, 91 + 34 * i, 16, ACC)
        b.text(46, 104 + 34 * i, s, 13.5, ACC if i == 4 else INK, 600 if i == 4 else None)
    X = 244
    b.text(X, 74, "Releases / 0.42.0", 13, SEC)
    b.rect(W - 46, 56, 28, 26, 6, fill="#EDEFF2")
    b.use("refresh", W - 40, 61, 16, "#4A5059")
    b.text(X, 110, "0.42.0", 22, INK, 600)
    b.chip(X + 84, 94, "Latest", GREEN, 12)
    b.text(W - 24, 108, "Open on GitHub", 12.5, ACC, anchor="end")
    b.text(X, 136, f'<tspan font-weight="600" fill="{INK}">alexec</tspan> released this 2 h ago · <tspan font-family="{MONO}">v0.41.0…v0.42.0</tspan> · 23 pull requests', 12.5, SEC)
    b.line(X, 152, W - 24, 152)
    b.rect(X, 168, 740, 200, 6, fill="#FFFFFF", stroke=LINE)
    b.text(X + 16, 196, "Milestones finished", 15, INK, 600)
    b.text(X + 16, 220, "•  Lineage and value     •  Work ▸ Timeline", 13.5)
    b.text(X + 16, 252, "What's new", 15, INK, 600)
    b.text(X + 16, 276, "•  Work ▸ Timeline: the epics on a time axis, with Now in the centre (#4173)", 13.5)
    b.text(X + 16, 298, "•  Forge: one interface for every forge (#4352)", 13.5)
    b.text(X + 16, 330, "Fixes", 15, INK, 600)
    b.text(X + 16, 354, "•  The Remote's sidebar keeps its place after a reconnect (#4296)", 13.5)
    b.text(X, 396, "PULL REQUESTS IN THIS RELEASE", 11, FAINT, 600)
    b.search(X, 406, 200, "Filter pull requests")
    b.line(X, 446, X + 740, 446)
    yy = 446
    for t, ch, l2 in (("Work ▸ Timeline: the epics in time on the Mac", [("enhancement", "#A2EEEF")], "#4188 · merged 1 d ago · ✦ Claude · $4.10"),
                      ("Forge interface: Forge, forgeCaps and the registry", [("task", "#C5DEF5")], "#4411 · merged 5 h ago · ✦ Codex · $2.35"),
                      ("Remote: the sidebar keeps its place after a reconnect", [("bug", "#D73A4A")], "#4296 · merged 7 h ago · ✦ Claude · $0.62")):
        item_row(b, X, yy, 740, ("merged", PURPLE, t, ch, l2))
        yy += 58
    b.rect(X + 290, yy + 14, 160, 30, 6, fill="#FFFFFF", stroke="#C7CCD3")
    b.text(X + 370, yy + 34, "Load more", 12.5, INK, 500, "middle")
    panel(b, X + 770, 178, [
        ("Tag", [f'<tspan font-family="{MONO}">v0.42.0</tspan> · bf6f4dd']),
        ("Milestones finished", ["⚑ Lineage and value", "⚑ Work ▸ Timeline"]),
        ("Pipeline", ["✓ CI run 14m", "✓ TestFlight · build 512"]),
        ("Assets", ["3 files · Open on GitHub"]),
        ("Lineage", ['<tspan fill="#C2410C">✦</tspan> Claude, Codex · $18.40', "41 sessions"]),
    ], 230)
    b.end()
    b.note(50, 24 + 1280 - 20, 64)
    # three 390 px pages
    for i, which in enumerate(("list", "page", "release")):
        b.phone(36 + 440 * i, 900)
        b.rect(0, 50, 390, 44, fill=BG2)
        b.text(16, 77, "☰  Agents", 15, INK, 600)
        b.use("refresh", 352, 64, 18, "#4A5059")
        if which == "list":
            b.text(20, 132, "Milestones", 28, INK, 700)
            b.search(16, 148, 358, "Filter milestones", 34)
            cx = 16
            for s, st in (("Project: Agents", True), ("Open", False), ("Repo", False), ("Sort", False)):
                cx += b.capsule(cx, 192, s, st)
            yy = 234
            for m in MILESTONES:
                title, due, due_c, op, cl, cost, ses, _ = m
                b.use("flag", 16, yy + 14, 16, GREEN)
                b.text(42, yy + 28, title, 15, INK, 600)
                b.text(374, yy + 28, f"{round(cl / (op + cl) * 100)}%", 13, SEC, 600, "end")
                b.bar(42, yy + 40, 332, cl / (op + cl), GREEN)
                b.text(42, yy + 66, f'<tspan fill="{due_c}">{due.replace("Due ", "")}</tspan> · {op} open · {cost}', 13, SEC)
                b.line(16, yy + 82, 390, yy + 82)
                yy += 84
        elif which == "page":
            b.text(20, 116, "Milestones / Projects", 13, SEC)
            b.text(20, 150, "Projects", 26, INK, 700)
            pw = b.pill(20, 164, "Open", GREEN, "flag")
            b.text(30 + pw, 181, "Due Fri 14 Nov · 72%", 13, SEC)
            b.bar(20, 202, 350, 46 / 64, GREEN, 8)
            b.rect(16, 222, 358, 90, 8, fill=BG2)
            for j, (k, v) in enumerate((("Released in", "0.41.0, 0.42.0"), ("Lineage", "✦ $41.20 · 37 sessions"))):
                b.text(30, 250 + 44 * j, k, 14, INK)
                b.text(360, 250 + 44 * j, v.replace("✦", '<tspan fill="#C2410C">✦</tspan>'), 14, SEC, anchor="end")
            b.line(30, 268, 374, 268)
            cx = 16
            for s, st in (("18 Open", True), ("Kind: All", False), ("Label", False), ("Sort", False)):
                cx += b.capsule(cx, 326, s, st)
            yy = 370
            for it in ITEMS:
                glyph, c, title, chips, l2 = it
                b.use(glyph, 16, yy + 12, 16, c)
                b.text(42, yy + 26, title if len(title) < 36 else title[:35] + "…", 14.5, INK, 600)
                cx = 42
                for name, col in chips:
                    cx += b.chip(cx, yy + 34, name, col) + 4
                b.text(42, yy + 72, l2.split(" · ")[0], 13, SEC)
                b.line(16, yy + 86, 390, yy + 86)
                yy += 88
        else:
            b.text(20, 132, "Releases", 28, INK, 700)
            b.search(16, 148, 358, "Filter releases", 34)
            yy = 196
            for r in RELEASES:
                name, chip, when, prs, cost, pipe = r
                b.use("box", 16, yy + 14, 16, GREY if chip and chip[0] == "Draft" else INK)
                b.text(42, yy + 28, name, 15, INK, 600)
                if chip:
                    b.chip(50 + width(name, 15, 600), yy + 15, chip[0], chip[1])
                if pipe:
                    b.use("tick", 354, yy + 16, 14, GREEN)
                short = when.replace("released ", "").replace(" ago by alexec", "")
                b.text(42, yy + 52, f"{short} · {prs} PRs · {cost}", 13, SEC)
                b.line(16, yy + 68, 390, yy + 68)
                yy += 70
            b.text(20, yy + 30, "A row is a link: ⌘-click opens it in a new tab.", 12, FAINT)
        b.end()
    b.note(51, 36 + 200, 888)
    b.note(52, 476 + 200, 888)
    b.write("milestones-web.svg")


# States -------------------------------------------------------------------------------------
def states():
    b = Board(1320, 1440, "Milestones, Releases and Timeline (#4334): the states, on the Mac window",
              "The Remote and the web page show the same states in their own layout. Numbers match the States table in milestones.md.")
    TW, TH = 410, 300
    tiles = []

    def tile(n, title):
        i = len(tiles)
        tiles.append(n)
        x, y = 24 + (TW + 20) * (i % 3), 76 + (TH + 30) * (i // 3)
        b.group(x, y)
        b.rect(0, 0, TW, TH, 10, fill="#FFFFFF")
        b.rect(0, 0, TW, 32, fill=BG2)
        b.line(0, 32, TW, 32)
        b.text(12, 21, title, 12, INK, 600)
        b.note(n, TW - 16, 16)

    def done():
        b.end()

    tile("S1", "Milestones · loading, first read")
    for j in range(5):
        b.placeholder(16, 50 + 46 * j, TW - 40)
    done()
    tile("S2", "Milestones · empty, no filter")
    b.use("flag", TW / 2 - 14, 110, 28, FAINT)
    b.text(TW / 2, 170, "No open milestones", 15, INK, 600, "middle")
    b.text(TW / 2, 192, "Milestones on alexec/Agents show here.", 12.5, SEC, anchor="middle")
    done()
    tile("S3", "Milestones · no forge here has milestones")
    b.use("flag", TW / 2 - 14, 90, 28, FAINT)
    b.text(TW / 2, 150, "Linear and Jira have no milestones", 15, INK, 600, "middle")
    b.text(TW / 2, 172, "Milestones come from GitHub, GitLab, Forgejo", 12.5, SEC, anchor="middle")
    b.text(TW / 2, 190, "and Bitbucket repos in your projects.", 12.5, SEC, anchor="middle")
    b.button(TW / 2 - 85, 210, "Settings ▸ Connectors")
    done()
    tile("S4", "Milestones · error, with rows")
    b.rect(12, 44, TW - 24, 36, 6, fill="#FFF4E5", stroke="#F0C27A")
    b.use("warn", 22, 54, 16, AMBER)
    b.text(44, 67, "GitHub said 401 Bad credentials", 12.5, INK)
    b.text(TW - 24, 67, "Try again", 12.5, ACC, 500, "end")
    b.raw('<g opacity="0.45">')
    for j, m in enumerate(MILESTONES[:3]):
        ms_row(b, 0, 92 + 62 * j, TW, (m[0], m[1], m[2], m[3], m[4], m[5], m[6], ""), short=True)
    b.raw("</g>")
    done()
    tile("S5", "Milestones · past due, no due date, closed")
    ms_row(b, 0, 40, TW, ("Lineage and value", "Past due by 2 days", RED, 1, 40, "$63.75", 52, ""), short=True)
    ms_row(b, 0, 102, TW, ("1.0 Public release", "No due date", FAINT, 31, 12, "$12.40", 11, ""), short=True)
    ms_row(b, 0, 164, TW, ("Voice mode", "", SEC, 0, 38, "$51.10", 40, ""), closed=True, short=True)
    b.text(12, 254, "State: All shows open and closed together;", 12, FAINT)
    b.text(12, 272, "a closed one has the purple flag and bar.", 12, FAINT)
    done()
    tile("S6", "Milestone page · closed")
    b.text(16, 66, "Auto runtime and voice mode", 17, INK, 600)
    pw = b.pill(16, 78, "Closed", PURPLE, "flag")
    b.text(26 + pw, 95, "Closed 3 d ago · 38 closed", 12.5, SEC)
    b.bar(16, 116, TW - 32, 1, PURPLE, 8)
    b.text(16, 150, "Finished in 0.40.0", 12.5, SEC)
    item_row(b, 16, 160, TW - 32, ("done", PURPLE, "Voice mode: push to talk", [], "#3840 · closed 4 d ago · $3.20"))
    item_row(b, 16, 218, TW - 32, ("notplanned", GREY, "Voice mode on the Remote", [], "#3851 · closed 5 d ago · not planned"))
    done()
    tile("S7", "Releases · draft, pre-release, latest")
    for j, r in enumerate((RELEASES[0], RELEASES[4], RELEASES[1])):
        rel_row(b, 0, 40 + 62 * j, TW, (r[0], r[1], r[2].replace(" by alexec", ""), r[3], r[4], r[5]))
    b.text(12, 254, "A draft shows only to a machine that can write", 12, FAINT)
    b.text(12, 272, "to the repo; it is first, before the newest.", 12, FAINT)
    done()
    tile("S8", "Release page · no notes, pipeline running")
    b.text(16, 66, "0.43.0", 17, INK, 600)
    b.chip(84, 52, "Pre-release", AMBER)
    b.text(16, 92, "alexec released this 5 min ago · 6 pull requests", 12.5, SEC)
    b.rect(16, 106, TW - 32, 54, 6, fill=BG2)
    b.text(TW / 2, 138, "No release notes.", 12.5, FAINT, anchor="middle")
    b.text(16, 186, "Pipeline", 12, SEC, 600)
    b.use("dot", 16, 196, 14, AMBER)
    b.text(36, 208, "CI run · running 6m", 12.5)
    b.use("dot", 16, 218, 14, FAINT)
    b.text(36, 230, "TestFlight · waits for the CI run", 12.5, SEC)
    done()
    tile("S9", "Releases · empty")
    b.use("box", TW / 2 - 14, 100, 28, FAINT)
    b.text(TW / 2, 160, "No releases yet", 15, INK, 600, "middle")
    b.text(TW / 2, 182, "A tag with a release on alexec/Agents shows here.", 12.5, SEC, anchor="middle")
    done()
    tile("S10", "Timeline · loading")
    b.line(16, 166, TW - 16, 166, "#E6E8EB", 3)
    for ly, x1, x2 in ((80, 60, 300), (120, 30, 240), (210, 100, 380), (250, 40, 200)):
        b.rect(x1, ly - 4, x2 - x1, 8, 4, fill="#E6E8EB")
    b.line(260, 40, 260, 290, "#FF3B30", 1.5)
    b.text(TW / 2, 290, "The lanes shimmer; Now is drawn at once.", 11.5, FAINT, anchor="middle")
    done()
    tile("S11", "Timeline · no epic in these 2 days")
    b.line(16, 166, TW - 16, 166, "#B8BDC4", 3)
    b.line(TW / 2, 40, TW / 2, 290, "#FF3B30", 1.5)
    b.rect(60, 92, TW - 120, 56, 8, fill="#FFFFFF", stroke=LINE)
    b.text(TW / 2, 114, "No epic in these 2 days", 13.5, INK, 600, "middle")
    b.text(TW / 2, 134, "The last one joined 4 d ago.", 12, SEC, anchor="middle")
    b.button(TW / 2 - 76, 196, "Show the week")
    done()
    tile("S12", "Timeline · no project, or an error")
    b.use("stream", TW / 2 - 14, 60, 28, FAINT)
    b.text(TW / 2, 116, "No project to draw", 15, INK, 600, "middle")
    b.text(TW / 2, 138, "The Timeline draws a project's epics. Add a", 12.5, SEC, anchor="middle")
    b.text(TW / 2, 156, "folder to a project in Settings ▸ Projects.", 12.5, SEC, anchor="middle")
    b.rect(12, 196, TW - 24, 36, 6, fill="#FFF4E5", stroke="#F0C27A")
    b.use("warn", 22, 206, 16, AMBER)
    b.text(44, 219, "MacBook: work/timeline timed out", 12.5, INK)
    b.text(TW - 24, 219, "Try again", 12.5, ACC, 500, "end")
    b.text(TW / 2, 260, "An error: the strip over the last plot, dimmed.", 11.5, FAINT, anchor="middle")
    done()
    b.write("milestones-states.svg")


if __name__ == "__main__":
    mac_milestones()
    mac_releases()
    timeline()
    remote()
    web()
    states()
