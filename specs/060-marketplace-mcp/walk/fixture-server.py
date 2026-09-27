#!/usr/bin/env python3
"""Stand-in for registry.modelcontextprotocol.io, for walking 060 on a scratch app
(quickstart §0). Serves Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/mcp/http.

  GET /v0/servers?search=&version=latest
  GET /v0/servers/{name}/versions/latest   (name may be percent-encoded)
  POST /_down  /  POST /_up

Point the app with AGENTS_TEST_MCP_REGISTRY_URL=http://127.0.0.1:8932

Usage: python3 specs/060-marketplace-mcp/walk/fixture-server.py [--port 8932]
"""
import argparse, json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
HTTP = os.path.normpath(os.path.join(
    HERE, "../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/mcp/http"))
STATE = {"down": False}


def read(name):
    with open(os.path.join(HTTP, name), "rb") as f:
        return f.read()


def detail_name(name):
    return "detail-" + name.replace("/", "__") + ".json"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stdout.write("fixture: " + (fmt % args) + "\n")
        sys.stdout.flush()

    def send(self, status, body=b"", kind="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/_down":
            STATE["down"] = True
        elif self.path == "/_up":
            STATE["down"] = False
        self.send(204)

    def do_GET(self):
        url = urlparse(self.path)
        path = urllib.parse.unquote(url.path)
        if STATE["down"]:
            return self.send(503, read("down.json"))
        if path in ("/v0/servers", "/v0.1/servers"):
            q = (parse_qs(url.query).get("search") or [""])[0].lower()
            data = json.loads(read("search-github.json"))
            if q:
                data["servers"] = [
                    s for s in data["servers"]
                    if q in s["server"]["name"].lower()
                    or q in (s["server"].get("title") or "").lower()
                    or q in (s["server"].get("description") or "").lower()
                ]
            data["metadata"] = {"count": len(data["servers"])}
            return self.send(200, json.dumps(data).encode())
        for prefix in ("/v0/servers/", "/v0.1/servers/"):
            if path.startswith(prefix) and path.endswith("/versions/latest"):
                name = path[len(prefix):-len("/versions/latest")]
                file = detail_name(name)
                if os.path.exists(os.path.join(HTTP, file)):
                    return self.send(200, read(file))
                return self.send(404, json.dumps({"title": "Not Found", "status": 404}).encode())
        self.send(404, b'{"detail":"Endpoint not found"}')


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8932)
    args = p.parse_args()
    if not os.path.isdir(HTTP):
        sys.stderr.write(f"fixtures missing: {HTTP}\n")
        sys.exit(1)
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"060 MCP fixture on http://127.0.0.1:{args.port} from {HTTP}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
