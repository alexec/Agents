#!/usr/bin/env python3
"""A fixture GitHub for Work ▸ Features's groups (#4115): forge3741-github.py's example/shop, with
search (an open epic, #91, whose pull request #95 is labelled needs-approval) and gifts (an open
epic, #100, updated before the others). With sessions labelled #40, #43 and #51 checkout is In
flight (3 sessions); with one labelled #91 and P#95 search Needs you; gifts, accounts and reviews
are Idle, gifts first; wishlist and wrapping are Finished. An alex-todo issue is in the unit
tests. Scratch data only. Point a run-app host at it with
--env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 Web/test/walk/forge4115-github.py <port>
"""
import re
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = "example/shop"
LABELS = {"epic": "3e4b9e", "story": "0e8a16", "task": "c5def5", "spike": "fbca04", "feature:checkout": "1d76db",
          "feature:accounts": "d93f0b", "docs": "0075ca", "bug": "d73a4a", "feature:wrapping": "5319e7",
          "feature:reviews": "fbca04", "feature:wishlist": "c2e0c6", "feature:search": "006b75",
          "feature:gifts": "e99695", "needs-approval": "d93f0b"}
NOW = "2026-11-02T18:00:00Z"

ITEMS = {
    40: {"title": "Epic: Gift cards at checkout", "state": "OPEN", "labels": ["epic", "feature:checkout"],
         "body": "Shoppers pay with a gift card at checkout.\n\nThe plan is this issue's sub-issues."},
    41: {"title": "Gift card balances in the store's API", "state": "CLOSED", "labels": ["task", "feature:checkout"], "parent": 40},
    42: {"title": "A gift card field on the payment form", "state": "CLOSED", "labels": ["story", "feature:checkout"], "parent": 40},
    43: {"title": "Pay part with a gift card, the rest by card", "state": "OPEN", "labels": ["story", "feature:checkout"], "parent": 40,
         "blockedBy": [41, 42]},
    44: {"title": "Show the card's balance after paying", "state": "OPEN", "labels": ["story", "feature:checkout"], "parent": 40,
         "blockedBy": [43]},
    45: {"title": "Which gift card provider to use", "state": "OPEN", "labels": ["spike", "feature:checkout"], "parent": 40,
         "blockedBy": [17]},
    17: {"title": "Document the coupon field", "state": "OPEN", "labels": ["docs"]},
    50: {"title": "Epic: Saved carts", "state": "OPEN", "labels": ["epic", "feature:checkout"]},
    51: {"title": "Keep a cart for 30 days", "state": "OPEN", "labels": ["story", "feature:checkout"], "parent": 50},
    52: {"title": "Email a saved cart", "state": "OPEN", "labels": ["story", "feature:checkout"], "parent": 50},
    30: {"title": "Epic: One-page checkout", "state": "CLOSED", "labels": ["epic", "feature:checkout"]},
    55: {"title": "Checkout button too small on phones", "state": "OPEN", "labels": ["feature:checkout"]},
    60: {"title": "Epic: Sign in with a passkey", "state": "OPEN", "labels": ["epic", "feature:accounts"]},
    61: {"title": "Passkeys in the store's API", "state": "CLOSED", "labels": ["task", "feature:accounts"], "parent": 60},
    62: {"title": "A passkey button on the sign-in page", "state": "OPEN", "labels": ["story", "feature:accounts"], "parent": 60},
    70: {"title": "Epic: Gift wrapping", "state": "CLOSED", "labels": ["epic", "feature:wrapping"]},
    71: {"title": "A gift wrap option in the cart", "state": "CLOSED", "labels": ["story", "feature:wrapping"], "parent": 70},
    80: {"title": "Epic: Product reviews", "state": "CLOSED", "labels": ["epic", "feature:reviews"]},
    81: {"title": "Review stars cut off on phones", "state": "OPEN", "labels": ["bug", "feature:reviews"]},
    90: {"title": "Epic: Wish lists", "state": "CLOSED", "labels": ["epic", "feature:wishlist"]},
    91: {"title": "Epic: Search the catalogue", "state": "OPEN", "labels": ["epic", "feature:search"]},
    92: {"title": "Filter results by price", "state": "OPEN", "labels": ["story", "feature:search"], "parent": 91},
    95: {"title": "Filter results by price", "state": "OPEN", "labels": ["needs-approval"], "pr": True},
    100: {"title": "Epic: Gift messages", "state": "OPEN", "labels": ["epic", "feature:gifts"], "at": "2026-10-20T18:00:00Z"},
}


def matches(n, q):
    """Whether an issue fits a search's is:open, is:closed and label:"…" words."""
    i = ITEMS[n]
    if ("is:pr" in q) != bool(i.get("pr")):
        return False
    if "is:open" in q and i["state"] != "OPEN" or "is:closed" in q and i["state"] != "CLOSED":
        return False
    return all(l in i["labels"] for l in re.findall(r'label:"([^"]+)"', q))


def node(n):
    i = ITEMS[n]
    kids = [k for k, c in ITEMS.items() if c.get("parent") == n]
    kind = "PullRequest" if i.get("pr") else "Issue"
    return {"__typename": kind, "number": n, "title": i["title"], ("pullState" if i.get("pr") else "issueState"): i["state"],
            "url": f"https://github.com/{REPO}/{'pull' if i.get('pr') else 'issues'}/{n}", "updatedAt": i.get("at", NOW),
            "author": {"login": "sam", "__typename": "User"}, "repository": {"nameWithOwner": REPO},
            "labels": {"nodes": [{"name": l, "color": LABELS[l]} for l in i["labels"]]}, "assignees": {"nodes": []},
            "milestone": {"title": "1.3"}, "commentCount": {"totalCount": 0},
            "parent": {"number": i["parent"], "repository": {"nameWithOwner": REPO}} if "parent" in i else None,
            "subIssuesSummary": {"total": len(kids), "completed": sum(ITEMS[k]["state"] == "CLOSED" for k in kids)}}


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
                {"number": x, "state": ITEMS[x]["state"], "repository": {"nameWithOwner": REPO}} for x in c.get("blockedBy", [])]}}
                for k, c in ITEMS.items() if c.get("parent") == n]}
            return self.answer(200, {"data": {"repository": {"issue": epic}}})
        if "issueOrPullRequest" in q:
            got = None
            if n in ITEMS:
                got = {**node(n), "body": ITEMS[n].get("body", ""), "comments": {"pageInfo": {"hasPreviousPage": False, "startCursor": None}, "nodes": []}}
            return self.answer(200, {"data": {"repository": {"issueOrPullRequest": got}}})
        if "search(" in q:
            words = v.get("q", "")
            ns = [k for k in ITEMS if matches(k, words)]
            return self.answer(200, {"data": {"search": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                                         "edges": [{"cursor": f"c{k}", "node": node(k)} for k in ns]}}})
        self.answer(200, {"data": {}})

    def do_GET(self):
        if self.path.split("?")[0] == f"/api/repos/{REPO}/labels":
            return self.answer(200, [{"name": k, "color": c} for k, c in LABELS.items()])
        self.answer(404, {"message": "Not Found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
