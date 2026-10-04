import sys, statistics, time
sys.argv=['x','/tmp/run-rp2','none']
exec(open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)),'rp-measure.py')).read().split("mode = sys.argv[2]")[0])
c=C()
for name,p in [("projects/list",{}),("client/catchUp",{}),("dashboard/summaries",{}),("pins/list",{}),("workflows/list",{})]:
    try:
        m,mx,sz=timed(c,name,p); print(f"| {name} | {m:.1f} | {mx:.1f} | {sz:,} |")
    except Exception as e: print(name,"error",str(e)[:120])
