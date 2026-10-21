#!/usr/bin/env python3
"""One voice-mode turn on a scratch host (the run-app skill's), for the #1792 spike.

    voice-turn.py ROOT RUNTIME PROMPT [--plain] [--timeout SECONDS]

Starts an agent in ROOT/work with the voice-mode text in front of PROMPT (left out with
--plain), says yes to its permissions, waits for the turn to end, and prints one JSON
line: the runtime, the prompt, the reply and its length. The reply is the text of the
turn's last agent message, as TurnParts.reply gives it; thoughts and tool calls are
other entry kinds and are never in it.

Never point it at the real root: run-app's launch.sh makes the scratch one.
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../../../../.claude/skills/run-app/scripts"))
from rpc import Client  # noqa: E402

VOICE = (
    "You are in voice mode. The person hears your reply and does not see it. "
    "Answer in one to three short spoken sentences. Use plain words. "
    "Do not use markdown, lists, tables, code or file paths. "
    "If the work changed files, say what changed in one sentence. "
    "If you need a decision, ask one clear question."
)

ENDED = {"finished", "stopped", "failed", "archived", "waitingOnUser"}


def reply(transcript):
    """The trailing agent message of the last turn, its streamed pieces joined."""
    entries = [json.loads(line) for line in open(transcript) if line.strip()]
    pieces = []
    for entry in reversed(entries):
        kind = entry["kind"]
        name = next(iter(kind))
        if name == "agentMessage":
            pieces.insert(0, kind[name].get("text", ""))
        elif pieces and name in ("toolCall", "toolCallUpdate", "agentThought", "userMessage"):
            break
    return "".join(pieces).strip()


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    root, runtime, prompt = argv[1], argv[2], argv[3]
    plain = "--plain" in argv
    timeout = float(argv[argv.index("--timeout") + 1]) if "--timeout" in argv else 300
    client = Client(root)
    text = prompt if plain else f"{VOICE}\n\n{prompt}"
    started = time.time()
    agent = client.call("agents/start", {
        "runtimeID": runtime, "cwd": f"file://{root}/work", "prompt": text,
    })
    agent_id = agent.get("id") if isinstance(agent, dict) else agent
    transcript = os.path.join(root, "agents", agent_id, "transcript.jsonl")
    state = None
    while time.time() - started < timeout:
        time.sleep(2)
        for pending in client.call("permissions/pending", {}) or []:
            allow = next((o["optionID"] for o in pending["options"] if o["kind"] == "allow_once"), None)
            if allow:
                client.call("permissions/answer", {"permissionID": pending["id"], "optionID": allow})
        agents = client.call("agents/list", {"includeArchived": True})
        state = next((a.get("state") for a in agents if a.get("id") == agent_id), None)
        if state in ENDED:
            break
    said = reply(transcript) if os.path.exists(transcript) else ""
    print(json.dumps({
        "runtime": runtime, "voice": not plain, "prompt": prompt, "state": state,
        "seconds": round(time.time() - started, 1), "words": len(said.split()),
        "markdown": any(m in said for m in ("```", "**", "\n- ", "\n1. ", "|", "`")),
        "reply": said,
    }), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
