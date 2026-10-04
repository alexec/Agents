#!/usr/bin/env python3
# A probe MCP server for 054 (research R9). Every request it gets is logged, so whether a
# runtime started it, listed its tools or called one is read from the log, not from the model.
#
#   mcp-server.py <tag>              stdio, newline-delimited JSON-RPC
#   mcp-server.py <tag> --http PORT  streamable HTTP, one JSON reply per POST
#   ... --apps                       also an MCP Apps view (#186, SEP-1865 2026-01-26): a tool
#                                    whose _meta.ui.resourceUri names a ui:// resource, the
#                                    resource itself, and a result with structuredContent and _meta
#
# The log is $PROBE_LOG (default /tmp/dotagents-probe/log/mcp.log): "<tag> <pid> <method>".
# With $PROBE_WIRE set, every message in and out is also appended there in full, one JSON per
# line, which is where a runtime's initialize capabilities (io.modelcontextprotocol/ui) show.
import json, os, sys, time

TAG = sys.argv[1] if len(sys.argv) > 1 else "probe"
LOG = os.environ.get("PROBE_LOG", "/tmp/dotagents-probe/log/mcp.log")
TOOL = TAG.replace("-", "_") + "_word"
APPS = "--apps" in sys.argv
WIRE = os.environ.get("PROBE_WIRE")
VIEW_TOOL = TAG.replace("-", "_") + "_weather"
VIEW_URI = f"ui://{TAG}/weather"
VIEW_MIME = "text/html;profile=mcp-app"
VIEW_HTML = ("<!DOCTYPE html><html><body><p id=w>waiting</p><script>"
             "addEventListener('message',e=>{if(e.data&&e.data.method==='ui/notifications/tool-result')"
             "document.getElementById('w').textContent=JSON.stringify(e.data.params.structuredContent)})"
             "</script></body></html>")


def wire(direction, msg):
    if WIRE and msg is not None:
        with open(WIRE, "a") as f:
            f.write(json.dumps({"t": time.strftime("%H:%M:%S"), "server": TAG, "pid": os.getpid(),
                                "dir": direction, "msg": msg}) + "\n")


def log(method):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(f"{time.strftime('%H:%M:%S')} {TAG} {os.getpid()} {method}\n")


def reply(msg):
    wire("in", msg)
    out = answer(msg)
    wire("out", out)
    return out


def answer(msg):
    method, id = msg.get("method"), msg.get("id")
    log(method or "reply")
    if id is None:
        return None
    params = msg.get("params") or {}
    if method == "initialize":
        caps = {"tools": {}}
        if APPS:
            caps["resources"] = {}
        result = {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                  "capabilities": caps,
                  "serverInfo": {"name": TAG, "version": "1"}}
    elif method == "tools/list":
        tools = [{"name": TOOL,
                  "description": f"Returns the probe word of the {TAG} server.",
                  "inputSchema": {"type": "object", "properties": {}}}]
        if APPS:
            # Offered whatever the client advertised, so a runtime that does not negotiate the
            # extension still gets the tool and the probe sees what it does with the _meta.
            # The flat "ui/resourceUri" is the spec's deprecated spelling, still sent by SDKs.
            tools.append({"name": VIEW_TOOL,
                          "description": f"Shows the weather for a city ({TAG} server).",
                          "inputSchema": {"type": "object",
                                          "properties": {"city": {"type": "string"}},
                                          "required": ["city"]},
                          "_meta": {"ui": {"resourceUri": VIEW_URI, "visibility": ["model", "app"]},
                                    "ui/resourceUri": VIEW_URI}})
        result = {"tools": tools}
    elif method == "tools/call" and params.get("name") == VIEW_TOOL:
        city = (params.get("arguments") or {}).get("city", "?")
        result = {"content": [{"type": "text", "text": f"KITE-WEATHER {city}: 21C, clear"}],
                  "structuredContent": {"city": city, "temperatureC": 21, "conditions": "clear",
                                        "probe": "STRUCTURED-4"},
                  "_meta": {"probe": "RESULT-META-5", "ui": {"resourceUri": VIEW_URI}}}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": f"{TAG.upper()}-9"}]}
    elif method == "resources/list" and APPS:
        result = {"resources": [{"uri": VIEW_URI, "name": "weather_view",
                                 "description": "The weather view of the probe.",
                                 "mimeType": VIEW_MIME}]}
    elif method == "resources/templates/list" and APPS:
        result = {"resourceTemplates": []}
    elif method == "resources/read" and APPS and params.get("uri") == VIEW_URI:
        result = {"contents": [{"uri": VIEW_URI, "mimeType": VIEW_MIME, "text": VIEW_HTML,
                                "_meta": {"ui": {"csp": {}, "prefersBorder": True}}}]}
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
            # A batch is never sent by these clients; one message per POST.
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
