#!/usr/bin/env python3
"""Draw the colour logo ideas as SVGs and lay them out on one sheet.

Each mark is drawn on a 1024 square with the macOS icon's rounded corners.
Run it, then `qlmanage -t -s 2400 -o . sheet.svg` renders the sheet.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
R = 230  # corner radius of the 1024 tile


def tile(bg, body, grad=None):
    defs = f"<defs>{grad}</defs>" if grad else ""
    return f'{defs}<rect width="1024" height="1024" rx="{R}" fill="{bg}"/>{body}'


def lin(id, a, b, x2="1", y2="1"):
    return (f'<linearGradient id="{id}" x1="0" y1="0" x2="{x2}" y2="{y2}">'
            f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>')


MARKS = []


def mark(name, title, says):
    def wrap(f):
        MARKS.append((name, title, says, f()))
        return f
    return wrap


@mark("hand", "Hand up", "Several agents in a row; the one that needs you is up and lit.")
def _():
    return tile("#5B3DF5",
        '<rect x="232" y="452" width="140" height="300" rx="70" fill="#fff" opacity=".55"/>'
        '<rect x="652" y="452" width="140" height="300" rx="70" fill="#fff" opacity=".55"/>'
        '<rect x="442" y="232" width="140" height="520" rx="70" fill="#FFD23F"/>')


@mark("trio", "Trio", "Three agents overlapping: separate, but working together.")
def _():
    return tile("#111318",
        '<g style="mix-blend-mode:screen">'
        '<circle cx="512" cy="395" r="210" fill="#FF3D7F"/>'
        '<circle cx="410" cy="572" r="210" fill="#2EC4FF"/>'
        '<circle cx="614" cy="572" r="210" fill="#FFD23F"/></g>')


@mark("flock", "Flock", "Three moving as one, the leader out front. The old Formation, in colour.")
def _():
    c = lambda x, y, s, col: (f'<path d="M{x-s} {y+s*0.75} L{x} {y-s*0.25} L{x+s} {y+s*0.75}" '
                              f'fill="none" stroke="{col}" stroke-width="{s*0.42:.0f}" '
                              f'stroke-linecap="round" stroke-linejoin="round"/>')
    return tile("url(#g-flock)",
        c(512, 340, 190, "#fff") + c(300, 640, 130, "#fff") + c(724, 640, 130, "#fff"),
        lin("g-flock", "#FF8A00", "#FF2E63"))


@mark("ping", "Ping", "One agent, one badge: something is waiting for you.")
def _():
    return tile("#0E7C66",
        '<rect x="222" y="262" width="500" height="500" rx="150" fill="#fff"/>'
        '<circle cx="390" cy="512" r="42" fill="#0E7C66"/><circle cx="554" cy="512" r="42" fill="#0E7C66"/>'
        '<circle cx="722" cy="282" r="132" fill="#FF5A36" stroke="#0E7C66" stroke-width="44"/>')


@mark("pinwheel", "Pinwheel", "Four quarters turning at once: parallel work, always moving.")
def _():
    q = ['<path d="M512 512 V212 A300 300 0 0 1 812 512 Z" fill="#FF3D7F"/>',
         '<path d="M512 512 H812 A300 300 0 0 1 512 812 Z" fill="#FFD23F"/>',
         '<path d="M512 512 V812 A300 300 0 0 1 212 512 Z" fill="#2EC4FF"/>',
         '<path d="M512 512 H212 A300 300 0 0 1 512 212 Z" fill="#7CE36B"/>']
    return tile("#161A22", f'<g transform="rotate(20 512 512)">{"".join(q)}</g>')


@mark("blob", "Blob", "The current faces, made one bold friendly character on colour.")
def _():
    return tile("url(#g-blob)",
        '<path d="M512 226 C700 226 812 330 812 520 C812 712 700 806 512 806 C324 806 212 712 212 520 '
        'C212 330 324 226 512 226 Z" fill="#fff"/>'
        '<ellipse cx="420" cy="500" rx="46" ry="62" fill="#1B1340"/>'
        '<ellipse cx="604" cy="500" rx="46" ry="62" fill="#1B1340"/>',
        lin("g-blob", "#8E5CFF", "#4A2BD6"))


@mark("crowd", "Crowd", "Faces again: three of them, each its own colour, the front one yours.")
def _():
    face = lambda x, y, s, col: (f'<rect x="{x-s/2}" y="{y-s/2}" width="{s}" height="{s}" rx="{s*0.3}" fill="{col}" '
                                 f'stroke="#FFF4E0" stroke-width="28"/>'
                                 f'<circle cx="{x-s*0.17}" cy="{y}" r="{s*0.075}" fill="#fff"/>'
                                 f'<circle cx="{x+s*0.17}" cy="{y}" r="{s*0.075}" fill="#fff"/>')
    return tile("#FFF4E0", face(330, 380, 280, "#2EC4FF") + face(694, 380, 280, "#FF3D7F") + face(512, 620, 380, "#5B3DF5"))


@mark("orbit", "Orbit", "You at the centre, your agents going round you.")
def _():
    return tile("#0B1E3F",
        '<ellipse cx="512" cy="512" rx="330" ry="150" fill="none" stroke="#2EC4FF" stroke-width="30" transform="rotate(-30 512 512)"/>'
        '<ellipse cx="512" cy="512" rx="330" ry="150" fill="none" stroke="#FF3D7F" stroke-width="30" transform="rotate(30 512 512)"/>'
        '<circle cx="512" cy="512" r="96" fill="#FFD23F"/>'
        '<circle cx="227" cy="347" r="52" fill="#2EC4FF"/><circle cx="797" cy="347" r="52" fill="#FF3D7F"/>')


@mark("monogram", "A of three", "The letter A drawn as three joined agents.")
def _():
    return tile("#FF5A36",
        '<path d="M512 250 L282 770 M512 250 L742 770 M372 568 H652" fill="none" stroke="#fff" '
        'stroke-width="70" stroke-linecap="round" stroke-linejoin="round"/>'
        '<circle cx="512" cy="250" r="82" fill="#1B1340"/>'
        '<circle cx="282" cy="770" r="82" fill="#1B1340"/><circle cx="742" cy="770" r="82" fill="#1B1340"/>')


@mark("cards", "Fan", "Sessions fanned out like cards; pick the one that needs you.")
def _():
    card = lambda a, col: (f'<rect x="372" y="232" width="280" height="420" rx="60" fill="{col}" '
                           f'transform="rotate({a} 512 820)"/>')
    return tile("#FFD23F", card(-22, "#2EC4FF") + card(22, "#FF3D7F") + card(0, "#1B1340") +
        '<circle cx="512" cy="360" r="40" fill="#FFD23F"/>')


@mark("hive", "Hive", "Cells working side by side; one lit up.")
def _():
    import math
    def hexagon(cx, cy, r, col):
        pts = " ".join(f"{cx + r*math.cos(math.radians(60*i+30)):.1f},{cy + r*math.sin(math.radians(60*i+30)):.1f}" for i in range(6))
        return f'<polygon points="{pts}" fill="{col}" stroke="#FFB300" stroke-width="22" stroke-linejoin="round"/>'
    r = 150; dx = r * math.sqrt(3)
    return tile("#FFB300",
        hexagon(512 - dx/2, 512 - r*0.75, r, "#3A2200") + hexagon(512 + dx/2, 512 - r*0.75, r, "#3A2200") +
        hexagon(512 - dx/2, 512 + r*0.75, r, "#3A2200") + hexagon(512 + dx/2, 512 + r*0.75, r, "#FFF4E0"))


@mark("relay", "Relay", "A conversation handed from agent to agent, and back to you.")
def _():
    return tile("url(#g-relay)",
        '<path d="M232 300 Q232 232 300 232 H560 Q628 232 628 300 V460 Q628 528 560 528 H380 L300 600 V528 Q232 528 232 460 Z" fill="#fff"/>'
        '<path d="M792 500 Q792 432 724 432 H464 Q396 432 396 500 V660 Q396 728 464 728 H644 L724 800 V728 Q792 728 792 660 Z" fill="#1B1340" opacity=".9"/>'
        '<circle cx="530" cy="580" r="34" fill="#FFD23F"/><circle cx="630" cy="580" r="34" fill="#FFD23F"/>',
        lin("g-relay", "#2EC4FF", "#5B3DF5"))


def standalone(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}</svg>\n'


for name, _t, _s, body in MARKS:
    with open(os.path.join(HERE, f"{name}.svg"), "w") as f:
        f.write(standalone(body))

# The sheet: four across; each cell a big mark, the 32 and 16 point sizes beside it, title and line.
COLS, CELL, BIG, PAD = 4, 560, 380, 50
rows = (len(MARKS) + COLS - 1) // COLS
W = COLS * CELL + PAD * 2
H = 200 + rows * 462 - 20
out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {W}" width="{W}" height="{W}">',
       f'<rect width="{W}" height="{W}" fill="#FAFAF7"/>',
       f'<text x="{PAD+20}" y="{PAD+60}" font-family="-apple-system, Helvetica Neue, sans-serif" font-size="54" font-weight="800" fill="#111">Agents — logo ideas in colour</text>',
       f'<text x="{PAD+20}" y="{PAD+108}" font-family="-apple-system, Helvetica Neue, sans-serif" font-size="26" fill="#666">Each at icon size, then at 32 and 16 points, where marks fall apart.</text>']
for i, (name, title, says, body) in enumerate(MARKS):
    x = PAD + (i % COLS) * CELL + 20
    y = 210 + (i // COLS) * 700
    out.append(f'<svg x="{x}" y="{y}" width="{BIG}" height="{BIG}" viewBox="0 0 1024 1024">{body}</svg>')
    out.append(f'<svg x="{x+BIG+24}" y="{y+BIG-130}" width="64" height="64" viewBox="0 0 1024 1024">{body}</svg>')
    out.append(f'<svg x="{x+BIG+24}" y="{y+BIG-44}" width="32" height="32" viewBox="0 0 1024 1024">{body}</svg>')
    out.append(f'<text x="{x}" y="{y+BIG+56}" font-family="-apple-system, Helvetica Neue, sans-serif" font-size="34" font-weight="700" fill="#111">{i+1}. {title}</text>')
    # wrap the line at ~38 characters
    words, lines, cur = says.split(), [], ""
    for w in words:
        if len(cur) + len(w) > 36:
            lines.append(cur); cur = w
        else:
            cur = (cur + " " + w).strip()
    lines.append(cur)
    for j, ln in enumerate(lines):
        out.append(f'<text x="{x}" y="{y+BIG+98+j*32}" font-family="-apple-system, Helvetica Neue, sans-serif" font-size="24" fill="#555">{ln}</text>')
out.append("</svg>\n")
with open(os.path.join(HERE, "sheet.svg"), "w") as f:
    f.write("\n".join(out))
print(len(MARKS), "marks")
