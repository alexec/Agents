#!/usr/bin/env python3
"""A fixture GitHub for a standing epic's plan (#3662): the repo example/shop with the standing epic
#60 (labels epic and standing, a standing block in its body), its open bugs with no milestone, a bug
in a milestone and a polish issue that its query leaves out, and #61, a standing epic whose block is
bad. Scratch data only. Point a run-app host at it with --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 Web/test/walk/forge3662-github.py <port>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = "example/shop"
LABELS = {"epic": "3e4b9e", "standing": "5319e7", "bug": "d73a4a", "polish": "c2e0c6", "priority:high": "b60205",
          "priority:low": "c5def5", "feature:checkout": "1d76db"}
NOW = "2026-11-02T18:00:00Z"
FENCE = "`" * 3

ITEMS = {
    60: {"title": "Bug lane", "state": "OPEN", "labels": ["epic", "standing"],
         "body": f"The open bugs with no milestone, worked one lane at a time.\n\n{FENCE}standing\nlabels: bug\nmilestone: none\nlanes: 1\n{FENCE}\n"},
    61: {"title": "Docs lane", "state": "OPEN", "labels": ["epic", "standing"],
         "body": f"{FENCE}standing\nlabels: docs\nlane: 1\n{FENCE}\n"},
    71: {"title": "Checkout total rounds the wrong way", "state": "OPEN", "labels": ["bug", "priority:high"]},
    72: {"title": "Gift card field loses focus on paste", "state": "OPEN", "labels": ["bug"]},
    73: {"title": "Basket badge shows 0 after sign-in", "state": "OPEN", "labels": ["bug"]},
    74: {"title": "Receipt email has the old logo", "state": "OPEN", "labels": ["bug", "priority:low"]},
    75: {"title": "Coupon code is case-sensitive", "state": "OPEN", "labels": ["bug"], "milestone": "1.3"},
    76: {"title": "Tighten the payment form's spacing", "state": "OPEN", "labels": ["polish"]},
}


def node(n):
    i = ITEMS[n]
    return {"__typename": "Issue", "number": n, "title": i["title"], "issueState": i["state"],
            "url": f"https://github.com/{REPO}/issues/{n}", "updatedAt": NOW,
            "author": {"login": "sam", "__typename": "User"}, "repository": {"nameWithOwner": REPO},
            "labels": {"nodes": [{"name": l, "color": LABELS.get(l, "ededed")} for l in i["labels"]]}, "assignees": {"nodes": []},
            "milestone": {"title": i["milestone"]} if "milestone" in i else None, "commentCount": {"totalCount": 0},
            "parent": None, "subIssuesSummary": {"total": 0, "completed": 0}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if self.path.split("?")[0] != "/api/graphql":
            return self.answer(404, {"message": "Not Found"})
        q, v = b.get("query", ""), b.get("variables", {})
        n = v.get("number")
        if "subIssues(" in q:
            if n not in ITEMS:
                return self.answer(200, {"data": {"repository": {"issue": None}}})
            return self.answer(200, {"data": {"repository": {"issue": {**node(n), "subIssues": {"nodes": []}}}}})
        if "issueOrPullRequest" in q:
            got = None
            if n in ITEMS:
                got = {**node(n), "body": ITEMS[n].get("body", ""), "comments": {"pageInfo": {"hasPreviousPage": False, "startCursor": None}, "nodes": []}}
            return self.answer(200, {"data": {"repository": {"issueOrPullRequest": got}}})
        if "search(" in q:
            words = " ".join(str(x) for x in v.values() if isinstance(x, str))
            want = [l.strip('"') for l in re.findall(r'label:("[^"]+"|\S+)', words)]
            ns = [k for k, i in ITEMS.items() if i["state"] == "OPEN" and all(l in i["labels"] for l in want)]
            return self.answer(200, {"data": {"search": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                                         "edges": [{"cursor": f"c{k}", "node": node(k)} for k in ns]}}})
        self.answer(200, {"data": {}})

    def do_GET(self):
        # The token check of connections/sign-in/token (AGENTS_TEST_GITHUB_URL): any token is sam's (#4092).
        if self.path.split("?")[0] == "/api/user":
            return self.answer(200, {"login": "sam"})
        if self.path.split("?")[0] == f"/api/repos/{REPO}/labels":
            return self.answer(200, [{"name": k, "color": c} for k, c in LABELS.items()])
        self.answer(404, {"message": "Not Found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
