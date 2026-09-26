#!/usr/bin/env python3
"""A stand-in for skills.sh and GitHub, for walking 059 on a scratch app (tasks T052,
quickstart §1).

Serves the recorded fixtures in Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/catalog
(made by make-http-fixtures.py from a real git repository) at the paths CatalogEndpoints
uses when AGENTS_TEST_CATALOG_URL and AGENTS_TEST_GITHUB_URL both name this server:

  /api/search?q=…                         skills.sh search, filtered by the query
  /api/download/<o>/<r>/<skill>           skills.sh's copy of a skill's text files
  /<o>/<r>.git/info/refs                  git's ref list
  /api/repos/<o>/<r>/git/trees/<sha>      the API's tree
  /raw/<o>/<r>/<sha>/<path>               one file at the commit
  /codeload/<o>/<r>/tar.gz/<sha>          the commit's tarball

POST /_down and /_up switch every route to 503 and back (frame E). Every request is
printed, so a walk can see what the app asked for.

Usage: python3 specs/059-marketplace/walk/fixture-server.py [--port 8931]
"""
import argparse, json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.normpath(os.path.join(HERE, "../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/catalog"))
HTTP = os.path.join(FIX, "http")
META = json.load(open(os.path.join(HTTP, "meta.json")))
OWNER, REPO, COMMIT = META["owner"], META["repo"], META["commit"]
STATE = {"down": False}


def read(name):
    with open(os.path.join(HTTP, name), "rb") as f:
        return f.read()


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
        path = url.path
        if STATE["down"]:
            return self.send(503, b"down", "text/plain")
        if path == "/api/search":
            q = (parse_qs(url.query).get("q") or [""])[0].lower()
            answer = json.loads(read("search-fixture.json"))
            rows = [r for r in answer["skills"] if r["source"] == f"{OWNER}/{REPO}"]
            answer["skills"] = [r for r in rows if q in r["name"].lower() or q in r["source"].lower() or q in "fixture skills"]
            answer["count"] = len(answer["skills"])
            return self.send(200, json.dumps(answer).encode())
        prefix = f"/api/download/{OWNER}/{REPO}/"
        if path.startswith(prefix):
            name = f"download-{path[len(prefix):]}.json"
            if os.path.exists(os.path.join(HTTP, name)):
                return self.send(200, read(name))
            return self.send(404)
        if path == f"/{OWNER}/{REPO}.git/info/refs":
            return self.send(200, read("info-refs.txt"), "application/x-git-upload-pack-advertisement")
        if path == f"/api/repos/{OWNER}/{REPO}/git/trees/{COMMIT}":
            return self.send(200, read("tree.json"))
        raw = f"/raw/{OWNER}/{REPO}/{COMMIT}/"
        if path.startswith(raw):
            rel = os.path.normpath(path[len(raw):])
            full = os.path.normpath(os.path.join(FIX, rel))
            if rel.startswith("skills/") and full.startswith(FIX + os.sep) and os.path.isfile(full):
                with open(full, "rb") as f:
                    return self.send(200, f.read(), "application/octet-stream")
            return self.send(404)
        if path == f"/codeload/{OWNER}/{REPO}/tar.gz/{COMMIT}":
            return self.send(200, read("tarball.tar.gz"), "application/gzip")
        self.send(404)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8931)
    args = parser.parse_args()
    print(f"fixture: serving {OWNER}/{REPO} @ {COMMIT[:7]} on 127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
