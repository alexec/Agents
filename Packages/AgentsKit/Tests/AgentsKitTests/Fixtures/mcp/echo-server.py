#!/usr/bin/env python3
# A stdio MCP server for MCPBridgeTests (054). Newline-delimited JSON-RPC.
#
# tools/call arguments:
#   {"sleep": s}   answer after s seconds (calls overlap: each is answered on its own thread)
#   {"exit": true} exit at once, answering nothing
#   {"ask": true}  first send the client a notification and a request, then answer with
#                  whatever came back for that request
#   anything else  echoed back as the result
# Every answer carries "pid", so a test can tell one process from the next.
import json, os, sys, threading, time

out = threading.Lock()
answers = {}
answered = threading.Condition()


def send(message):
    with out:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def call(id, args):
    if args.get("sleep"):
        time.sleep(float(args["sleep"]))
    if args.get("exit"):
        os._exit(0)
    if args.get("ask"):
        send({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info"}})
        send({"jsonrpc": "2.0", "id": "srv-1", "method": "roots/list"})
        with answered:
            answered.wait_for(lambda: "srv-1" in answers, timeout=5)
            args = {"asked": answers.get("srv-1")}
    send({"jsonrpc": "2.0", "id": id, "result": {"echo": args, "pid": os.getpid()}})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method, id = message.get("method"), message.get("id")
    if method is None:
        with answered:
            answers[id] = message
            answered.notify_all()
    elif method == "initialize":
        send({"jsonrpc": "2.0", "id": id, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                                     "serverInfo": {"name": "echo", "version": "1"}}})
    elif method == "tools/call":
        threading.Thread(target=call, args=(id, message.get("params", {}).get("arguments", {})), daemon=True).start()
    elif id is not None:
        send({"jsonrpc": "2.0", "id": id, "result": {"pid": os.getpid()}})
