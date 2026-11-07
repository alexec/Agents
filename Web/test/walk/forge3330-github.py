#!/usr/bin/env python3
"""A fixture GitHub for For Review's pull requests (#3330): the repo example/shop with four open pull
requests, three labelled needs-approval and one of those approved too, as forge/pulls reads them
(GraphQL search), and each one's Work page (issueOrPullRequest). Scratch data only. Point a run-app host at it with
--env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 Web/test/walk/forge3330-github.py <port>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = "example/shop"
LABELS = {"needs-approval": "fbca04", "approved": "0e8a16", "enhancement": "a2eeef"}

ITEMS = {
    31: {"title": "Checkout: a gift card field", "labels": ["enhancement", "needs-approval"], "updatedAt": "2026-11-03T17:40:00Z"},
    32: {"title": "Cart: a quieter empty state", "labels": ["enhancement", "needs-approval"], "updatedAt": "2026-11-03T15:10:00Z"},
    33: {"title": "Header: the new logo", "labels": ["enhancement", "needs-approval", "approved"], "updatedAt": "2026-11-03T16:00:00Z"},
    34: {"title": "Fix the coupon rounding", "labels": ["enhancement"], "updatedAt": "2026-11-03T14:00:00Z"},
}


def node(n):
    i = ITEMS[n]
    return {"__typename": "PullRequest", "number": n, "title": i["title"], "pullState": "OPEN",
            "url": f"https://github.com/{REPO}/pull/{n}", "updatedAt": i["updatedAt"],
            "author": {"login": "sam", "__typename": "User"}, "repository": {"nameWithOwner": REPO},
            "labels": {"nodes": [{"name": l, "color": LABELS[l]} for l in i["labels"]]}, "assignees": {"nodes": []},
            "milestone": None, "commentCount": {"totalCount": 0}, "isDraft": False, "mergeable": "MERGEABLE",
            "reviewDecision": "REVIEW_REQUIRED", "autoMergeRequest": None,
            "checkState": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}}


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
        if "search(" in q:
            words = v.get("q", "")
            ns = [n for n, i in ITEMS.items() if "is:pr" in words
                  and all(f'label:"{l}"' not in words or l in i["labels"] for l in LABELS)]
            return self.answer(200, {"data": {"search": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                                         "edges": [{"cursor": f"c{n}", "node": node(n)} for n in ns]}}})
        if "issueOrPullRequest(" in q and v.get("number") in ITEMS:
            # One pull request's Work page (forge/pull): its body says what Alex looks at.
            item = dict(node(v["number"]), body="The screenshots, one per client and per state, are below.",
                        comments={"pageInfo": {"hasPreviousPage": False, "startCursor": None}, "nodes": []},
                        reviewThreads={"totalCount": 0}, changedFiles=3, headRefOid="0" * 40, commits={"nodes": []})
            return self.answer(200, {"data": {"repository": {"issueOrPullRequest": item}}})
        return self.answer(200, {"data": {}})

    def do_GET(self):
        self.answer(404, {"message": "Not Found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
