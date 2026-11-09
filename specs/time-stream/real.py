# Draws real.svg, the time stream from this repo's real epics (specs/time-stream/wireframe.md).
# A throwaway prototype, not product code. To draw it again, first fetch into /tmp/ts:
#   gh api graphql --paginate -f query='query($endCursor:String){ repository(owner:"alexec",name:"Agents"){ issues(labels:["epic"], first:20, after:$endCursor){ pageInfo{hasNextPage endCursor} nodes{ number title state stateReason createdAt closedAt labels(first:20){nodes{name}} subIssues(first:60){ nodes{ number title state stateReason createdAt closedAt labels(first:15){nodes{name}} } } } } } }' > /tmp/ts/epics.json
#   echo "[]" > /tmp/ts/closed.json
#   gh release list --limit 30 --json tagName,publishedAt -q '.[]|"\(.tagName) \(.publishedAt)"' > /tmp/ts/rels.txt
# then: python3 specs/time-stream/real.py  (the ALEX set is the open alex-todo issues when it was drawn)
import json, statistics, hashlib, html
from datetime import datetime, timedelta, timezone
P=lambda s: datetime.fromisoformat(s.replace("Z","+00:00")) if s else None
epics=[n for page in open("/tmp/ts/epics.json").read().replace("}{","}\n{").splitlines() for n in json.loads(page)["data"]["repository"]["issues"]["nodes"]]
closed=json.load(open("/tmp/ts/closed.json"))
ALEX={4135,4079,3951,3911,3908,3782,3739,3495,3494,3418,3416,3415,3414,3413,3412,3410,3004,2227,1781,1780,1064}
rels=[l.split() for l in open("/tmp/ts/rels.txt")]
NOW=datetime.now(timezone.utc)
HALF=timedelta(hours=24); T0=NOW-HALF; T1=NOW+HALF  # Now in the centre
W,LEFT,RIGHT=1500,30,1470
def X(t):
    t=min(max(t,T0),T1)
    return LEFT+(t-T0).total_seconds()/(T1-T0).total_seconds()*(RIGHT-LEFT)
def esc(s): return html.escape(s,quote=True)
# The forecast (M10 in backtest.py): a working clock that runs at the rate this repo closes issues at each
# hour of the day (Pacific), a simulation of the gaps between child closes of closed epics on that clock,
# and the scope growth of past epics, less as the epic is done. Backtest at 25/50/75/90%: off by x2.2 (median).
import math, random
from collections import Counter
H_=lambda d: d.timestamp()/3600
hc=Counter(int((H_(P(c["closedAt"]))-8)%24) for e in epics for c in e["subIssues"]["nodes"] if c["closedAt"])
RATE=[max(hc[i]/sum(hc.values())*24,0.05) for i in range(24)]
def WC(t):
    full=math.floor(t); d=full//24
    return d*sum(RATE)+sum(RATE[int((h-8)%24)] for h in range(d*24,full))+RATE[int((full-8)%24)]*(t-full)
def Winv(t,w):
    acc=0
    while True:
        r=RATE[int((math.floor(t)-8)%24)]; step=(math.floor(t)+1-t)*r
        if acc+step>=w: return t+(w-acc)/r
        acc+=step; t=math.floor(t)+1
def wall(h): return datetime.fromtimestamp(h*3600,timezone.utc)
WG=[]; GROW=[]
for e in epics:
    if e["state"]!="CLOSED" or e["stateReason"]=="NOT_PLANNED": continue
    k=e["subIssues"]["nodes"]
    if len(k)<4 or any(not c["closedAt"] for c in k): continue
    ts=sorted([H_(P(e["createdAt"]))]+[H_(P(c["closedAt"])) for c in k]); WG+=[WC(b)-WC(a) for a,b in zip(ts,ts[1:])]
    f=min(P(c["closedAt"]) for c in k); GROW.append(len(k)/max(1,sum(1 for c in k if P(c["createdAt"])<=f)))
GR=statistics.median(GROW); RND=random.Random(1)
print("forecast from %d gaps, scope growth x%.2f"%(len(WG),GR))
inepic={c["number"] for e in epics for c in e["subIssues"]["nodes"]}
PAL=["#5cf2c4","#ffb347","#6fa8ff","#c38bff","#ff7eb6","#f2e85c","#7ef29a","#5ce1f2","#ff9a5c","#b3a1ff","#9ff25c","#f25c8e"]
feats=sorted({next((l["name"][8:] for l in e["labels"]["nodes"] if l["name"].startswith("feature:")),"none") for e in epics})
COL={f:PAL[i%len(PAL)] for i,f in enumerate(feats)}
rows=[]
for e in epics:
    f=next((l["name"][8:] for l in e["labels"]["nodes"] if l["name"].startswith("feature:")),"none")
    start=P(e["createdAt"]); end=P(e["closedAt"])
    kids=e["subIssues"]["nodes"]
    done=[c for c in kids if c["state"]=="CLOSED"]
    openk=[c for c in kids if c["state"]=="OPEN"]
    waits=[c for c in openk if c["number"] in ALEX or any(l["name"] in("needs-account","alex-todo") for l in c["labels"]["nodes"])]
    pred=[c for c in openk if c not in waits]
    pts=[]; pjoin=lo=hi=None
    if pred and e["state"]=="OPEN":
        kn=len(kids)-len(waits)  # M10: the growth still to come shrinks as the epic is done
        mg=max(len(pred),round(len(pred)+kn*(GR-1)*(1-len(done)/max(kn,1))))
        sims=sorted(sum(RND.choice(WG) for _ in range(mg)) for _ in range(1000))
        n0=H_(NOW); p10,p50,p90=sims[100],sims[500],sims[900]
        pts=[(c,wall(Winv(n0,p50*(i+1)/mg))) for i,c in enumerate(pred)]
        lo,hi=wall(Winv(n0,p10)),wall(Winv(n0,p90))
        if not waits: pjoin=wall(Winv(n0,p50))
    t=pts[-1][1] if pts else NOW
    pend=end or (t if pred else NOW)
    rows.append(dict(e=e,f=f,start=start,end=end,done=done,pred=pts,waits=waits,pjoin=pjoin,lo=lo,hi=hi,pend=max(pend,NOW) if not end else end,notplanned=e["stateReason"]=="NOT_PLANNED"))
rows=[r for r in rows if r["start"]<=T1 and (not r["end"] or r["end"]>=T0)]  # only epics that overlap the window
rows.sort(key=lambda r:r["start"])
# lanes: alternate above/below, nearest free
LANE=26; free={}  # lane index (+k above, -k below) -> busy until
for r in rows:
    k=1; side=1 if len(free)%2==0 else -1
    while True:
        cand=[k*side,-k*side]
        ok=[c for c in cand if free.get(c,-1e9)+8<X(r["start"])]
        if ok: r["lane"]=ok[0]; break
        k+=1
    tail=r["end"] or r["hi"] or T1
    lab=min(len(r["e"]["title"].replace("Epic: ",""))+7,41)*6.1
    free[r["lane"]]=max(X(tail)+14,X(r["start"])+16+lab)
maxl=max(abs(r["lane"]) for r in rows)
TOP=90; TRUNK=TOP+maxl*LANE+20; H=TRUNK+maxl*LANE+90
Y=lambda r: TRUNK-r["lane"]*LANE
o=[f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="SF Mono, Menlo, monospace" font-size="11">',
'<defs><filter id="g" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="2.2" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>',
f'<rect width="{W}" height="{H}" fill="#070b14"/>',
f'<text x="24" y="30" fill="#cfe3ff" font-size="15">Work ▸ Timeline · alexec/Agents · real data, read {NOW:%Y-%m-%d %H:%M} UTC</text>',
f'<text x="24" y="50" fill="#7f93b3">{len(rows)} epics on screen · 24 h each side of Now · Forecast: working clock + past epics (backtest x2.2); band = P10-P90 of the close · ? = waits for Alex</text>']
nx=X(NOW)
o.append(f'<rect x="{nx}" y="64" width="{RIGHT-nx+30}" height="{H-100}" fill="#0b1222" opacity="0.7"/>')
o.append(f'<line x1="{nx}" y1="64" x2="{nx}" y2="{H-40}" stroke="#e8f1ff" stroke-dasharray="2 3"/><text x="{nx+6}" y="78" fill="#e8f1ff">NOW</text>')
d=T0.replace(minute=0,second=0,microsecond=0)+timedelta(hours=6-T0.hour%6)
while d<T1:
    x=X(d); lab=f"{d:%b %-d}" if d.hour==0 else f"{d:%H}:00"
    o.append(f'<line x1="{x}" y1="64" x2="{x}" y2="{H-40}" stroke="{"#1a2438" if d.hour==0 else "#111a2b"}"/><text x="{x+3}" y="{H-22}" fill="#4d5f7d" font-size="{11 if d.hour==0 else 9}">{lab}</text>'); d+=timedelta(hours=6)
o.append(f'<line x1="{LEFT}" y1="{TRUNK}" x2="{nx}" y2="{TRUNK}" stroke="#9fd0ff" stroke-width="5" filter="url(#g)"/><line x1="{nx}" y1="{TRUNK}" x2="{RIGHT}" y2="{TRUNK}" stroke="#9fd0ff" stroke-width="5" stroke-dasharray="10 6" opacity=".45"/>')
for tag,at in rels:
    t=P(at)
    if t>=T0: o.append(f'<circle cx="{X(t)}" cy="{TRUNK}" r="8" fill="#070b14" stroke="#e8f1ff" stroke-width="2"><title>{tag} {at[:16]}</title></circle><text x="{X(t)-16}" y="{TRUNK+24}" fill="#7f93b3" font-size="10">{tag}</text>')
nb=0
def curve(x1,y1,x2,y2): m=(x1+x2)/2; return f"C{m} {y1} {m} {y2} {x2} {y2}"
for r in rows:
    e=r["e"]; c=COL[r["f"]]; y=Y(r); x0=X(r["start"]); xf=x0+14
    name=esc(e["title"].replace("Epic: ","")[:34]); tip=esc(f'#{e["number"]} {e["title"]} · {len(r["done"])} of {len(e["subIssues"]["nodes"])} · feature:{r["f"]}')
    o.append(f'<g><title>{tip}</title>')
    if r["end"]:
        xe=X(r["end"]); col="#7f93b3" if r["notplanned"] else c
        if r["notplanned"]:
            o.append(f'<path d="M{x0} {TRUNK} {curve(x0,TRUNK,xf,y)} L{xe} {y}" fill="none" stroke="{col}" stroke-width="2" opacity=".6"/><text x="{xe+2}" y="{y+4}" fill="{col}">✕</text>')
        else:
            o.append(f'<path d="M{x0} {TRUNK} {curve(x0,TRUNK,xf,y)} L{max(xe-14,xf)} {y} {curve(max(xe-14,xf),y,xe,TRUNK)}" fill="none" stroke="{col}" stroke-width="2.5" filter="url(#g)"/><circle cx="{xe}" cy="{TRUNK}" r="4.5" fill="{col}"/>')
    else:
        o.append(f'<path d="M{x0} {TRUNK} {curve(x0,TRUNK,xf,y)} L{nx} {y}" fill="none" stroke="{c}" stroke-width="2.5" filter="url(#g)"/>')
        if r["pred"]:
            xl=X(r["pred"][-1][1])
            if r["pjoin"]:
                xj=X(r["pjoin"]); xl0=X(r["lo"]); xh=X(r["hi"])
                o.append(f'<path d="M{nx} {y} L{xl} {y} {curve(xl,y,xj,TRUNK)}" fill="none" stroke="{c}" stroke-width="2" stroke-dasharray="5 4" opacity=".7"/>')
                o.append(f'<rect x="{xl0}" y="{y-6}" width="{max(xh-xl0,2)}" height="12" rx="6" fill="{c}" opacity=".16"><title>closes between {r["lo"]:%b %-d %H:%M} and {r["hi"]:%b %-d %H:%M} UTC, 8 times in 10</title></rect><circle cx="{xj}" cy="{TRUNK}" r="4.5" fill="none" stroke="{c}" stroke-width="1.5"/>')
            else:
                o.append(f'<path d="M{nx} {y} L{xl+18} {y}" fill="none" stroke="{c}" stroke-width="2" stroke-dasharray="5 4" opacity=".7"/>')
            for k,t in r["pred"]: o.append(f'<circle cx="{X(t):.1f}" cy="{y}" r="3" fill="#070b14" stroke="{c}" opacity=".8"><title>#{k["number"]} {esc(k["title"])} · forecast about {t:%b %-d %H:%M} UTC</title></circle>')
        if r["waits"]:
            xq=(X(r["pred"][-1][1]) if r["pred"] else nx)+26
            o.append(f'<text x="{xq}" y="{y+4}" fill="{c}" font-size="13">?</text><text x="{xq+10}" y="{y+4}" fill="#7f93b3" font-size="9">{len(r["waits"])} wait for Alex</text>')
    for k in r["done"]:
        t=P(k["closedAt"]); np_=k["stateReason"]=="NOT_PLANNED"
        o.append(f'<circle cx="{X(t):.1f}" cy="{y}" r="{2 if np_ else 3.2}" fill="{"#7f93b3" if np_ else c}"><title>#{k["number"]} {esc(k["title"])} · closed {k["closedAt"][:16]}</title></circle>')
    o.append(f'<text x="{max(x0+16,LEFT+4)}" y="{y-6}" fill="{c}" font-size="10">{"◀ " if r["start"]<T0 else ""}#{e["number"]} {name}</text></g>')
o.append(f'<text x="24" y="{H-6}" fill="#4d5f7d" font-size="10">rings on main: releases · ◀ an epic that started before the left edge · fork = epic filed (lineage has no start time yet) · hover a dot for its issue</text></svg>')
open("/Users/alexcollins/Agents/specs/time-stream/real.svg","w").write("\n".join(o))
print("lanes",maxl,"height",H,"bugs",nb)
