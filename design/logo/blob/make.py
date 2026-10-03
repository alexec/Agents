#!/usr/bin/env python3
"""Blob, taken further: grounds, eyes, bodies, and the icon among others in a Dock.

Run it, then `qlmanage -t -s 2340 -o . sheet.svg && mv sheet.svg.png sheet.png`.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
INK = "#1B1340"
FONT = 'font-family="-apple-system, Helvetica Neue, sans-serif"'


def grad(id, a, b):
    return (f'<linearGradient id="{id}" x1="0" y1="0" x2="1" y2="1">'
            f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>')


GROUNDS = {
    "violet": ("#8E5CFF", "#4A2BD6"),
    "orange": ("#FF9A3D", "#FF5A1F"),
    "coral": ("#FF6F91", "#E8336D"),
    "teal": ("#2FD3B5", "#0E8F7A"),
    "blue": ("#4FB3FF", "#2B5BF5"),
    "night": ("#2A2440", "#0F0C1D"),
}


def body(kind="soft", fill="#fff"):
    if kind == "soft":  # the Blob from the first sheet
        return (f'<path d="M512 226 C700 226 812 330 812 520 C812 712 700 806 512 806 C324 806 212 712 212 520 '
                f'C212 330 324 226 512 226 Z" fill="{fill}"/>')
    if kind == "round":
        return f'<circle cx="512" cy="520" r="300" fill="{fill}"/>'
    if kind == "ghost":  # taller, wavy hem: a little spirit, an agent
        return (f'<path d="M232 820 V500 C232 320 352 216 512 216 C672 216 792 320 792 500 V820 '
                f'Q745 770 698 820 Q651 870 605 820 Q558 770 512 820 Q465 870 418 820 Q372 770 325 820 Q279 870 232 820 Z" fill="{fill}"/>')
    if kind == "peek":  # rising from the bottom edge
        return (f'<path d="M180 1024 V560 C180 360 330 270 512 270 C694 270 844 360 844 560 V1024 Z" fill="{fill}"/>')
    if kind == "drop":
        return (f'<path d="M512 180 C600 330 800 420 800 590 C800 750 672 840 512 840 C352 840 224 750 224 590 '
                f'C224 420 424 330 512 180 Z" fill="{fill}"/>')
    raise ValueError(kind)


def eyes(kind="oval", cy=500, dx=92, col=INK):
    l, r = 512 - dx, 512 + dx
    if kind == "oval":
        return f'<ellipse cx="{l}" cy="{cy}" rx="46" ry="62" fill="{col}"/><ellipse cx="{r}" cy="{cy}" rx="46" ry="62" fill="{col}"/>'
    if kind == "dot":
        return f'<circle cx="{l}" cy="{cy}" r="48" fill="{col}"/><circle cx="{r}" cy="{cy}" r="48" fill="{col}"/>'
    if kind == "look":  # looking up and to the right, at you in the corner
        return (f'<ellipse cx="{l+26}" cy="{cy-22}" rx="44" ry="60" fill="{col}"/><ellipse cx="{r+26}" cy="{cy-22}" rx="44" ry="60" fill="{col}"/>')
    if kind == "happy":
        a = lambda x: f'<path d="M{x-48} {cy+18} Q{x} {cy-58} {x+48} {cy+18}" fill="none" stroke="{col}" stroke-width="34" stroke-linecap="round"/>'
        return a(l) + a(r)
    if kind == "wink":
        return (f'<ellipse cx="{l}" cy="{cy}" rx="46" ry="62" fill="{col}"/>'
                f'<path d="M{r-50} {cy+6} Q{r} {cy+40} {r+50} {cy+6}" fill="none" stroke="{col}" stroke-width="34" stroke-linecap="round"/>')
    if kind == "shine":  # ovals with a highlight: more life at large sizes
        return (eyes("oval", cy, dx, col) +
                f'<circle cx="{l+14}" cy="{cy-24}" r="14" fill="#fff"/><circle cx="{r+14}" cy="{cy-24}" r="14" fill="#fff"/>')
    raise ValueError(kind)


def icon(uid, ground="violet", b="soft", e="oval", extra="", eye_cy=None):
    a, z = GROUNDS[ground]
    cy = eye_cy or {"soft": 500, "round": 500, "ghost": 470, "peek": 560, "drop": 590}[b]
    return (f'<defs>{grad("g" + uid, a, z)}</defs><rect width="1024" height="1024" rx="230" fill="url(#g{uid})"/>'
            f'{extra}{body(b)}{eyes(e, cy)}')


def friend(uid):
    """A second blob behind, smaller and tinted: still one character, but not alone."""
    return ('<g transform="translate(560 -40) scale(.55)" opacity=".45">' + body("soft") + '</g>')


ROWS = [
    ("Ground", "The same Blob on six colours. Violet is the one from the first sheet.",
     [(g.capitalize(), dict(ground=g)) for g in GROUNDS]),
    ("Eyes", "Expression carries the character. The first is today's.",
     [("Ovals", dict(e="oval")), ("Dots", dict(e="dot")), ("Looking up", dict(e="look")),
      ("Shine", dict(e="shine")), ("Happy", dict(e="happy")), ("Wink", dict(e="wink"))]),
    ("Body", "The outline: softer, rounder, a ghost, peeking up, a drop, or with a friend.",
     [("Soft", dict(b="soft")), ("Round", dict(b="round")), ("Ghost", dict(b="ghost")),
      ("Peek", dict(b="peek")), ("Drop", dict(b="drop")), ("Friend", dict(b="soft", extra="FRIEND"))]),
]

W, PAD, BIG, STEP = 2340, 60, 260, 370
out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {W}" width="{W}" height="{W}">',
       f'<rect width="{W}" height="{W}" fill="#FAFAF7"/>',
       f'<text x="{PAD}" y="{PAD+54}" {FONT} font-size="54" font-weight="800" fill="#111">Blob, taken further</text>',
       f'<text x="{PAD}" y="{PAD+100}" {FONT} font-size="26" fill="#666">Each row changes one thing from the first sheet’s Blob. The small pair is 32 and 16 points.</text>']
y = 220
n = 0
for title, sub, items in ROWS:
    out.append(f'<text x="{PAD}" y="{y}" {FONT} font-size="36" font-weight="700" fill="#111">{title}</text>')
    out.append(f'<text x="{PAD+180}" y="{y}" {FONT} font-size="24" fill="#666">{sub}</text>')
    for i, (label, kw) in enumerate(items):
        n += 1
        uid = f"s{n}"
        extra = friend(uid) if kw.pop("extra", "") == "FRIEND" else ""
        svg = icon(uid, extra=extra, **kw)
        x = PAD + i * STEP
        out.append(f'<svg x="{x}" y="{y+30}" width="{BIG}" height="{BIG}" viewBox="0 0 1024 1024">{svg}</svg>')
        out.append(f'<svg x="{x+BIG+14}" y="{y+30+BIG-104}" width="32" height="32" viewBox="0 0 1024 1024">{svg.replace(uid, uid+"m")}</svg>')
        out.append(f'<svg x="{x+BIG+14}" y="{y+30+BIG-50}" width="16" height="16" viewBox="0 0 1024 1024">{svg.replace(uid, uid+"t")}</svg>')
        out.append(f'<text x="{x}" y="{y+30+BIG+40}" {FONT} font-size="26" font-weight="600" fill="#222">{label}</text>')
    y += BIG + 150

# A Dock: the Blob among other apps' kinds of icons, at Dock size, light and dark.
others = ['<rect width="1024" height="1024" rx="230" fill="#D97757"/><path d="M512 260 L540 470 L740 400 L560 520 L700 700 L512 570 L324 700 L464 520 L284 400 L484 470 Z" fill="#fff"/>',
          '<rect width="1024" height="1024" rx="230" fill="#10A37F"/><circle cx="512" cy="512" r="250" fill="none" stroke="#fff" stroke-width="70"/>',
          '<rect width="1024" height="1024" rx="230" fill="#1E1E1E"/><path d="M330 380 L470 512 L330 644 M540 660 H700" fill="none" stroke="#fff" stroke-width="70" stroke-linecap="round"/>',
          '<rect width="1024" height="1024" rx="230" fill="#2B7FFF"/><path d="M300 700 L512 300 L724 700 Z" fill="#fff"/>',
          '<rect width="1024" height="1024" rx="230" fill="#F5F5F5"/><circle cx="512" cy="512" r="260" fill="#FFB000"/>']
for row, (bg, label) in enumerate([("#E9E6EF", "In a light Dock"), ("#2B2A30", "In a dark Dock")]):
    dy = y + 30 + row * 190
    out.append(f'<text x="{PAD}" y="{dy-10}" {FONT} font-size="26" font-weight="600" fill="#222">{label}</text>')
    out.append(f'<rect x="{PAD}" y="{dy}" width="1100" height="140" rx="36" fill="{bg}"/>')
    icons = others[:3] + [icon(f"d{row}v", "violet")] + others[3:] + [icon(f"d{row}o", "orange")]
    for i, ic in enumerate(icons):
        out.append(f'<svg x="{PAD+30+i*130}" y="{dy+20}" width="100" height="100" viewBox="0 0 1024 1024">{ic}</svg>')
out.append(f'<text x="{PAD+1180}" y="{y+90}" {FONT} font-size="24" fill="#666">Violet and orange beside stand-ins for other agent apps.</text>')
out.append(f'<text x="{PAD+1180}" y="{y+124}" {FONT} font-size="24" fill="#666">Orange sits too close to Claude’s own colour.</text>')
out.append("</svg>\n")
with open(os.path.join(HERE, "sheet.svg"), "w") as f:
    f.write("\n".join(out))
print("ok", y)
