#!/usr/bin/env python3
"""A stand-in MCP server for the #858 walk: its tools don't follow the provider contract.

machines-get, machine-on and machine-off over two machines. It needs TEST_TOKEN, and puts
its value in a tool description and an error, so the walk can see it is redacted (SC-003).
Each call is a line in $WALK858_LOG.
"""
import json, os, sys

token = os.environ.get("TEST_TOKEN", "")
log = os.environ.get("WALK858_LOG")
state = {"m-101": "on", "m-102": "off"}
names = {"m-101": "devbox", "m-102": "scratch-1"}

def note(line):
    if log:
        with open(log, "a") as f:
            f.write(line + "\n")

tools = [
    {"name": "machines-get", "description": f"Every machine on the account (signed in with {token}).",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "machine-on", "description": "Power a machine on, by its uid.",
     "inputSchema": {"type": "object", "properties": {"uid": {"type": "string"}}, "required": ["uid"]}},
    {"name": "machine-off", "description": "Power a machine off, by its uid.",
     "inputSchema": {"type": "object", "properties": {"uid": {"type": "string"}}, "required": ["uid"]}},
]

def call(name, args):
    note(name + " " + json.dumps(args, sort_keys=True))
    if not token:
        raise ValueError("TEST_TOKEN is not set")
    if name == "machines-get":
        return {"machines": [{"uid": u, "label": names[u], "power": p} for u, p in state.items()]}
    uid = args.get("uid")
    if uid not in state:
        raise ValueError(f"no machine {uid!r} for token {token}")
    state[uid] = "on" if name == "machine-on" else "off"
    return {"uid": uid, "power": state[uid]}

for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if "id" not in message:
        continue
    method, params = message.get("method"), message.get("params") or {}
    if method == "initialize":
        result = {"protocolVersion": params.get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
                  "serverInfo": {"name": "walk858-machines", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": tools}
    elif method == "tools/call":
        try:
            out = call(params.get("name"), params.get("arguments") or {})
            result = {"content": [{"type": "text", "text": json.dumps(out)}], "structuredContent": out}
        except ValueError as e:
            result = {"content": [{"type": "text", "text": str(e)}], "isError": True}
    elif method == "ping":
        result = {}
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"],
                                     "error": {"code": -32601, "message": f"no {method}"}}) + "\n")
        sys.stdout.flush()
        continue
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n")
    sys.stdout.flush()
