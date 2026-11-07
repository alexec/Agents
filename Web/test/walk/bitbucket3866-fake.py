#!/usr/bin/env python3
"""A fake Bitbucket Cloud for the bitbucket server's views (#3866): the repository acme/app with
three open pull requests (checks, a conflict, reviews, comments on lines, a failed Pipelines run
with its log) and three open issues, over the REST API 2.0 paths the views read. Writes (a
comment, approve, merge, a new run) are answered and kept nowhere. Scratch data only: Bitbucket
Cloud has no local container, and a walk makes no outside account. Point the host at it with

    BITBUCKET_API_URL=http://127.0.0.1:<port>/2.0  BITBUCKET_TOKEN=walk

and a folder whose remote is git@bitbucket.org:acme/app.git.

    python3 Web/test/walk/bitbucket3866-fake.py <port>
"""
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8798
START = datetime.now(timezone.utc)
WEB = "https://bitbucket.org/acme/app"


def ago(hours):
    return (START - timedelta(hours=hours)).isoformat()


def person(n, nickname, name):
    return {"type": "user", "uuid": "{%d}" % n, "account_id": "a-" + nickname, "nickname": nickname, "display_name": name}


KIM = person(1, "kim", "Kim Lee")  # the token's owner
SAM = person(2, "sam", "Sam Park")  # write access: Team
ROB = person(3, "rob", "Rob Diaz")  # no access: Others
BOT = person(4, "renovate-bot", "Renovate Bot")
PERMS = {"a-kim": "admin", "a-sam": "write"}


def pull(n, title, branch, author, hours, extra=None):
    p = {"id": n, "title": title, "description": "", "state": "OPEN", "author": author, "draft": False,
         "links": {"html": {"href": f"{WEB}/pull-requests/{n}"}},
         "source": {"branch": {"name": branch}, "commit": {"hash": f"{n:012x}"}, "repository": {"full_name": "acme/app"}},
         "destination": {"branch": {"name": "main"}, "commit": {"hash": "aaaaaaaaaaaa"}, "repository": {"full_name": "acme/app"}},
         "created_on": ago(hours), "updated_on": ago(hours / 2), "reviewers": [], "participants": [], "comment_count": 0}
    p.update(extra or {})
    return p


PULLS = [
    pull(12, "Divide the mean by the count", "fix-mean", SAM, 5, {
        "description": "The mean summed and never divided.\n\nCloses #7.", "reviewers": [KIM]}),
    pull(14, "Write the install docs", "docs", KIM, 3, {
        "participants": [{"user": SAM, "role": "REVIEWER", "approved": False, "state": "changes_requested"}]}),
    pull(15, "Update dependency pytest to v9", "renovate/pytest-9", BOT, 2),
    pull(9, "Try a faster sort", "fast-sort", ROB, 30),
]
STATUSES = {
    f"{12:012x}": [
        {"key": "test", "name": "Pipeline #31 for fix-mean", "state": "FAILED", "url": f"{WEB}/pipelines/results/31",
         "description": "1 of 2 steps failed", "updated_on": ago(4)},
        {"key": "lint", "name": "Pipeline #30 for fix-mean", "state": "SUCCESSFUL", "url": f"{WEB}/pipelines/results/30", "updated_on": ago(4)}],
    f"{14:012x}": [{"key": "jenkins", "name": "Jenkins build", "state": "INPROGRESS", "url": "https://ci.example.test/job/14", "updated_on": ago(1)}],
    f"{15:012x}": [{"key": "test", "name": "Pipeline #33 for renovate/pytest-9", "state": "SUCCESSFUL",
                    "url": f"{WEB}/pipelines/results/33", "updated_on": ago(1)}],
}
DIFFSTAT = {
    12: [{"status": "modified", "lines_added": 3, "lines_removed": 1, "old": {"path": "average.py"}, "new": {"path": "average.py"}},
         {"status": "added", "lines_added": 6, "lines_removed": 0, "new": {"path": "test_average.py"}}],
    14: [{"status": "merge conflict", "lines_added": 12, "lines_removed": 2, "old": {"path": "README.md"}, "new": {"path": "README.md"}}],
    15: [{"status": "modified", "lines_added": 1, "lines_removed": 1, "old": {"path": "requirements.txt"}, "new": {"path": "requirements.txt"}}],
}
DIFFS = {12: "diff --git a/average.py b/average.py\nindex 1111111..2222222 100644\n--- a/average.py\n+++ b/average.py\n"
             "@@ -1,3 +1,5 @@\n def mean(xs):\n-    return sum(xs)\n+    if not xs:\n+        raise ValueError(\"mean of an empty list\")\n"
             "+    return sum(xs) / len(xs)\n \n \n"
             "diff --git a/test_average.py b/test_average.py\nnew file mode 100644\nindex 0000000..3333333\n--- /dev/null\n+++ b/test_average.py\n"
             "@@ -0,0 +1,6 @@\n+import pytest\n+from average import mean\n+\n+def test_mean():\n+    assert mean([1, 2, 3]) == 2\n+\n"}


def comment(cid, by, body, hours, extra=None):
    c = {"id": cid, "content": {"raw": body}, "user": by, "created_on": ago(hours), "deleted": False,
         "links": {"html": {"href": f"{WEB}/pull-requests/12#comment-{cid}"}}}
    c.update(extra or {})
    return c


LINE = {"path": "average.py", "to": 2}
COMMENTS = {12: [
    comment(101, KIM, "Thanks: this is the bug from #7.", 4.5),
    comment(102, ROB, "What if xs is empty? This raises ZeroDivisionError.", 4, {"inline": LINE}),
    comment(103, SAM, "Now it raises ValueError with a clear message.", 3.5, {"inline": LINE, "parent": {"id": 102}}),
    comment(104, KIM, "Can the test cover the empty list too?", 3, {"inline": {"path": "test_average.py", "to": 5}}),
]}
STEPS = {31: [{"uuid": "{s1}", "name": "Test", "state": {"name": "COMPLETED", "result": {"name": "FAILED"}}},
              {"uuid": "{s2}", "name": "Lint", "state": {"name": "COMPLETED", "result": {"name": "SUCCESSFUL"}}}]}
LOGS = {"{s1}": "+ pytest -q\n.F\n=================================== FAILURES ===================================\n"
                "___________________________________ test_mean ___________________________________\n"
                "    assert mean([]) == 0\nE   ValueError: mean of an empty list\n1 failed, 1 passed in 0.03s\n"}


def issue(n, title, reporter, hours, kind="bug", extra=None):
    i = {"id": n, "title": title, "content": {"raw": ""}, "state": "new", "kind": kind, "priority": "major",
         "reporter": reporter, "assignee": None, "links": {"html": {"href": f"{WEB}/issues/{n}"}},
         "created_on": ago(hours), "updated_on": ago(hours / 2)}
    i.update(extra or {})
    return i


ISSUES = [
    issue(7, "The mean of an empty list is wrong", ROB, 26, extra={
        "content": {"raw": "## What happens\n\n`mean([])` raises **ZeroDivisionError**.\n\n## What should happen\n\n- A clear error\n- A test"},
        "assignee": KIM, "component": {"name": "maths"}}),
    issue(8, "Add a median", SAM, 20, kind="enhancement"),
    issue(10, "Document the release steps", KIM, 6, kind="task", extra={"component": {"name": "docs"}}),
]


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, value, status=200, kind="application/json"):
        body = value.encode() if isinstance(value, str) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def page(self, values):
        self.send({"values": values, "pagelen": 50, "size": len(values)})

    def missing(self):
        self.send({"type": "error", "error": {"message": "not here"}}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        p = urlparse(self.path).path.removeprefix("/2.0")
        if p.endswith("/comments"):
            self.send({"id": 999, "links": {"html": {"href": f"{WEB}/pull-requests/12#comment-999"}}})
        elif p.endswith("/approve") or p.endswith("/merge"):
            self.send({})
        elif p.endswith("/pipelines/"):
            self.send({"uuid": "{p34}", "build_number": 34, "state": {"name": "PENDING"}}, 201)
        else:
            self.missing()

    def do_GET(self):
        url = urlparse(self.path)
        p, q = unquote(url.path).removeprefix("/2.0"), parse_qs(url.query)
        if q.get("page", ["1"])[0] != "1":
            return self.page([])
        root = "/repositories/acme/app"
        if p == "/user":
            return self.send(KIM)
        if p == root:
            return self.send({"full_name": "acme/app", "has_issues": True, "mainbranch": {"name": "main"},
                              "links": {"html": {"href": WEB}}})
        if p == root + "/pullrequests":
            states = q.get("state", ["OPEN"])
            return self.page(sorted([x for x in PULLS if x["state"] in states], key=lambda x: x["created_on"], reverse=True))
        if m := re.fullmatch(root + r"/pullrequests/(\d+)", p):
            found = [x for x in PULLS if x["id"] == int(m[1])]
            return self.send(found[0]) if found else self.missing()
        if m := re.fullmatch(root + r"/pullrequests/(\d+)/diffstat", p):
            return self.page(DIFFSTAT.get(int(m[1]), []))
        if m := re.fullmatch(root + r"/pullrequests/(\d+)/diff", p):
            return self.send(DIFFS.get(int(m[1]), ""), kind="text/plain")
        if m := re.fullmatch(root + r"/pullrequests/(\d+)/comments", p):
            return self.page(sorted(COMMENTS.get(int(m[1]), []), key=lambda c: c["created_on"], reverse="-created_on" in q.get("sort", [""])[0]))
        if m := re.fullmatch(root + r"/pullrequests/(\d+)/activity", p):
            return self.page([])
        if m := re.fullmatch(root + r"/commit/([^/]+)/statuses", p):
            return self.page(STATUSES.get(m[1], []))
        if m := re.fullmatch(root + r"/refs/branches/([^/]+)", p):
            return self.send({"name": m[1], "target": {"hash": "aaaaaaaaaaaa"}, "merge_strategies": ["merge_commit", "squash"],
                              "default_merge_strategy": "squash"})
        if p == root + "/issues":
            text = q.get("q", [""])[0]
            label = re.search(r'kind="([^"]+)"', text)
            out = [i for i in ISSUES if not label or i["kind"] == label[1] or (i.get("component") or {}).get("name") == label[1]]
            return self.page(sorted(out, key=lambda i: i["created_on"], reverse=True))
        if m := re.fullmatch(root + r"/issues/(\d+)", p):
            found = [i for i in ISSUES if i["id"] == int(m[1])]
            return self.send(found[0]) if found else self.missing()
        if re.fullmatch(root + r"/issues/(\d+)/(comments|changes)", p):
            return self.page([])
        if m := re.fullmatch(root + r"/permissions-config/users/([^/]+)", p):
            return self.send({"permission": PERMS[m[1]]}) if m[1] in PERMS else self.missing()
        if re.fullmatch(r"/workspaces/acme/members/([^/]+)", p):
            return self.missing()
        if m := re.fullmatch(root + r"/pipelines/(\d+)", p):
            return self.send({"uuid": "{p%s}" % m[1], "build_number": int(m[1]), "state": {"name": "COMPLETED", "result": {"name": "FAILED"}},
                              "target": {"type": "pipeline_ref_target", "ref_name": "fix-mean", "commit": {"hash": f"{12:012x}"}}})
        if m := re.fullmatch(root + r"/pipelines/(\d+)/steps", p):
            return self.page(STEPS.get(int(m[1]), []))
        if m := re.fullmatch(root + r"/pipelines/(\d+)/steps/(\{[^/]+\})/log", p):
            return self.send(LOGS[m[2]], kind="text/plain") if m[2] in LOGS else self.missing()
        # What the events poll and nothing here keeps: an empty page.
        return self.page([])


ThreadingHTTPServer(("127.0.0.1", PORT), Fake).serve_forever()
