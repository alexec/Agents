import sys, time, subprocess, json
sys.argv=['x','/tmp/run-rk','none']
exec(open('/tmp/rp-measure.py').read().split("mode = sys.argv[2]")[0])
pid = int(open('/tmp/run-rk/daemon.lock').read().split()[0])
c = C()
def kids():
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
    return [int(x) for x in out]
def pipes(): return subprocess.run(["lsof","-p",str(pid)],capture_output=True,text=True).stdout.count(" PIPE ")
print("start: fds", fds(pid), "pipes", pipes(), "children", len(kids()))
states = []
for k in range(int(sys.argv[-1]) if False else 10):
    before = set(kids())
    a = c.call("agents/start", {"runtimeID": "grok", "cwd": "file:///tmp/run-rk/work/", "prompt": f"long reply {k}"})
    aid = a["id"] if isinstance(a, dict) else a
    rt = None
    for _ in range(100):
        new = set(kids()) - before
        if new: rt = new.pop(); break
        time.sleep(0.1)
    time.sleep(1.5)
    subprocess.run(["kill", "-9", str(rt)])
    time.sleep(1.5)
    st = c.call("agents/list", {"agentID": aid, "lean": True})
    states.append(st[0]["state"] if st else "?")
    print(f"killed runtime {rt}: agent {st[0]['state'] if st else '?'}; fds {fds(pid)} pipes {pipes()} children {len(kids())}")
time.sleep(3)
print("end: fds", fds(pid), "pipes", pipes(), "children", len(kids()), "daemon cpu", subprocess.run(["ps","-o","%cpu=","-p",str(pid)],capture_output=True,text=True).stdout.strip())
