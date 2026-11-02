#!/usr/bin/env python3
"""A fixture GitHub for the Work pages' actions (#3130): the repo example/shop, with two issues and
two pull requests, as forge/* reads them (GraphQL search and issueOrPullRequest), and the writes the
pages make (comment, labels, close, merge, review, rerun, a failed job's log, a diff), kept in memory
so the next read shows them. Scratch data only. Point a run-app host at it with
--env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 Web/test/walk/forge3130-github.py <port>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = "example/shop"
LABELS = {"bug": "d73a4a", "ui": "a2eeef", "checkout": "0e8a16", "docs": "0075ca"}
NOW = "2026-11-01T18:00:00Z"


def comment(author, body, at):
    return {"author": {"login": author, "__typename": "User"}, "body": body, "createdAt": at, "url": f"https://github.com/{REPO}/issues/1#c"}


ITEMS = {
    12: {"pr": False, "title": "Safari drops the cart on reload", "state": "OPEN", "labels": ["bug", "ui"], "author": "sam",
         "body": "Reload the cart page in Safari 19 and the cart is empty.\n\n1. Add two items\n2. Reload",
         "comments": [comment("kim", "Seen on iOS too.", "2026-11-01T16:00:00Z")]},
    17: {"pr": False, "title": "Document the coupon field", "state": "OPEN", "labels": ["docs"], "author": "kim",
         "body": "The README says nothing about coupons.", "comments": []},
    19: {"pr": False, "title": "Coupon codes are case-sensitive", "state": "OPEN", "labels": ["checkout"], "author": "sam",
         "body": "SAVE10 works and save10 does not.", "comments": []},
    21: {"pr": True, "title": "Keep the cart in local storage", "state": "OPEN", "labels": ["bug"], "author": "sam", "head": "c0ffee21",
         "body": "Fixes #12.\n\nThe cart is saved on each change and read on load.", "comments": [comment("kim", "Looks right to me.", "2026-11-01T17:00:00Z")],
         "checks": [("build", "SUCCESS"), ("test", "FAILURE"), ("lint", "SUCCESS")]},
    22: {"pr": True, "title": "Faster checkout page", "state": "OPEN", "labels": ["checkout"], "author": "kim", "head": "beef0022",
         "body": "Loads the payment form after the page.", "comments": [], "checks": [("build", "SUCCESS"), ("test", None)]},
}


def node(n):
    i = ITEMS[n]
    out = {"__typename": "PullRequest" if i["pr"] else "Issue", "number": n, "title": i["title"],
           "url": f"https://github.com/{REPO}/{'pull' if i['pr'] else 'issues'}/{n}", "updatedAt": NOW,
           "author": {"login": i["author"], "__typename": "User"}, "repository": {"nameWithOwner": REPO},
           "labels": {"nodes": [{"name": l, "color": LABELS[l]} for l in i["labels"]]}, "assignees": {"nodes": []},
           "milestone": {"title": "1.2"}, "commentCount": {"totalCount": len(i["comments"])}}
    out["pullState" if i["pr"] else "issueState"] = i["state"]
    if i["pr"]:
        failing = any(c == "FAILURE" for _, c in i["checks"])
        running = any(c is None for _, c in i["checks"])
        out.update({"isDraft": False, "mergeable": "MERGEABLE", "reviewDecision": i.get("review", "REVIEW_REQUIRED"), "autoMergeRequest": i.get("auto"),
                    "checkState": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE" if failing else "PENDING" if running else "SUCCESS"}}}]}})
    return out


def detail(n):
    i = ITEMS[n]
    out = node(n)
    out.update({"body": i["body"], "comments": {"pageInfo": {"hasPreviousPage": False, "startCursor": None}, "nodes": i["comments"]}})
    if i["pr"]:
        out.update({"reviewThreads": {"totalCount": 0}, "changedFiles": 2, "headRefOid": i["head"], "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": [
            {"__typename": "CheckRun", "name": name, "status": "COMPLETED" if c else "IN_PROGRESS", "conclusion": c,
             "detailsUrl": f"https://github.com/{REPO}/actions/runs/{900 + n}/job/{n}{k}"} for k, (name, c) in enumerate(i["checks"])]}}}}]}})
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

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_POST(self):
        path, b = self.path.split("?")[0], self.body()
        if path == "/api/graphql":
            q, v = b.get("query", ""), b.get("variables", {})
            if "enablePullRequestAutoMerge" in q:
                for i in ITEMS.values():
                    if i.get("head") == v.get("sha"):
                        i["auto"] = {"enabledAt": NOW}
                return self.answer(200, {"data": {"enablePullRequestAutoMerge": {"pullRequest": {"number": 1}}}})
            if "search(" in q:
                prs = "is:pr" in v.get("q", "")
                closed = "is:closed" in v.get("q", "")
                ns = [n for n, i in ITEMS.items() if i["pr"] == prs and (i["state"] != "OPEN") == closed]
                return self.answer(200, {"data": {"search": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                                             "edges": [{"cursor": f"c{n}", "node": node(n)} for n in ns]}}})
            if "issueOrPullRequest" in q:
                n = v.get("number")
                return self.answer(200, {"data": {"repository": {"issueOrPullRequest": detail(n) if n in ITEMS else None,
                                                                 "viewerDefaultMergeMethod": "SQUASH", "squashMergeAllowed": True,
                                                                 "mergeCommitAllowed": True, "rebaseMergeAllowed": True}}})
            return self.answer(200, {"data": {}})
        if m := re.fullmatch(rf"/api/repos/{REPO}/issues/(\d+)/comments", path):
            ITEMS[int(m[1])]["comments"].append(comment("you", b["body"], NOW))
            return self.answer(201, {"html_url": f"https://github.com/{REPO}/issues/{m[1]}#new"})
        if m := re.fullmatch(rf"/api/repos/{REPO}/issues/(\d+)/labels", path):
            i = ITEMS[int(m[1])]
            i["labels"] += [l for l in b["labels"] if l not in i["labels"]]
            return self.answer(200, [])
        if m := re.fullmatch(rf"/api/repos/{REPO}/pulls/(\d+)/reviews", path):
            ITEMS[int(m[1])]["review"] = "APPROVED"
            return self.answer(200, {})
        if m := re.fullmatch(rf"/api/repos/{REPO}/actions/runs/(\d+)/rerun-failed-jobs", path):
            i = ITEMS[int(m[1]) - 900]
            i["checks"] = [(name, None if c == "FAILURE" else c) for name, c in i["checks"]]
            return self.answer(201, {})
        self.answer(404, {"message": "Not Found"})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == f"/api/repos/{REPO}/labels":
            return self.answer(200, [{"name": k, "color": c} for k, c in LABELS.items()])
        if m := re.fullmatch(rf"/api/repos/{REPO}/pulls/(\d+)", path):
            i = ITEMS[int(m[1])]
            return self.answer(200, {"node_id": f"PR_{m[1]}", "head": {"ref": "fix", "sha": i["head"], "repo": {"full_name": REPO}}})
        if m := re.fullmatch(rf"/api/repos/{REPO}/pulls/(\d+)/files", path):
            return self.answer(200, [] if "page=1" not in self.path else [
                {"filename": "src/cart.js", "status": "modified", "additions": 3, "deletions": 1,
                 "patch": "@@ -1,3 +1,5 @@\n const cart = [];\n-export function load() { return []; }\n+export function load() {\n+  return JSON.parse(localStorage.cart ?? \"[]\");\n+}\n+export const save = () => { localStorage.cart = JSON.stringify(cart); };\n"},
                {"filename": "test/cart.test.js", "status": "added", "additions": 4, "deletions": 0,
                 "patch": "@@ -0,0 +1,4 @@\n+import { load } from \"../src/cart.js\";\n+test(\"an empty cart\", () => {\n+  expect(load()).toEqual([]);\n+});\n"}])
        if m := re.fullmatch(rf"/api/repos/{REPO}/actions/runs/(\d+)/jobs", path):
            i = ITEMS[int(m[1]) - 900]
            return self.answer(200, {"jobs": [{"id": k, "name": name, "html_url": f"https://github.com/{REPO}/actions/runs/{m[1]}/job/{k}",
                                               "conclusion": (c or "").lower()} for k, (name, c) in enumerate(i["checks"])]})
        if re.fullmatch(rf"/api/repos/{REPO}/actions/jobs/(\d+)/logs", path):
            text = "Run npm test\n\n  cart\n    ✓ adds an item\n    ✗ keeps the cart on reload\n\n  Expected 2 items, got 0\n    at test/cart.test.js:12:5\n\nError: Process completed with exit code 1.\n"
            b = text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            return self.wfile.write(b)
        self.answer(404, {"message": "Not Found"})

    def do_PATCH(self):
        path, b = self.path.split("?")[0], self.body()
        if m := re.fullmatch(rf"/api/repos/{REPO}/issues/(\d+)", path):
            ITEMS[int(m[1])]["state"] = "CLOSED" if b.get("state") == "closed" else "OPEN"
            return self.answer(200, {})
        self.answer(404, {"message": "Not Found"})

    def do_PUT(self):
        path = self.path.split("?")[0]
        self.body()
        if m := re.fullmatch(rf"/api/repos/{REPO}/pulls/(\d+)/merge", path):
            ITEMS[int(m[1])]["state"] = "MERGED"
            return self.answer(200, {"merged": True})
        self.answer(404, {"message": "Not Found"})

    def do_DELETE(self):
        path = self.path.split("?")[0]
        if m := re.fullmatch(rf"/api/repos/{REPO}/issues/(\d+)/labels/(.+)", path):
            i = ITEMS[int(m[1])]
            i["labels"] = [l for l in i["labels"] if l != m[2]]
            return self.answer(200, [])
        self.answer(204, {})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
