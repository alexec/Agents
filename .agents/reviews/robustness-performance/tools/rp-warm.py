import sys, time, subprocess, threading
sys.argv=['x','/tmp/run-rp2','none']
exec(open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)),'rp-measure.py')).read().split("mode = sys.argv[2]")[0])
pid = int(open('/tmp/run-rp2/daemon.lock').read().split()[0])
c = C()
def kids(): return [int(x) for x in subprocess.run(["pgrep","-P",str(pid)],capture_output=True,text=True).stdout.split()]
def pipes(): return subprocess.run(["lsof","-p",str(pid)],capture_output=True,text=True).stdout.count(" PIPE ")
N=int(sys.argv[-1]) if False else 12
ids=[]
for k in range(N):
    a=c.call("agents/start",{"runtimeID":"demo","cwd":"file:///tmp/run-rp2/work/","prompt":f"hello {k}"})
    ids.append(a["id"] if isinstance(a,dict) else a)
for _ in range(100):
    st=[c.call("agents/list",{"agentID":i,"lean":True})[0]["state"] for i in ids]
    if all(s in("finished","stopped") for s in st): break
    time.sleep(0.2)
print("states", set(st)); time.sleep(2)
print("after turns: children", len(kids()), "fds", fds(pid), "pipes", pipes())
peak=[0]; stop=[False]
def sample():
    while not stop[0]:
        peak[0]=max(peak[0],len(kids())); time.sleep(0.005)
t=threading.Thread(target=sample); t.start()
t0=time.perf_counter()
for i in ids: c.call("agents/prewarm",{"agentID":i,"why":"opened"})
time.sleep(4); stop[0]=True; t.join()
print(f"prewarmed {N} sessions: peak children {peak[0]}, children now {len(kids())}, fds {fds(pid)}, pipes {pipes()}")
# kill -9 every runtime child, check cleanup and CPU
ks=kids(); 
for k in ks: subprocess.run(["kill","-9",str(k)])
time.sleep(4)
cpu=subprocess.run(["ps","-o","%cpu=","-p",str(pid)],capture_output=True,text=True).stdout.strip()
print(f"killed {len(ks)} warm runtimes: children {len(kids())}, fds {fds(pid)}, pipes {pipes()}, daemon cpu {cpu}%")
