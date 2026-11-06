#!/usr/bin/env python3
"""A fixture GitHub for a waiting deploy (#3587): the repo example/shop, whose Release run of the
tag v1.3.0 waits for a reviewer of production, as the host's poll and approvals/read read it
(actions/runs?status=waiting, pending_deployments, tags, compare), and the answer
(POST pending_deployments), kept in memory so the next read shows the run gone on. Scratch data
only. Point a run-app host at it with --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 Web/test/walk/deploy3587-github.py <port>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = "example/shop"
RUN = 501
ENV = {"id": 11, "name": "production", "html_url": f"https://github.com/{REPO}/deployments/activity_log?environments_filter=production"}
STATE = {"answered": None}

RUN_JSON = {"id": RUN, "run_attempt": 1, "name": "Release", "path": ".github/workflows/release.yml", "event": "push",
            "status": "waiting", "head_branch": "v1.3.0", "head_sha": "c0ffee13", "html_url": f"https://github.com/{REPO}/actions/runs/{RUN}",
            "updated_at": "2026-11-05T21:40:00Z", "actor": {"login": "sam", "type": "User"}}

COMMITS = [
    ("Keep the cart in local storage (#21)", "a1"),
    ("Faster checkout page (#22)", "a2"),
    ("Coupon codes ignore case (#24)", "a3"),
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == f"/api/repos/{REPO}/actions/runs":
            return self.answer({"workflow_runs": [] if STATE["answered"] else [RUN_JSON]})
        if path == f"/api/repos/{REPO}/actions/runs/{RUN}/pending_deployments":
            if STATE["answered"]:
                return self.answer([])
            return self.answer([{"environment": ENV, "current_user_can_approve": True,
                                 "reviewers": [{"type": "User", "reviewer": {"login": "sam"}}, {"type": "Team", "reviewer": {"slug": "release"}}]}])
        if path == f"/api/repos/{REPO}/tags":
            return self.answer([{"name": "v1.3.0"}, {"name": "v1.2.0"}, {"name": "v1.1.0"}])
        if path == f"/api/repos/{REPO}/compare/v1.2.0...v1.3.0":
            return self.answer({"commits": [{"sha": sha, "commit": {"message": title + "\n\nThe body."}} for title, sha in COMMITS]})
        self.answer({"message": "Not Found"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if path == f"/api/repos/{REPO}/actions/runs/{RUN}/pending_deployments":
            STATE["answered"] = body
            print("answered", json.dumps(body, sort_keys=True), flush=True)
            return self.answer([{"id": 9001, "environment": "production", "creator": {"login": "sam"}}])
        if path == "/api/graphql":
            return self.answer({"data": {"search": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}})
        self.answer({"message": "Not Found"}, 404)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
