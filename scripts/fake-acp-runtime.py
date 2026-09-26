#!/usr/bin/env python3
"""A stand-in ACP runtime for walking 052 on a scratch app (T005). Test-only: never
linked into the app or agentsd, and never installed anywhere but a scratch folder.

Copied (or linked) as `grok` and `copilot` into a folder named by
AGENTS_TEST_SEARCH_PATHS, it speaks ACP over stdio. What each turn does is read,
every turn, from `<its folder>/<its name>.behaviour`:

  spent   the turn ends with the typed session failure a spent plan sends
          (limit, no actions): the pool moves the chat on.
  spent <epoch>
          the same, with the plan window's reset time first, so it is out until then.
  ok      (or no file) it answers, saying what it was handed.

So a walk can make a runtime run out, and later come back, by rewriting one file.
"""
import json
import os
import sys
import uuid

NAME = os.path.basename(sys.argv[0])
HERE = os.path.dirname(os.path.abspath(sys.argv[0]))

if "--version" in sys.argv:
    print(f"{NAME} 0.0.0-fake")
    sys.exit(0)


def behaviour():
    try:
        with open(os.path.join(HERE, f"{NAME}.behaviour")) as f:
            return f.read().strip() or "ok"
    except OSError:
        return "ok"


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def say(session_id, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": session_id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


SPENT = {"jetbrains": {"air": {"version": 1, "sessionFailure": {
    "id": "turn:error", "revision": 1, "category": "limit", "severity": "error",
    "title": "You've used your plan's allowance for now", "actions": []}}}}


def prompt(request_id, params):
    session_id = params.get("sessionId", "")
    blocks = params.get("prompt", [])
    how = behaviour().split()
    if how and how[0] == "spent":
        # `spent <epoch>`: the plan window says when it is back, as Claude's does.
        if len(how) > 1:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": session_id,
                "update": {"sessionUpdate": "usage_update", "used": 1000, "size": 200000,
                           "_meta": {"_claude/rateLimit": {"status": "rejected", "resetsAt": int(how[1]),
                                                           "rateLimitType": "five_hour", "isUsingOverage": False}}}}})
        reply(request_id, {"stopReason": "end_turn", "_meta": SPENT})
        return
    handoff = next((b["resource"]["text"] for b in blocks
                    if b.get("type") == "resource" and "handoff" in b.get("resource", {}).get("uri", "")), None)
    if handoff is None:
        handoff = next((b.get("text") for b in blocks
                        if b.get("type") == "text" and b.get("text", "").startswith("# Conversation so far")), None)
    typed = [b.get("text", "") for b in blocks if b.get("type") == "text" and b.get("text") != handoff]
    words = []
    if handoff:
        words.append(f"{NAME} here. I was handed the conversation so far ({len(handoff)} characters).")
    words.append(f"You said: {typed[0][:200] if typed else '(nothing)'}")
    say(session_id, "\n\n".join(words))
    reply(request_id, {"stopReason": "end_turn"})


# A model and a mode, as real runtimes offer them, so a walk has settings to carry.
chosen = {}


def options():
    def select(id_, name, category, values, current):
        return {"id": id_, "name": name, "category": category, "type": "select",
                "currentValue": chosen.get(id_, current),
                "options": [{"value": v, "name": v} for v in values]}
    return [
        select("model", "Model", "model", [f"{NAME}-fast", f"{NAME}-smart"], f"{NAME}-smart"),
        select("mode", "Mode", "mode", ["default", "acceptEdits", "bypassPermissions"], "default"),
    ]


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method, request_id = message.get("method"), message.get("id")
        if method is None or request_id is None:
            continue  # a reply to us, or a notification: nothing to say back
        params = message.get("params") or {}
        if method == "initialize":
            reply(request_id, {"protocolVersion": 1, "authMethods": [],
                               "agentCapabilities": {"loadSession": False,
                                                     "promptCapabilities": {"embeddedContext": True}}})
        elif method == "session/new":
            reply(request_id, {"sessionId": f"{NAME}-{uuid.uuid4()}", "configOptions": options()})
        elif method == "session/set_config_option":
            chosen[params.get("configId", "")] = params.get("value")
            reply(request_id, {"configOptions": options()})
        elif method == "session/prompt":
            prompt(request_id, params)
        else:
            reply(request_id, {})


if __name__ == "__main__":
    main()
