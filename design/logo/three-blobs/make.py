# Ideas for "3 happy blobs": each a 1024 tile; sheet shows each at 240, 64, 32 and 16 pt.
BG = '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5B9BFF"/><stop offset="1" stop-color="#1A52C0"/></linearGradient></defs><rect width="1024" height="1024" rx="230" fill="url(#g)"/>'
BODY = "M0 -290 C188 -290 300 -186 300 4 C300 196 188 290 0 290 C-188 290 -300 196 -300 4 C-300 -186 -188 -290 0 -290 Z"
INK = "#0E1A3A"
RIM = "#3A78E6"

def blob(x, y, s, fill="#fff", eyes="oval", smile=True, cheeks=False, rim=True, look=0, tilt=0):
    g = f'<g transform="translate({x} {y}) rotate({tilt}) scale({s})">'
    if rim:
        g += f'<path d="{BODY}" fill="none" stroke="{RIM}" stroke-width="{56}" stroke-linejoin="round"/>'
    g += f'<path d="{BODY}" fill="{fill}"/>'
    for ex in (-92 + look, 92 + look):
        if eyes == "oval":
            g += f'<ellipse cx="{ex}" cy="-30" rx="46" ry="62" fill="{INK}"/>'
        else:  # happy ^ ^
            g += f'<path d="M{ex-44} -10 Q{ex} -86 {ex+44} -10" fill="none" stroke="{INK}" stroke-width="30" stroke-linecap="round"/>'
    if cheeks:
        for cx in (-170 + look, 170 + look):
            g += f'<ellipse cx="{cx}" cy="70" rx="42" ry="26" fill="#FF9BB0" opacity="0.8"/>'
    if smile:
        g += f'<path d="M{-64+look} 80 Q{look} 150 {64+look} 80" fill="none" stroke="{INK}" stroke-width="28" stroke-linecap="round"/>'
    return g + "</g>"

W = "#fff"; SKY = "#CFE3FF"; SUN = "#FFE08A"; MINT = "#BFF2DA"; PEACH = "#FFC9B0"
ideas = {
  "A  Trio in a row": blob(512, 470, .62) + blob(232, 610, .5, look=22) + blob(792, 610, .5, look=-22),
  "B  Huddle": blob(300, 430, .5, SKY, look=20, tilt=-8) + blob(724, 430, .5, SKY, look=-20, tilt=8) + blob(512, 600, .62),
  "C  Triangle": blob(512, 330, .44) + blob(318, 650, .44, look=14) + blob(706, 650, .44, look=-14),
  "D  Three colours": blob(300, 420, .48, SUN, look=20, tilt=-6) + blob(724, 420, .48, MINT, look=-20, tilt=6) + blob(512, 610, .6),
  "E  Happy eyes": blob(512, 470, .62, eyes="arc") + blob(232, 610, .5, eyes="arc") + blob(792, 610, .5, eyes="arc"),
  "F  Cheeks": blob(300, 430, .5, cheeks=True, look=20, tilt=-8) + blob(724, 430, .5, cheeks=True, look=-20, tilt=8) + blob(512, 600, .62, cheeks=True),
  "G  Big and two small": blob(470, 480, .78, look=30) + blob(790, 700, .34, PEACH, look=-24) + blob(250, 760, .3, SUN, look=24),
  "H  Leaning in": blob(250, 560, .48, SKY, look=34, tilt=-14) + blob(774, 560, .48, SKY, look=-34, tilt=14) + blob(512, 470, .58, eyes="arc"),
}

def tile(inner):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{BG}{inner}</svg>'

import os
cols, cw, ch = 4, 440, 400
rows = (len(ideas) + cols - 1) // cols
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{cols*cw}" height="{rows*ch+40}"><rect width="100%" height="100%" fill="#F4F5F7"/>']
for i, (name, inner) in enumerate(ideas.items()):
    slug = name.split()[0]
    open(f"{slug}.svg", "w").write(tile(inner))
    x0, y0 = (i % cols) * cw + 20, (i // cols) * ch + 30
    out.append(f'<text x="{x0}" y="{y0}" font-family="Helvetica" font-size="20" font-weight="bold" fill="#222">{name}</text>')
    for size, dx, dy in ((240, 0, 14), (64, 260, 14), (32, 340, 14), (16, 390, 14)):
        out.append(f'<svg x="{x0+dx}" y="{y0+dy}" width="{size}" height="{size}" viewBox="0 0 1024 1024">{BG}{inner}</svg>')
out.append("</svg>")
open("sheet.svg", "w").write("".join(out))
