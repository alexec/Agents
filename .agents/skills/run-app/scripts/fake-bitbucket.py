#!/usr/bin/env python3
"""A fake Bitbucket Cloud for walks on a scratch app (#4136): the REST API 2.0 paths that the
daemon's Work pages (forge/*) and the bitbucket server read and write, from its test fake
(Go/internal/bitbucketmcp/fake_test.go). Scratch data only, kept in memory: a walk makes no
outside account.

- The API root is http://127.0.0.1:<port>/2.0/. Any token connects, as an access token (Bearer)
  or with an email (Basic), except "wrong-token", which gets a 401. /user says Kim Lee (kim).
- The workspace acme, whose members are kim and sam, and its repository acme/app (main branch main,
  merge commit or squash): four issues (kinds and components for labels, one feature:wallet
  component for Work ▸ Features), their comments and changes; three pull requests (open with a
  failing Pipelines status, a draft in conflict, merged), their comments, activity, diffstat,
  diff and statuses; a failed Pipelines run with two steps and a log; the commits and tags
  v1.0.0 and v1.1.0, so the release v1.1.0 has the pull request 5 (lineage, #3879).
- Writes: a comment (and a comment's edit), an issue's state, kind or component, a pull
  request's decline, merge and approve, a Pipelines run again.

run-app starts it with `launch.sh --fake-bitbucket`, which gives the host
BITBUCKET_API_URL=http://127.0.0.1:<port>/2.0. Then connect Bitbucket with any token, and add a
folder whose remote is https://bitbucket.org/acme/app.git: the host finds a Bitbucket repository
only on bitbucket.org, and reads it at BITBUCKET_API_URL. By hand:

    python3 .agents/skills/run-app/scripts/fake-bitbucket.py <port>
"""
import base64
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8798
WEB = "https://bitbucket.org"
REPO = "acme/app"
ROOT = "/2.0/repositories/" + REPO
START = datetime.now(timezone.utc)


def ago(hours):
    """A time hours before the fake started, as Bitbucket writes one."""
    return (START - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S.%f+00:00")


def person(n, nickname, name):
    return {"type": "user", "uuid": "{%d}" % n, "account_id": "a-" + nickname, "nickname": nickname, "display_name": name}


KIM = person(1, "kim", "Kim Lee")
SAM = person(2, "sam", "Sam Ortiz")
MEMBERS = {"a-kim": "admin", "a-sam": "write"}
CLOSED = {"resolved", "invalid", "duplicate", "wontfix", "closed"}


def issue(n, title, kind, state, component, reporter, assignee, updated, body):
    return {"type": "issue", "id": n, "title": title, "content": {"raw": body}, "state": state, "kind": kind, "priority": "major",
            "component": {"name": component} if component else None, "reporter": reporter, "assignee": assignee,
            "links": {"html": {"href": f"{WEB}/{REPO}/issues/{n}"}}, "created_on": ago(150), "updated_on": updated}


def pull(n, title, branch, state, author, updated, body, draft=False, reviewers=()):
    return {"type": "pullrequest", "id": n, "title": title, "description": body, "state": state, "author": author, "draft": draft,
            "links": {"html": {"href": f"{WEB}/{REPO}/pull-requests/{n}"}},
            "source": {"branch": {"name": branch}, "commit": {"hash": f"c{n}head"}, "repository": {"full_name": REPO}},
            "destination": {"branch": {"name": "main"}, "commit": {"hash": "base"}, "repository": {"full_name": REPO}},
            "created_on": ago(60), "updated_on": updated, "reviewers": list(reviewers), "participants": [],
            "comment_count": 0, "merge_commit": {"hash": "b5" * 20} if state == "MERGED" else None}


def comment(cid, by, body, when, inline=None):
    c = {"id": cid, "content": {"raw": body}, "user": by, "created_on": when, "updated_on": when, "deleted": False,
         "links": {"html": {"href": f"{WEB}/{REPO}/c/{cid}"}}}
    if inline:
        c["inline"] = inline
    return c


ISSUES = {
    1: issue(1, "Apple Pay sheet closes before the payment is confirmed", "bug", "open", "feature:wallet", SAM, KIM, ago(1),
             "1. Add an item to the cart\n2. Pay with **Apple Pay**\n\nThe sheet closes and the order stays unpaid."),
    2: issue(2, "Log the payment sheet's dismiss reason", "enhancement", "new", "feature:wallet", KIM, None, ago(4),
             "So we can tell a cancel from a timeout."),
    3: issue(3, "Coupon field hides behind the keyboard", "bug", "resolved", "checkout", SAM, SAM, ago(30),
             "On a small phone the coupon field is under the keyboard."),
    4: issue(4, "Gift cards", "proposal", "on hold", None, KIM, None, ago(40), "Sell and redeem gift cards."),
}
ISSUE_COMMENTS = {1: [comment(11, KIM, "Seen on iOS 19.1 only.", ago(2)), comment(12, SAM, "Build **2.4.1** has the fix.", ago(1.5))]}
CHANGES = {3: [{"id": 1, "user": SAM, "created_on": ago(30), "changes": {"state": {"old": "open", "new": "resolved"}}}]}
PULLS = {
    7: pull(7, "Pay with a saved card", "saved-card", "OPEN", SAM, ago(3), "Adds **saved cards** to checkout.\n\nFixes #1",
            reviewers=[KIM]),
    8: pull(8, "Coupon field above the keyboard", "coupon", "OPEN", KIM, ago(2), "", draft=True),
    5: pull(5, "Show the card's brand", "brand", "MERGED", SAM, ago(45), "Fixes #3", reviewers=[KIM]),
}
PR_COMMENTS = {7: [comment(21, KIM, "Does it work with **Apple Pay** too?", ago(4)),
                   comment(22, KIM, "Name this savedCard", ago(3.5), {"path": "src/checkout.ts", "to": 3})]}
ACTIVITY = {7: [{"approval": {"date": ago(3.2), "user": KIM}, "pull_request": {"id": 7}},
                {"update": {"state": "OPEN", "date": ago(3), "author": SAM, "source": {"commit": {"hash": "c7head"}}},
                 "pull_request": {"id": 7}}]}
DIFFSTAT = {7: [{"status": "modified", "new": {"path": "src/checkout.ts"}, "old": {"path": "src/checkout.ts"},
                 "lines_added": 2, "lines_removed": 1}],
            8: [{"status": "merge conflict", "new": {"path": "src/coupon.ts"}, "old": {"path": "src/coupon.ts"},
                 "lines_added": 4, "lines_removed": 2}],
            5: [{"status": "added", "new": {"path": "src/brand.ts"}, "old": None, "lines_added": 3, "lines_removed": 0}]}
DIFFS = {7: "diff --git a/src/checkout.ts b/src/checkout.ts\n--- a/src/checkout.ts\n+++ b/src/checkout.ts\n"
            "@@ -1,3 +1,4 @@\n export function pay(cart) {\n-  return charge(cart)\n+  const card = savedCard()\n+  return charge(cart, card)\n }\n",
         8: "diff --git a/src/coupon.ts b/src/coupon.ts\n--- a/src/coupon.ts\n+++ b/src/coupon.ts\n"
            "@@ -1,2 +1,4 @@\n-export const coupon = field()\n+export const coupon = field({\n+  aboveKeyboard: true,\n+})\n",
         5: "diff --git a/src/brand.ts b/src/brand.ts\nnew file mode 100644\n--- /dev/null\n+++ b/src/brand.ts\n"
            "@@ -0,0 +1,3 @@\n+export function brand(card) {\n+  return card.network\n+}\n"}
STATUSES = {"c7head": [{"key": "shop-pr", "name": "Pipeline #12", "state": "FAILED", "url": f"{WEB}/{REPO}/pipelines/results/12",
                        "description": "Tests failed", "created_on": ago(2.9), "updated_on": ago(2.9)},
                       {"key": "scan", "name": "secrets", "state": "SUCCESSFUL", "url": "https://scan.example/1",
                        "description": "No secrets", "created_on": ago(3), "updated_on": ago(3)}]}
PIPELINES_RUNS = {12: {"uuid": "{p12}", "build_number": 12, "state": {"name": "COMPLETED", "result": {"name": "FAILED"}},
                       "target": {"type": "pipeline_ref_target", "ref_name": "saved-card", "commit": {"hash": "c7head"}},
                       "created_on": ago(3), "completed_on": ago(2.9)}}
STEPS = {12: [{"uuid": "{s1}", "name": "Build", "state": {"name": "COMPLETED", "result": {"name": "SUCCESSFUL"}}},
              {"uuid": "{s2}", "name": "Test", "state": {"name": "COMPLETED", "result": {"name": "FAILED"}}}]}
LOGS = {"{s1}": "+ npm ci\nadded 412 packages\n+ npm run build\nbuilt in 4.2s\n",
        "{s2}": "+ npm test\n PASS  src/cart.test.ts\n FAIL  src/checkout.test.ts\n  ● pays with a saved card\n"
                "    expected charge(cart, card), got charge(cart)\nTests: 1 failed, 11 passed, 12 total\n"}
# main's commits newest first, and the tags (#3879): v1.1.0 has the merge of pull request 5.
COMMITS = [{"hash": "b5" * 20, "date": ago(45), "message": "Merged in brand (pull request #5)\n\nShow the card's brand"},
           {"hash": "a1" * 20, "date": ago(100), "message": "First release"}]
TAGS = {"v1.1.0": "b5" * 20, "v1.0.0": "a1" * 20}
COMMIT_PULLS = {"b5" * 20: [5]}
NEXT = [100]


def commit_of(ref):
    sha = TAGS.get(ref, ref)
    return next((c for c in COMMITS if c["hash"] == sha), None)


def commit_json(c):
    return {"hash": c["hash"], "date": c["date"], "message": c["message"], "author": {"user": SAM, "raw": "Sam Ortiz <sam@example.com>"}}


def matches(i, q):
    """Whether issue i matches the BBQL q, as far as the daemon and the bitbucket server write it."""
    states = re.findall(r'state="([^"]+)"', q)
    if states and i["state"] not in states:
        return False
    for label in re.findall(r'\(kind="([^"]+)" OR component\.name="[^"]+"\)', q):
        if i["kind"] != label and (i["component"] or {}).get("name") != label:
            return False
    for k in re.findall(r'kind="([^"]+)"', re.sub(r'\(kind="[^"]+" OR component\.name="[^"]+"\)', "", q)):
        if i["kind"] != k:
            return False
    words = re.search(r'title ~ "([^"]*)"', q)
    if words and words[1].lower() not in (i["title"] + " " + i["content"]["raw"]).lower():
        return False
    since, until = re.search(r"updated_on>=(\S+)", q), re.search(r"updated_on<=(\S+)", q)
    if since and i["updated_on"] < unquote(since[1]).strip('"'):
        return False
    if until and i["updated_on"] > unquote(until[1]).strip('"'):
        return False
    who = re.search(r'assignee\.uuid="([^"]+)"', q)
    if who and ((i["assignee"] or {}).get("uuid") != who[1] or i["state"] in CLOSED):
        return False
    return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def text(self, value, status=200):
        data = value.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def page(self, values):
        self.reply({"values": values, "pagelen": 50, "size": len(values), "page": 1})

    def missing(self):
        self.reply({"type": "error", "error": {"message": "not here"}}, 404)

    def authed(self):
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Basic "):
            auth = base64.b64decode(auth[6:] + "==").decode(errors="replace").partition(":")[2]
        elif auth.startswith("Bearer "):
            auth = auth[7:]
        else:
            auth = ""
        if auth in ("", "wrong-token"):
            self.reply({"type": "error", "error": {"message": "Unauthorized"}}, 401)
            return False
        return True

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            return {}

    def route(self, method):
        if not self.authed():
            return
        u = urlparse(self.path)
        p, q = unquote(u.path).rstrip("/") or "/", parse_qs(u.query)
        if q.get("page", ["1"])[0] not in ("", "1"):
            return self.page([])
        if p == "/2.0/user":
            return self.reply(KIM)
        m = re.fullmatch(r"/2\.0/workspaces/acme/members/([^/]+)", p)
        if m:
            return self.reply({"type": "workspace_membership"}) if unquote(m[1]) in MEMBERS or unquote(m[1]) in ("{1}", "{2}") \
                else self.missing()
        if not p.startswith(ROOT):
            return self.missing()
        rest = p[len(ROOT):]
        if method == "GET":
            return self.get(rest, q)
        return self.write(method, rest, self.body())

    def get(self, rest, q):
        query = " ".join(q.get("q", []))
        if rest == "":
            return self.reply({"full_name": REPO, "name": "app", "has_issues": True, "mainbranch": {"name": "main"},
                               "links": {"html": {"href": f"{WEB}/{REPO}"}}})
        if rest == "/issues":
            out = [i for i in ISSUES.values() if matches(i, query)]
            return self.page(sorted(out, key=lambda i: i["updated_on"], reverse=True))
        if rest == "/pullrequests":
            states = q.get("state", ["OPEN"])
            words = re.search(r'title ~ "([^"]*)"', query)
            out = [pr for pr in PULLS.values() if pr["state"] in states
                   and (not words or words[1].lower() in (pr["title"] + " " + pr["description"]).lower())]
            return self.page(sorted(out, key=lambda pr: pr["updated_on"], reverse=True))
        if rest == "/components":
            names = sorted({i["component"]["name"] for i in ISSUES.values() if i["component"]})
            return self.page([{"name": n} for n in names])
        if rest == "/milestones":
            return self.page([])
        if rest == "/commits":
            head, base = q.get("include", [""])[0], q.get("exclude", [""])[0]
            shas = [c["hash"] for c in COMMITS]
            h, b = TAGS.get(head, head), TAGS.get(base, base)
            if h not in shas:
                return self.page([])
            listed = COMMITS[shas.index(h):shas.index(b) if b in shas else len(shas)]
            return self.page([commit_json(c) for c in listed])
        m = re.fullmatch(r"/(issues|pullrequests)/(\d+)", rest)
        if m:
            found = (ISSUES if m[1] == "issues" else PULLS).get(int(m[2]))
            return self.reply(found) if found else self.missing()
        m = re.fullmatch(r"/(issues|pullrequests)/(\d+)/comments", rest)
        if m:
            got = (ISSUE_COMMENTS if m[1] == "issues" else PR_COMMENTS).get(int(m[2]), [])
            return self.page(sorted(got, key=lambda c: c["created_on"], reverse=True))
        m = re.fullmatch(r"/pullrequests/(\d+)/comments/(\d+)", rest)
        if m:
            c = next((c for c in PR_COMMENTS.get(int(m[1]), []) if c["id"] == int(m[2])), None)
            return self.reply(c) if c else self.missing()
        m = re.fullmatch(r"/issues/(\d+)/changes", rest)
        if m:
            return self.page(CHANGES.get(int(m[1]), []))
        m = re.fullmatch(r"/pullrequests/(\d+)/(activity|diffstat)", rest)
        if m:
            return self.page((ACTIVITY if m[2] == "activity" else DIFFSTAT).get(int(m[1]), []))
        m = re.fullmatch(r"/pullrequests/(\d+)/diff", rest)
        if m:
            return self.text(DIFFS.get(int(m[1]), ""))
        m = re.fullmatch(r"/commit/([^/]+)/statuses", rest)
        if m:
            return self.page(STATUSES.get(unquote(m[1]), []))
        m = re.fullmatch(r"/commit/([^/]+)/pullrequests", rest)
        if m:
            sha = TAGS.get(unquote(m[1]), unquote(m[1]))
            return self.page([PULLS[n] for n in COMMIT_PULLS.get(sha, [])])
        m = re.fullmatch(r"/commit/([^/]+)", rest)
        if m:
            c = commit_of(unquote(m[1]))
            return self.reply(commit_json(c)) if c else self.missing()
        m = re.fullmatch(r"/refs/branches/([^/]+)", rest)
        if m:
            name = unquote(m[1])
            head = {"main": "b5" * 20, **{pr["source"]["branch"]["name"]: pr["source"]["commit"]["hash"] for pr in PULLS.values()}}
            if name not in head:
                return self.missing()
            return self.reply({"name": name, "target": {"hash": head[name]}, "merge_strategies": ["merge_commit", "squash"],
                               "default_merge_strategy": "merge_commit"})
        if rest == "/pipelines":
            return self.page(sorted(PIPELINES_RUNS.values(), key=lambda r: r["build_number"], reverse=True))
        m = re.fullmatch(r"/pipelines/(\d+)", rest)
        if m:
            run = PIPELINES_RUNS.get(int(m[1]))
            return self.reply(run) if run else self.missing()
        m = re.fullmatch(r"/pipelines/(\d+)/steps", rest)
        if m:
            return self.page(STEPS.get(int(m[1]), []))
        m = re.fullmatch(r"/pipelines/(\d+)/steps/(\{[^/]+\})/log", rest)
        if m:
            log = LOGS.get(unquote(m[2]))
            return self.text(log) if log is not None else self.missing()
        m = re.fullmatch(r"/permissions-config/users/([^/]+)", rest)
        if m:
            perm = MEMBERS.get(unquote(m[1]))
            return self.reply({"permission": perm}) if perm else self.missing()
        return self.missing()

    def write(self, method, rest, body):
        m = re.fullmatch(r"/(issues|pullrequests)/(\d+)/comments", rest)
        if method == "POST" and m:
            NEXT[0] += 1
            c = comment(NEXT[0], KIM, (body.get("content") or {}).get("raw", ""), ago(0))
            (ISSUE_COMMENTS if m[1] == "issues" else PR_COMMENTS).setdefault(int(m[2]), []).append(c)
            return self.reply(c, 201)
        m = re.fullmatch(r"/pullrequests/(\d+)/comments/(\d+)", rest)
        if method == "PUT" and m:
            c = next((c for c in PR_COMMENTS.get(int(m[1]), []) if c["id"] == int(m[2])), None)
            if not c:
                return self.missing()
            c["content"], c["updated_on"] = body.get("content", c["content"]), ago(0)
            return self.reply(c)
        m = re.fullmatch(r"/issues/(\d+)", rest)
        if method == "PUT" and m and int(m[1]) in ISSUES:
            i = ISSUES[int(m[1])]
            for key in ("state", "kind", "title"):
                if key in body:
                    i[key] = body[key]
            if "component" in body:
                i["component"] = body["component"]
            i["updated_on"] = ago(0)
            return self.reply(i)
        m = re.fullmatch(r"/pullrequests/(\d+)/(decline|merge|approve)", rest)
        if method == "POST" and m and int(m[1]) in PULLS:
            pr = PULLS[int(m[1])]
            if m[2] == "approve":
                return self.reply({"approved": True, "user": KIM, "date": ago(0)})
            pr["state"], pr["updated_on"] = {"decline": "DECLINED", "merge": "MERGED"}[m[2]], ago(0)
            return self.reply(pr)
        if method == "POST" and rest == "/pipelines":
            n = max(PIPELINES_RUNS) + 1
            run = {"uuid": "{p%d}" % n, "build_number": n, "state": {"name": "PENDING"}, "target": body.get("target"),
                   "created_on": ago(0)}
            PIPELINES_RUNS[n] = run
            return self.reply(run, 201)
        return self.missing()

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
