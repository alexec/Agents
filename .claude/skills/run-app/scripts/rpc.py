#!/usr/bin/env python3
"""Talk to one scratch daemon over its socket: JSON-RPC, one object per line.

  rpc.py ROOT call METHOD ['{"json":"params"}']   one request, prints the reply
  rpc.py ROOT watch [SECONDS] [METHOD ...]        print notifications as they arrive
  rpc.py ROOT start RUNTIME CWD PROMPT [SECONDS] [--ask]
                                                  start an agent, answer its
                                                  permissions yes, follow it to
                                                  the end; --ask leaves the
                                                  permissions for you

Everything the window can ask, this can ask: projects/add, agents/start,
agents/prompt, agents/list, agents/transcript, permissions/answer, cost/state,
workflows/list … see DaemonAPI.Method for the whole list.

Import it instead for anything longer than one call:

    from rpc import Client
    c = Client("/tmp/ag-xxxx")
    c.call("projects/add", {"folder": "file:///tmp/ag-xxxx/work"})
"""
import json
import os
import socket
import sys
import threading
import time


class Client:
    def __init__(self, root, timeout=30):
        self.path = os.path.join(root, "daemon.sock")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        deadline = time.time() + timeout
        while True:
            try:
                self.sock.connect(self.path)
                break
            except OSError:
                if time.time() > deadline:
                    raise RuntimeError(f"nothing listening on {self.path}")
                time.sleep(0.1)
        self.buf = b""
        self.n = 0
        self.replies = {}
        self.notes = []
        self.lock = threading.Lock()
        self.dead = False
        self.on_note = None
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                self.dead = True
                return
            self.buf += chunk
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if "id" in msg and ("result" in msg or "error" in msg):
                    with self.lock:
                        self.replies[msg["id"]] = msg
                else:
                    with self.lock:
                        self.notes.append(msg)
                    if self.on_note:
                        self.on_note(msg)

    def send(self, method, params=None):
        self.n += 1
        req = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            req["params"] = params
        self.sock.sendall((json.dumps(req) + "\n").encode())
        return self.n

    def call(self, method, params=None, timeout=60):
        rid = self.send(method, params)
        end = time.time() + timeout
        while time.time() < end and not self.dead:
            reply = None
            with self.lock:
                if rid in self.replies:
                    reply = self.replies.pop(rid)
            if reply is not None:
                if "error" in reply:
                    raise RuntimeError(f"{method}: {reply['error']}")
                return reply.get("result")
            time.sleep(0.02)
        raise TimeoutError(f"{method} did not answer in {timeout}s")

    def wait_for(self, predicate, timeout=120):
        """Wait for a notification the predicate likes. Returns it, or None."""
        end = time.time() + timeout
        seen = 0
        while time.time() < end and not self.dead:
            with self.lock:
                notes = self.notes[seen:]
                seen = len(self.notes)
            for note in notes:
                if predicate(note):
                    return note
            time.sleep(0.05)
        return None


def _pretty(value):
    print(json.dumps(value, indent=2, sort_keys=True))


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    root, verb = argv[1], argv[2]
    client = Client(root)

    if verb == "call":
        method = argv[3]
        # Some methods want an object even when every field is optional.
        params = json.loads(argv[4]) if len(argv) > 4 else {}
        _pretty(client.call(method, params))
        return 0

    if verb == "watch":
        seconds = float(argv[3]) if len(argv) > 3 else 30.0
        wanted = set(argv[4:])
        client.on_note = lambda m: (
            not wanted or m.get("method") in wanted
        ) and print(json.dumps(m), flush=True)
        time.sleep(seconds)
        return 0

    if verb == "start":
        runtime, cwd, prompt = argv[3], argv[4], argv[5]
        rest = argv[6:]
        auto = "--ask" not in rest
        rest = [a for a in rest if a != "--ask"]
        seconds = float(rest[0]) if rest else 300.0
        client.on_note = lambda m: m.get("method") == "agent/changed" and print(
            f"{time.strftime('%H:%M:%S')} state={(m.get('params') or {}).get('state')}",
            flush=True,
        )
        agent = client.call("agents/start", {
            "runtimeID": runtime,
            "cwd": cwd if cwd.startswith("file://") else "file://" + os.path.abspath(cwd),
            "prompt": prompt,
        })
        print("agentID:", json.dumps(agent))
        end = time.time() + seconds
        while time.time() < end:
            time.sleep(2)
            # A turn that wants a person stops here forever otherwise: the window
            # would be showing a permission card and nobody is looking at it.
            if auto:
                for pending in client.call("permissions/pending", {}) or []:
                    allow = next((o["optionID"] for o in pending["options"]
                                  if o["kind"] == "allow_once"), None)
                    if allow:
                        print("allowing:", pending["toolCall"].get("title"), flush=True)
                        client.call("permissions/answer",
                                    {"permissionID": pending["id"], "optionID": allow})
            states = [a.get("state") for a in client.call("agents/list", {"includeArchived": False})]
            if states and all(s in ("finished", "stopped", "failed") for s in states):
                print("settled:", states)
                break
        else:
            print("still going after", seconds, "s")
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
