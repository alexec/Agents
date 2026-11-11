#!/usr/bin/env python3
"""A fixture GitHub for the Work look's shared parts (#4391, #4392): example/shop's issues and pull
requests in every state (open, closed, draft, merged, closed unmerged), with label colours, scoped
labels, more than three labels, assignees, comment counts, a pull request's checks and review, a
long title, and an issue (#12) with comments by two people and a bot; for the pull request page
(#4406), each pull request's checks one by one, a pull request with conflicts (#24) and one with
auto-merge on (#25), and the failed check's job and the end of its log (`forge/log`, #4407); for the
epic page (#4416), the epic #10 with sub-issues in three steps: #12 waits for #11 (closed, so step 1
starts folded), #13 and #17 wait for #12, and #17 is also blocked by #16, outside the plan. Scratch
data only. Point a
run-app host at it with --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>, and connect GitHub with
rpc.py call connections/sign-in/token '{"provider":"github","token":"walk"}'.

    python3 Web/test/walk/forge4391-github.py <port> [slow seconds] [page size]

With slow seconds, each list read waits that long first, so a walk sees the loading state. With a
page size, a list comes in pages of that many, so a walk sees paging (#4395); while the file
<port>.fail-more is in the system's temporary folder, a page after the first fails.
"""
import datetime
import json
import os
import re
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = "example/shop"
LABELS = {"bug": "d73a4a", "story": "0e8a16", "spike": "fbca04", "task": "5319e7", "epic": "3e4b9e", "feature:checkout": "1d76db",
          "feature:search": "006b75", "priority:high": "b60205", "area:cart": "c5def5", "docs": "0075ca",
          "needs-approval": "d93f0b", "good first issue": "7057ff"}
START = datetime.datetime.now(datetime.timezone.utc)


def ago(minutes):
    return (START - datetime.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


ITEMS = {
    12: {"title": "Pay part with a gift card, the rest by card", "state": "OPEN", "labels": ["story", "feature:checkout"],
         "author": "sam", "assignees": ["sam", "robin"], "at": 20, "parent": 10, "blockedBy": [11], "comments": [
             ("robin", "User", "Which provider gives us partial captures? I looked at two; only one has them.", 180),
             ("github-actions", "Bot", "Labelled `story` from the issue form.", 170),
             ("sam", "User", "Use the one with **partial captures**. I wrote the spike's answer in the spec.", 20)],
         "body": "A shopper pays part of an order with a gift card and the rest by card.\n\n- The card's balance is read first.\n- What is left goes to the card form."},
    10: {"title": "Epic: Gift cards at checkout", "state": "OPEN", "labels": ["epic", "feature:checkout"], "author": "sam",
         "at": 300, "body": "Shoppers pay with a gift card at checkout."},
    11: {"title": "Gift card balances in the store's API", "state": "CLOSED", "labels": ["story", "feature:checkout"],
         "author": "robin", "at": 2 * 1440, "parent": 10},
    13: {"title": "Show a gift card's balance in the cart", "state": "OPEN", "labels": ["story", "feature:checkout"],
         "author": "robin", "at": 50, "parent": 10, "blockedBy": [12]},
    17: {"title": "Refund a gift card payment to the card", "state": "OPEN", "labels": ["task", "feature:checkout"],
         "author": "kai", "at": 70, "parent": 10, "blockedBy": [12, 16]},
    14: {"title": "Review stars cut off on phones narrower than 375 points when the product name is long and wraps",
         "state": "OPEN", "labels": ["bug", "priority:high", "area:cart", "feature:search", "good first issue"],
         "author": "kai", "assignees": ["kai"], "at": 95, "commentCount": 3},
    15: {"title": "Which search index to use", "state": "OPEN", "labels": ["spike", "feature:search"], "author": "robin",
         "at": 26 * 60},
    16: {"title": "Document the coupon field", "state": "OPEN", "labels": ["docs"], "author": "kai", "at": 3 * 1440},
    21: {"title": "Pay part with a gift card", "state": "OPEN", "labels": ["feature:checkout"], "pr": True, "author": "sam",
         "assignees": ["sam"], "at": 12, "check": "SUCCESS", "review": "APPROVED", "commentCount": 2},
    22: {"title": "Filter results by price", "state": "OPEN", "labels": ["needs-approval", "feature:search"], "pr": True,
         "author": "robin", "at": 75, "check": "FAILURE", "review": "CHANGES_REQUESTED", "commentCount": 5},
    23: {"title": "Search: typo tolerance", "state": "OPEN", "labels": [], "pr": True, "draft": True, "author": "kai",
         "at": 4 * 60, "check": "PENDING"},
    24: {"title": "Cart: keep the coupon after a refresh", "state": "OPEN", "labels": ["area:cart"], "pr": True,
         "author": "sam", "at": 40, "check": "SUCCESS", "review": "REVIEW_REQUIRED", "conflicts": True, "threads": 2},
    25: {"title": "Search: rank exact matches first", "state": "OPEN", "labels": ["feature:search"], "pr": True,
         "author": "kai", "at": 30, "check": "PENDING", "review": "APPROVED", "auto": True},
    19: {"title": "Gift card balances in the store's API", "state": "MERGED", "labels": ["feature:checkout"], "pr": True,
         "author": "robin", "at": 2 * 1440, "check": "SUCCESS", "review": "APPROVED"},
    18: {"title": "Try a second payment provider", "state": "CLOSED", "labels": [], "pr": True, "author": "sam",
         "at": 5 * 1440},
}


def wanted(n, q):
    """Whether an item fits a search's is:pr, is:open, is:closed and label:"…" words."""
    i = ITEMS[n]
    if ("is:pr" in q) != bool(i.get("pr")):
        return False
    closed = i["state"] in ("CLOSED", "MERGED")
    if "is:open" in q and closed or "is:closed" in q and not closed:
        return False
    return all(l in i["labels"] for l in re.findall(r'label:"([^"]+)"', q))


def node(n):
    i = ITEMS[n]
    pr = bool(i.get("pr"))
    got = {"__typename": "PullRequest" if pr else "Issue", "number": n, "title": i["title"],
           ("pullState" if pr else "issueState"): i["state"],
           "url": f"https://github.com/{REPO}/{'pull' if pr else 'issues'}/{n}", "updatedAt": ago(i["at"]),
           "author": {"login": i["author"], "__typename": "User"}, "repository": {"nameWithOwner": REPO},
           "labels": {"nodes": [{"name": l, "color": LABELS[l]} for l in i["labels"]]},
           "assignees": {"nodes": [{"login": a, "__typename": "User"} for a in i.get("assignees", [])]},
           "milestone": {"title": "1.3"} if not pr else None,
           "commentCount": {"totalCount": i.get("commentCount", len(i.get("comments", [])))},
           "parent": {"number": i["parent"], "repository": {"nameWithOwner": REPO}} if "parent" in i else None}
    kids = [k for k, c in ITEMS.items() if c.get("parent") == n]
    got["subIssuesSummary"] = {"total": len(kids), "completed": sum(ITEMS[k]["state"] == "CLOSED" for k in kids)}
    if pr:
        got.update({"isDraft": bool(i.get("draft")), "mergeable": "CONFLICTING" if i.get("conflicts") else "MERGEABLE",
                    "reviewDecision": i.get("review", ""),
                    "autoMergeRequest": {"enabledAt": ago(5)} if i.get("auto") else None,
                    "checkState": {"nodes": [{"commit": {"statusCheckRollup": {"state": i["check"]} if "check" in i else None}}]}})
    return got


def checks(n):
    """A pull request's checks one by one, as its rollup word says: a failing one has a failed test
    job, a pending one has jobs still running."""
    state = ITEMS[n]["check"]
    run = f"https://github.com/{REPO}/actions/runs/{900 + n}/job/1"
    names = ["build", "lint", "unit tests", "web", "go-darwin"]
    got = []
    for k, name in enumerate(names):
        conclusion, status = "SUCCESS", "COMPLETED"
        if state == "FAILURE" and name == "unit tests":
            conclusion = "FAILURE"
        if state == "PENDING" and k >= 3:
            conclusion, status = None, "IN_PROGRESS"
        got.append({"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion, "detailsUrl": run})
    got.append({"__typename": "CheckRun", "name": "deploy preview", "status": "COMPLETED", "conclusion": "SKIPPED",
                "detailsUrl": run})
    return got


def detail(n):
    i = ITEMS[n]
    comments = [{"author": {"login": who, "__typename": kind}, "body": body, "createdAt": ago(m),
                 "url": f"https://github.com/{REPO}/issues/{n}#c{k}"} for k, (who, kind, body, m) in enumerate(i.get("comments", []))]
    got = {**node(n), "body": i.get("body", ""),
           "comments": {"pageInfo": {"hasPreviousPage": False, "startCursor": None}, "nodes": comments}}
    if i.get("pr"):
        rollup = {"contexts": {"nodes": checks(n)}} if "check" in i else None
        got.update({"reviewThreads": {"totalCount": i.get("threads", 0)}, "changedFiles": 3, "headRefOid": "abc123",
                    "commits": {"nodes": [{"commit": {"oid": "abc123", "statusCheckRollup": rollup}}]}})
    return got


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
            epic = node(n)
            epic["subIssues"] = {"nodes": [{**node(k), "blockedBy": {"nodes": [
                {"number": b, "state": ITEMS[b]["state"], "repository": {"nameWithOwner": REPO}} for b in c.get("blockedBy", [])]}}
                                           for k, c in ITEMS.items() if c.get("parent") == n]}
            return self.answer(200, {"data": {"repository": {"issue": epic}}})
        if "issueOrPullRequest" in q:
            return self.answer(200, {"data": {"repository": {"issueOrPullRequest": detail(n) if n in ITEMS else None,
                                                             "viewerDefaultMergeMethod": "SQUASH", "squashMergeAllowed": True,
                                                             "mergeCommitAllowed": True, "rebaseMergeAllowed": False}}})
        if "search(" in q:
            time.sleep(SLOW)
            ns = sorted((k for k in ITEMS if wanted(k, v.get("q", ""))), key=lambda k: ITEMS[k]["at"])
            after = v.get("after")
            if after and os.path.exists(FAIL_MORE):
                return self.answer(502, {"message": "Server Error"})
            if after:
                ns = ns[[f"c{k}" for k in ns].index(after) + 1:]
            size = PAGE or len(ns)
            more = len(ns) > size
            ns = ns[:size]
            return self.answer(200, {"data": {"search": {"pageInfo": {"hasNextPage": more, "endCursor": f"c{ns[-1]}" if more else None},
                                                         "edges": [{"cursor": f"c{k}", "node": node(k)} for k in ns]}}})
        self.answer(200, {"data": {}})

    def do_GET(self):
        # The token check of connections/sign-in/token (AGENTS_TEST_GITHUB_URL): any token is sam's.
        if self.path.split("?")[0] == "/api/user":
            return self.answer(200, {"login": "sam"})
        if self.path.split("?")[0] == f"/api/repos/{REPO}/labels":
            return self.answer(200, [{"name": k, "color": c} for k, c in LABELS.items()])
        # A failed check's run: its jobs, then the failed one's log (#4407).
        m = re.fullmatch(rf"/api/repos/{REPO}/actions/runs/(\d+)/jobs", self.path.split("?")[0])
        if m:
            run = int(m.group(1))
            return self.answer(200, {"jobs": [{"id": run, "name": "unit tests", "conclusion": "failure",
                                               "html_url": f"https://github.com/{REPO}/actions/runs/{run}/job/1"}]})
        if re.fullmatch(rf"/api/repos/{REPO}/actions/jobs/\d+/logs", self.path.split("?")[0]):
            b = LOG.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            return self.wfile.write(b)
        self.answer(404, {"message": "Not Found"})


LOG = "\n".join([f"ok   shop/cart/{p}  0.{k}s" for k, p in enumerate(["coupon", "totals", "tax", "gift"])] + [
    "--- FAIL: TestFilterByPrice (0.02s)",
    "    filter_test.go:41: price 12.50 in range 10..12: expected it out, got it in",
    "FAIL shop/search 0.31s", "FAIL", "Process completed with exit code 1."]) + "\n"
SLOW = float(sys.argv[2]) if len(sys.argv) > 2 else 0
PAGE = int(sys.argv[3]) if len(sys.argv) > 3 else 0
FAIL_MORE = os.path.join(tempfile.gettempdir(), f"{sys.argv[1]}.fail-more")

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
