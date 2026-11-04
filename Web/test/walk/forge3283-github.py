#!/usr/bin/env python3
"""A fixture GitHub for Work's Project filter (#3283): two repos, example/shop and example/www, each
with open issues and a pull request, as forge/issues, forge/pulls and an item's page read them
(GraphQL search, filtered by its repo: and is: words, and issueOrPullRequest). Scratch data only.
Point a run-app host at it with --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>, and give the
host two folders, in two projects, whose origins are the two repos.

    python3 Web/test/walk/forge3283-github.py <port>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LABELS = {"bug": "d73a4a", "ui": "a2eeef", "docs": "0075ca"}
NOW = "2026-11-04T18:00:00Z"

ITEMS = {
    ("example/shop", 12): {"pr": False, "title": "Safari drops the cart on reload", "labels": ["bug", "ui"]},
    ("example/shop", 14): {"pr": False, "title": "A gift card field on the payment form", "labels": ["ui"]},
    ("example/shop", 15): {"pr": True, "title": "Keep the cart in local storage", "labels": ["bug"]},
    ("example/www", 3): {"pr": False, "title": "The pricing page says the old plans", "labels": ["docs"]},
    ("example/www", 4): {"pr": True, "title": "A dark theme for the blog", "labels": ["ui"]},
}


def node(repo, n, body=False):
    i = ITEMS[(repo, n)]
    out = {"__typename": "PullRequest" if i["pr"] else "Issue", "number": n, "title": i["title"],
           "url": f"https://github.com/{repo}/{'pull' if i['pr'] else 'issues'}/{n}", "updatedAt": NOW,
           "author": {"login": "sam", "__typename": "User"}, "repository": {"nameWithOwner": repo},
           "labels": {"nodes": [{"name": l, "color": LABELS[l]} for l in i["labels"]]}, "assignees": {"nodes": []},
           "milestone": None, "commentCount": {"totalCount": 0}}
    out["pullState" if i["pr"] else "issueState"] = "OPEN"
    if i["pr"]:
        out.update({"isDraft": False, "mergeable": "MERGEABLE", "reviewDecision": "REVIEW_REQUIRED", "autoMergeRequest": None,
                    "checkState": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}})
    if body:
        out.update({"body": f"{i['title']}.", "comments": {"pageInfo": {"hasPreviousPage": False, "startCursor": None}, "nodes": []}})
        if i["pr"]:
            out.update({"reviewThreads": {"totalCount": 0}, "changedFiles": 1, "headRefOid": "0" * 40,
                        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": []}}}}]}})
    return out


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
        if "issueOrPullRequest" in q:
            repo, n = f"{v.get('owner')}/{v.get('name')}", v.get("number")
            got = node(repo, n, body=True) if (repo, n) in ITEMS else None
            return self.answer(200, {"data": {"repository": {"issueOrPullRequest": got}}})
        if "search(" in q:
            words = v.get("q", "")
            repos = re.findall(r"repo:(\S+)", words)
            prs = "is:pr" in words
            closed = "is:closed" in words or "is:merged" in words
            got = [] if closed else [k for k, i in ITEMS.items() if k[0] in repos and i["pr"] == prs]
            return self.answer(200, {"data": {"search": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                                         "edges": [{"cursor": f"c{k[1]}", "node": node(*k)} for k in got]}}})
        self.answer(200, {"data": {}})

    def do_GET(self):
        m = re.match(r"^/api/repos/([^/]+/[^/]+)/labels", self.path)
        if m:
            return self.answer(200, [{"name": k, "color": c} for k, c in LABELS.items()])
        self.answer(404, {"message": "Not Found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
