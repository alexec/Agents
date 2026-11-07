#!/usr/bin/env python3
"""A fake Bitbucket Cloud API on loopback for the #3881 walk: the repository agentstest/agents-walk
with one issue (#1, kind bug) and one pull request (#3), enough for Work ▸ Issues, Work ▸ Pull
requests and both pages. Scratch data only. Give the host BITBUCKET_API_URL=http://127.0.0.1:<port>/2.0/
and connect it with any token (connections/sign-in/token, provider bitbucket).

    python3 Web/test/walk/forge3881-bitbucket.py <port>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

REPO = "agentstest/agents-walk"
WEB = "https://bitbucket.org/" + REPO
WALKER = {"uuid": "{walker}", "nickname": "walker", "display_name": "Walk Er", "account_id": "1"}
AT = "2026-11-07T09:00:00.000000+00:00"

ISSUE = {"id": 1, "title": "Export the report as CSV", "content": {"raw": "The report needs a **CSV** export."},
         "state": "open", "kind": "bug", "priority": "major", "component": {"name": "ui"}, "reporter": WALKER,
         "assignee": None, "links": {"html": {"href": WEB + "/issues/1"}}, "updated_on": AT, "created_on": AT,
         "repository": {"full_name": REPO}}
PULL = {"id": 3, "type": "pullrequest", "title": "Add the CSV export", "description": "Fixes #1", "state": "OPEN",
        "author": WALKER, "updated_on": AT, "created_on": AT, "comment_count": 0,
        "source": {"branch": {"name": "csv-export"}, "commit": {"hash": "abc123def456"}, "repository": {"full_name": REPO}},
        "destination": {"branch": {"name": "main"}, "commit": {"hash": "0011223344"}, "repository": {"full_name": REPO}},
        "reviewers": [], "participants": [], "links": {"html": {"href": WEB + "/pull-requests/3"}}}


def page(values):
    return {"values": values, "size": len(values), "page": 1, "pagelen": 50}


class Fake(BaseHTTPRequestHandler):
    def send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path.removeprefix("/2.0/")
        repo = "repositories/" + REPO
        routes = {
            "user": WALKER,
            repo: {"full_name": REPO, "has_issues": True, "mainbranch": {"name": "main"}},
            repo + "/issues": page([ISSUE]),
            repo + "/pullrequests": page([PULL]),
            repo + "/issues/1": ISSUE,
            repo + "/issues/1/comments": page([]),
            repo + "/pullrequests/3": PULL,
            repo + "/pullrequests/3/comments": page([]),
            repo + "/pullrequests/3/activity": page([]),
            repo + "/pullrequests/3/diffstat": page([{"status": "added", "new": {"path": "export.csv"}}]),
            repo + "/commit/abc123def456/statuses": page([{"key": "test", "name": "Pipeline #4", "state": "SUCCESSFUL",
                                                            "url": WEB + "/pipelines/results/4"}]),
            repo + "/refs/branches/main": {"name": "main", "merge_strategies": ["merge_commit", "squash"],
                                           "default_merge_strategy": "squash"},
            repo + "/components": page([{"name": "ui"}]),
            repo + "/milestones": page([]),
        }
        if path in routes:
            self.send(200, routes[path])
        else:
            sys.stderr.write(f"fake bitbucket: no route for GET {self.path}\n")
            self.send(404, {"type": "error", "error": {"message": "Not found"}})

    def do_POST(self):
        self.send(200, {})

    do_PUT = do_POST


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Fake).serve_forever()
