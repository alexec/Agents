#!/usr/bin/env python3
"""A fake Bitbucket Cloud API on loopback for the #3880 walk: the repository agentstest/agents-walk
with two open issues whose component is feature:export (#1, a task, and #2, a bug), enough for
Work ▸ Features and the feature's issues. A list asked for the kind or component epic has none,
as Bitbucket's BBQL would say. Scratch data only. Give the host BITBUCKET_API_URL=http://127.0.0.1:<port>/2.0/
and connect it with any token (connections/sign-in/token, provider bitbucket).

    python3 Web/test/walk/forge3880-bitbucket.py <port>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

REPO = "agentstest/agents-walk"
WEB = "https://bitbucket.org/" + REPO
WALKER = {"uuid": "{walker}", "nickname": "walker", "display_name": "Walk Er", "account_id": "1"}
AT = "2026-11-07T09:00:00.000000+00:00"



def issue(n, title, kind, at):
    return {"id": n, "title": title, "content": {"raw": title + "."}, "state": "open", "kind": kind, "priority": "major",
            "component": {"name": "feature:export"}, "reporter": WALKER, "assignee": None,
            "links": {"html": {"href": f"{WEB}/issues/{n}"}}, "updated_on": at, "created_on": at,
            "repository": {"full_name": REPO}}


ISSUES = [issue(2, "The CSV export drops the last row", "bug", "2026-11-07T10:00:00.000000+00:00"),
          issue(1, "Export the report as CSV", "task", AT)]


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
        url = urlparse(self.path)
        path = url.path.removeprefix("/2.0/")
        q = parse_qs(url.query).get("q", [""])[0]
        repo = "repositories/" + REPO
        routes = {
            "user": WALKER,
            repo: {"full_name": REPO, "has_issues": True, "mainbranch": {"name": "main"}},
            repo + "/issues": page([] if '"epic"' in q else ISSUES),
            repo + "/pullrequests": page([]),
            repo + "/issues/1": ISSUES[1],
            repo + "/issues/2": ISSUES[0],
            repo + "/issues/1/comments": page([]),
            repo + "/issues/2/comments": page([]),
            repo + "/components": page([{"name": "feature:export"}]),
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
