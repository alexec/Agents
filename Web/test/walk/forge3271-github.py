#!/usr/bin/env python3
"""A fixture GitHub for changing an epic's plan (#3271): forge3268-github.py's example/shop, epic #40
and its sub-issues, plus the writes that Add child and Blocked by make (REST: an issue's id, a new
issue, a sub-issue, a "blocked by" link added and taken off), kept in memory so the next forge/plan
reads them. An issue's id is its number times 1000. Scratch data only. Point a run-app host at it
with --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 Web/test/walk/forge3271-github.py <port>
"""
import importlib.util
import json
import os
import re
import sys
import threading
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("forge3268", os.path.join(os.path.dirname(__file__), "forge3268-github.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
ITEMS, REPO = base.ITEMS, base.REPO
lock = threading.Lock()
ISSUE = re.compile(rf"^/api/repos/{re.escape(REPO)}/issues/(\d+)$", re.I)
SUB = re.compile(rf"^/api/repos/{re.escape(REPO)}/issues/(\d+)/sub_issues$", re.I)
BLOCKED = re.compile(rf"^/api/repos/{re.escape(REPO)}/issues/(\d+)/dependencies/blocked_by(?:/(\d+))?$", re.I)


class Handler(base.Handler):
    def do_GET(self):
        m = ISSUE.match(self.path.split("?")[0])
        if m and int(m[1]) in ITEMS:
            return self.answer(200, {"id": int(m[1]) * 1000, "number": int(m[1])})
        super().do_GET()

    def do_POST(self):
        path = self.path.split("?")[0]
        if path.startswith("/api/graphql"):
            return super().do_POST()
        b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with lock:
            if path.lower() == f"/api/repos/{REPO}/issues":
                n = max(ITEMS) + 1
                for label in b.get("labels", []):
                    base.LABELS.setdefault(label, "ededed")
                ITEMS[n] = {"title": b["title"], "state": "OPEN", "labels": b.get("labels", [])}
                return self.answer(201, {"id": n * 1000, "number": n, "html_url": f"https://github.com/{REPO}/issues/{n}"})
            if m := SUB.match(path):
                ITEMS[b["sub_issue_id"] // 1000]["parent"] = int(m[1])
                return self.answer(201, {})
            if m := BLOCKED.match(path):
                ITEMS[int(m[1])].setdefault("blockedBy", []).append(b["issue_id"] // 1000)
                return self.answer(201, {})
        self.answer(404, {"message": "Not Found"})

    def do_DELETE(self):
        m = BLOCKED.match(self.path.split("?")[0])
        with lock:
            if m and m[2] and int(m[2]) // 1000 in ITEMS[int(m[1])].get("blockedBy", []):
                ITEMS[int(m[1])]["blockedBy"].remove(int(m[2]) // 1000)
                return self.answer(200, {})
        self.answer(404, {"message": "Not Found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
