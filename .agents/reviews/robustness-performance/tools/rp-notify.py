#!/usr/bin/env python3
# What each connection is told (#203), against a scratch root's daemon.sock only.
#   rp-notify.py ROOT labels [N]      bytes of each agent/changed a label toggle sends (median of N)
#   rp-notify.py ROOT turn [KB]       an echo turn with a KB-sized prompt: what a connection showing
#                                     the agent and one showing nothing each receive
#   rp-notify.py ROOT retention       what one listener receives while retention/set moves every note
# Start the host with AGENTS_TEST_RUNTIME=echo for `turn`.
import json, socket, statistics, sys, threading, time
ROOT = sys.argv[1]; assert ROOT.startswith("/tmp/run-")
SOCK = ROOT + "/daemon.sock"

class C:
    def __init__(s):
        s.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.s.connect(SOCK); s.buf = b""; s.n = 0
        s.cv = threading.Condition(); s.replies = {}; s.count = {}; s.bytes = {}; s.sizes = {}
        threading.Thread(target=s.loop, daemon=True).start()
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
                        k = m["method"]
                        s.count[k] = s.count.get(k, 0) + 1; s.bytes[k] = s.bytes.get(k, 0) + len(line) + 1
                        s.sizes.setdefault(k, []).append(len(line) + 1)
                    elif "id" in m: s.replies[m["id"]] = m; s.cv.notify_all()
    def call(s, method, params=None, timeout=120):
        with s.cv: s.n += 1; i = s.n
        req = {"jsonrpc": "2.0", "id": i, "method": method}
        if params is not None: req["params"] = params
        s.s.sendall((json.dumps(req) + "\n").encode())
        with s.cv:
            if not s.cv.wait_for(lambda: i in s.replies, timeout): raise TimeoutError(method)
            r = s.replies.pop(i)
        if "error" in r: raise RuntimeError(f"{method}: {r['error']}")
        return r.get("result")
    def reset(s):
        with s.cv: s.count = {}; s.bytes = {}; s.sizes = {}
    def table(s, name):
        with s.cv:
            rows = sorted(s.count)
            return "\n".join(f"| {name} | {k} | {s.count[k]:,} | {s.bytes[k]:,} | {max(s.sizes[k]):,} |" for k in rows) or f"| {name} | (nothing) | 0 | 0 | 0 |"

mode = sys.argv[2]
c = C()
if mode == "labels":
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    listener = C()
    aid = c.call("agents/list", {"lean": True})[0]["id"]
    time.sleep(0.3); listener.reset()
    sizes = []
    for k in range(n):
        before = len(listener.sizes.get("agent/changed", []))
        c.call("agents/setLabels", {"agentID": aid, "add": ["rp"], "remove": []} if k % 2 == 0 else {"agentID": aid, "add": [], "remove": ["rp"]})
        deadline = time.time() + 5
        while len(listener.sizes.get("agent/changed", [])) == before and time.time() < deadline: time.sleep(0.005)
        time.sleep(0.02)
        sizes.extend(listener.sizes.get("agent/changed", [])[before:])
    print(f"label toggle x{n}: agent/changed bytes median {statistics.median(sizes):,.0f}, max {max(sizes):,}, count {len(sizes)}")
elif mode == "turn":
    kb = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    runtimes = c.call("runtimes/list", {})
    rid = next(r["runtime"]["id"] for r in runtimes if r["runtime"]["id"] == "demo")
    folder = c.call("projects/list", {})[0]["project"]["folder"]
    shower, idle = C(), C()
    # The idle one says where it is and that it shows nothing; the shower says the agent once it exists.
    idle.call("presence/report", {"active": False})
    agent = c.call("agents/start", {"runtimeID": rid, "cwd": folder, "prompt": "warm up"})
    aid = agent if isinstance(agent, str) else agent["id"]
    shower.call("presence/report", {"active": False, "watching": aid, "showing": aid})
    deadline = time.time() + 60
    while time.time() < deadline and c.call("agents/list", {"agentID": aid, "lean": True})[0]["state"] not in ("finished", "stopped"): time.sleep(0.2)
    time.sleep(0.5); shower.reset(); idle.reset(); c.reset()
    words = ("Seeded words for a big prompt. " * (kb * 1024 // 31 + 1))[: kb * 1024]
    c.call("agents/prompt", {"agentID": aid, "text": words})
    deadline = time.time() + 60
    time.sleep(0.5)
    while time.time() < deadline and c.call("agents/list", {"agentID": aid, "lean": True})[0]["state"] not in ("finished", "stopped"): time.sleep(0.2)
    time.sleep(1.0)
    print(f"echo turn with a {kb} KB prompt\n| connection | notification | count | bytes | largest |\n|---|---|---|---|---|")
    print(shower.table("showing it")); print(idle.table("showing nothing")); print(c.table("no presence"))
elif mode == "retention":
    listener = C()
    state = c.call("retention/state")
    print("retention before:", json.dumps(state.get("settings", state))[:200])
    for keep in ("days7", "days90"):
        time.sleep(0.5); listener.reset()
        t = time.perf_counter()
        c.call("retention/set", {"settings": {"keepFor": keep, "cap": "none"}, "confirmed": True})
        time.sleep(3.0)
        print(f"retention/set keepFor={keep}: call {1000*(time.perf_counter()-t-3.0):.0f} ms\n| connection | notification | count | bytes | largest |\n|---|---|---|---|---|")
        print(listener.table("listener"))
