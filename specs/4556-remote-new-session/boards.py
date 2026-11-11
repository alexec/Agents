#!/usr/bin/env python3
"""Draws the boards of spec 4556 (the Remote's New session as a composer) as SVG.

Run it from anywhere: it writes beside itself. Paper palette, light mode, scratch data.
"""
from pathlib import Path

HERE = Path(__file__).parent
INK, SEC, TER = "#1C1D20", "#5B616B", "#8A9099"
GROUND, RAISED, RULE, FILL = "#F7F8F9", "#FFFFFF", "#DDE1E6", "#EEF0F3"
ACCENT, NOTE, ATTN, FAIL, GREEN, PURPLE = "#0A6CDB", "#B35900", "#9A6700", "#B42318", "#1A7F37", "#8250DF"
FONT = "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"


def tw(s, size):
    """Roughly how wide `s` is at `size`, in SF."""
    return sum(0.33 * size if c in " .·,'’il|:" else 0.56 * size for c in s)


class Board:
    def __init__(self, w, h, title, sub):
        self.w, self.h = w, h
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">',
                      DEFS, f'<rect width="{w}" height="{h}" fill="#E7EAEE"/>']
        self.text(24, 34, title, 15, INK, weight=600)
        self.text(24, 54, sub, 12, SEC)
        self.clips = 0

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size, color=INK, weight=None, anchor=None, italic=False):
        a = []
        if weight: a.append(f'font-weight="{weight}"')
        if anchor: a.append(f'text-anchor="{anchor}"')
        if italic: a.append('font-style="italic"')
        s = s.replace("&", "&amp;").replace("<", "&lt;")
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{color}" {" ".join(a)}>{s}</text>')

    def rect(self, x, y, w, h, fill=RAISED, stroke=None, rx=0, opacity=None, sw=1):
        a = f'rx="{rx}" fill="{fill}"'
        if stroke: a += f' stroke="{stroke}" stroke-width="{sw}"'
        if opacity is not None: a += f' opacity="{opacity}"'
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" {a}/>')

    def line(self, x1, y1, x2, y2, color=RULE):
        self.add(f'<path d="M{x1:.1f} {y1:.1f}H{x2:.1f}" stroke="{color}" stroke-width="1"/>' if y1 == y2 else
                 f'<path d="M{x1:.1f} {y1:.1f}L{x2:.1f} {y2:.1f}" stroke="{color}" stroke-width="1"/>')

    def glyph(self, name, x, y, size, color):
        self.add(f'<use href="#{name}" x="{x:.1f}" y="{y:.1f}" width="{size}" height="{size}" color="{color}"/>')

    def circle(self, cx, cy, r, fill, stroke=None):
        s = f' stroke="{stroke}"' if stroke else ""
        self.add(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r}" fill="{fill}"{s}/>')

    def note(self, n, x, y):
        self.circle(x, y, 9, NOTE)
        self.text(x, y + 4, str(n), 11, "#FFF", weight=700, anchor="middle")

    def caption(self, x, y, s):
        for i, ln in enumerate(s.split("\n")):
            self.text(x, y + i * 15, ln, 12, SEC, weight=600)

    # --- phone -------------------------------------------------------------------------
    def phone(self, x, y, title="Agents", back="Folders", keyboard=False, w=390, h=844):
        """An iPhone frame, its status bar and its inline navigation bar. Returns the content
        area: (x, top, w, bottom), the bottom being the keyboard's top or the home area."""
        self.clips += 1
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="48" fill="{GROUND}" stroke="#C7CCD3"/></g>')
        self.add(f'<clipPath id="c{self.clips}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="48"/></clipPath>')
        self.add(f'<g clip-path="url(#c{self.clips})">')
        self.rect(x, y, w, h, GROUND)
        self.text(x + 32, y + 34, "9:41", 15, INK, weight=600)
        self.rect(x + w / 2 - 60, y + 11, 120, 34, INK, rx=17)  # the island
        self.glyph("back", x + 10, y + 62, 18, ACCENT)
        self.text(x + 30, y + 76, back, 15, ACCENT)
        self.text(x + w / 2, y + 76, title, 15, INK, weight=600, anchor="middle")
        self.line(x, y + 96, x + w, y + 96, "#E0E3E7")
        bottom = y + h
        self._kb = None
        if keyboard:
            bottom = y + h - 336
            self._kb = (x, bottom, w)
        else:
            self.rect(x + w / 2 - 67, y + h - 12, 134, 5, INK, rx=2.5)
        return x, y + 96, w, bottom

    def end_phone(self):
        if self._kb:
            self.keyboard(*self._kb)
        self.add("</g>")

    def keyboard(self, x, top, w):
        self.rect(x, top, w, 336, "#D1D4DA")
        rows = ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]
        ky = top + 8
        for i, row in enumerate(rows):
            kw, gap = 33, 6
            rw = len(row) * kw + (len(row) - 1) * gap
            kx = x + (w - rw) / 2
            if i == 2:
                self.rect(kx - 48, ky, 42, 42, "#AEB3BC", rx=5)
                self.glyph("shift", kx - 38, ky + 11, 20, INK)
                self.rect(kx + rw + 6, ky, 42, 42, "#AEB3BC", rx=5)
                self.glyph("del", kx + rw + 17, ky + 11, 20, INK)
            for ch in row:
                self.rect(kx, ky, kw, 42, "#FFFFFF", rx=5)
                self.text(kx + kw / 2, ky + 28, ch, 17, INK, anchor="middle")
                kx += kw + gap
            ky += 42 + 12
        self.rect(x + 6, ky, 86, 42, "#AEB3BC", rx=5)
        self.text(x + 49, ky + 26, "123", 15, INK, anchor="middle")
        self.rect(x + 98, ky, 194, 42, "#FFFFFF", rx=5)
        self.text(x + 195, ky + 26, "space", 15, INK, anchor="middle")
        self.rect(x + 298, ky, 86, 42, "#AEB3BC", rx=5)
        self.text(x + 341, ky + 26, "return", 15, INK, anchor="middle")
        self.glyph("globe", x + 22, ky + 56, 22, SEC)
        self.glyph("mic", x + w - 44, ky + 56, 22, SEC)
        self.rect(x + w / 2 - 67, top + 336 - 12, 134, 5, INK, rx=2.5)
        return top

    # --- pieces -------------------------------------------------------------------------
    def grouped_row(self, x, y, w, label, value, h=44, first=False, last=False, chevron=True, dim=False):
        """An inset grouped Form row, as the Remote draws them today."""
        if first and last:
            self.rect(x, y, w, h, RAISED, rx=10)
        elif first:
            self.add(f'<path d="M{x} {y+h}V{y+10}a10 10 0 0 1 10-10H{x+w-10}a10 10 0 0 1 10 10V{y+h}Z" fill="{RAISED}"/>')
        elif last:
            self.add(f'<path d="M{x} {y}V{y+h-10}a10 10 0 0 0 10 10H{x+w-10}a10 10 0 0 0 10-10V{y}Z" fill="{RAISED}"/>')
        else:
            self.rect(x, y, w, h, RAISED)
        if not first:
            self.line(x + 16, y, x + w, y, FILL)
        c = TER if dim else INK
        self.text(x + 16, y + h / 2 + 5, label, 15, c)
        if value:
            self.text(x + w - (34 if chevron else 16), y + h / 2 + 5, value, 15, TER if dim else SEC, anchor="end")
        if chevron:
            self.glyph("updown", x + w - 26, y + h / 2 - 7, 14, TER)

    def segmented(self, x, y, w, items, picked):
        self.rect(x, y, w, 32, "#E3E6EA", rx=8)
        sw = w / len(items)
        for i, it in enumerate(items):
            if i == picked:
                self.rect(x + i * sw + 2, y + 2, sw - 4, 28, RAISED, rx=6)
                self.add(f'<rect x="{x + i*sw + 2}" y="{y+2}" width="{sw-4}" height="28" rx="6" fill="none" stroke="#C7CCD3"/>')
            self.text(x + i * sw + sw / 2, y + 21, it, 13, INK, weight=600 if i == picked else None, anchor="middle")

    def chip(self, x, y, label, glyph=None, badge=None, dim=False, lock=False, dot=None, tag=False):
        """A raised paper capsule, 32 pt tall, that reads its value and opens a menu. Returns its width."""
        pad, size = 10, 13
        w = pad * 2 + tw(label, size)
        if glyph: w += 18
        if not tag and label: w += 14
        if lock: w += 16
        if badge: w += 18
        fill = FILL if tag else RAISED
        self.rect(x, y, w, 32, fill, stroke=None if tag else RULE, rx=16, opacity=0.55 if dim else None)
        cx = x + pad
        if glyph:
            self.glyph(glyph, cx, y + 8, 16, SEC)
            cx += 18
        self.text(cx, y + 20.5, label, size, SEC if tag else INK, weight=None if tag else 500)
        cx += tw(label, size)
        if lock:
            self.glyph("lock", cx + 3, y + 9, 13, TER)
            cx += 16
        if badge:
            self.circle(cx + 10, y + 16, 8, ACCENT)
            self.text(cx + 10, y + 19.5, str(badge), 10, "#FFF", weight=700, anchor="middle")
            cx += 18
        if not tag and label:
            self.glyph("chev", cx + 4, y + 11, 10, TER)
        if dot:
            self.circle(x + w - 4, y + 4, 4.5, dot, stroke=RAISED)
        return w

    def chips(self, x, y, w, items):
        """Items flow into rows of `w`: (label, kwargs). Returns the bottom."""
        cx, cy = x, y
        for label, kw in items:
            cw = tw(label, 13) + 20 + (18 if kw.get("glyph") else 0) + (0 if kw.get("tag") or not label else 14) + (16 if kw.get("lock") else 0) + (18 if kw.get("badge") else 0)
            if cx + cw > x + w and cx > x:
                cx, cy = x, cy + 40
            self.chip(cx, cy, label, **kw)
            cx += cw + 8
        return cy + 32

    def composer(self, x, y, w, chips, text=None, placeholder="What should it do?", lines=2,
                 above=None, above_color=ATTN, attachments=None, starting=False, dim_send=False, voice=False, dim=False):
        """The prompt card (#2752) with the chips above the words. Returns its height, card included."""
        inner = w - 20
        # measure first
        rows = 1
        cx = 0
        for label, kw in chips:
            cw = tw(label, 13) + 20 + (18 if kw.get("glyph") else 0) + (0 if kw.get("tag") or not label else 14) + (16 if kw.get("lock") else 0) + (18 if kw.get("badge") else 0)
            if cx + cw > inner and cx > 0:
                rows += 1
                cx = 0
            cx += cw + 8
        chips_h = rows * 32 + (rows - 1) * 8
        att_h = 70 if attachments else 0
        field_h = max(44, lines * 20 + 8)
        h = 10 + chips_h + 10 + att_h + field_h + 8 + 32 + 10
        top = y
        if above:
            self.text(x, y + 12, above, 12, above_color)
            top = y + 22
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{top}" width="{w}" height="{h}" rx="18" fill="{RAISED}" stroke="{RULE}"/></g>')
        cy = top + 10
        self.chips(x + 10, cy, inner, [(l, {**k, "dim": k.get("dim", dim)}) for l, k in chips])
        cy += chips_h + 10
        if attachments:
            for i, name in enumerate(attachments):
                ax = x + 10 + i * 68
                self.rect(ax, cy, 60, 60, "#C9D7E8", rx=8)
                self.glyph("photo", ax + 20, cy + 20, 20, "#5F7A99")
                self.circle(ax + 58, cy + 2, 8, INK)
                self.text(ax + 58, cy + 5.5, "×", 11, "#FFF", anchor="middle")
            cy += att_h
        if starting:
            self.text(x + 10, cy + 20, text or "", 16, TER)
        elif voice:
            self.add(f'<g transform="translate({x+10},{cy+4})">' + "".join(
                f'<rect x="{i*7}" y="{18-hh/2}" width="4" height="{hh}" rx="2" fill="{ACCENT}"/>' for i, hh in enumerate([8, 16, 26, 14, 30, 20, 10, 24, 16, 8, 20, 28, 12])) + "</g>")
            self.text(x + 110, cy + 24, "Listening…", 16, SEC)
        elif text:
            for i, ln in enumerate(text.split("\n")):
                self.text(x + 10, cy + 20 + i * 20, ln, 16, INK)
            self.rect(x + 10 + tw(text.split("\n")[-1], 16) + 1, cy + 6 + (len(text.split("\n")) - 1) * 20, 2, 20, ACCENT)
        else:
            self.text(x + 10, cy + 20, placeholder, 16, TER)
        cy += field_h + 8
        # buttons
        self.circle(x + 26, cy + 16, 16, RAISED, RULE)
        self.glyph("paperclip", x + 17, cy + 7, 18, SEC if not dim else TER)
        bx = x + w - 26
        self.circle(bx, cy + 16, 16, ACCENT if not dim_send else "#B9C6D6")
        if starting:
            self.add(f'<circle cx="{bx}" cy="{cy+16}" r="7" fill="none" stroke="#FFF" stroke-width="2" stroke-dasharray="26 18"/>')
        else:
            self.glyph("up", bx - 8, cy + 8, 16, "#FFF")
        self.circle(bx - 40, cy + 16, 16, RAISED, RULE)
        self.glyph("wave", bx - 49, cy + 7, 18, SEC)
        self.circle(bx - 80, cy + 16, 16, RAISED, RULE)
        self.glyph("mic", bx - 89, cy + 7, 18, SEC)
        return top + h - y

    def menu(self, x, y, w, items, title=None):
        """An iOS menu: rows of (title, detail, checked, disabled)."""
        h = (24 if title else 0) + sum(50 if d else 40 for _, d, _, _ in items) + 4
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="13" fill="{RAISED}"/></g>')
        cy = y + 2
        if title:
            self.text(x + 16, cy + 16, title, 12, SEC)
            cy += 24
            self.line(x, cy, x + w, cy, FILL)
        for i, (t, d, checked, disabled) in enumerate(items):
            rh = 50 if d else 40
            c = TER if disabled else INK
            self.text(x + 16, cy + (22 if d else 26), t, 15, c)
            if d:
                self.text(x + 16, cy + 40, d, 12, TER if disabled else SEC)
            if checked:
                self.glyph("tick", x + w - 30, cy + (12 if d else 12), 16, INK)
            if t.endswith("›"):
                pass
            cy += rh
            if i < len(items) - 1:
                self.line(x + 16, cy, x + w, cy, FILL)
        return h

    def huddle(self, cx, cy, small=False):
        """The Blobs (#987), looking at the prompt."""
        s = 0.7 if small else 1
        for dx, dy, r, col in [(-34, 6, 20, "#8FB8E8"), (0, -8, 24, "#F2B76B"), (36, 8, 18, "#9ED3A8")]:
            self.circle(cx + dx * s, cy + dy * s, r * s, col)
            self.circle(cx + (dx - 5) * s, cy + (dy - 3) * s, 3 * s, INK)
            self.circle(cx + (dx + 5) * s, cy + (dy - 3) * s, 3 * s, INK)

    def finish(self, name):
        self.add("</svg>")
        (HERE / name).write_text("\n".join(self.parts))
        print("wrote", name)


DEFS = f'''<defs>
  <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="4" stdDeviation="8" flood-color="#20242A" flood-opacity="0.12"/></filter>
  <symbol id="back" viewBox="0 0 16 16"><path d="M10 3L5 8l5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></symbol>
  <symbol id="chev" viewBox="0 0 10 10"><path d="M2 3.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></symbol>
  <symbol id="updown" viewBox="0 0 16 16"><path d="M5 6.5L8 3.5l3 3M5 9.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></symbol>
  <symbol id="tick" viewBox="0 0 16 16"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></symbol>
  <symbol id="up" viewBox="0 0 16 16"><path d="M8 13V3M3.5 7.5L8 3l4.5 4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></symbol>
  <symbol id="mic" viewBox="0 0 16 16"><rect x="5.5" y="1.5" width="5" height="8" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M3.5 7.5a4.5 4.5 0 0 0 9 0M8 12v2.5M5.5 14.5h5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></symbol>
  <symbol id="wave" viewBox="0 0 16 16"><path d="M2 8v0M4.5 5.5v5M7 3v10M9.5 5v6M12 6.5v3M14 8v0" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></symbol>
  <symbol id="paperclip" viewBox="0 0 16 16"><path d="M10.5 5.5l-4.6 4.6a1.6 1.6 0 0 0 2.3 2.3l5-5a3 3 0 0 0-4.3-4.3l-5.3 5.3a4.2 4.2 0 0 0 6 6l3.6-3.6" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></symbol>
  <symbol id="branch" viewBox="0 0 16 16"><circle cx="4" cy="3.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="4" cy="12.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="12" cy="5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M4 5.1v5.8M12 6.6c0 2.6-3 3.4-6.3 3.9" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></symbol>
  <symbol id="folder" viewBox="0 0 16 16"><path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h3l1.5 1.5h4.5A1.5 1.5 0 0 1 14 6v6a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 12z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></symbol>
  <symbol id="spark" viewBox="0 0 16 16"><path d="M8 2l1.4 4.6L14 8l-4.6 1.4L8 14l-1.4-4.6L2 8l4.6-1.4z" fill="currentColor"/></symbol>
  <symbol id="shield" viewBox="0 0 16 16"><path d="M8 1.8l5 2v4.2c0 3-2.2 5.2-5 6.2-2.8-1-5-3.2-5-6.2V3.8z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></symbol>
  <symbol id="more" viewBox="0 0 16 16"><circle cx="3.5" cy="8" r="1.4" fill="currentColor"/><circle cx="8" cy="8" r="1.4" fill="currentColor"/><circle cx="12.5" cy="8" r="1.4" fill="currentColor"/></symbol>
  <symbol id="lock" viewBox="0 0 16 16"><rect x="3.5" y="7" width="9" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" fill="none" stroke="currentColor" stroke-width="1.3"/></symbol>
  <symbol id="photo" viewBox="0 0 16 16"><rect x="2" y="3" width="12" height="10" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="5.5" cy="6.5" r="1.2" fill="currentColor"/><path d="M3 12l3.5-3.5 2.5 2.5 2-2L14 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></symbol>
  <symbol id="shift" viewBox="0 0 16 16"><path d="M8 2.5l5.5 6H10v5H6v-5H2.5z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></symbol>
  <symbol id="del" viewBox="0 0 16 16"><path d="M5.5 3.5h8v9h-8L2 8zM7.5 6l3 4M10.5 6l-3 4" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></symbol>
  <symbol id="globe" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M2 8h12M8 2c2.5 2.5 2.5 9.5 0 12M8 2C5.5 4.5 5.5 11.5 8 14" fill="none" stroke="currentColor" stroke-width="1.3"/></symbol>
  <symbol id="warn" viewBox="0 0 16 16"><path d="M8 2.2L14.3 13.5H1.7z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/><path d="M8 6.5v3.2" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="11.6" r=".8" fill="currentColor"/></symbol>
  <symbol id="plus" viewBox="0 0 16 16"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></symbol>
  <symbol id="sidebar" viewBox="0 0 16 16"><rect x="2" y="3" width="12" height="10" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M6 3v10" stroke="currentColor" stroke-width="1.3"/></symbol>
</defs>'''

# The scratch session's choices, as chips.
WHERE = ("New worktree", {"glyph": "branch"})
RUNTIME = ("Auto · Claude", {})
MODEL = ("Smart", {})
PERM = ("Ask", {})
SANDBOX = ("Default sandbox", {})
MORE = ("", {"glyph": "more"})
CHIPS = [WHERE, RUNTIME, MODEL, PERM, SANDBOX, MORE]


def today_phone(b, x, y):
    """The page as it is now (StartAgentView), with the keyboard up."""
    px, top, pw, bottom = b.phone(x, y, "Agents", keyboard=True)
    b.huddle(px + pw / 2, top + 44)
    ry = top + 88
    b.grouped_row(px + 16, ry, pw - 32, "Project", "Agents", first=True)
    b.grouped_row(px + 16, ry + 44, pw - 32, "On", "This Mac", last=True)
    ry += 88 + 20
    b.segmented(px + 70, ry, 250, ["No persona", "Lead", "Product"], 0)
    ry += 32 + 20
    b.grouped_row(px + 16, ry, pw - 32, "Runtime", "Auto (Claude)", first=True)
    ry += 44
    # the Model row: a segmented control with a line under it
    b.rect(px + 16, ry, pw - 32, 72, RAISED)
    b.line(px + 32, ry, px + pw - 16, ry, FILL)
    b.segmented(px + 32, ry + 8, pw - 64, ["Fast", "Balanced", "Smart"], 2)
    b.text(px + 32, ry + 60, "Opus on Claude", 12, SEC)
    ry += 72
    b.grouped_row(px + 16, ry, pw - 32, "Permission mode", "Ask")
    ry += 44
    b.grouped_row(px + 16, ry, pw - 32, "Worktree", "Folder")
    ry += 44
    b.grouped_row(px + 16, ry, pw - 32, "Sandbox", "Default sandbox", last=True)
    # the prompt card, where it sits today: over the keyboard, under the form
    b.end_phone()
    # Behind the keyboard: say so
    b.add(f'<g opacity="0.92"><rect x="{px+40}" y="{bottom+120}" width="{pw-80}" height="92" rx="12" fill="{INK}"/></g>')
    for i, ln in enumerate(["Under the keyboard: Permission mode,", "Worktree, Sandbox, Claude’s own options,", "Reach, Labels and the prompt card itself."]):
        b.text(px + pw / 2, bottom + 150 + i * 20, ln, 13, "#FFF", anchor="middle")
    return px, top, pw, bottom


def after_phone(b, x, y, keyboard=True, text=None, notes=True):
    px, top, pw, bottom = b.phone(x, y, "Agents", keyboard=keyboard)
    ry = top + 12
    # Project and On, only when the project has more than one folder: not in this scratch folder.
    b.segmented(px + 70, ry, 250, ["No persona", "Lead", "Product"], 0)
    if notes: b.note(2, px + 46, ry + 16)
    ry += 32 + 8
    b.text(px + pw / 2, ry + 10, "Starts a session with no persona file.", 12, SEC, anchor="middle")
    ry += 28
    # the card, pinned to the bottom (the keyboard's top)
    chips = CHIPS
    card_h = 10 + (2 * 32 + 8) + 10 + 44 + 8 + 32 + 10
    cy = bottom - 10 - card_h
    b.huddle(px + pw / 2, (ry + cy) / 2, small=not keyboard)
    b.composer(px + 16, cy, pw - 32, chips, text=text)
    if notes:
        b.note(1, px + 8, cy + 26)
        b.note(3, px + 8, cy + 66)
        b.note(4, px + pw - 8, cy + 26)
        b.note(5, px + pw - 8, cy + 66)
        b.note(6, px + 8, cy + card_h - 24)
    b.end_phone()
    return px, top, pw, bottom, cy


def board_today_after():
    b = Board(900, 960, "New session on the iPhone (#4556): today and after, with the keyboard up",
              "Left: StartAgentView today, a Form of rows with the prompt card at its end. Right: the composer, the choices as chips in the card. Scratch data.")
    b.caption(24, 74, "Today: the keyboard hides the rows from\nPermission mode down, and the card itself")
    today_phone(b, 24, 96)
    b.caption(470, 74, "After: every choice is a chip in the card,\nwhich sits over the keyboard")
    after_phone(b, 470, 96, text="Rework the new-session layout for\nthe iPhone")
    b.finish("today-after.svg")


def board_page():
    b = Board(1340, 960, "After (#4556): the page with the keyboard down, the Worktree chip's menu, and the More sheet",
              "The body is short: Project and On (when the project has several folders), the persona, kept starts. The card is the chat's card (#2752), with the chips above the words.")
    b.caption(24, 88, "The page, keyboard down")
    px, top, pw, bottom, cy = after_phone(b, 24, 96, keyboard=False, notes=False)
    b.note(7, px + pw / 2 - 60, top + 160)

    b.caption(470, 88, "The Worktree chip's menu")
    px, top, pw, bottom, cy = after_phone(b, 470, 96, keyboard=False, notes=False)
    b.add(f'<rect x="0" y="0" width="0" height="0"/>')
    # dim the page under the menu, iOS-style, and draw the menu above the chip
    b.add(f'<rect x="{470}" y="{96}" width="390" height="844" rx="48" fill="#000" opacity="0.18"/>')
    wx = px + 26
    b.chip(wx, cy + 10, "New worktree", glyph="branch")
    items = [("Folder", "~/Agents · main · 2 changes", False, False),
             ("New worktree", "A new branch from the last commit here", True, False),
             ("agents/4099-connectors", "main · clean · 1 agent working", False, False),
             ("agents/4416-work-look", "Missing", False, True),
             ("New worktree on a branch  ›", None, False, False)]
    mh = 24 + sum(50 if d else 40 for _, d, _, _ in items) + 4
    b.menu(wx, cy + 10 - mh - 8, 300, items, title="Worktree")
    b.note(8, wx + 300, cy + 10 - mh)

    b.caption(916, 88, "The ⋯ chip opens the More sheet")
    px, top, pw, bottom, cy = after_phone(b, 916, 96, keyboard=False, notes=False)
    b.add(f'<rect x="{916}" y="{96}" width="390" height="844" rx="48" fill="#000" opacity="0.18"/>')
    sy = 96 + 844 - 560
    b.add(f'<clipPath id="sheet"><rect x="916" y="{sy}" width="390" height="560" rx="48"/></clipPath>')
    b.add(f'<g clip-path="url(#sheet)">')
    b.rect(916, sy, 390, 600, GROUND, rx=24)
    b.rect(916 + 195 - 18, sy + 8, 36, 5, "#C7CCD3", rx=2.5)
    b.text(916 + 195, sy + 40, "More", 17, INK, weight=600, anchor="middle")
    b.text(916 + 374, sy + 40, "Done", 17, ACCENT, weight=600, anchor="end")
    ry = sy + 64
    b.text(916 + 32, ry + 12, "CLAUDE’S OWN", 12, SEC)
    ry += 22
    b.grouped_row(916 + 16, ry, 358, "Effort", "High", first=True)
    b.grouped_row(916 + 16, ry + 44, 358, "Fast mode", "", chevron=False)
    b.rect(916 + 374 - 16 - 51, ry + 44 + 7, 51, 31, "#E3E6EA", rx=15.5)
    b.circle(916 + 374 - 16 - 51 + 15.5, ry + 44 + 22.5, 13.5, RAISED, "#C7CCD3")
    b.grouped_row(916 + 16, ry + 88, 358, "Permission requests", "Ask each time", last=True)
    ry += 132 + 24
    b.text(916 + 32, ry + 12, "REACH", 12, SEC)
    ry += 22
    b.grouped_row(916 + 16, ry, 358, "~/Agents", "", first=True, chevron=False)
    b.text(916 + 374 - 16, ry + 27, "This folder", 15, TER, anchor="end")
    b.grouped_row(916 + 16, ry + 44, 358, "~/Agents-docs", "", chevron=False)
    b.text(916 + 374 - 16, ry + 44 + 27, "Remove", 15, ACCENT, anchor="end")
    b.grouped_row(916 + 16, ry + 88, 358, "Add a folder…", "", last=True, chevron=False)
    b.add(f'<text x="{916+32}" y="{ry+88+27}" font-size="15" fill="{ACCENT}">Add a folder…</text>')
    ry += 132 + 24
    b.text(916 + 32, ry + 12, "LABELS", 12, SEC)
    ry += 22
    b.rect(916 + 16, ry, 358, 44, RAISED, rx=10)
    b.chip(916 + 28, ry + 6, "lead", tag=True)
    b.chip(916 + 28 + 56, ry + 6, "#4327", tag=True)
    b.text(916 + 28 + 56 + 70, ry + 27, "Add a label", 15, TER)
    b.add("</g>")
    b.note(9, 916 + 8, sy + 40)
    b.note(10, 916 + 8, sy + 64 + 22 + 88 + 22)
    b.note(11, 916 + 8, sy + 64 + 22 + 132 + 24 + 22 + 22)
    b.note(12, 916 + 8, sy + 64 + 22 + 132 + 24 + 22 + 132 + 24 + 22 + 22)
    b.finish("page.svg")


def board_states():
    b = Board(1260, 1040, "After (#4556): the card's states", "Each is the card cut from the page, 358 pt wide, as it is on an iPhone. The chips stay where they are in every state.")
    x0, y0, cw, gap = 24, 124, 358, 48
    col = lambda i: x0 + i * (cw + gap)

    b.caption(col(0), y0 - 26, "A. Not a repository: no Where chip. A runtime\nchosen by name, and its Account chip (two accounts)")
    b.composer(col(0), y0, cw, [("Codex", {}), ("Work account", {}), MODEL, PERM, ("Runtime sandbox", {}), MORE])
    b.note(13, col(0) + cw + 10, y0 + 26)

    b.caption(col(1), y0 - 26, "B. Starting: the words held, the spinner,\nand the host it tells")
    b.composer(col(1), y0, cw, CHIPS, text="Rework the new-session layout for the iPhone", starting=True, dim=True,
               above="Starting — telling your Mac", above_color=SEC)
    b.note(14, col(1) + cw + 10, y0 + 48)

    b.caption(col(2), y0 - 26, "C. The runtime is out: said once above the words,\nand a dot on its chip; Send still sends")
    b.composer(col(2), y0, cw, [WHERE, ("Claude", {"dot": ATTN}), MODEL, PERM, SANDBOX, MORE],
               above="Claude’s plan is spent until 3:00 pm. It will say no until then.", above_color=ATTN)
    b.note(15, col(2) + cw + 10, y0 + 48)

    y1 = y0 + 310
    b.caption(col(0), y1 - 26, "D. The folder's host is not answering: the strip,\nthe chips and Send dimmed")
    b.rect(col(0), y1, cw, 36, "#FFF4D6", rx=8)
    b.glyph("warn", col(0) + 12, y1 + 10, 16, ATTN)
    b.text(col(0) + 36, y1 + 23, "Your Mac is not answering. Waiting for it.", 13, ATTN)
    b.composer(col(0), y1 + 48, cw, CHIPS, dim=True, dim_send=True)
    b.note(16, col(0) + cw + 10, y1 + 18)

    b.caption(col(1), y1 - 26, "E. A persona picked: its choices in the chips, its labels\nas tags after ⋯, and ⋯ counts what is set in More")
    b.composer(col(1), y1, cw, [WHERE, ("Claude", {}), ("Smart", {}), ("Approve for me", {}), SANDBOX, ("", {"glyph": "more", "badge": 2}), ("lead", {"tag": True}), ("#4327", {"tag": True})])
    b.note(17, col(1) + cw + 10, y1 + 66)

    b.caption(col(2), y1 - 26, "F. Set by the organisation: a lock on the chip; it opens,\nand offers no other value")
    b.composer(col(2), y1, cw, [WHERE, RUNTIME, MODEL, ("Ask", {"lock": True}), ("Default sandbox", {"lock": True}), MORE],
               above="Permission mode and Sandbox are set by your organisation.", above_color=SEC)
    b.note(18, col(2) + cw + 10, y1 + 48)

    y2 = y1 + 320
    b.caption(col(0), y2 - 26, "G. A picture attached that the runtime does not take:\nrefused before sending, in the runtime's name")
    b.composer(col(0), y2, cw, [WHERE, ("Codex", {}), MODEL, PERM, ("Runtime sandbox", {}), MORE],
               attachments=["IMG_0412"], above="Codex does not take pictures.", above_color=FAIL)
    b.note(19, col(0) + cw + 10, y2 + 48)

    b.caption(col(1), y2 - 26, "H. Voice mode on: the first words start the session;\nthe chips stay")
    b.composer(col(1), y2, cw, CHIPS, voice=True)
    b.note(20, col(1) + cw + 10, y2 + 26)

    b.caption(col(2), y2 - 26, "I. Auto picks nothing: the chip says so with a red dot,\nand the line says why")
    b.composer(col(2), y2, cw, [WHERE, ("Auto · no runtime", {"dot": FAIL}), MODEL, PERM, SANDBOX, MORE],
               above="No runtime can start now: Claude is out, Codex is not signed in.", above_color=FAIL, dim_send=True)
    b.note(21, col(2) + cw + 10, y2 + 48)
    b.finish("states.svg")


def board_ipad():
    b = Board(1300, 940, "After (#4556): the iPad in landscape", "The sidebar and the folder's page. The card sits at the reading width (680 pt) and the chips fit one row; with a hardware keyboard there is no soft keyboard.")
    x, y, w, h = 24, 80, 1180, 820
    b.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="36" fill="{GROUND}" stroke="#C7CCD3"/></g>')
    b.add(f'<clipPath id="ipad"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="36"/></clipPath><g clip-path="url(#ipad)">')
    b.text(x + 28, y + 24, "9:41  Mon 10 Nov", 13, INK, weight=600)
    # sidebar
    b.rect(x, y, 320, h, "#F0F2F4")
    b.add(f'<path d="M{x+320} {y}V{y+h}" stroke="{RULE}"/>')
    b.text(x + 20, y + 68, "Agents", 26, INK, weight=700)
    b.glyph("plus", x + 290, y + 56, 18, ACCENT)
    sy = y + 96
    for name, rows in [("This Mac", ["Agents", "Agents-docs"]), ("Needs you", ["Fix the Remote's start page…"])]:
        b.text(x + 20, sy + 12, name.upper(), 11, SEC, weight=600)
        sy += 24
        for r in rows:
            if r == "Agents":
                b.rect(x + 10, sy, 300, 40, "#DCE6F3", rx=10)
            b.glyph("folder", x + 22, sy + 12, 16, SEC)
            b.text(x + 46, sy + 25, r, 15, INK)
            sy += 44
        sy += 12
    b.rect(x + 10, sy, 300, 40, RAISED, rx=10)
    b.glyph("plus", x + 22, sy + 12, 16, ACCENT)
    b.text(x + 46, sy + 25, "New session", 15, ACCENT)
    # detail
    dx, dw = x + 320, w - 320
    b.glyph("sidebar", dx + 16, y + 52, 20, ACCENT)
    b.text(dx + dw / 2, y + 66, "Agents", 17, INK, weight=600, anchor="middle")
    b.line(dx, y + 88, dx + dw, y + 88, "#E0E3E7")
    rw = 680
    rx = dx + (dw - rw) / 2
    b.segmented(rx + rw / 2 - 230, y + 112, 460, ["No persona", "Lead", "Product Owner", "Scrum Master"], 0)
    b.text(rx + rw / 2, y + 166, "Starts a session with no persona file.", 13, SEC, anchor="middle")
    b.huddle(rx + rw / 2, y + 420)
    card_h = 10 + 32 + 10 + 64 + 8 + 32 + 10
    b.composer(rx, y + h - 24 - card_h, rw, CHIPS, lines=3)
    b.add("</g>")
    b.note(22, rx - 14, y + h - 24 - card_h + 26)
    b.finish("ipad.svg")


if __name__ == "__main__":
    board_today_after()
    board_page()
    board_states()
    board_ipad()
