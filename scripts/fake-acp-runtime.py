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
  stream <chunks> <ms>
          a long Markdown reply, in that many chunks, that many milliseconds apart:
          for watching a reply arrive in a long chat (#90).
  work <seconds>
          a thought, a call held `in_progress` that long, another thought held that long,
          then a reply: for seeing where the working mark is in each (#2831).
  tool <name> <json arguments>
          the turn calls the app's own tool by that name on the agents server it was given,
          as a model would, shows the call, and says what the tool answered: for seeing a
          card an app tool raises, such as ask_secret's (#2885).
  goal    the turn sends the goal in `<its folder>/<its name>.goal` (JSON: a snapshot, or
          null to clear it) on a session_info_update, as Codex's and Claude's adapters do
          for an AIR client, then answers: for seeing the goal card (#2742).
  ok      (or no file) it answers, saying what it was handed.

So a walk can make a runtime run out, and later come back, by rewriting one file.
"""
import json
import os
import sys
import time
import urllib.request
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


# The app's own MCP server, as session/new hands it over: its address and headers.
servers = {}


def call_tool(session_id, name, arguments):
    """One tools/call on the session's agents server, after its initialize."""
    server = servers.get(session_id)
    if not server:
        return "No agents server was given to this session."
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    headers.update({h["name"]: h["value"] for h in server.get("headers", [])})

    def post(body):
        req = urllib.request.Request(server["url"], data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(req, timeout=120) as r:
            if r.headers.get("Mcp-Session-Id"):
                headers["Mcp-Session-Id"] = r.headers["Mcp-Session-Id"]
            return json.loads(r.read() or b"{}")

    post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
    answer = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
    content = answer.get("result", {}).get("content") or [{"text": json.dumps(answer.get("error"))}]
    return content[0].get("text", "")


def prompt(request_id, params):
    session_id = params.get("sessionId", "")
    blocks = params.get("prompt", [])
    # Every prompt it was sent, one JSON line each, for a walk to read back.
    with open(os.path.join(HERE, f"{NAME}.prompts"), "a") as f:
        f.write(json.dumps(blocks) + "\n")
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
    if how and how[0] == "stream":
        chunks = int(how[1]) if len(how) > 1 else 200
        pause = (int(how[2]) if len(how) > 2 else 50) / 1000
        for i in range(chunks):
            piece = f"Line {i + 1} of the reply, with *some* `marks` in it. "
            if i % 10 == 9:
                piece += "\n\n"
            if i % 40 == 20:
                piece += "\n\n- a point\n- another point\n\n"
            say(session_id, piece)
            time.sleep(pause)
        reply(request_id, {"stopReason": "end_turn"})
        return
    if how and how[0] == "work":
        hold = float(how[1]) if len(how) > 1 else 20

        def update(body):
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": body}})

        def think(text):
            update({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": text}})

        think("Reading the project's notes first, to see how it is laid out.")
        update({"sessionUpdate": "tool_call", "toolCallId": "work-1", "title": "Read notes.md",
                "kind": "read", "status": "in_progress"})
        time.sleep(hold)
        update({"sessionUpdate": "tool_call_update", "toolCallId": "work-1", "status": "completed"})
        think("The notes say what to change. Planning the edit now.")
        time.sleep(hold)
        say(session_id, "Done: the notes are read and the edit is planned.")
        reply(request_id, {"stopReason": "end_turn"})
        return
    if how and how[0] == "tool":
        _, name, arguments = behaviour().split(maxsplit=2)

        def update(body):
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": body}})

        update({"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": f"mcp__agents__{name}",
                "kind": "other", "status": "in_progress", "rawInput": json.loads(arguments)})
        text = call_tool(session_id, name, json.loads(arguments))
        update({"sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "status": "completed",
                "content": [{"type": "content", "content": {"type": "text", "text": text}}]})
        say(session_id, text)
        reply(request_id, {"stopReason": "end_turn"})
        return
    if how and how[0] == "goal":
        with open(os.path.join(HERE, f"{NAME}.goal")) as f:
            goal = json.load(f)
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {
            "sessionUpdate": "session_info_update", "_meta": {"jetbrains": {"air": {"version": 1, "goal": goal}}}}}})
        say(session_id, "Working towards the goal." if goal else "The goal is cleared.")
        reply(request_id, {"stopReason": "end_turn"})
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
                                                     "promptCapabilities": {"embeddedContext": True},
                                                     "mcpCapabilities": {"http": True}}})
        elif method == "session/new":
            session_id = f"{NAME}-{uuid.uuid4()}"
            for server in params.get("mcpServers", []):
                if server.get("name") == "agents" and server.get("url"):
                    servers[session_id] = server
            reply(request_id, {"sessionId": session_id, "configOptions": options()})
        elif method == "session/set_config_option":
            chosen[params.get("configId", "")] = params.get("value")
            reply(request_id, {"configOptions": options()})
        elif method == "session/prompt":
            prompt(request_id, params)
        else:
            reply(request_id, {})


if __name__ == "__main__":
    main()
