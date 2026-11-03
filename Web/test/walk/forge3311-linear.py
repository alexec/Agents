#!/usr/bin/env python3
"""A fixture Linear workspace for Work ▸ Issues (#3311): the teams ENG and OPS, with four issues,
as forge/issues and forge/issue read them over Linear's GraphQL API (the ForgeIssues and
ForgeIssue queries), the whole workspace when the filter names no team. Scratch data only.
Point a run-app host at it with --env AGENTS_TEST_LINEAR_URL=http://127.0.0.1:<port>/graphql
and a Linear connection in the scratch root's Keychain service (any token: this fixture reads
none).

    python3 Web/test/walk/forge3311-linear.py <port>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8797
SITE = "https://linear.example"

ISSUES = [
    {"identifier": "ENG-41", "title": "Retry the invoice export when the bank times out", "state": "started", "labels": [("Bug", "#eb5757")],
     "assignee": "Kim Lee", "creator": "Sam Ortiz", "updatedAt": "2026-11-02T18:00:00.000Z", "milestone": "Beta",
     "description": "The export gives up after one try.\n\n- Retry three times\n- Say which bank timed out"},
    {"identifier": "OPS-7", "title": "Rotate the staging database password", "state": "unstarted", "labels": [("Chore", "#5e6ad2")],
     "assignee": None, "creator": "Kim Lee", "updatedAt": "2026-11-02T17:00:00.000Z", "milestone": None,
     "description": "Due before the audit."},
    {"identifier": "ENG-38", "title": "Dark mode for the receipts page", "state": "backlog", "labels": [("Feature", "#26b5ce")],
     "assignee": "Sam Ortiz", "creator": "Sam Ortiz", "updatedAt": "2026-11-02T15:30:00.000Z", "milestone": None,
     "description": "Match the app's colours."},
    {"identifier": "OPS-5", "title": "Alert when the queue is over 1,000", "state": "completed", "labels": [],
     "assignee": "Kim Lee", "creator": "Kim Lee", "updatedAt": "2026-11-01T12:00:00.000Z", "milestone": None,
     "description": "Done in the dashboard."},
]


def node(i, full=False):
    n = {"identifier": i["identifier"], "title": i["title"], "url": f"{SITE}/issue/{i['identifier']}", "updatedAt": i["updatedAt"],
         "team": {"key": i["identifier"].split("-")[0]}, "state": {"type": i["state"]},
         "projectMilestone": {"name": i["milestone"]} if i["milestone"] else None,
         "labels": {"nodes": [{"name": n, "color": c} for n, c in i["labels"]]},
         "assignee": {"displayName": i["assignee"]} if i["assignee"] else None,
         "creator": {"displayName": i["creator"]}, "botActor": None, "commentCount": {"nodes": [{"id": "c1"}]}, "parent": None}
    if full:
        n["children"] = {"nodes": []}
        n["description"] = i["description"]
        n["comments"] = {"pageInfo": {"hasNextPage": False, "endCursor": None},
                         "nodes": [{"body": "Seen again this morning.", "createdAt": i["updatedAt"], "url": f"{SITE}/issue/{i['identifier']}#c1",
                                    "user": {"displayName": "Kim Lee"}, "botActor": None}]}
    return n


def matches(i, f):
    teams = (f.get("team") or {}).get("key", {}).get("in")
    if teams and i["identifier"].split("-")[0] not in teams:
        return False
    closed = i["state"] in ("completed", "canceled")
    state = (f.get("state") or {}).get("type", {})
    if "nin" in state and closed or "in" in state and not closed:
        return False
    return True


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        name = (re.match(r"\s*query (\w+)", body.get("query", "")) or [None, ""])[1]
        v = body.get("variables") or {}
        if name == "ForgeIssues":
            got = [i for i in ISSUES if matches(i, v.get("filter") or {})][: v.get("first", 50)]
            data = {"issues": {"edges": [{"cursor": i["identifier"], "node": node(i)} for i in got],
                               "pageInfo": {"hasNextPage": False, "endCursor": None}}}
        elif name == "ForgeIssue":
            found = [i for i in ISSUES if i["identifier"] == v.get("id")]
            data = {"issue": node(found[0], full=True) if found else None}
        else:
            data = {}
        print(name, json.dumps(v.get("filter", {})), flush=True)
        out = json.dumps({"data": data}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
