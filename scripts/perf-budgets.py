#!/usr/bin/env python3
"""Time what the window and the Remote ask the host for, against budgets (073).

  scripts/perf-budgets.py ROOT [--runs N] [--markdown] [--control]

ROOT is a scratch root started by the run-app skill (`launch.sh`), seeded first:

  mkdir -p ROOT/work && git -C ROOT/work init -q            # a project, added with projects/add
  scripts/seed-big-repo.py ROOT/big                           # 40,000 files, 1,800 changed
  swift scripts/seed-archived.swift --root ROOT --live --count 40 --project ROOT/work --transcript-bytes 200000
  swift scripts/seed-archived.swift --root ROOT --live --count 1 --project ROOT/big
  swift scripts/seed-archived.swift --root ROOT --live --count 1 --project ROOT/work --transcript-bytes 1000
  scripts/seed-long-transcript.py ROOT <that last id> 100000
  (restart the host so it reads them)

It talks to ROOT/daemon.sock directly, one request at a time with no polling, so what
it measures is the host's answer, not this script. With --control it also times the
same calls through the scratch control plane, as the window makes them, with the
operator code it makes for itself (the `agents-control` helper beside agentsd).

Each line is the median of N runs (default 5) and the slowest. It exits 1 if a median
is over its budget, so it can be run before and after a change.
"""
import json
import os
import socket
import statistics
import subprocess
import sys
import time

# The budgets, in milliseconds, for the host's answer (the window adds its own drawing).
# 100 ms is "a click responds"; 1 s is "a list is there" (#73).
BUDGETS = {
    "daemon/ping": 20,
    "agents/list": 250,
    "projects/list": 100,
    "open a long chat (turns + open turn)": 500,
    "a long chat, Remote's last 500": 500,
    "files/list, big repo root": 250,
    "files/list, big repo deep folder": 100,
    "changes/list, big repo": 1000,
}


class Socket:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b""
        self.n = 0

    def call(self, method, params=None, timeout=60):
        self.n += 1
        request = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            request["params"] = params
        self.sock.settimeout(timeout)
        self.sock.sendall((json.dumps(request) + "\n").encode())
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if not line.strip():
                    continue
                message = json.loads(line)
                if message.get("id") == self.n:
                    if "error" in message:
                        raise RuntimeError(f"{method}: {message['error']}")
                    return message.get("result"), len(line)
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise RuntimeError("the host closed the socket")
            self.buf += chunk


def timed(runs, work):
    took = []
    size = 0
    for _ in range(runs):
        started = time.perf_counter()
        size = work()
        took.append((time.perf_counter() - started) * 1000)
    return statistics.median(took), max(took), size


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    root = argv[1]
    runs = int(argv[argv.index("--runs") + 1]) if "--runs" in argv else 5
    host = Socket(os.path.join(root, "daemon.sock"))

    agents, _ = host.call("agents/list", {"includeArchived": False})
    agents = agents if isinstance(agents, list) else agents.get("agents", [])
    def transcript_size(agent):
        path = os.path.join(root, "agents", agent["id"], "transcript.jsonl")
        return os.path.getsize(path) if os.path.exists(path) else 0
    longest = max(agents, key=transcript_size, default=None)
    big = next((a for a in agents if str(a.get("cwd", "")).rstrip("/").endswith("/big")), None)

    rows = []
    def row(name, work, note=""):
        try:
            median, slowest, size = timed(runs, work)
        except Exception as error:  # a failure is a row too, not a crash of the check
            rows.append((name, None, None, BUDGETS.get(name), f"failed: {error}"))
            return
        rows.append((name, median, slowest, BUDGETS.get(name), note or f"{size // 1000} KB"))

    row("daemon/ping", lambda: host.call("daemon/ping")[1])
    row("agents/list", lambda: host.call("agents/list", {"includeArchived": False})[1],
        f"{len(agents)} agents")
    row("projects/list", lambda: host.call("projects/list", {})[1])
    if longest:
        lines = sum(1 for _ in open(os.path.join(root, "agents", longest["id"], "transcript.jsonl")))
        def open_chat():
            turns, a = host.call("agents/turns", {"agentID": longest["id"]})
            page, b = host.call("agents/transcript", {"agentID": longest["id"], "from": turns["openStart"]})
            return a + b
        row("open a long chat (turns + open turn)", open_chat, f"{lines:,} entries")
        def remote_page():
            return host.call("agents/transcript", {"agentID": longest["id"], "limit": 500})[1]
        row("a long chat, Remote's last 500", remote_page, f"{lines:,} entries")
    if big:
        cwd = big["cwd"].replace("file://", "").rstrip("/")
        row("files/list, big repo root", lambda: host.call("files/list", {"agentID": big["id"], "folder": cwd})[1])
        row("files/list, big repo deep folder",
            lambda: host.call("files/list", {"agentID": big["id"], "folder": cwd + "/src/mod07/pkg0712"})[1])
        row("changes/list, big repo", lambda: host.call("changes/list", {"agentID": big["id"]}, timeout=120)[1])

    over = [r for r in rows if r[1] is not None and r[3] is not None and r[1] > r[3]]
    failed = [r for r in rows if r[1] is None]
    if "--markdown" in argv:
        print("| What | Median ms | Slowest ms | Budget ms | Size |")
        print("|---|---:|---:|---:|---|")
        for name, median, slowest, budget, note in rows:
            m = "—" if median is None else f"{median:.0f}"
            s = "—" if slowest is None else f"{slowest:.0f}"
            flag = " **over**" if median is not None and budget is not None and median > budget else ""
            print(f"| {name} | {m}{flag} | {s} | {budget if budget is not None else '—'} | {note} |")
    else:
        for name, median, slowest, budget, note in rows:
            if median is None:
                print(f"FAIL {name}: {note}")
                continue
            mark = "OVER" if budget is not None and median > budget else "ok  "
            print(f"{mark} {name:40s} {median:8.1f} ms (slowest {slowest:.1f}, budget {budget}) {note}")
    return 1 if over or failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
