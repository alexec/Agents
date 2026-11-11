#!/usr/bin/env python3
"""Draws the boards of wireframe.md (#4448): python3 boards.py, in this folder.

Scratch data. Paper palette, light mode, the glyphs and the chrome of the Work look boards
(specs/4328-work-look), so the archived pages agree with the Work pages.
"""
from pathlib import Path

HERE = Path(__file__).parent
INK, SEC, FAINT, LINE, BG2, PAGE = "#1C1D20", "#5B616B", "#8A9099", "#E0E3E7", "#F6F7F8", "#E7EAEE"
SIDEBAR, WASH, RAISED, GROUND = "#F0F1F3", "#E7EAEE", "#FFFFFF", "#F7F8F9"
ACC, GREEN, GREY, RED, NOTE, ISSUE, PULL = "#0A6CDB", "#1A7F37", "#6E7781", "#CF222E", "#B35900", "#0E6B82", "#7442B8"
SEL = "#DCEBFC"

SYMBOLS = """
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">
      <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#20242A" flood-opacity="0.14"/>
    </filter>
    <symbol id="box" viewBox="0 0 16 16"><path d="M2.5 3.5h11v3h-11zM3.5 6.5v6h9v-6M6.5 9h3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" stroke-linecap="round"/></symbol>
    <symbol id="search" viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M10.5 10.5L14 14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></symbol>
    <symbol id="chev" viewBox="0 0 10 10"><path d="M2 3.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="chevr" viewBox="0 0 10 10"><path d="M3.5 2l3 3-3 3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="back" viewBox="0 0 16 16"><path d="M10 3L5 8l5 5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="fwd" viewBox="0 0 16 16"><path d="M6 3l5 5-5 5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="plus" viewBox="0 0 16 16"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></symbol>
    <symbol id="tick" viewBox="0 0 16 16"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="pause" viewBox="0 0 16 16"><path d="M5.5 4v8M10.5 4v8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></symbol>
    <symbol id="ring" viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.5" fill="none" stroke="currentColor" stroke-width="1.5"/></symbol>
    <symbol id="rack" viewBox="0 0 16 16"><rect x="2.5" y="3" width="11" height="4" rx="1" fill="none" stroke="currentColor" stroke-width="1.3"/><rect x="2.5" y="9" width="11" height="4" rx="1" fill="none" stroke="currentColor" stroke-width="1.3"/></symbol>
    <symbol id="flow" viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M8 4.5V8l2.5 1.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></symbol>
    <symbol id="warn" viewBox="0 0 16 16"><path d="M8 2.2L14.3 13.5H1.7z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/><path d="M8 6.5v3.2" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="11.6" r=".8" fill="currentColor"/></symbol>
    <symbol id="spin" viewBox="0 0 16 16"><path d="M8 2a6 6 0 1 1-6 6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></symbol>
    <symbol id="cross" viewBox="0 0 16 16"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></symbol>
    <symbol id="hand" viewBox="0 0 16 16"><path d="M5 8V3.5a1 1 0 0 1 2 0V7M7 7V2.5a1 1 0 0 1 2 0V7M9 7V3.5a1 1 0 0 1 2 0V8.5M11 8.5V5a1 1 0 0 1 2 0v4.5c0 3-2 4.5-4.5 4.5S4.5 12.5 4 10L3 7.5a1 1 0 0 1 1.9-.6L5 8" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></symbol>
    <symbol id="sparkles" viewBox="0 0 16 16"><path d="M6.5 2.5l1.2 3.3 3.3 1.2-3.3 1.2-1.2 3.3-1.2-3.3L2 7l3.3-1.2zM12 9.5l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6z" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/></symbol>
    <symbol id="doc" viewBox="0 0 16 16"><path d="M4 1.8h5.2L12.5 5v9.2H4zM9 1.8V5.2h3.5M6 8h4.5M6 10.5h4.5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></symbol>
"""


def width(s, size=13, weight=None):
    return len(s) * size * (0.56 if weight and weight >= 600 else 0.52)


class Board:
    def __init__(self, w, h, title, sub):
        self.w, self.h, self.o = w, h, []
        self.rect(0, 0, w, h, fill=PAGE)
        self.text(24, 34, title, 15, weight=600)
        self.text(24, 54, sub, 12, SEC)

    def raw(self, s):
        self.o.append("  " + s)

    def rect(self, x, y, w, h, rx=0, fill="none", stroke=None, sw=1, op=None, dash=None):
        a = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        a += f' fill-opacity="{op}"' if op is not None else ""
        a += f' stroke-dasharray="{dash}"' if dash else ""
        self.raw(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{a}/>')

    def line(self, x1, y1, x2, y2, stroke=LINE, sw=1):
        self.raw(f'<path d="M{x1} {y1}L{x2} {y2}" stroke="{stroke}" stroke-width="{sw}" fill="none"/>')

    def circle(self, cx, cy, r, fill="none", stroke=None, sw=1.5):
        s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        self.raw(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"{s}/>')

    def text(self, x, y, s, size=13, fill=INK, weight=None, anchor=None, op=None, italic=False):
        a = f' font-weight="{weight}"' if weight else ""
        a += f' text-anchor="{anchor}"' if anchor else ""
        a += f' opacity="{op}"' if op is not None else ""
        a += ' font-style="italic"' if italic else ""
        s = s.replace("&", "&amp;").replace("<", "&lt;")
        self.raw(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}"{a}>{s}</text>')

    def use(self, sym, x, y, size=16, color=INK):
        self.raw(f'<use href="#{sym}" x="{x}" y="{y}" width="{size}" height="{size}" color="{color}"/>')

    def group(self, x, y, shadow=True, op=None, clip=None):
        f = ' filter="url(#shadow)"' if shadow else ""
        o = f' opacity="{op}"' if op is not None else ""
        self.raw(f'<g transform="translate({x},{y})"{f}{o}>')

    def end(self):
        self.raw("</g>")

    def note(self, n, x, y):
        self.circle(x, y, 9, NOTE)
        self.text(x, y + 4, str(n), 11, "#FFF", 700, "middle")

    def chip(self, x, y, s, color, size=10.5):
        w = width(s, size) + 10
        self.rect(x, y, w, 16, 8, fill=color, op=0.14)
        self.rect(x, y, w, 16, 8, stroke=color, sw=0.8)
        self.text(x + 5, y + 11.5, s, size, color, 500)
        return w

    def search(self, x, y, w, s, h=26, fill="#FFFFFF"):
        self.rect(x, y, w, h, 7, fill=fill, stroke="#C7CCD3")
        self.use("search", x + 8, y + h / 2 - 7, 14, FAINT)
        self.text(x + 28, y + h / 2 + 4.5, s, 12.5, FAINT)

    def button(self, x, y, s, primary=False, h=26):
        w = width(s, 12.5, 500) + 24
        self.rect(x, y, w, h, 7, fill=ACC if primary else "#FFFFFF", stroke=None if primary else "#C7CCD3")
        self.text(x + 12, y + h / 2 + 4.5, s, 12.5, "#FFF" if primary else INK, 500)
        return w

    # ---- Mac window ----
    def mac_window(self, w, h, title, subtitle, sidebar_w=240, search=None, back=True):
        self.rect(0, 0, w, h, 12, fill=RAISED)
        self.raw(f'<path d="M12 0h{w - 24}a12 12 0 0 1 12 12v52H0V12A12 12 0 0 1 12 0z" fill="{BG2}"/>')
        self.rect(0, 0, sidebar_w, h, 12, fill=SIDEBAR)
        self.rect(sidebar_w - 12, 0, 12, h, fill=SIDEBAR)
        self.line(0, 52, w, 52)
        self.line(sidebar_w, 0, sidebar_w, h)
        for i, c in enumerate(("#FF5F57", "#FEBC2E", "#28C840")):
            self.circle(20 + i * 20, 20, 6, c)
        if back:
            self.use("back", sidebar_w + 16, 18, 16, FAINT)
            self.use("fwd", sidebar_w + 36, 18, 16, "#C7CCD3")
        self.text(sidebar_w + 68, 26, title, 14, INK, 600)
        self.text(sidebar_w + 68, 42, subtitle, 11.5, SEC)
        if search:
            self.search(w - 236, 13, 220, search, fill="#FFFFFF")

    def sb_fold(self, x, y, s, count=None, open_=True, indent=0):
        self.use("chev" if open_ else "chevr", x + indent + 4, y + 5, 10, FAINT)
        self.text(x + indent + 22, y + 14, s, 12.5, INK, 500)
        if count is not None:
            self.text(x + 218, y + 14, str(count), 11.5, FAINT, anchor="end")

    def sb_session(self, x, y, s, mark="tick", color=SEC, indent=22, bold=False):
        self.use(mark, x + indent + 1, y + 3, 14, color)
        self.text(x + indent + 22, y + 14, s, 12.5, INK, 600 if bold else None)

    def sb_page(self, x, y, s, sym, selected=False, indent=0, w=224):
        if selected:
            self.rect(x - 8, y - 3, w, 24, 6, fill=SEL)
        self.use(sym, x + indent + 1, y + 3, 14, ACC)
        self.text(x + indent + 22, y + 14, s, 12.5, INK)

    # ---- list parts ----
    def day_head(self, x, y, w, s, size=11.5):
        self.text(x, y + 12, s, size, SEC, 600)

    def session_row(self, x, y, w, title, line, time, labels=(), hover=False, pad=0):
        if hover:
            self.rect(x - 8, y - 6, w + 16, 44, 6, fill=WASH)
        self.use("box", x + pad, y + 2, 14, FAINT)
        self.text(x + pad + 22, y + 13, title, 13, INK)
        tx = x + pad + 22 + width(title, 13) + 8
        for s, c in labels:
            tx += self.chip(tx, y + 1, s, c) + 5
        self.text(x + w, y + 13, time, 11.5, FAINT, anchor="end")
        self.text(x + pad + 22, y + 29, line, 11.5, SEC)
        self.line(x + pad + 22, y + 38, x + w, y + 38)

    def workflow_row(self, x, y, w, name, line, time, sym="pause", color=FAINT, pad=0):
        self.use(sym, x + pad, y + 2, 14, color)
        self.text(x + pad + 22, y + 13, name, 13, INK)
        self.text(x + w, y + 13, time, 11.5, FAINT, anchor="end")
        self.text(x + pad + 22, y + 29, line, 11.5, SEC)
        self.line(x + pad + 22, y + 38, x + w, y + 38)

    def skeleton_row(self, x, y, w, pad=0):
        self.circle(x + pad + 7, y + 9, 7, "#E6E8EB")
        self.rect(x + pad + 22, y + 3, w * 0.45, 10, 5, fill="#E6E8EB")
        self.rect(x + pad + 22, y + 21, w * 0.7, 8, 4, fill="#EEF0F2")
        self.line(x + pad + 22, y + 38, x + w, y + 38)

    def footer(self, x, y, w, s, link=None):
        self.text(x, y + 12, s, 11.5, SEC)
        if link:
            self.text(x + width(s, 11.5) + 10, y + 12, link, 11.5, ACC, 500)

    # ---- iPhone ----
    def phone(self, w, h, title, subtitle=None, back="Agents", search=None, large=True):
        self.rect(0, 0, w, h, 34, fill="#1C1D20")
        self.rect(8, 8, w - 16, h - 16, 28, fill=GROUND)
        self.rect(w / 2 - 50, 16, 100, 26, 13, fill="#1C1D20")
        self.use("back", 20, 60, 16, ACC)
        self.text(38, 72, back, 14, ACC)
        if large:
            self.text(24, 112, title, 26, INK, 700)
            if subtitle:
                self.text(24, 130, subtitle, 12.5, SEC)
        else:
            self.text(w / 2, 72, title, 15, INK, 600, "middle")
        if search:
            self.search(24, 142 if large else 92, w - 48, search, h=34, fill="#E9EBEE")

    def phone_section(self, x, y, s):
        self.text(x, y + 12, s, 12.5, SEC, 600)

    def phone_row(self, x, y, w, title, line, time, sym="box", color=FAINT, chevron=True, bg=None):
        if bg:
            self.rect(x - 16, y - 8, w + 32, 54 if line is not None else 40, 0, fill=bg)
        self.use(sym, x, y + 4, 16, color)
        self.text(x + 28, y + 15, title, 15, INK)
        self.text(x + w - (14 if chevron else 0), y + 15, time, 12.5, FAINT, anchor="end")
        if chevron:
            self.use("chevr", x + w - 8, y + 7, 12, "#C7CCD3")
        if line is None:
            self.line(x + 28, y + 30, x + w, y + 30)
            return 40
        self.text(x + 28, y + 34, line, 12.5, SEC)
        self.line(x + 28, y + 46, x + w, y + 46)
        return 54

    # ---- web ----
    def web_frame(self, w, h, sidebar_w=260):
        self.rect(0, 0, w, h, 8, fill=RAISED)
        self.rect(0, 0, sidebar_w, h, 8, fill=SIDEBAR)
        self.rect(sidebar_w - 8, 0, 8, h, fill=SIDEBAR)
        self.line(sidebar_w, 0, sidebar_w, h)

    def web_head(self, x, y, w, title, quiet, back=True):
        if back:
            self.use("back", x, y + 4, 16, ACC)
        self.text(x + (24 if back else 0), y + 17, title, 17, INK, 600)
        self.text(x + (24 if back else 0) + width(title, 17, 600) + 10, y + 17, quiet, 12, SEC)
        self.line(x - 16, y + 34, x + w + 16, y + 34)

    def write(self, name):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" '
                "font-family=\"-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif\">\n  <defs>" + SYMBOLS + "  </defs>\n")
        (HERE / name).write_text(head + "\n".join(self.o) + "\n</svg>\n")


SESSIONS_TODAY = [
    ("Sidebar: a folding Work group", "Merged P#4021 · the segmented picker is gone", "2 h ago", [("#4004", ISSUE), ("merged", GREY)]),
    ("Fix the web test job", "A failing web test fails the web job now", "5 h ago", [("#4385", ISSUE)]),
    ("Messages page, read only", "Shipped on the Mac and the web; the Remote is tier mac+web", "9 h ago", [("#4344", ISSUE), ("P#4387", PULL)]),
]
SESSIONS_YESTERDAY = [
    ("Forge interface: move Azure Repos", "Azure Repos is on the one interface", "18:40", [("#4356", ISSUE)]),
    ("Pair a Device… in Settings", "Three buttons under Clients; walked on a scratch app", "11:05", [("#4253", ISSUE)]),
]
SESSIONS_FRIDAY = [
    ("Why does the walk hang on the simulator?", "The sim had a stale lock; filed #4402", "16:12", []),
    ("Lint: shellcheck on scripts/web.sh", "Two warnings fixed", "09:48", [("#4390", ISSUE)]),
]
WORKFLOWS = [
    ("Nightly dead-code review", "Tuesday, Thursday and Saturday · folder workflow", "Last ran 3 d ago"),
    ("Release notes draft", "On release.tagged · folder workflow", "Last ran 2 w ago"),
    ("Weekly competitor check", "Mondays 06:00 · user workflow", "Last ran 1 mo ago"),
    ("Crash reports (old)", "Replaced by the crash-reports skill · folder workflow", "Never ran"),
]


def sidebar(b, x, y, selected="sessions", before=False):
    """A folder's fold as the sidebar draws it; `before` draws today's Recently archived group."""
    b.use("plus", x + 5, y + 3, 14, ACC)
    b.text(x + 22, y + 14, "New Session", 12.5, INK, 500)
    b.use("doc", x + 5, y + 27, 14, ACC)
    b.text(x + 22, y + 38, "Docs", 12.5, INK)
    y += 56
    b.sb_fold(x, y, "Work", open_=False)
    b.sb_fold(x, y + 24, "Your setup", open_=False)
    b.sb_fold(x, y + 48, "Machines", open_=False)
    y += 80
    b.sb_fold(x, y, "Agents", open_=True)
    y += 24
    b.sb_fold(x, y, "Sessions", 3, indent=22)
    b.sb_session(x, y + 22, "Archived pages: hi-fi mocks", "hand", NOTE, indent=44, bold=True)
    b.sb_session(x, y + 44, "Bug lane: #4440 sidebar count", "ring", ACC, indent=44)
    b.sb_session(x, y + 66, "Daily summary", "tick", SEC, indent=44)
    y += 88
    if before:
        b.sb_fold(x, y, "Recently archived sessions", 3, indent=22)
        b.sb_session(x, y + 22, "Sidebar: a folding Work group", "box", FAINT, indent=44)
        b.sb_session(x, y + 44, "Fix the web test job", "box", FAINT, indent=44)
        b.sb_session(x, y + 66, "Messages page, read only", "box", FAINT, indent=44)
        y += 88
    b.sb_fold(x, y, "Workflows", 5, open_=False, indent=22)
    y += 24
    b.sb_page(x, y, "Connectors", "rack", indent=22)
    y += 24
    if before:
        b.sb_page(x, y, "Archived", "box", indent=22, selected=True)
        return y + 24
    b.sb_page(x, y, "Archived Sessions", "box", indent=22, selected=selected == "sessions")
    b.sb_page(x, y + 24, "Archived Workflows", "flow", indent=22, selected=selected == "workflows")
    return y + 48


def mac():
    b = Board(1340, 1220, "Archived Sessions and Archived Workflows (#4448): the Mac window",
              "Two rows of the folder's fold, two pages. Title and filter in the title bar, rows by day, Load more. Orange numbers are the notes in wireframe.md. Scratch data.")
    # Board 1: Archived Sessions
    b.group(24, 76)
    b.mac_window(900, 560, "Archived Sessions", "Agents", search="Filter")
    sidebar(b, 16, 68, selected="sessions")
    cx, cw = 272, 596
    y = 76
    b.day_head(cx, y, cw, "Today")
    y += 24
    for i, (t, l, tm, labels) in enumerate(SESSIONS_TODAY):
        b.session_row(cx, y, cw, t, l, tm, labels, hover=(i == 1))
        y += 46
    y += 8
    b.day_head(cx, y, cw, "Yesterday")
    y += 24
    for t, l, tm, labels in SESSIONS_YESTERDAY:
        b.session_row(cx, y, cw, t, l, tm, labels)
        y += 46
    y += 8
    b.day_head(cx, y, cw, "Friday 7 November")
    y += 24
    for t, l, tm, labels in SESSIONS_FRIDAY:
        b.session_row(cx, y, cw, t, l, tm, labels)
        y += 46
    y += 10
    b.footer(cx, y, cw, "50 of 128 archived sessions ·", "Load more")
    b.end()
    # notes on board 1
    b.note(1, 24 + 272 + 68 + 150, 76 + 26)
    b.note(2, 24 + 900 - 236 - 14, 76 + 26)
    b.note(3, 24 + 16 + 230, 76 + 68 + 56 + 80 + 24 + 88 + 24 + 24 + 10)
    b.note(4, 24 + 272 - 30, 76 + 76 + 12)
    b.note(5, 24 + 272 + 596 - 110, 76 + 76 + 24 + 46 + 13)
    b.note(6, 24 + 272 + 596 + 12, 76 + y + 6)
    b.note(7, 24 + 272 + 596 + 12, 76 + 76 + 24 + 46 + 13)

    # Board 2: Archived Workflows
    b.group(24, 670)
    b.mac_window(900, 430, "Archived Workflows", "Agents", search="Filter")
    sidebar(b, 16, 68, selected="workflows")
    y = 76
    for n, l, tm in WORKFLOWS:
        b.workflow_row(cx, y, cw, n, l, tm)
        y += 46
    y += 10
    b.footer(cx, y, cw, "4 archived workflows")
    b.end()
    b.note(8, 24 + 272 - 30, 670 + 76 + 12)
    b.note(9, 24 + 272 + 596 + 12, 670 + y + 6)

    # Right column: before and after, the folder's fold
    rx = 960
    b.text(rx, 92, "The folder's fold, before", 13, INK, 600)
    b.group(rx, 104)
    b.rect(0, 0, 350, 420, 10, fill=SIDEBAR)
    sidebar(b, 16, 16, before=True)
    b.end()
    b.rect(rx + 16 + 22 - 6, 104 + 16 + 56 + 80 + 24 + 88 - 4, 300, 92, 6, stroke=RED, sw=1.2, dash="4 3")
    b.rect(rx + 16 + 22 - 6, 104 + 16 + 56 + 80 + 24 + 88 + 88 + 24 + 24 - 4, 300, 26, 6, stroke=NOTE, sw=1.2, dash="4 3")
    b.text(rx, 104 + 420 + 18, "Red: the Recently archived sessions group goes.", 11.5, RED)
    b.text(rx, 104 + 420 + 34, "Orange: one Archived row and page, split in two.", 11.5, NOTE)

    b.text(rx, 580, "The folder's fold, after", 13, INK, 600)
    b.group(rx, 592)
    b.rect(0, 0, 350, 380, 10, fill=SIDEBAR)
    sidebar(b, 16, 16, selected=None)
    b.end()
    b.rect(rx + 16 + 22 - 6, 592 + 16 + 56 + 80 + 24 + 88 + 24 + 24 - 4, 300, 50, 6, stroke=GREEN, sw=1.2, dash="4 3")
    b.text(rx, 592 + 380 + 18, "Green: two rows, each shown only with something archived.", 11.5, GREEN)
    b.text(rx, 592 + 380 + 34, "Help on each: “128 archived sessions”, “4 archived workflows”.", 11.5, SEC)

    b.text(rx, 1040, "Notes", 13, INK, 600)
    notes = [
        "1  The title bar holds the page's title and the folder's name.",
        "2  Filter: the toolbar's search field (.searchable).",
        "3  Two sidebar rows; the open page's row is selected.",
        "4  Rows under day headings: Today, Yesterday, then the date.",
        "5  Time: when it was archived (ago today, the clock time before).",
        "6  Footer: the count, and Load more for the next 50.",
        "7  A row under the pointer: the list's hover wash.",
        "8  Workflows: the sidebar's row, by name, no day headings.",
        "9  No Load more: a folder's workflows are all held.",
    ]
    for i, s in enumerate(notes):
        b.text(rx, 1060 + i * 16, s, 11.5, SEC)
    b.write("mac.svg")


def remote():
    b = Board(1120, 940, "Archived Sessions and Archived Workflows (#4448): the Remote",
              "iPhone. The folder's fold with the two rows; Archived Sessions with a swipe; Archived Workflows. The iPad draws the Mac's list in its detail column. Scratch data.")
    pw, ph = 340, 740
    # Phone 1: the folder's fold
    b.group(24, 80)
    b.phone(pw, ph, "Agents", back="Folders", large=True)
    y = 150
    b.phone_section(28, y, "Sessions · 3")
    y += 26
    for t, l, tm, sym, c in [("Archived pages: hi-fi mocks", "Needs you · a question", "", "hand", NOTE),
                             ("Bug lane: #4440 sidebar count", "Working · 2 m", "", "ring", ACC),
                             ("Daily summary", "Done · 7:00", "", "tick", SEC)]:
        b.phone_row(28, y, pw - 56, t, l, tm, sym, c)
        y += 54
    y += 10
    y += b.phone_row(28, y, pw - 56, "Workflows", None, "5", "chevr", FAINT, chevron=False)
    y += b.phone_row(28, y, pw - 56, "Connectors", None, "", "rack", ACC)
    b.rect(16, y - 8, pw - 32, 40, 0, fill=SEL)
    y += b.phone_row(28, y, pw - 56, "Archived Sessions", None, "", "box", ACC)
    y += b.phone_row(28, y, pw - 56, "Archived Workflows", None, "", "flow", ACC)
    b.end()
    b.note(1, 24 + pw - 30, 80 + 150 + 26 + 54 * 3 + 10 + 40 * 2 + 12)

    # Phone 2: Archived Sessions with a swipe
    px = 24 + pw + 36
    b.group(px, 80)
    b.phone(pw, ph, "Archived Sessions", "Agents", back="Agents", search="Filter")
    y = 196
    b.phone_section(28, y, "Today")
    y += 26
    for i, (t, l, tm, labels) in enumerate(SESSIONS_TODAY):
        if i == 1:
            # swiped row: Unarchive on the leading edge
            b.rect(8, y - 8, 110, 54, 0, fill=ACC)
            b.text(63, y + 24, "Unarchive", 13, "#FFF", 600, "middle")
            b.raw(f'<g transform="translate(102,0)">')
            b.rect(-74, y - 8, pw - 16, 54, 0, fill=GROUND)
            b.phone_row(28, y, pw - 56, t, l[:26] + "…", "", chevron=False)
            b.raw("</g>")
        else:
            b.phone_row(28, y, pw - 56, t[:24] + ("…" if len(t) > 24 else ""), l[:34] + ("…" if len(l) > 34 else ""), tm)
        y += 54
    y += 8
    b.phone_section(28, y, "Yesterday")
    y += 26
    for t, l, tm, labels in SESSIONS_YESTERDAY:
        b.phone_row(28, y, pw - 56, t[:24] + ("…" if len(t) > 24 else ""), l[:34] + ("…" if len(l) > 34 else ""), tm)
        y += 54
    y += 8
    b.phone_section(28, y, "Friday 7 November")
    y += 26
    b.phone_row(28, y, pw - 56, "Why does the walk hang on…", "The sim had a stale lock; filed #4402", "16:12")
    y += 60
    b.text(pw / 2, y + 12, "50 of 128 · Load more", 13, ACC, 500, "middle")
    b.end()
    b.note(2, px + pw - 30, 80 + 118)
    b.note(3, px + pw - 30, 80 + 160)
    b.note(4, px + 118, 80 + 196 + 26 + 54 + 18)
    b.note(5, px + pw - 30, 80 + y + 6)

    # Phone 3: Archived Workflows
    px2 = px + pw + 36
    b.group(px2, 80)
    b.phone(pw, ph, "Archived Workflows", "Agents", back="Agents", search="Filter")
    y = 196
    for n, l, tm in WORKFLOWS:
        b.phone_row(28, y, pw - 56, n[:17] + ("…" if len(n) > 17 else ""), l[:36] + ("…" if len(l) > 36 else ""), tm, "pause", FAINT)
        y += 54
    y += 14
    b.text(pw / 2, y + 12, "4 archived workflows", 12.5, SEC, None, "middle")
    b.end()
    b.note(6, px2 + pw - 30, 80 + 196 + 18)

    notes = [
        "1  Two rows in the folder's fold after Connectors; a tap pushes its page. The count is VoiceOver's, as today.",
        "2  A large title, the folder's name under it; Back goes to the folder.",
        "3  The filter is the navigation bar's search field (.searchable).",
        "4  Swipe right: Unarchive (accent). Swipe left: Delete (red). Long press: the row's menu.",
        "5  Load more at the end of the list; pull to refresh at the top.",
        "6  Workflows by name. A tap opens the workflow's page, where Unarchive is in the toolbar.",
    ]
    for i, s in enumerate(notes):
        b.text(24, 846 + i * 15, s, 11.5, SEC)
    b.write("remote.svg")


def web():
    b = Board(1340, 786, "Archived Sessions and Archived Workflows (#4448): the web page",
              "Wide (over 700 px) and 390 px. The column head holds Back, the title and the folder; a filter field; rows by day; Load more. Scratch data.")
    # Wide
    b.group(24, 80)
    b.web_frame(900, 580)
    # sidebar
    sidebar(b, 16, 20, selected="sessions")
    cx, cw = 292, 576
    b.web_head(cx, 16, cw, "Archived Sessions", "Agents")
    b.search(cx, 62, 260, "Filter archived sessions", h=28)
    y = 108
    b.day_head(cx, y, cw, "Today")
    y += 24
    for i, (t, l, tm, labels) in enumerate(SESSIONS_TODAY):
        b.session_row(cx, y, cw, t, l, tm, labels, hover=(i == 0))
        y += 46
    y += 8
    b.day_head(cx, y, cw, "Yesterday")
    y += 24
    for t, l, tm, labels in SESSIONS_YESTERDAY:
        b.session_row(cx, y, cw, t, l, tm, labels)
        y += 46
    y += 8
    b.day_head(cx, y, cw, "Friday 7 November")
    y += 24
    b.session_row(cx, y, cw, *SESSIONS_FRIDAY[0][:3], SESSIONS_FRIDAY[0][3])
    y += 56
    b.text(cx, y + 12, "50 of 128 archived sessions", 11.5, SEC)
    b.button(cx + 190, y - 2, "Load more")
    b.end()
    b.note(1, 24 + cx + 260, 80 + 30)
    b.note(2, 24 + cx + 276, 80 + 76)
    b.note(3, 24 + cx + cw + 12, 80 + y + 10)
    b.note(4, 24 + 16 + 230, 80 + 20 + 56 + 80 + 24 + 88 + 24 + 24 + 10)

    # Narrow
    nx = 24 + 900 + 40
    b.group(nx, 80)
    b.rect(0, 0, 350, 580, 8, fill=RAISED)
    b.web_head(16, 16, 318, "Archived Sessions", "Agents")
    b.search(16, 62, 318, "Filter archived sessions", h=30)
    y = 108
    b.day_head(16, y, 318, "Today")
    y += 24
    for t, l, tm, labels in SESSIONS_TODAY:
        b.session_row(16, y, 318, t[:26] + ("…" if len(t) > 26 else ""), l[:40] + ("…" if len(l) > 40 else ""), tm)
        y += 46
    y += 8
    b.day_head(16, y, 318, "Yesterday")
    y += 24
    for t, l, tm, labels in SESSIONS_YESTERDAY:
        b.session_row(16, y, 318, t[:26] + ("…" if len(t) > 26 else ""), l[:40] + ("…" if len(l) > 40 else ""), tm)
        y += 46
    y += 14
    b.text(175, y + 12, "50 of 128", 11.5, SEC, anchor="middle")
    b.button(175 - 46, y + 22, "Load more")
    b.end()
    b.note(5, nx + 350 - 20, 80 + 30)

    notes = [
        "1  The column head: Back to the folder, the title, the folder's name quiet after it. The address is /ar/sessions (and /ar/workflows).",
        "2  A filter field under the head, 260 px wide; on a narrow page it fills the width. It filters what is loaded and asks the host with the words, as the sidebar search does.",
        "3  The footer: the count and a Load more button (a button, so a keyboard reaches it).",
        "4  Two sidebar rows, as the Mac's. The open page's row is marked chosen.",
        "5  At 390 px: no labels on the row, the title cut at one line, the footer centred.",
    ]
    for i, s in enumerate(notes):
        b.text(24, 694 + i * 16, s, 11.5, SEC)
    b.write("web.svg")


def states():
    b = Board(1340, 600, "Archived Sessions and Archived Workflows (#4448): the states",
              "Tiles of the Mac page's content column; the Remote and the web draw the same words. Scratch data.")
    tw, th = 400, 200
    tiles = [
        ("1  Loading, first read", "skeleton"),
        ("2  Empty", "empty"),
        ("3  Its machine is not answering", "offline"),
        ("4  Filter with no match", "nomatch"),
        ("5  Loading more", "more"),
        ("6  Archived Workflows, empty", "wempty"),
    ]
    for i, (title, kind) in enumerate(tiles):
        x = 24 + (i % 3) * (tw + 36)
        y = 80 + (i // 3) * (th + 50)
        b.text(x, y - 8, title, 12.5, INK, 600)
        b.group(x, y)
        b.rect(0, 0, tw, th, 10, fill=RAISED)
        cx, cw = 20, tw - 40
        if kind == "skeleton":
            b.rect(cx, 16, 60, 10, 5, fill="#E6E8EB")
            for r in range(3):
                b.skeleton_row(cx, 40 + r * 46, cw)
        elif kind == "empty":
            b.use("box", tw / 2 - 16, 56, 32, "#C7CCD3")
            b.text(tw / 2, 116, "No Archived Sessions", 14, INK, 600, "middle")
            b.text(tw / 2, 138, "Sessions you archive in Agents show here.", 12, SEC, None, "middle")
        elif kind == "offline":
            b.rect(cx, 16, cw, 32, 7, fill="#FFF4E5")
            b.use("warn", cx + 10, 24, 16, NOTE)
            b.text(cx + 34, 37, "Its machine isn’t answering. Showing what was last read.", 12, "#7A4A00")
            for r, (t, l, tm, labels) in enumerate(SESSIONS_TODAY[:3]):
                b.group(0, 0, shadow=False, op=0.55)
                b.session_row(cx, 64 + r * 46, cw, t, l, tm)
                b.end()
        elif kind == "nomatch":
            b.search(cx, 16, cw, "walk simulator", h=28)
            b.text(tw / 2, 110, "No archived sessions match", 14, INK, 600, "middle")
            b.button(tw / 2 - 30, 128, "Clear")
        elif kind == "more":
            for r, (t, l, tm, labels) in enumerate(SESSIONS_FRIDAY):
                b.session_row(cx, 16 + r * 46, cw, t, l, tm)
            b.use("spin", cx, 120, 14, FAINT)
            b.text(cx + 22, 132, "Loading more…", 12, SEC)
            b.text(cx, 160, "100 of 128 archived sessions", 11.5, SEC)
        elif kind == "wempty":
            b.use("flow", tw / 2 - 16, 56, 32, "#C7CCD3")
            b.text(tw / 2, 116, "No Archived Workflows", 14, INK, 600, "middle")
            b.text(tw / 2, 138, "Workflows you archive in Agents show here.", 12, SEC, None, "middle")
        b.end()
    notes = [
        "1  Placeholder rows that shimmer while the host answers; never “none” before it has said (#664).",
        "2  Centred glyph, title and one line. Seen after the last one is unarchived or by a link: the sidebar row hides at zero.",
        "3  A strip over the rows last read, dimmed; with none read, the strip stands alone in the middle.",
        "4  The filter's words stay in the field; Clear empties it.",
        "5  Load more becomes a spinner and the words; the count under it updates when the page lands.",
        "6  The same shape on the workflows page.",
    ]
    for i, s in enumerate(notes):
        b.text(24 + (i % 2) * 660, 548 + (i // 2) * 16, s, 11.5, SEC)
    b.write("states.svg")


if __name__ == "__main__":
    mac()
    remote()
    web()
    states()
