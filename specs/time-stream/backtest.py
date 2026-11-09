# Backtest of the Timeline's forecast (wireframe.md, section 4). For each closed epic with 4 or more
# children, stop the clock just after 25%, 50% and 75% of its children closed, forecast its close from what
# was known then (only epics closed before that moment), and compare with when it really closed.
# Fetch first: the epics query in real.py, with subIssues(first:80) and no labels, into /tmp/bt/epics.json.
# Then: python3 specs/time-stream/backtest.py
import json, random, statistics as st
from datetime import datetime
P=lambda s: datetime.fromisoformat(s.replace("Z","+00:00")).timestamp()/3600 if s else None
E=[n for p in open("/tmp/bt/epics.json").read().replace("}{","}\n{").splitlines() for n in json.loads(p)["data"]["repository"]["issues"]["nodes"]]
ep=[]
for e in E:
    k=[dict(c=P(c["createdAt"]),x=P(c["closedAt"])) for c in e["subIssues"]["nodes"]]
    ep.append(dict(n=e["number"],c=P(e["createdAt"]),x=P(e["closedAt"]),np=e["stateReason"]=="NOT_PLANNED",k=k))
done=[e for e in ep if e["x"] and not e["np"] and len(e["k"])>=4 and all(c["x"] for c in e["k"])]
def gaps(e,upto):
    ts=sorted([e["c"]]+[c["x"] for c in e["k"] if c["x"]<=upto]); return [b-a for a,b in zip(ts,ts[1:])]
def growth(e): # children at the end / children that existed when the first child closed
    f=min(c["x"] for c in e["k"]); return len(e["k"])/max(1,sum(1 for c in e["k"] if c["c"]<=f))
R=random.Random(1)
def mc(pool,m,N=2000):
    s=sorted(sum(R.choice(pool) for _ in range(m)) for _ in range(N)); return s[N//2],s[N//10],s[N*9//10]
res={}
def add(name,pred,act,lo=None,hi=None):
    r=res.setdefault(name,[[],0,0]); a=max(act,0.05); p=max(pred,0.05)
    r[0].append(max(p/a,a/p))
    if lo is not None: r[1]+=1; r[2]+= lo<=act<=hi
cuts=0
for e in done:
    xs=sorted(c["x"] for c in e["k"])
    for q in (.25,.5,.75):
        t=xs[max(0,int(len(xs)*q)-1)]  # just after a close
        if t>=e["x"]-1e-6: continue
        known=[c for c in e["k"] if c["c"]<=t]; open_=[c for c in known if c["x"]>t]; nd=len(known)-len(open_)
        if not open_: continue
        act=e["x"]-t; cuts+=1
        past=[p for p in done if p["x"]<t]  # only epics closed before the cut
        pool=[g for p in past for g in gaps(p,p["x"])]
        m=len(open_)
        add("M0 now: 0.74 h per open child",0.74*m,act)
        if pool: add("M1 past gaps, median x open",st.median(pool)*m,act)
        el=t-e["c"]; add("M2 this epic's own rate so far",el/nd*m,act)
        if pool:
            mdn,lo,hi=mc(pool,m); add("M3 simulation of past gaps",mdn,act,lo,hi)
        own=gaps(e,t)
        pool2=own if len(own)>=3 else pool
        if pool2:
            mdn,lo,hi=mc(pool2,m); add("M4 simulation of own gaps (past if <3)",mdn,act,lo,hi)
        if past and pool2:
            gr=st.median([growth(p) for p in past]); mg=max(m,round(len(known)*gr)-nd)
            mdn,lo,hi=mc(pool2,mg); add("M5 M4 + scope growth of past epics",mdn,act,lo,hi)
print("closed epics",len(done),"cuts",cuts)
for k,(r,n,h) in sorted(res.items()):
    print(f"{k:42s} median error x{st.median(r):.2f}  within x2: {sum(x<=2 for x in r)}/{len(r)}"+(f"  P10-P90 holds {h}/{n}" if n else ""))
print("median scope growth",st.median([growth(e) for e in done]))
print("--- diagnosis")
lag=[e["x"]-max(c["x"] for c in e["k"]) for e in done]
print("epic close after its last child: median %.2fh, max %.1fh"%(st.median(lag),max(lag)))
tot=[e["x"]-e["c"] for e in done]; print("epic life median %.1fh p10 %.1f p90 %.1f"%(st.median(tot),sorted(tot)[len(tot)//10],sorted(tot)[len(tot)*9//10]))
allg=sorted(g for e in done for g in gaps(e,e["x"])); n=len(allg)
print("gaps: median %.2f p80 %.2f p95 %.2f max %.1f; share of time in gaps >3h: %.0f%%"%(allg[n//2],allg[int(n*.8)],allg[int(n*.95)],allg[-1],100*sum(g for g in allg if g>3)/sum(allg)))
# hour of day (Pacific = UTC-8) of child closes
from collections import Counter
h=Counter(int((c["x"]-8)%24) for e in ep for c in e["k"] if c["x"])
print("child closes by Pacific hour:"," ".join(f"{k}:{h[k]}" for k in range(24)))
# long gaps: what hour do they start
lg=Counter(); 
for e in done:
    ts=sorted([e["c"]]+[c["x"] for c in e["k"]])
    for a,b in zip(ts,ts[1:]):
        if b-a>3: lg[int((a-8)%24)]+=1
print("gaps >3h start at Pacific hour:",dict(sorted(lg.items())))
# M6 reference class: remaining = median over past epics of remaining/elapsed at same fraction
print("--- M6/M7")
res2={}
for e in done:
    xs=sorted(c["x"] for c in e["k"])
    for q in (.25,.5,.75):
        t=xs[max(0,int(len(xs)*q)-1)]
        if t>=e["x"]-1e-6: continue
        known=[c for c in e["k"] if c["c"]<=t]; nd=sum(1 for c in known if c["x"]<=t); m=len(known)-nd
        if not m: continue
        act=e["x"]-t; el=t-e["c"]; frac=nd/len(known)
        past=[p for p in done if p["x"]<t]
        rat=[]; rem=[]
        for p in past:
            pxs=sorted(c["x"] for c in p["k"]); j=max(0,min(len(pxs)-1,round(frac*len(pxs))-1)); pt=pxs[j]
            if p["x"]>pt and pt>p["c"]: rat.append((p["x"]-pt)/(pt-p["c"])); rem.append(p["x"]-pt)
        if len(rat)<3: continue
        for name,pred in (("M6 past epics' remaining/elapsed at same fraction",el*st.median(rat)),("M7 past epics' remaining hours at same fraction",st.median(rem))):
            r=res2.setdefault(name,[]); a=max(act,.05); p=max(pred,.05); r.append(max(a/p,p/a))
for k,r in res2.items(): print(f"{k:50s} median error x{st.median(r):.2f} within x2: {sum(x<=2 for x in r)}/{len(r)}")
import sys
QS=(.25,.5,.75,.9) if "--late" in sys.argv else (.25,.5,.75)
print("--- M8/M9 working clock, cuts at",QS)
import math
def clock_from(before):
    hc=Counter(int((x-8)%24) for e in ep for c in e["k"] if c["x"] and (x:=c["x"])<before)
    tot=sum(hc.values()) or 1; return [max(hc[i]/tot*24,0.05) for i in range(24)]  # rate per wall hour, mean 1
def W(t,rate):  # working hours from 0 to t (t in hours since epoch)
    full=math.floor(t); day=sum(rate)
    d,r=divmod(full,24); base=d*day+sum(rate[int((h-8)%24)] for h in range(d*24,full)); return base+rate[int((full-8)%24)]*(t-full)
def Winv(t0,w,rate):
    t=t0; acc=0
    while True:
        h=math.floor(t)+1; step=(h-t)*rate[int((math.floor(t)-8)%24)]
        if acc+step>=w: return t+(w-acc)/rate[int((math.floor(t)-8)%24)]
        acc+=step; t=h
res3={}
for e in done:
    xs=sorted(c["x"] for c in e["k"])
    for q in QS:
        t=xs[max(0,int(len(xs)*q)-1)]
        if t>=e["x"]-1e-6: continue
        known=[c for c in e["k"] if c["c"]<=t]; nd=sum(1 for c in known if c["x"]<=t); m=len(known)-nd
        if not m: continue
        past=[p for p in done if p["x"]<t]
        if len(past)<3: continue
        rate=clock_from(t); act=e["x"]-t
        wg=[]
        for p in past:
            ts=sorted([p["c"]]+[c["x"] for c in p["k"]]); wg+=[W(b,rate)-W(a,rate) for a,b in zip(ts,ts[1:])]
        gr=st.median([growth(p) for p in past]); mg=max(m,round(len(known)*gr)-nd)
        mgd=max(m,round(m+len(known)*(gr-1)*(1-nd/len(known))))
        for name,mm in (("M8 working clock, simulation of past gaps",m),("M9 M8 + scope growth",mg),("M10 M8 + scope growth that shrinks as the epic is done",mgd),("M11 M9, but at most twice the open children",min(mg,2*m))):
            s=sorted(sum(R.choice(wg) for _ in range(mm)) for _ in range(1000))
            pm,lo,hi=[Winv(t,s[i],rate)-t for i in (500,100,900)]
            r=res3.setdefault(name,[[],0]); a=max(act,.05); p=max(pm,.05); r[0].append(max(a/p,p/a)); r[1]+=lo<=act<=hi
for k,(r,h) in res3.items(): print(f"{k:45s} median error x{st.median(r):.2f} within x2: {sum(x<=2 for x in r)}/{len(r)}  P10-P90 holds {h}/{len(r)}")
