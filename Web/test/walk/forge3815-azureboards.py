#!/usr/bin/env python3
"""A fixture Azure DevOps for the Work pages (#3815): the project acme/Web Shop (Agile's work item
types), with four work items, as forge/* reads them over Azure DevOps's REST API 7.1 (WIQL and
workitemsbatch of the organization, a work item with its links, its comments, the project's work
item types and tags) and the writes the pages make (a comment, tags, a state, a new child), kept
in memory so the next read shows them; and the project's own WIQL, workitemsbatch and
connectionData (Kim Lee is the token's owner), which the azureboards server's Azure Boards page
reads (#3826). Scratch data only. Point a run-app host at it with a
scratch AGENTS_PERSONAL_HOME whose .agents-secrets/secrets.env says

    AZURE_DEVOPS_URL=http://127.0.0.1:<port>
    AZURE_DEVOPS_TOKEN=walk

and a folder whose .agents/folder.json says {"azureBoardsProjects": ["acme/Web Shop"]}.

    python3 Web/test/walk/forge3815-azureboards.py <port>
"""
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
KIM = {"id": "u-kim", "displayName": "Kim Lee", "uniqueName": "kim@example.com", "descriptor": "aad.a2lt"}
SAM = {"id": "u-sam", "displayName": "Sam Ortiz", "uniqueName": "sam@example.com", "descriptor": "aad.c2Ft"}
BOT = {"id": "u-bot", "displayName": "Project Collection Build Service (acme)", "uniqueName": "Build\\acme", "descriptor": "svc.YnVpbGQ"}


def item(title, kind, state, tags, creator, assignee, changed, description, comments=(), relations=()):
    fields = {"System.Title": title, "System.WorkItemType": kind, "System.State": state, "System.Tags": "; ".join(tags),
              "System.CreatedBy": creator, "System.CreatedDate": ago(150), "System.ChangedDate": changed,
              "System.TeamProject": PROJECT, "System.AreaPath": PROJECT, "System.Description": description,
              "System.CommentCount": len(comments)}
    if assignee:
        fields["System.AssignedTo"] = assignee
    return {"rev": 1, "fields": fields, "comments": list(comments), "relations": list(relations)}


def link(rel, n):
    return {"rel": rel, "url": f"{BASE}/acme/_apis/wit/workItems/{n}", "attributes": {}}


ITEMS = {
    40: item("Pay with a wallet", "Epic", "Active", ["payments"], SAM, SAM, ago(3),
             "<p>Apple Pay and Google Pay at checkout.</p>",
             relations=[link("System.LinkTypes.Hierarchy-Forward", 41), link("System.LinkTypes.Hierarchy-Forward", 42)]),
    41: item("Apple Pay sheet closes before the payment is confirmed", "Bug", "Active", ["payments", "mobile"], SAM, KIM,
             ago(1),
             "<h3>Steps</h3><ol><li>Add an item to the cart</li><li>Pay with <b>Apple Pay</b></li></ol>"
             "<p>The sheet closes and the order stays unpaid.</p>",
             comments=[{"id": 1, "text": "<p>Seen on iOS 19.1 only.</p>", "createdBy": KIM, "createdDate": ago(2)},
                       {"id": 2, "text": "Build **2.4.1** has the fix.", "format": "markdown", "createdBy": BOT,
                        "createdDate": ago(1.5)}],
             relations=[link("System.LinkTypes.Hierarchy-Reverse", 40)]),
    42: item("Log the payment sheet's dismiss reason", "User Story", "New", ["payments"], KIM, None, ago(4),
             "<p>So we can tell a cancel from a timeout.</p>",
             relations=[link("System.LinkTypes.Hierarchy-Reverse", 40), link("System.LinkTypes.Dependency-Reverse", 41)]),
    43: item("Coupon field hides behind the keyboard", "User Story", "Resolved", ["checkout", "ux"], SAM, SAM,
             ago(1.25), "<p>On a small phone the coupon field is under the keyboard.</p>"),
}
NEXT = [100]


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
    m = re.search(r"\[System\.WorkItemType\] = '([^']*)'", query)
    if m:
        ids = [n for n in ids if ITEMS[n]["fields"]["System.WorkItemType"] == m.group(1)]
    for tag in re.findall(r"\[System\.Tags\] CONTAINS '([^']*)'", query):
        ids = [n for n in ids if tag.lower() in [t.strip().lower() for t in ITEMS[n]["fields"]["System.Tags"].split(";")]]
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
        if method == "GET" and path == "/acme/_apis/connectionData":
            return self.answer({"authenticatedUser": {"id": KIM["id"]}})
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


if __name__ == "__main__":
    print(f"fixture Azure DevOps on {BASE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
