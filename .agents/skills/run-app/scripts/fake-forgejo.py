#!/usr/bin/env python3
"""A fake Forgejo for walks on a scratch app (#4136): the REST API v1 paths that the daemon's
Work pages (forge/*) and the forgejo server read and write, from its test fake
(Go/internal/forgejomcp/fake_test.go). Scratch data only, kept in memory: a walk makes no
outside account.

- Forgejo 17 at http://127.0.0.1:<port>/. Any token connects ("Authorization: token …"),
  except "wrong-token", which gets a 401. /user says kim.
- The repository acme/app (main branch main, merge or squash): issues 1 to 3 (labels, one
  feature:wallet label for Work ▸ Features, a milestone, comments, a timeline, dependencies, so
  issue 1 is blocked by issue 2), and pull requests 4 to 6, numbered with the issues as Forgejo
  numbers them (open with a failing Actions status and a review, a draft in conflict, merged),
  their reviews, line comments, files, diff and statuses; a failed Forgejo Actions run with its
  jobs and log; the commits and tags v1.0.0 and v1.1.0, so the release v1.1.0 has the pull
  request 6 (lineage).
- Writes: a comment (and a comment's edit), labels, an issue's state, a new issue,
  dependencies, a review, a merge, a job or a run's failed jobs again.

run-app starts it with `launch.sh --fake-forgejo`. Then connect Forgejo with the URL
http://127.0.0.1:<port> and any token, and add a folder whose remote is
http://127.0.0.1:<port>/acme/app.git: the host finds a Forgejo repository on the connection's
host. By hand:

    python3 .agents/skills/run-app/scripts/fake-forgejo.py <port>
"""
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
BASE = f"http://127.0.0.1:{PORT}"
REPO = "acme/app"
ROOT = "/api/v1/repos/" + REPO
START = datetime.now(timezone.utc)


def ago(hours):
    """A time hours before the fake started, as Forgejo writes one."""
    return (START - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")


KIM = {"id": 1, "login": "kim", "full_name": "Kim Lee"}
SAM = {"id": 2, "login": "sam", "full_name": "Sam Ortiz"}
BOT = {"id": 9, "login": "forgejo-actions", "full_name": "Forgejo Actions"}
PERMS = {"kim": "admin", "sam": "write"}
LABELS = [{"id": n, "name": name, "color": color} for n, (name, color) in
          enumerate([("bug", "ee0701"), ("enhancement", "84b6eb"), ("payments", "0e8a16"), ("ux", "c5def5"),
                     ("feature:wallet", "5319e7")], 1)]
MILESTONE = {"id": 1, "title": "Wallet", "state": "open", "html_url": f"{BASE}/{REPO}/milestone/1"}


def labels(*names):
    return [dict(next(l for l in LABELS if l["name"] == n)) for n in names]


def issue(n, title, state, author, assignees, updated, body, names=(), milestone=None):
    return {"id": 100 + n, "number": n, "title": title, "body": body, "state": state, "user": author,
            "html_url": f"{BASE}/{REPO}/issues/{n}", "labels": labels(*names), "assignees": list(assignees),
            "milestone": milestone, "comments": 0, "created_at": ago(150), "updated_at": updated,
            "closed_at": updated if state == "closed" else None, "pull_request": None,
            "repository": {"full_name": REPO, "owner": "acme", "name": "app"}}


def pull(n, title, branch, state, author, updated, body, names=(), draft=False, mergeable=True, merged=False, reviewers=()):
    i = issue(n, ("WIP: " if draft else "") + title, state, author, (), updated, body, names)
    i["html_url"] = f"{BASE}/{REPO}/pulls/{n}"
    i["pull_request"] = {"merged": merged, "draft": draft, "merged_at": updated if merged else None,
                         "html_url": i["html_url"]}
    p = dict(i, draft=draft, mergeable=mergeable, merged=merged, merged_at=updated if merged else None,
             merge_commit_sha=("b6" * 20) if merged else "", changed_files=1,
             head={"ref": branch, "sha": f"c{n}head", "repo_id": 7}, base={"ref": "main", "sha": "a1" * 20, "repo_id": 7},
             requested_reviewers=list(reviewers))
    return i, p


ITEMS = {
    1: issue(1, "Apple Pay sheet closes before the payment is confirmed", "open", SAM, [KIM], ago(1),
             "1. Add an item to the cart\n2. Pay with **Apple Pay**\n\nThe sheet closes and the order stays unpaid.",
             ("bug", "payments", "feature:wallet"), MILESTONE),
    2: issue(2, "Log the payment sheet's dismiss reason", "open", KIM, [], ago(4), "So we can tell a cancel from a timeout.",
             ("enhancement", "feature:wallet"), MILESTONE),
    3: issue(3, "Coupon field hides behind the keyboard", "closed", SAM, [SAM], ago(30),
             "On a small phone the coupon field is under the keyboard.", ("bug", "ux")),
}
PULLS = {}
for _n, _i, _p in [(4, *pull(4, "Pay with a saved card", "saved-card", "open", SAM, ago(3),
                                 "Adds **saved cards** to checkout.\n\nFixes #1", ("payments",), reviewers=[KIM])),
                   (5, *pull(5, "Coupon field above the keyboard", "coupon", "open", KIM, ago(2), "", ("ux",), draft=True,
                                 mergeable=False)),
                   (6, *pull(6, "Show the card's brand", "brand", "closed", SAM, ago(45), "Fixes #3", merged=True))]:
    ITEMS[_n], PULLS[_n] = _i, _p


def comment(cid, n, by, body, when):
    return {"id": cid, "html_url": f"{BASE}/{REPO}/issues/{n}#issuecomment-{cid}", "issue_url": f"{BASE}/{ROOT}/issues/{n}",
            "pull_request_url": "", "user": by, "body": body, "created_at": when, "updated_at": when}


COMMENTS = {1: [comment(11, 1, KIM, "Seen on iOS 19.1 only.", ago(2)), comment(12, 1, SAM, "Build **2.4.1** has the fix.", ago(1.5))],
            4: [comment(21, 4, KIM, "Does it work with **Apple Pay** too?", ago(4))]}
TIMELINE = {3: [{"id": 31, "type": "close", "user": SAM, "created_at": ago(30), "body": ""}]}
DEPENDS = {1: [2]}  # issue → the issues it is blocked by
REVIEWS = {4: [{"id": 41, "user": KIM, "state": "REQUEST_CHANGES", "body": "One rename.", "commit_id": "c4head",
                "comments_count": 1, "submitted_at": ago(3.5), "updated_at": ago(3.5), "html_url": f"{BASE}/{REPO}/pulls/4#review-41"}],
           6: [{"id": 61, "user": KIM, "state": "APPROVED", "body": "", "commit_id": "c6head", "comments_count": 0,
                "submitted_at": ago(46), "updated_at": ago(46), "html_url": f"{BASE}/{REPO}/pulls/6#review-61"}]}
LINES = {41: [{"id": 411, "body": "Name this savedCard", "user": KIM, "resolver": None, "pull_request_review_id": 41,
               "path": "src/checkout.ts", "position": 3, "line": 3, "created_at": ago(3.5), "updated_at": ago(3.5),
               "html_url": f"{BASE}/{REPO}/pulls/4#issuecomment-411"}]}
FILES = {4: [{"filename": "src/checkout.ts", "status": "changed", "additions": 2, "deletions": 1, "changes": 3}],
         5: [{"filename": "src/coupon.ts", "status": "changed", "additions": 3, "deletions": 1, "changes": 4}],
         6: [{"filename": "src/brand.ts", "status": "added", "additions": 3, "deletions": 0, "changes": 3}]}
DIFFS = {4: "diff --git a/src/checkout.ts b/src/checkout.ts\n--- a/src/checkout.ts\n+++ b/src/checkout.ts\n"
            "@@ -1,3 +1,4 @@\n export function pay(cart) {\n-  return charge(cart)\n+  const card = savedCard()\n+  return charge(cart, card)\n }\n",
         5: "diff --git a/src/coupon.ts b/src/coupon.ts\n--- a/src/coupon.ts\n+++ b/src/coupon.ts\n"
            "@@ -1,2 +1,4 @@\n-export const coupon = field()\n+export const coupon = field({\n+  aboveKeyboard: true,\n+})\n",
         6: "diff --git a/src/brand.ts b/src/brand.ts\nnew file mode 100644\n--- /dev/null\n+++ b/src/brand.ts\n"
            "@@ -0,0 +1,3 @@\n+export function brand(card) {\n+  return card.network\n+}\n"}
STATUSES = {"c4head": {"state": "failure", "sha": "c4head", "statuses": [
    {"id": 1, "context": "ci / test (pull_request)", "status": "failure", "target_url": f"{BASE}/{REPO}/actions/runs/12/jobs/1",
     "description": "Failing after 41s", "created_at": ago(2.9), "updated_at": ago(2.9)},
    {"id": 2, "context": "scan/secrets", "status": "success", "target_url": "https://scan.example/1",
     "description": "No secrets", "created_at": ago(3), "updated_at": ago(3)}]}}
RUNS = [{"id": 512, "index_in_repo": 12, "run_number": 12, "status": "failure", "head_sha": "c4head", "head_branch": "saved-card",
         "event": "pull_request", "html_url": f"{BASE}/{REPO}/actions/runs/12", "created": ago(3), "updated": ago(2.9)}]
JOBS = {512: [{"id": 601, "name": "build", "status": "success", "html_url": f"{BASE}/{REPO}/actions/runs/12/jobs/0",
               "steps": [{"number": 0, "name": "npm ci", "status": "success"}, {"number": 1, "name": "npm run build", "status": "success"}]},
              {"id": 602, "name": "test", "status": "failure", "html_url": f"{BASE}/{REPO}/actions/runs/12/jobs/1",
               "steps": [{"number": 0, "name": "npm ci", "status": "success"}, {"number": 1, "name": "npm test", "status": "failure"}]}]}
LOGS = {601: "npm ci\nadded 412 packages\nnpm run build\nbuilt in 4.2s\n",
        602: "npm ci\nadded 412 packages\nnpm test\n PASS  src/cart.test.ts\n FAIL  src/checkout.test.ts\n  ● pays with a saved card\n"
             "    expected charge(cart, card), got charge(cart)\nTests: 1 failed, 11 passed, 12 total\n"}
# main's commits newest first, and the tags: v1.1.0 has the merge of pull request 6.
COMMITS = [{"sha": "b6" * 20, "date": ago(45), "message": "Show the card's brand (#6)"},
           {"sha": "a1" * 20, "date": ago(100), "message": "First release"}]
TAGS = {"v1.1.0": "b6" * 20, "v1.0.0": "a1" * 20}
COMMIT_PULLS = {"b6" * 20: 6}
NEXT = [1000]

for _n, _list in COMMENTS.items():
    ITEMS[_n]["comments"] = len(_list)


def sha_of(ref):
    return TAGS.get(ref, ref)


def commit_json(c):
    who = {"name": "Sam Ortiz", "email": "sam@example.com", "date": c["date"]}
    return {"sha": c["sha"], "html_url": f"{BASE}/{REPO}/commit/{c['sha']}",
            "commit": {"message": c["message"], "author": who, "committer": who}}


def touch(n):
    ITEMS[n]["updated_at"] = ago(0)
    if n in PULLS:
        PULLS[n]["updated_at"] = ago(0)


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

    def empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def missing(self):
        self.reply({"message": "The target couldn't be found."}, 404)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            return {}

    def route(self, method):
        u = urlparse(self.path)
        p, q = u.path.rstrip("/") or "/", parse_qs(u.query)
        if p == "/api/v1/version":
            return self.reply({"version": "17.0.1+gitea-1.22.0"})
        if self.headers.get("Authorization", "") in ("", "token ", "token wrong-token") or \
                not self.headers.get("Authorization", "").startswith("token "):
            return self.reply({"message": "token is required"}, 401)
        if q.get("page", ["1"])[0] not in ("", "1") and method == "GET":
            return self.reply([])
        if p == "/api/v1/user":
            return self.reply(KIM)
        if re.fullmatch(r"/api/v1/orgs/acme/members/[^/]+", p):
            return self.empty(204) if p.rsplit("/", 1)[1] in PERMS else self.missing()
        if not p.startswith(ROOT):
            return self.missing()
        rest = p[len(ROOT):]
        if method == "GET":
            return self.get(rest, q)
        return self.write(method, rest, self.body())

    def get(self, rest, q):
        one = lambda k, d="": q.get(k, [d])[0]  # noqa: E731
        if rest == "":
            return self.reply({"full_name": REPO, "name": "app", "owner": {"login": "acme"}, "default_branch": "main",
                               "html_url": f"{BASE}/{REPO}", "has_issues": True, "has_pull_requests": True,
                               "allow_merge_commits": True, "allow_squash_merge": True, "allow_rebase": False,
                               "default_merge_style": "merge"})
        if rest == "/issues":
            kind, state = one("type"), one("state", "open")
            out = []
            for i in ITEMS.values():
                if (kind == "issues" and i["pull_request"]) or (kind == "pulls" and not i["pull_request"]):
                    continue
                if state != "all" and i["state"] != state:
                    continue
                if one("labels") and not any(l["name"] == one("labels") for l in i["labels"]):
                    continue
                if one("assigned_by") and not any(a["login"] == one("assigned_by") for a in i["assignees"]):
                    continue
                if one("since") and i["updated_at"] < one("since"):
                    continue
                if one("before") and i["updated_at"] > one("before"):
                    continue
                if one("q") and one("q").lower() not in (i["title"] + " " + i["body"]).lower():
                    continue
                out.append(i)
            return self.reply(sorted(out, key=lambda i: i["updated_at"], reverse=True))
        if rest == "/issues/comments":
            since = one("since")
            return self.reply([c for cs in COMMENTS.values() for c in cs if c["updated_at"] >= since])
        if rest == "/pulls":
            state = one("state", "open")
            out = [p for p in PULLS.values() if state == "all" or p["state"] == state]
            return self.reply(sorted(out, key=lambda p: p["updated_at"], reverse=True))
        if rest == "/labels":
            return self.reply(LABELS)
        if rest == "/milestones":
            return self.reply([MILESTONE])
        if rest == "/milestones/1":
            return self.reply(MILESTONE)
        m = re.fullmatch(r"/issues/(\d+)", rest)
        if m:
            i = ITEMS.get(int(m[1]))
            return self.reply(i) if i else self.missing()
        m = re.fullmatch(r"/issues/(\d+)/comments", rest)
        if m:
            return self.reply(COMMENTS.get(int(m[1]), []))
        m = re.fullmatch(r"/issues/(\d+)/timeline", rest)
        if m:
            return self.reply(TIMELINE.get(int(m[1]), []))
        m = re.fullmatch(r"/issues/(\d+)/labels", rest)
        if m:
            i = ITEMS.get(int(m[1]))
            return self.reply(i["labels"]) if i else self.missing()
        m = re.fullmatch(r"/issues/(\d+)/(dependencies|blocks)", rest)
        if m:
            n = int(m[1])
            ids = DEPENDS.get(n, []) if m[2] == "dependencies" else [k for k, v in DEPENDS.items() if n in v]
            return self.reply([ITEMS[k] for k in ids if k in ITEMS])
        m = re.fullmatch(r"/pulls/(\d+)", rest)
        if m:
            p = PULLS.get(int(m[1]))
            return self.reply(p) if p else self.missing()
        m = re.fullmatch(r"/pulls/(\d+)\.diff", rest)
        if m:
            return self.text(DIFFS.get(int(m[1]), "")) if int(m[1]) in PULLS else self.missing()
        m = re.fullmatch(r"/pulls/(\d+)/files", rest)
        if m:
            return self.reply(FILES.get(int(m[1]), []))
        m = re.fullmatch(r"/pulls/(\d+)/reviews", rest)
        if m:
            return self.reply(REVIEWS.get(int(m[1]), []))
        m = re.fullmatch(r"/pulls/(\d+)/reviews/(\d+)/comments", rest)
        if m:
            return self.reply(LINES.get(int(m[2]), []))
        m = re.fullmatch(r"/commits/([^/]+)/status", rest)
        if m:
            return self.reply(STATUSES.get(unquote(m[1]), {"state": "", "sha": unquote(m[1]), "statuses": []}))
        m = re.fullmatch(r"/commits/([^/]+)/pull", rest)
        if m:
            n = COMMIT_PULLS.get(sha_of(unquote(m[1])))
            return self.reply(PULLS[n]) if n else self.missing()
        m = re.fullmatch(r"/git/commits/([^/]+)", rest)
        if m:
            c = next((c for c in COMMITS if c["sha"] == sha_of(unquote(m[1]))), None)
            return self.reply(commit_json(c)) if c else self.missing()
        m = re.fullmatch(r"/compare/(.+)\.\.\.(.+)", rest)
        if m:
            shas = [c["sha"] for c in COMMITS]
            base, head = sha_of(unquote(m[1])), sha_of(unquote(m[2]))
            if head not in shas or base not in shas:
                return self.missing()
            listed = COMMITS[shas.index(head):shas.index(base)]
            return self.reply({"total_commits": len(listed), "commits": [commit_json(c) for c in reversed(listed)]})
        if rest == "/actions/runs":
            n = one("run_number")
            return self.reply({"workflow_runs": [r for r in RUNS if not n or str(r["index_in_repo"]) == n],
                               "total_count": len(RUNS)})
        m = re.fullmatch(r"/actions/runs/(\d+)/jobs", rest)
        if m:
            return self.reply(JOBS.get(int(m[1]), []))
        m = re.fullmatch(r"/actions/jobs/(\d+)", rest)
        if m:
            job = next((j for js in JOBS.values() for j in js if j["id"] == int(m[1])), None)
            return self.reply(job) if job else self.missing()
        m = re.fullmatch(r"/actions/jobs/(\d+)/logs", rest)
        if m:
            log = LOGS.get(int(m[1]))
            return self.text(log) if log is not None else self.missing()
        m = re.fullmatch(r"/collaborators/([^/]+)/permission", rest)
        if m:
            return self.reply({"permission": PERMS.get(unquote(m[1]), "read")})
        m = re.fullmatch(r"/collaborators/([^/]+)", rest)
        if m:
            return self.empty(204) if unquote(m[1]) in PERMS else self.missing()
        return self.missing()

    def write(self, method, rest, body):
        m = re.fullmatch(r"/issues/(\d+)/comments", rest)
        if method == "POST" and m and int(m[1]) in ITEMS:
            n = int(m[1])
            NEXT[0] += 1
            c = comment(NEXT[0], n, KIM, body.get("body", ""), ago(0))
            COMMENTS.setdefault(n, []).append(c)
            ITEMS[n]["comments"] = len(COMMENTS[n])
            touch(n)
            return self.reply(c, 201)
        m = re.fullmatch(r"/issues/comments/(\d+)", rest)
        if method == "PATCH" and m:
            c = next((c for cs in COMMENTS.values() for c in cs if c["id"] == int(m[1])), None)
            if not c:
                return self.missing()
            c["body"], c["updated_at"] = body.get("body", c["body"]), ago(0)
            return self.reply(c)
        m = re.fullmatch(r"/issues/(\d+)/labels", rest)
        if method == "POST" and m and int(m[1]) in ITEMS:
            i = ITEMS[int(m[1])]
            for name in body.get("labels", []):
                known = next((l for l in LABELS if l["name"] == name or l["id"] == name), None)
                if known and known not in i["labels"]:
                    i["labels"].append(dict(known))
            touch(int(m[1]))
            return self.reply(i["labels"])
        m = re.fullmatch(r"/issues/(\d+)/labels/(\d+)", rest)
        if method == "DELETE" and m and int(m[1]) in ITEMS:
            i = ITEMS[int(m[1])]
            i["labels"] = [l for l in i["labels"] if l["id"] != int(m[2])]
            touch(int(m[1]))
            return self.empty(204)
        m = re.fullmatch(r"/issues/(\d+)", rest)
        if method == "PATCH" and m and int(m[1]) in ITEMS:
            n = int(m[1])
            for key in ("state", "title", "body"):
                if key in body:
                    ITEMS[n][key] = body[key]
                    if n in PULLS:
                        PULLS[n][key] = body[key]
            touch(n)
            return self.reply(ITEMS[n], 201)
        if method == "POST" and rest == "/issues":
            n = max(ITEMS) + 1
            ITEMS[n] = issue(n, body.get("title", ""), "open", KIM, [], ago(0), body.get("body", ""))
            return self.reply(ITEMS[n], 201)
        m = re.fullmatch(r"/issues/(\d+)/dependencies", rest)
        if method in ("POST", "DELETE") and m and int(m[1]) in ITEMS:
            n, other = int(m[1]), body.get("index")
            deps = DEPENDS.setdefault(n, [])
            if method == "POST" and other not in deps:
                deps.append(other)
            if method == "DELETE" and other in deps:
                deps.remove(other)
            return self.reply(ITEMS[n], 201)
        m = re.fullmatch(r"/pulls/(\d+)/reviews", rest)
        if method == "POST" and m and int(m[1]) in PULLS:
            n = int(m[1])
            NEXT[0] += 1
            r = {"id": NEXT[0], "user": KIM, "state": {"APPROVE": "APPROVED"}.get(body.get("event", ""), body.get("event", "COMMENT")),
                 "body": body.get("body", ""), "commit_id": body.get("commit_id", ""), "comments_count": 0,
                 "submitted_at": ago(0), "updated_at": ago(0), "html_url": f"{BASE}/{REPO}/pulls/{n}#review-{NEXT[0]}"}
            REVIEWS.setdefault(n, []).append(r)
            touch(n)
            return self.reply(r)
        m = re.fullmatch(r"/pulls/(\d+)/merge", rest)
        if method == "POST" and m and int(m[1]) in PULLS:
            n = int(m[1])
            PULLS[n].update(state="closed", merged=True, merged_at=ago(0))
            ITEMS[n]["state"], ITEMS[n]["pull_request"]["merged"] = "closed", True
            touch(n)
            return self.empty(200)
        if method == "POST" and re.fullmatch(r"/actions/jobs/\d+/rerun", rest):
            return self.empty(204)
        if method == "POST" and re.fullmatch(r"/actions/runs/\d+/rerun-failed-jobs", rest):
            return self.empty(201)
        return self.missing()

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
