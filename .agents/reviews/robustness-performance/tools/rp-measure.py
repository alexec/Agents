#!/usr/bin/env python3
# Measurements for the 2026-10-03 review, against a scratch root's daemon.sock only.
import json, os, socket, statistics, sys, threading, time, subprocess
ROOT = sys.argv[1]; assert ROOT.startswith("/tmp/run-")
SOCK = ROOT + "/daemon.sock"

class C:
    def __init__(s, read=True):
        s.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.s.connect(SOCK); s.buf = b""; s.n = 0
        s.notes = {}; s.lock = threading.Lock(); s.replies = {}; s.cv = threading.Condition(s.lock); s.last = {}
        if read: threading.Thread(target=s.loop, daemon=True).start()
    def loop(s):
        while True:
            try: d = s.s.recv(1 << 20)
            except OSError: return
            if not d: return
            s.buf += d
            while b"\n" in s.buf:
                line, s.buf = s.buf.split(b"\n", 1)
                m = json.loads(line)
                with s.cv:
                    if "method" in m and "id" not in m:
                        s.notes[m["method"]] = s.notes.get(m["method"], 0) + 1; s.last[m["method"]] = time.perf_counter()
                    elif "id" in m: s.replies[m["id"]] = m; s.cv.notify_all()
    def call(s, method, params=None, timeout=120):
        with s.cv: s.n += 1; i = s.n
        req = {"jsonrpc": "2.0", "id": i, "method": method}
        if params is not None: req["params"] = params
        s.s.sendall((json.dumps(req) + "\n").encode())
        with s.cv:
            ok = s.cv.wait_for(lambda: i in s.replies, timeout)
            if not ok: raise TimeoutError(method)
            r = s.replies.pop(i)
        if "error" in r: raise RuntimeError(f"{method}: {r['error']}")
        return r.get("result")

def timed(c, method, params=None, runs=7):
    ts = []; size = 0
    for _ in range(runs):
        t = time.perf_counter(); r = c.call(method, params); ts.append((time.perf_counter() - t) * 1000)
        size = len(json.dumps(r))
    return statistics.median(ts), max(ts), size

def rss(pid): return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0) // 1024
def fds(pid): return len(subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines()) - 1

mode = sys.argv[2]
pid = int(open(ROOT + "/daemon.lock").read().split()[0])
c = C()
if mode == "lists":
    agents = c.call("agents/list", {"lean": True})
    folder = agents[0]["cwd"] if agents else None
    one = agents[0]["id"] if agents else None
    rows = [("daemon/ping", None), ("projects/list", None), ("agents/list, lean", {"lean": True}),
            ("agents/list", {}), ("agents/list, lean, includeArchived", {"lean": True, "includeArchived": True}),
            ("agents/list, includeArchived", {"includeArchived": True}),
            ("agents/list, one agentID", {"agentID": one}), ("agents/list, one folder, lean", {"folder": folder, "lean": True}),
            ("agents/list, one folder archivedOnly lean", {"folder": folder, "archivedOnly": True, "lean": True}),
            ("events/list", {}), ("workflows/list", None), ("retention/state", None)]
    print(f"| call | median ms | max ms | reply bytes |\n|---|---|---|---|")
    for name, p in rows:
        meth = name.split(",")[0]
        try:
            m, mx, sz = timed(c, meth, p)
            print(f"| {name} | {m:.1f} | {mx:.1f} | {sz:,} |")
        except Exception as e: print(f"| {name} | error {str(e)[:80]} | | |")
    print(f"daemon rss {rss(pid)} MB, fds {fds(pid)}")
elif mode == "change":
    # Per-change cost: setLabels on one agent, with N listening clients.
    n = int(sys.argv[3]); calls = int(sys.argv[4]) if len(sys.argv) > 4 else 100
    listeners = [C() for _ in range(n)]
    agents = c.call("agents/list", {"lean": True}); aid = agents[0]["id"]
    time.sleep(0.5)
    ts = []
    t0 = time.perf_counter()
    for k in range(calls):
        t = time.perf_counter()
        c.call("agents/setLabels", {"agentID": aid, "add": ["rp"], "remove": []} if k % 2 == 0 else {"agentID": aid, "add": [], "remove": ["rp"]})
        ts.append((time.perf_counter() - t) * 1000)
    wall = time.perf_counter() - t0
    time.sleep(1.0)
    got = [l.notes.get("agent/changed", 0) for l in listeners] or [c.notes.get("agent/changed", 0)]
    pc = [l.notes.get("project/changed", 0) for l in listeners] or [c.notes.get("project/changed", 0)]
    lag = max(((l.last.get("agent/changed", t0) - t0) - wall) * 1000 for l in listeners) if listeners else 0
    print(f"listeners={n} calls={calls} setLabels median {statistics.median(ts):.2f} ms p90 {sorted(ts)[int(len(ts)*.9)]:.2f} max {max(ts):.1f}; "
          f"{calls/wall:.0f} changes/s; agent/changed per listener {min(got)}..{max(got)}, project/changed {min(pc)}..{max(pc)}; "
          f"last listener lag after last reply {lag:.0f} ms; daemon rss {rss(pid)} MB")
    print("notes seen by one listener:", (listeners[0] if listeners else c).notes)
elif mode == "slow":
    # N clients that never read, while one agent changes `calls` times.
    n = int(sys.argv[3]); calls = int(sys.argv[4])
    dead = [C(read=False) for _ in range(n)]
    agents = c.call("agents/list", {"lean": True}); aid = agents[7]["id"]
    r0 = rss(pid); t0 = time.perf_counter(); ts = []
    for k in range(calls):
        t = time.perf_counter()
        c.call("agents/setLabels", ({"agentID": aid, "add": ["rp"], "remove": []} if k % 2 == 0 else {"agentID": aid, "add": [], "remove": ["rp"]}))
        ts.append((time.perf_counter() - t) * 1000)
        if k % 500 == 499: print(f"  after {k+1}: rss {rss(pid)} MB, median {statistics.median(ts[-500:]):.1f} ms", flush=True)
    print(f"slow readers={n}: rss {r0} -> {rss(pid)} MB in {time.perf_counter()-t0:.1f}s; fds {fds(pid)}")
    alive = 0
    for d in dead:
        try: d.s.setblocking(False); d.s.recv(1); alive += 1
        except BlockingIOError: alive += 1
        except OSError: pass
    print(f"non-reading connections still open: {alive}/{n}")
