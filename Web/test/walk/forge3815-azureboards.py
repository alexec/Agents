#!/usr/bin/env python3
"""A fixture Azure DevOps for the Work pages (#3815): the project acme/Web Shop (Agile's work item
types), with five work items (#3939: two Epics with feature: tags), as forge/* reads them over Azure DevOps's REST API 7.1 (WIQL and
workitemsbatch of the organization, a work item with its links, its comments, the project's work
item types and tags) and the writes the pages make (a comment, tags, a state, a new child), kept
in memory so the next read shows them; and the project's own WIQL, workitemsbatch and
connectionData (Kim Lee is the token's owner), which the azureboards server's Azure Boards page
reads (#3826); and the repository acme/Web Shop/shop with one pull request and one Azure
Pipelines build, which an Azure DevOps folder's set-up reads (#3802), and a no to the token
"wrong-token"; the team Payments, whose area path Web Shop\\Payments holds the wallet's
work items, for a project's board (#3816):
http://127.0.0.1:<port>/acme/Web%20Shop/_boards/board/t/Payments; and that repository's pull
requests on the Work pages (#3803): three of them, a pull request's threads, builds, a status,
its files and their diff, tags, and the writes the pages make (a comment, tags, abandon,
complete, a vote, a build run again). Scratch data only. Point a run-app host at it with a
scratch AGENTS_PERSONAL_HOME whose .agents-secrets/secrets.env says

    AZURE_DEVOPS_URL=http://127.0.0.1:<port>
    AZURE_DEVOPS_TOKEN=walk

and a folder whose .agents/folder.json says {"azureBoardsProjects": ["acme/Web Shop"]}. For the
set-up (#3802), connect Azure DevOps with the organization http://127.0.0.1:<port>/acme instead,
and give the folder the remote http://127.0.0.1:<port>/acme/Web%20Shop/_git/shop.

    python3 Web/test/walk/forge3815-azureboards.py <port>
"""
import base64
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8797
BASE = f"http://127.0.0.1:{PORT}"
START = datetime.now(timezone.utc)


def ago(hours):
    """A time hours before the fixture started, so the pages say "3 hours ago"."""
    return (START - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


NOW = ago(0)
PROJECT = "Web Shop"
STATES = [("New", "Proposed"), ("Active", "InProgress"), ("Resolved", "Resolved"), ("Closed", "Completed"), ("Removed", "Removed")]
TYPES = {"User Story": STATES, "Bug": STATES[:4], "Task": [("New", "Proposed"), ("Active", "InProgress"), ("Closed", "Completed")],
         "Epic": STATES}
TAGS = ["checkout", "mobile", "payments", "ux"]
PAYMENTS = PROJECT + "\\Payments"
KIM = {"id": "u-kim", "displayName": "Kim Lee", "uniqueName": "kim@example.com", "descriptor": "aad.a2lt"}
SAM = {"id": "u-sam", "displayName": "Sam Ortiz", "uniqueName": "sam@example.com", "descriptor": "aad.c2Ft"}
BOT = {"id": "u-bot", "displayName": "Project Collection Build Service (acme)", "uniqueName": "Build\\acme", "descriptor": "svc.YnVpbGQ"}


def item(title, kind, state, tags, creator, assignee, changed, description, comments=(), relations=(), area=PROJECT):
    fields = {"System.Title": title, "System.WorkItemType": kind, "System.State": state, "System.Tags": "; ".join(tags),
              "System.CreatedBy": creator, "System.CreatedDate": ago(150), "System.ChangedDate": changed,
              "System.TeamProject": PROJECT, "System.AreaPath": area, "System.Description": description,
              "System.CommentCount": len(comments)}
    if assignee:
        fields["System.AssignedTo"] = assignee
    return {"rev": 1, "fields": fields, "comments": list(comments), "relations": list(relations)}


def link(rel, n):
    return {"rel": rel, "url": f"{BASE}/acme/_apis/wit/workItems/{n}", "attributes": {}}


ITEMS = {
    40: item("Pay with a wallet", "Epic", "Active", ["payments", "feature:wallet"], SAM, SAM, ago(3),
             "<p>Apple Pay and Google Pay at checkout.</p>",
             relations=[link("System.LinkTypes.Hierarchy-Forward", 41), link("System.LinkTypes.Hierarchy-Forward", 42)],
             area=PAYMENTS),
    41: item("Apple Pay sheet closes before the payment is confirmed", "Bug", "Active", ["payments", "mobile", "feature:wallet"], SAM, KIM,
             ago(1),
             "<h3>Steps</h3><ol><li>Add an item to the cart</li><li>Pay with <b>Apple Pay</b></li></ol>"
             "<p>The sheet closes and the order stays unpaid.</p>",
             comments=[{"id": 1, "text": "<p>Seen on iOS 19.1 only.</p>", "createdBy": KIM, "createdDate": ago(2)},
                       {"id": 2, "text": "Build **2.4.1** has the fix.", "format": "markdown", "createdBy": BOT,
                        "createdDate": ago(1.5)}],
             relations=[link("System.LinkTypes.Hierarchy-Reverse", 40)], area=PAYMENTS),
    42: item("Log the payment sheet's dismiss reason", "User Story", "New", ["payments"], KIM, None, ago(4),
             "<p>So we can tell a cancel from a timeout.</p>",
             relations=[link("System.LinkTypes.Hierarchy-Reverse", 40), link("System.LinkTypes.Dependency-Reverse", 41)],
             area=PAYMENTS),
    43: item("Coupon field hides behind the keyboard", "User Story", "Resolved", ["checkout", "ux"], SAM, SAM,
             ago(1.25), "<p>On a small phone the coupon field is under the keyboard.</p>"),
    # An epic outside the team Payments, done, with no epic tag: Work ▸ Features finds it by its type (#3939).
    44: item("Gift cards", "Epic", "Closed", ["feature:gift-cards"], KIM, None, ago(40), "<p>Sell and redeem gift cards.</p>"),
}
NEXT = [100]

# The repository acme/Web Shop/shop's pull requests (#3803), and what each one's page reads.
PULLS = {
    7: {"pullRequestId": 7, "title": "Pay with a saved card", "status": "active", "createdBy": SAM, "creationDate": ago(5),
        "sourceRefName": "refs/heads/saved-card", "targetRefName": "refs/heads/main", "mergeStatus": "succeeded",
        "description": "Adds **saved cards** to checkout.\n\nFixes AB#41", "lastMergeSourceCommit": {"commitId": "c7head"},
        "labels": [{"name": "payments", "active": True}], "reviewers": [{**KIM, "vote": 0}]},
    8: {"pullRequestId": 8, "title": "Coupon field above the keyboard", "status": "active", "createdBy": KIM, "creationDate": ago(2),
        "sourceRefName": "refs/heads/coupon", "targetRefName": "refs/heads/main", "mergeStatus": "conflicts", "isDraft": True,
        "description": "", "lastMergeSourceCommit": {"commitId": "c8head"}, "labels": [], "reviewers": []},
    6: {"pullRequestId": 6, "title": "Log the dismiss reason", "status": "completed", "createdBy": KIM, "creationDate": ago(30),
        "closedDate": ago(26), "sourceRefName": "refs/heads/dismiss", "targetRefName": "refs/heads/main", "mergeStatus": "succeeded",
        "description": "", "lastMergeSourceCommit": {"commitId": "c6head"}, "labels": [{"name": "ux", "active": True}],
        "reviewers": [{**SAM, "vote": 10}]},
}
THREADS = {7: [
    {"id": 1, "status": "active", "comments": [{"id": 1, "author": KIM, "content": "Does it work with **Apple Pay** too?",
                                               "publishedDate": ago(4), "commentType": "text"}]},
    {"id": 2, "status": "active", "comments": [{"id": 1, "author": BOT, "content": "Policy: build validation queued",
                                               "publishedDate": ago(4.5), "commentType": "system"}]},
    {"id": 3, "status": "active", "threadContext": {"filePath": "/src/checkout.ts", "rightFileStart": {"line": 3}},
     "comments": [{"id": 1, "author": KIM, "content": "Name this savedCard", "publishedDate": ago(3.5), "commentType": "text"}]},
]}
BUILDS = [{"id": 31, "buildNumber": "20261107.3", "status": "completed", "result": "succeeded", "queueTime": ago(4),
           "finishTime": ago(3.9), "definition": {"id": 1, "name": "shop-ci"}, "repository": {"id": "r-shop"},
           "sourceBranch": "refs/heads/main", "_links": {"web": {"href": f"{BASE}/acme/{PROJECT}/_build/results?buildId=31"}}},
          {"id": 32, "buildNumber": "20261107.4", "status": "completed", "result": "failed", "queueTime": ago(3),
           "finishTime": ago(2.9), "definition": {"id": 2, "name": "shop-pr"}, "repository": {"id": "r-shop"},
           "sourceBranch": "refs/pull/7/merge", "triggerInfo": {"pr.number": "7", "pr.sourceSha": "c7head"},
           "_links": {"web": {"href": f"{BASE}/acme/{PROJECT}/_build/results?buildId=32"}}}]
STATUSES = {7: [{"id": 1, "state": "succeeded", "description": "No secrets", "targetUrl": "https://scan.example/1",
                 "creationDate": ago(3), "context": {"genre": "scan", "name": "secrets"}}]}
FILES = {"c7base:/src/checkout.ts": "export function pay(card) {\n  return charge(card);\n}\n",
         "c7head:/src/checkout.ts": "export function pay(card, saved) {\n  const card2 = saved ?? card;\n  return charge(card2);\n}\n",
         "c7head:/src/saved.ts": "export const saved = [];\n"}


def full(n):
    it = ITEMS[n]
    return {"id": n, "rev": it["rev"], "fields": it["fields"], "relations": it["relations"],
            "url": f"{BASE}/acme/_apis/wit/workItems/{n}"}


def closed_states():
    return {s for states in TYPES.values() for s, c in states if c in ("Completed", "Removed")}


def wiql(query):
    ids = list(ITEMS)
    for m in re.finditer(r"\[System\.State\] (NOT IN|IN) \(([^)]*)\)", query):
        names = set(re.findall(r"'([^']*)'", m.group(2)))
        ids = [n for n in ids if (ITEMS[n]["fields"]["System.State"] in names) == (m.group(1) == "IN")]
    # The label epic: an Epic work item, or one tagged epic (#3939).
    m = re.search(r"\(\[System\.WorkItemType\] = '([^']*)' OR \[System\.Tags\] CONTAINS '([^']*)'\)", query)
    if m:
        ids = [n for n in ids if ITEMS[n]["fields"]["System.WorkItemType"] == m.group(1) or
               m.group(2).lower() in [t.strip().lower() for t in ITEMS[n]["fields"]["System.Tags"].split(";")]]
        query = query.replace(m.group(0), "")
    m = re.search(r"\[System\.WorkItemType\] = '([^']*)'", query)
    if m:
        ids = [n for n in ids if ITEMS[n]["fields"]["System.WorkItemType"] == m.group(1)]
    for tag in re.findall(r"\[System\.Tags\] CONTAINS '([^']*)'", query):
        ids = [n for n in ids if tag.lower() in [t.strip().lower() for t in ITEMS[n]["fields"]["System.Tags"].split(";")]]
    areas = re.findall(r"\[System\.AreaPath\] (UNDER|=) '([^']*)'", query)
    if areas:
        def within(path):
            return any(path == a or (op == "UNDER" and path.startswith(a + "\\")) for op, a in areas)
        ids = [n for n in ids if within(ITEMS[n]["fields"]["System.AreaPath"])]
    m = re.search(r"\[System\.Title\] CONTAINS '([^']*)'", query)
    if m:
        ids = [n for n in ids if m.group(1).lower() in ITEMS[n]["fields"]["System.Title"].lower()]
    return sorted(ids, key=lambda n: (ITEMS[n]["fields"]["System.ChangedDate"], n), reverse=True)


def touch(it):
    it["rev"] += 1
    it["fields"]["System.ChangedDate"] = NOW


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"null")

    def route(self, method):
        u = urlparse(self.path)
        path, q = unquote(u.path), parse_qs(u.query)
        project = f"/acme/{PROJECT}/_apis/wit/".lower()
        lower = path.lower()
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Basic ") and base64.b64decode(auth[6:]).decode().endswith(":wrong-token"):
            return self.answer({"message": "TF400813: The user is not authorized to access this resource."}, 401)
        if method == "GET" and path == "/acme/_apis/connectionData":
            return self.answer({"authenticatedUser": {"id": KIM["id"], "providerDisplayName": KIM["displayName"]}})
        repo = f"/acme/{PROJECT}/_apis/git/repositories/shop".lower()
        if method == "GET" and lower == repo:
            return self.answer({"id": "r-shop", "name": "shop", "defaultBranch": "refs/heads/main",
                                "webUrl": f"{BASE}/acme/{PROJECT}/_git/shop"})
        if lower.startswith(repo + "/") or lower.startswith(f"/acme/{PROJECT}/_apis/build/".lower()) or \
                lower == f"/acme/{PROJECT}/_apis/git/policy/configurations".lower():
            return self.repos(method, lower[len(repo):] if lower.startswith(repo) else lower, q)
        if method == "POST" and lower in ("/acme/_apis/wit/wiql", project + "wiql"):
            ids = wiql(self.body()["query"])[: int(q.get("$top", ["200"])[0])]
            return self.answer({"workItems": [{"id": n} for n in ids]})
        if method == "POST" and lower in ("/acme/_apis/wit/workitemsbatch", project + "workitemsbatch"):
            b = self.body()
            out = []
            for n in b["ids"]:
                if n not in ITEMS:
                    out.append(None)
                elif b.get("$expand"):
                    out.append(full(n))
                else:
                    out.append({"id": n, "fields": {f: v for f, v in ITEMS[n]["fields"].items() if f in b["fields"]}})
            return self.answer({"count": len(out), "value": out})
        m = re.fullmatch(r"/acme/_apis/wit/workitems/(\d+)", lower)
        if method == "GET" and m:
            n = int(m.group(1))
            return self.answer(full(n)) if n in ITEMS else self.answer({"message": "TF401232: Work item does not exist"}, 404)
        if method == "GET" and lower == f"/acme/{PROJECT}/Payments/_apis/work/teamsettings/teamfieldvalues".lower():
            return self.answer({"field": {"referenceName": "System.AreaPath"}, "defaultValue": PAYMENTS,
                                "values": [{"value": PAYMENTS, "includeChildren": True}]})
        if not lower.startswith(project):
            return self.answer({"message": f"the fixture has no {method} {path}"}, 404)
        rest = path[len(project):]
        if method == "GET" and rest == "workitemtypes":
            return self.answer({"value": [{"name": t, "states": [{"name": s, "category": c} for s, c in states]} for t, states in TYPES.items()]})
        if method == "GET" and rest == "tags":
            return self.answer({"value": [{"id": t, "name": t} for t in TAGS]})
        m = re.fullmatch(r"workItems/(\d+)/comments", rest)
        if m:
            it = ITEMS[int(m.group(1))]
            if method == "POST":
                c = {"id": NEXT[0], "text": self.body()["text"], "format": q.get("format", ["html"])[0], "createdBy": KIM, "createdDate": NOW}
                NEXT[0] += 1
                it["comments"].append(c)
                it["fields"]["System.CommentCount"] = len(it["comments"])
                touch(it)
                return self.answer(c)
            return self.answer({"comments": sorted(it["comments"], key=lambda c: c["createdDate"], reverse=True)})
        m = re.fullmatch(r"workitems/(\d+)", rest)
        if method == "PATCH" and m:
            n = int(m.group(1))
            self.apply(ITEMS[n], self.body())
            return self.answer(full(n))
        m = re.fullmatch(r"workitems/\$(.+)", rest)
        if method == "POST" and m:
            n = NEXT[0]
            NEXT[0] += 1
            ITEMS[n] = item("", m.group(1), "New", [], KIM, None, NOW, "")
            self.apply(ITEMS[n], self.body())
            parent = next((r for r in ITEMS[n]["relations"] if r["rel"] == "System.LinkTypes.Hierarchy-Reverse"), None)
            if parent:
                p = int(parent["url"].rsplit("/", 1)[1])
                ITEMS[p]["relations"].append(link("System.LinkTypes.Hierarchy-Forward", n))
            return self.answer(full(n))
        return self.answer({"message": f"the fixture has no {method} {path}"}, 404)

    def repos(self, method, rest, q):
        """The repository's pull requests and builds (#3803)."""
        one = lambda k: q.get(k, [""])[0]
        if method == "GET" and rest == "/pullrequests":
            status = one("searchCriteria.status") or "active"
            out = sorted((p for p in PULLS.values() if status == "all" or p["status"] == status), key=lambda p: -p["pullRequestId"])
            skip, top = int(one("$skip") or 0), int(one("$top") or 100)
            return self.answer({"value": out[skip:skip + top]})
        m = re.fullmatch(r"/pullrequests/(\d+)", rest)
        if m:
            p = PULLS.get(int(m.group(1)))
            if p is None:
                return self.answer({"message": "TF401180: The requested pull request was not found."}, 404)
            if method == "PATCH":
                b = self.body()
                if b.get("status"):
                    p["status"] = b["status"]
                    if b["status"] != "active":
                        p["closedDate"] = NOW
                if b.get("autoCompleteSetBy"):
                    p["autoCompleteSetBy"] = KIM
            return self.answer(p)
        m = re.fullmatch(r"/pullrequests/(\d+)/threads", rest)
        if m:
            n = int(m.group(1))
            if method == "POST":
                c = self.body()["comments"][0]
                t = {"id": NEXT[0], "status": "active", "comments": [{"id": 1, "author": KIM, "content": c["content"],
                                                                     "publishedDate": NOW, "commentType": "text"}]}
                NEXT[0] += 1
                THREADS.setdefault(n, []).append(t)
                return self.answer(t)
            return self.answer({"value": THREADS.get(n, [])})
        m = re.fullmatch(r"/pullrequests/(\d+)/labels(?:/(.+))?", rest)
        if m:
            p = PULLS[int(m.group(1))]
            if method == "POST":
                p["labels"].append({"name": self.body()["name"], "active": True})
            elif method == "DELETE":
                p["labels"] = [l for l in p["labels"] if l["name"].lower() != m.group(2)]
            return self.answer({})
        m = re.fullmatch(r"/pullrequests/(\d+)/reviewers/(.+)", rest)
        if method == "PUT" and m:
            p = PULLS[int(m.group(1))]
            p["reviewers"] = [r for r in p["reviewers"] if r["id"] != KIM["id"]] + [{**KIM, "vote": self.body()["vote"]}]
            return self.answer({})
        m = re.fullmatch(r"/pullrequests/(\d+)/statuses", rest)
        if m:
            return self.answer({"value": STATUSES.get(int(m.group(1)), [])})
        m = re.fullmatch(r"/pullrequests/(\d+)/iterations", rest)
        if m:
            n = int(m.group(1))
            return self.answer({"value": [{"id": 1, "sourceRefCommit": {"commitId": f"c{n}head"},
                                           "commonRefCommit": {"commitId": f"c{n}base"}}]})
        m = re.fullmatch(r"/pullrequests/(\d+)/iterations/1/changes", rest)
        if m:
            changes = [{"changeType": "edit", "item": {"path": "/src/checkout.ts"}}, {"changeType": "add", "item": {"path": "/src/saved.ts"}}]
            return self.answer({"changeEntries": changes if m.group(1) == "7" else []})
        if method == "POST" and rest == "/filediffs":
            return self.answer([{"path": "/src/checkout.ts", "lineDiffBlocks": [
                {"changeType": "edit", "originalLineNumberStart": 1, "originalLinesCount": 2, "modifiedLineNumberStart": 1,
                 "modifiedLinesCount": 3}]}])
        if method == "GET" and rest == "/items":
            text = FILES.get(one("versionDescriptor.version") + ":" + one("path"))
            return self.answer({"content": text}) if text is not None else self.answer({"message": "no such file"}, 404)
        if rest.endswith("/_apis/git/policy/configurations"):
            return self.answer({"value": [{"isEnabled": True, "settings": {"allowSquash": True, "allowNoFastForward": True}}]})
        if rest.endswith("/_apis/build/builds") and method == "GET":
            out = [b for b in reversed(BUILDS) if not one("branchName") or b["sourceBranch"] == one("branchName")]
            return self.answer({"value": out})
        m = re.search(r"/_apis/build/builds/(\d+)$", rest)
        if m and method == "PATCH":
            b = next(b for b in BUILDS if b["id"] == int(m.group(1)))
            b["status"], b["result"] = "inProgress", ""
            return self.answer(b)
        if re.search(r"/_apis/build/builds/(\d+)/timeline$", rest):
            return self.answer({"records": [{"id": "j", "type": "Job", "name": "Test"},
                                            {"id": "t", "parentId": "j", "type": "Task", "name": "npm test", "result": "failed",
                                             "log": {"id": 4}, "issues": [{"type": "error", "message": "1 test failed"}]}]})
        if re.search(r"/_apis/build/builds/(\d+)/logs/4$", rest):
            return self.answer({"value": ["> npm test", "FAIL checkout.test.ts", "  expected saved card"]})
        return self.answer({"message": f"the fixture has no {method} {rest}"}, 404)

    def apply(self, it, ops):
        for op in ops:
            path = op["path"]
            if op["op"] == "add" and path.startswith("/fields/"):
                it["fields"][path[len("/fields/"):]] = op["value"]
            elif op["op"] == "add" and path == "/relations/-":
                it["relations"].append(op["value"])
            elif op["op"] == "remove" and path.startswith("/relations/"):
                del it["relations"][int(path[len("/relations/"):])]
        touch(it)

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
    print(f"fixture Azure DevOps on {BASE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
