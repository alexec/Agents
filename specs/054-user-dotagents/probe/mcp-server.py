#!/usr/bin/env python3
# A probe MCP server for 054 (research R9). Every request it gets is logged, so whether a
# runtime started it, listed its tools or called one is read from the log, not from the model.
#
#   mcp-server.py <tag>              stdio, newline-delimited JSON-RPC
#   mcp-server.py <tag> --http PORT  streamable HTTP, one JSON reply per POST
#
# The log is $PROBE_LOG (default /tmp/dotagents-probe/log/mcp.log): "<tag> <pid> <method>".
import json, os, sys, time

TAG = sys.argv[1] if len(sys.argv) > 1 else "probe"
LOG = os.environ.get("PROBE_LOG", "/tmp/dotagents-probe/log/mcp.log")
TOOL = TAG.replace("-", "_") + "_word"


def log(method):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(f"{time.strftime('%H:%M:%S')} {TAG} {os.getpid()} {method}\n")


def reply(msg):
    method, id = msg.get("method"), msg.get("id")
    log(method or "reply")
    if id is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": TAG, "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": TOOL,
                             "description": f"Returns the probe word of the {TAG} server.",
                             "inputSchema": {"type": "object", "properties": {}}}]}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": f"{TAG.upper()}-9"}]}
    elif method == "ping":
        result = {}
    else:
        return {"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "not here"}}
    return {"jsonrpc": "2.0", "id": id, "result": result}


if "--http" in sys.argv:
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            out = reply(body)
            data = json.dumps(out).encode() if out else b""
            self.send_response(200 if out else 202)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # no server-sent stream
            log("GET")
            self.send_response(405)
            self.end_headers()

        def log_message(self, *a):
            pass

    HTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--http") + 1])), Handler).serve_forever()
else:
    log("started")
    for line in sys.stdin:
        if line.strip():
            out = reply(json.loads(line))
            if out:
                sys.stdout.write(json.dumps(out) + "\n")
                sys.stdout.flush()
