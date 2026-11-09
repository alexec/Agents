# Draws hifi-day.svg: Work ▸ Timeline on the Mac window, in the light appearance, from real data.
# A throwaway prototype, not product code. It reuses real.py's data and forecast (fetch as real.py says),
# then draws the window: python3 specs/time-stream/hifi.py
import html, os
from datetime import timedelta
src = open(os.path.join(os.path.dirname(__file__), "real.py")).read()
ns = {}
exec(src[: src.index("LANE=26")], ns)  # data, forecast and rows; not real.py's drawing
rows, NOW, T0, T1, epics = ns["rows"], ns["NOW"], ns["T0"], ns["T1"], ns["epics"]
rels, P = ns["rels"], ns["P"]
esc = lambda s: html.escape(s, quote=True)

W, H = 1440, 900
SB = 248                      # sidebar width
TB = 52                       # toolbar height
LEFT, RIGHT = SB + 28, W - 28
def X(t):
    t = min(max(t, T0), T1)
    return LEFT + (t - T0).total_seconds() / (T1 - T0).total_seconds() * (RIGHT - LEFT)
PST = timedelta(hours=-8)

# System colours (light), one per feature in a fixed order.
SYS = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#30B0C7", "#5856D6", "#00A89D", "#A2845E",
       "#FF3B30", "#C69200", "#32ADE6"]
feats = sorted({r["f"] for r in rows})
COL = {f: SYS[i % len(SYS)] for i, f in enumerate(feats)}

# Lanes: alternate above and below the releases line; a lane is free when its line and its label have ended.
LANE, CH = 30, 6.7
free = {}
for r in sorted(rows, key=lambda r: r["start"]):
    k = 1; side = 1 if len(free) % 2 == 0 else -1
    while True:
        ok = [c for c in (k * side, -k * side) if free.get(c, -1e9) + 10 < X(r["start"])]
        if ok: r["lane"] = ok[0]; break
        k += 1
    tail = r["end"] or r["hi"] or T1
    name = r["e"]["title"].replace("Epic: ", "")
    r["name"] = name if len(name) <= 38 else name[:37].rstrip() + "…"
    lab = (len(r["name"]) + 14) * CH
    free[r["lane"]] = max(X(tail) + 16, X(r["start"]) + 18 + lab)
maxl = max(abs(r["lane"]) for r in rows)
PT = TB + 64                                   # plot top
TRUNK = PT + maxl * LANE + 18
PB = TRUNK + maxl * LANE + 30                  # plot bottom
H = max(PB + 100, 720)                         # the window fits the plot
Y = lambda r: TRUNK - r["lane"] * LANE
nx = X(NOW)

o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
     f'font-family="-apple-system, \'SF Pro Text\', \'Helvetica Neue\', sans-serif">',
     '<defs>',
     '<filter id="sh" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="8" stdDeviation="14" flood-color="#1D1D1F" flood-opacity="0.16"/></filter>',
     '<filter id="pop" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="4" stdDeviation="8" flood-color="#1D1D1F" flood-opacity="0.18"/></filter>',
     f'<clipPath id="win"><rect width="{W}" height="{H}" rx="12"/></clipPath>',
     f'<clipPath id="plot"><rect x="{SB}" y="{TB}" width="{W-SB}" height="{H-TB}"/></clipPath>',
     '<symbol id="issue" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="8" cy="8" r="2" fill="currentColor"/></symbol>',
     '<symbol id="pr" viewBox="0 0 16 16"><circle cx="4" cy="3.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.2"/><circle cx="4" cy="12.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.2"/><circle cx="12" cy="12.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M4 5.1v5.8M12 10.9V6.5a2 2 0 0 0-2-2H7.5M9 3l-1.6 1.5L9 6" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></symbol>',
     '<symbol id="sparkles" viewBox="0 0 16 16"><path d="M6.5 2.5l1.2 3.3 3.3 1.2-3.3 1.2-1.2 3.3-1.2-3.3L2 7l3.3-1.2zM12 9.5l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6z" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/></symbol>',
     '<symbol id="flag" viewBox="0 0 16 16"><path d="M3.5 14V2.5M3.5 3h8.5l-2 3 2 3H3.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></symbol>',
     '<symbol id="box" viewBox="0 0 16 16"><path d="M2.5 5l5.5-2.5L13.5 5v6.5L8 14l-5.5-2.5zM2.5 5L8 7.5 13.5 5M8 7.5V14" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></symbol>',
     '<symbol id="timeline" viewBox="0 0 16 16"><path d="M1.5 9h13M3 9c2 0 2-5 4-5h3c2 0 2 5 4 5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/><circle cx="8.5" cy="4" r="1.3" fill="currentColor"/></symbol>',
     '<symbol id="person" viewBox="0 0 16 16"><circle cx="8" cy="5" r="2.6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M3 14c.6-2.8 2.6-4.2 5-4.2s4.4 1.4 5 4.2" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></symbol>',
     '<symbol id="plus" viewBox="0 0 16 16"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></symbol>',
     '<symbol id="chev" viewBox="0 0 10 10"><path d="M2 3.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></symbol>',
     '</defs>',
     f'<rect x="20" y="20" width="{W-40}" height="{H-40}" rx="12" fill="none" filter="url(#sh)"/>',
     '<g clip-path="url(#win)">',
     f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>']

# Sidebar
o.append(f'<rect width="{SB}" height="{H}" fill="#F3F3F5"/><line x1="{SB}" y1="0" x2="{SB}" y2="{H}" stroke="#E2E2E6"/>')
for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
    o.append(f'<circle cx="{22+i*20}" cy="26" r="6" fill="{c}"/>')
o.append('<g transform="translate(16 56)"><rect width="216" height="30" rx="7" fill="#FFFFFF" stroke="#DCDCE0"/>'
         '<use href="#plus" x="10" y="7" width="16" height="16" color="#3C3C43"/><text x="34" y="20" font-size="13" fill="#1D1D1F">New Session</text></g>')
y = 112
o.append(f'<text x="18" y="{y}" font-size="11" font-weight="600" fill="#8E8E93">Work</text>')
for ic, name in [("issue", "Issues"), ("pr", "Pull requests"), ("sparkles", "Features"), ("flag", "Milestones"),
                 ("box", "Releases"), ("timeline", "Timeline")]:
    y += 28
    sel = name == "Timeline"
    if sel: o.append(f'<rect x="10" y="{y-18}" width="{SB-20}" height="26" rx="6" fill="#007AFF"/>')
    col = "#FFFFFF" if sel else "#3C3C43"
    o.append(f'<use href="#{ic}" x="20" y="{y-13}" width="16" height="16" color="{"#FFFFFF" if sel else "#007AFF"}"/>'
             f'<text x="44" y="{y}" font-size="13" fill="{col}">{name}</text>')
y += 36
for grp in ["Your setup", "Machines", "Usage", "Agents", "Agents-web"]:
    o.append(f'<use href="#chev" x="16" y="{y-9}" width="10" height="10" color="#8E8E93" transform="rotate(-90 21 {y-4})"/>'
             f'<text x="30" y="{y}" font-size="11" font-weight="600" fill="#8E8E93">{grp}</text>'); y += 26

# Toolbar
o.append(f'<rect x="{SB}" y="0" width="{W-SB}" height="{TB}" fill="#FFFFFF"/><line x1="{SB}" y1="{TB}" x2="{W}" y2="{TB}" stroke="#E5E5EA"/>')
o.append(f'<text x="{SB+20}" y="24" font-size="15" font-weight="700" fill="#1D1D1F">Timeline</text>'
         f'<text x="{SB+20}" y="40" font-size="11" fill="#8E8E93">alexec/Agents · {len(rows)} epics</text>')
sx = W - 560
o.append(f'<g transform="translate({sx} 13)"><rect width="210" height="26" rx="7" fill="#EEEEF0"/>'
         '<rect x="72" y="2" width="66" height="22" rx="5.5" fill="#FFFFFF" stroke="#D8D8DC" stroke-width=".5"/>'
         '<text x="36" y="17.5" font-size="12" fill="#3C3C43" text-anchor="middle">1 Day</text>'
         '<text x="105" y="17.5" font-size="12" font-weight="600" fill="#1D1D1F" text-anchor="middle">2 Days</text>'
         '<text x="174" y="17.5" font-size="12" fill="#3C3C43" text-anchor="middle">Week</text></g>')
o.append(f'<g transform="translate({sx+222} 13)"><rect width="52" height="26" rx="7" fill="#EEEEF0"/><text x="26" y="17.5" font-size="12" fill="#1D1D1F" text-anchor="middle">Now</text></g>')
o.append(f'<g transform="translate({sx+286} 13)"><rect width="106" height="26" rx="7" fill="#EEEEF0"/>'
         '<rect x="8" y="7" width="12" height="12" rx="3" fill="#007AFF"/><path d="M10.5 13l2.2 2.2 4-4.4" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>'
         '<text x="28" y="17.5" font-size="12" fill="#1D1D1F">Forecast</text></g>')
o.append(f'<g transform="translate({sx+404} 13)"><rect width="124" height="26" rx="7" fill="#EEEEF0"/>'
         '<text x="12" y="17.5" font-size="12" fill="#1D1D1F">Board: All</text><use href="#chev" x="102" y="8" width="10" height="10" color="#3C3C43"/></g>')

o.append('<g clip-path="url(#plot)">')
# Forecast side, grid, axis
o.append(f'<rect x="{nx}" y="{TB}" width="{W-nx}" height="{H-TB}" fill="#F7F8FA"/>')
d = T0.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)
while d < T1:
    lt = d + PST
    if lt.hour % 3 == 0:
        x = X(d); major = lt.hour == 0
        o.append(f'<line x1="{x:.1f}" y1="{PT-24}" x2="{x:.1f}" y2="{PB}" stroke="{"#D1D1D6" if major else "#EDEDF0"}"/>')
        lab = f'{lt:%a %-d %b}' if major else (f'{lt:%-I %p}'.replace("AM", "am").replace("PM", "pm"))
        o.append(f'<text x="{x+4:.1f}" y="{PB+18}" font-size="11" fill="{"#1D1D1F" if major else "#8E8E93"}" font-weight="{600 if major else 400}">{lab}</text>')
    d += timedelta(hours=1)
o.append(f'<text x="{nx+12}" y="{PT-30}" font-size="11" font-weight="600" fill="#8E8E93" letter-spacing=".4">FORECAST</text>'
         f'<text x="{nx-12}" y="{PT-30}" font-size="11" font-weight="600" fill="#8E8E93" letter-spacing=".4" text-anchor="end">DONE</text>')

def curve(x1, y1, x2, y2):
    m = (x1 + x2) / 2
    return f"C{m:.1f} {y1} {m:.1f} {y2} {x2:.1f} {y2}"

# Releases line
o.append(f'<line x1="{LEFT-20}" y1="{TRUNK}" x2="{nx}" y2="{TRUNK}" stroke="#AEAEB2" stroke-width="3" stroke-linecap="round"/>'
         f'<line x1="{nx}" y1="{TRUNK}" x2="{RIGHT+20}" y2="{TRUNK}" stroke="#C7C7CC" stroke-width="3" stroke-dasharray="7 6"/>')
for tag, at in rels:
    t = P(at)
    if T0 <= t <= T1:
        x = X(t)
        o.append(f'<circle cx="{x:.1f}" cy="{TRUNK}" r="7" fill="#FFFFFF" stroke="#1D1D1F" stroke-width="2"/>'
                 f'<rect x="{x-30:.1f}" y="{TRUNK+12}" width="60" height="18" rx="9" fill="#1D1D1F"/>'
                 f'<text x="{x:.1f}" y="{TRUNK+25}" font-size="11" font-weight="600" fill="#FFFFFF" text-anchor="middle">{tag}</text>')

# Epics
pop = None
labels = []
for r in rows:
    e = r["e"]; c = COL[r["f"]]; y = Y(r); x0 = X(r["start"]); xf = x0 + 18
    clipped = r["start"] < T0
    fork = (lambda xe: f"M{LEFT-20:.1f} {y}") if clipped else (lambda xe: f"M{x0:.1f} {TRUNK} {curve(x0,TRUNK,xf,y)}")
    kids = e["subIssues"]["nodes"]
    if r["end"]:
        xe = X(r["end"])
        if r["notplanned"]:
            o.append(f'<path d="{fork(0)} L{xe:.1f} {y}" fill="none" stroke="#C7C7CC" stroke-width="2"/>')
        else:
            xb = max(xe - 18, xf if not clipped else LEFT)
            o.append(f'<path d="{fork(0)} L{xb:.1f} {y} {curve(xb,y,xe,TRUNK)}" fill="none" stroke="{c}" stroke-width="2.5" stroke-linecap="round"/>'
                     f'<circle cx="{xe:.1f}" cy="{TRUNK}" r="5" fill="{c}" stroke="#FFFFFF" stroke-width="1.5"/>')
    else:
        o.append(f'<path d="{fork(0)} L{nx:.1f} {y}" fill="none" stroke="{c}" stroke-width="2.5" stroke-linecap="round"/>')
        if r["lo"]:
            xl0, xh = X(r["lo"]), X(r["hi"])
            o.append(f'<rect x="{xl0:.1f}" y="{y-7}" width="{max(xh-xl0,4):.1f}" height="14" rx="7" fill="{c}" fill-opacity=".13"/>')
        if r["pred"]:
            xl = X(r["pred"][-1][1])
            if r["pjoin"]:
                xj = X(r["pjoin"])
                o.append(f'<path d="M{nx:.1f} {y} L{xl:.1f} {y} {curve(xl,y,xj,TRUNK)}" fill="none" stroke="{c}" stroke-width="1.8" stroke-dasharray="4 4" stroke-linecap="round"/>'
                         f'<circle cx="{xj:.1f}" cy="{TRUNK}" r="5" fill="#FFFFFF" stroke="{c}" stroke-width="2"/>')
                if pop is None or r["pjoin"] < pop[0]["pjoin"]: pop = (r, xj, y)
            else:
                o.append(f'<path d="M{nx:.1f} {y} L{xl+14:.1f} {y}" fill="none" stroke="{c}" stroke-width="1.8" stroke-dasharray="4 4" stroke-linecap="round"/>')
            for _, t in r["pred"]:
                o.append(f'<circle cx="{X(t):.1f}" cy="{y}" r="3.5" fill="#FFFFFF" stroke="{c}" stroke-width="1.5"/>')
        if r["waits"]:
            xq = (X(r["pred"][-1][1]) if r["pred"] else nx) + 22
            txt = f'{len(r["waits"])} wait for Alex'
            wq = len(txt) * 6.4 + 30
            o.append(f'<g transform="translate({xq:.1f} {y-10})"><rect width="{wq:.0f}" height="20" rx="10" fill="#FFF4E5" stroke="#FFB340" stroke-width=".8"/>'
                     f'<use href="#person" x="7" y="3" width="14" height="14" color="#C46A00"/><text x="24" y="14" font-size="11" fill="#9A5200">{txt}</text></g>')
    for k in r["done"]:
        t = P(k["closedAt"])
        if t < T0: continue
        np_ = k["stateReason"] == "NOT_PLANNED"
        o.append(f'<circle cx="{X(t):.1f}" cy="{y}" r="{2.5 if np_ else 4}" fill="{"#C7C7CC" if np_ else c}" stroke="#FFFFFF" stroke-width="1.5"><title>#{k["number"]} {esc(k["title"])}</title></circle>')
    lx = max(xf + 4, LEFT - 8) if not clipped else LEFT - 14
    count = f'{len(r["done"])} of {len(kids)}'
    labels.append(f'<text x="{lx:.1f}" y="{y-8}" font-size="12" stroke="#FFFFFF" stroke-width="4" stroke-linejoin="round" paint-order="stroke"><tspan fill="{c}" font-weight="600">{"← " if clipped else ""}{esc(r["name"])}</tspan>'
             f'<tspan fill="#8E8E93"> #{e["number"]} · {count}</tspan></text>')

o += labels
# Now
o.append(f'<line x1="{nx:.1f}" y1="{PT-20}" x2="{nx:.1f}" y2="{PB}" stroke="#FF3B30" stroke-width="1.5"/>'
         f'<circle cx="{nx:.1f}" cy="{PT-20}" r="4" fill="#FF3B30"/>'
         f'<rect x="{nx-30:.1f}" y="{PB+4}" width="60" height="20" rx="10" fill="#FF3B30"/>'
         f'<text x="{nx:.1f}" y="{PB+18}" font-size="11" font-weight="600" fill="#FFFFFF" text-anchor="middle">{(NOW+PST):%-I:%M %p}</text>')

# Popover on the first forecast join
if pop:
    r, xj, ly = pop
    lo, hi, pj = r["lo"] + PST, r["hi"] + PST, r["pjoin"] + PST
    left = len(r["pred"])
    px, py, pw, ph = xj + 18, TRUNK + 40, 330, 128
    o.append(f'<g filter="url(#pop)"><rect x="{px:.1f}" y="{py}" width="{pw}" height="{ph}" rx="10" fill="#FFFFFF" stroke="#E5E5EA"/></g>'
             f'<path d="M{xj+6:.1f} {TRUNK+6} L{px+18:.1f} {py}" stroke="#D1D1D6" stroke-width="1"/>'
             f'<text x="{px+16:.1f}" y="{py+24}" font-size="13" font-weight="600" fill="#1D1D1F">{esc(r["name"])}</text>'
             f'<text x="{px+16:.1f}" y="{py+44}" font-size="12" fill="#3C3C43">#{r["e"]["number"]} · {len(r["done"])} of {len(r["e"]["subIssues"]["nodes"])} done · {left} left</text>'
             f'<text x="{px+16:.1f}" y="{py+70}" font-size="12" fill="#1D1D1F">Closes about <tspan font-weight="600">{pj:%-I %p}</tspan>'.replace("AM", "am").replace("PM", "pm") + '</text>'
             f'<text x="{px+16:.1f}" y="{py+88}" font-size="12" fill="#3C3C43">8 times in 10: {lo:%-I:%M %p} – {hi:%a %-I:%M %p}</text>'
             f'<text x="{px+16:.1f}" y="{py+112}" font-size="11" fill="#8E8E93">From 18 past epics · off by ×2.2 on average</text>')
o.append('</g>')   # plot clip

# Legend
ly = H - 34
o.append(f'<line x1="{SB}" y1="{ly-18}" x2="{W}" y2="{ly-18}" stroke="#E5E5EA"/>')
lg = [("dot", "Issue closed"), ("ring", "Forecast"), ("band", "8 times in 10"), ("tag", "Release"), ("now", "Now")]
x = SB + 24
for kind, label in lg:
    if kind == "dot": o.append(f'<circle cx="{x+5}" cy="{ly-4}" r="4" fill="#007AFF"/>')
    if kind == "ring": o.append(f'<circle cx="{x+5}" cy="{ly-4}" r="3.5" fill="#fff" stroke="#007AFF" stroke-width="1.5"/>')
    if kind == "band": o.append(f'<rect x="{x-4}" y="{ly-11}" width="22" height="14" rx="7" fill="#007AFF" fill-opacity=".13"/>')
    if kind == "tag": o.append(f'<circle cx="{x+5}" cy="{ly-4}" r="5" fill="#fff" stroke="#1D1D1F" stroke-width="2"/>')
    if kind == "now": o.append(f'<line x1="{x+5}" y1="{ly-12}" x2="{x+5}" y2="{ly+4}" stroke="#FF3B30" stroke-width="1.5"/>')
    o.append(f'<text x="{x+24}" y="{ly}" font-size="11" fill="#6E6E73">{label}</text>')
    x += 24 + len(label) * 6.4 + 28
o.append('</g></svg>')
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hifi-day.svg")
open(out, "w").write("\n".join(o))
print("wrote", out, "rows", len(rows), "lanes", maxl, "plot bottom", PB)
