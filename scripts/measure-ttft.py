#!/usr/bin/env python3
"""Time to first token on a scratch host (#183).

    scripts/measure-ttft.py ROOT RUNTIME CASE [REPEATS] [--folder DIR]

CASE is one of:
  cold     the runtime let go first (parked and unparked), then the prompt
  pool     the prompt straight after the last turn ended, its runtime in the pool
  open     let go, then agents/prewarm as a window opening the session, 6 s, the prompt
  typing   let go, then agents/prewarm as typing, 2 s, the prompt

Starts one agent of RUNTIME in DIR (default ROOT/work), lets its first turn end, then
times each prompt from `agents/prompt` to the first thing the runtime streams: text,
a thought or a tool call. The prompt calls finish_turn, so no question of the app's own
follows the turn. Prints each
time and the median. Never against the live daemon: ROOT is a run-app root.
"""
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".agents", "skills", "run-app", "scripts"))
from rpc import Client  # noqa: E402

PROMPT = ("Call finish_turn now with outcome done and the message \"ok\". "
          "Do nothing else and say nothing else.")


def settled(client, agent_id, timeout=240):
    end = time.time() + timeout
    while time.time() < end:
        for pending in client.call("permissions/pending", {}) or []:
            allow = next((o["optionID"] for o in pending["options"] if o["kind"] == "allow_once"), None)
            if allow:
                client.call("permissions/answer", {"permissionID": pending["id"], "optionID": allow})
        agent = next((a for a in client.call("agents/list", {"includeArchived": False}) if a["id"] == agent_id), None)
        if agent and agent.get("state") in ("finished", "stopped"):
            return agent
        time.sleep(0.5)
    raise TimeoutError("the turn did not end")


def first_token(client, agent_id, send):
    seen = len(client.notes)
    started = time.monotonic()
    send()
    end = time.time() + 240
    while time.time() < end:
        with client.lock:
            notes = client.notes[seen:]
            seen += len(notes)
        for note in notes:
            if note.get("method") != "agent/entry":
                continue
            params = note.get("params") or {}
            if params.get("agentID") != agent_id:
                continue
            kind = params.get("entry", {}).get("kind", {})
            if isinstance(kind, dict) and set(kind) & {"agentMessage", "agentThought", "toolCall"}:
                return time.monotonic() - started
        time.sleep(0.01)
    raise TimeoutError("no token")


def let_go(client, agent_id):
    client.call("agents/park", {"agentID": agent_id})
    client.call("agents/unpark", {"agentID": agent_id})
    time.sleep(2)


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    root, runtime, case = args[0], args[1], args[2]
    repeats = int(args[3]) if len(args) > 3 else 3
    folder = os.path.join(root, "work")
    if "--folder" in argv:
        folder = argv[argv.index("--folder") + 1]
    client = Client(root)
    agent_id = client.call("agents/start", {"runtimeID": runtime, "cwd": "file://" + folder, "prompt": PROMPT})
    if isinstance(agent_id, dict):
        agent_id = agent_id.get("agentID") or agent_id.get("id")
    settled(client, agent_id)
    times = []
    for _ in range(repeats):
        if case in ("cold", "open", "typing"):
            let_go(client, agent_id)
        prompt = lambda: client.call("agents/prompt", {"agentID": agent_id, "text": PROMPT})
        if case in ("open", "typing"):
            client.call("agents/prewarm", {"agentID": agent_id, "why": "opened" if case == "open" else "typing"})
            time.sleep(6 if case == "open" else 2)
        elapsed = first_token(client, agent_id, prompt)
        times.append(elapsed)
        print(f"{runtime} {case}: {elapsed:.2f}s", flush=True)
        settled(client, agent_id)
    print(f"{runtime} {case}: median {statistics.median(times):.2f}s of {len(times)}"
          f" ({', '.join(f'{t:.2f}' for t in times)})", flush=True)
    client.call("agents/archive", {"agentID": agent_id})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
