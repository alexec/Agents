#!/usr/bin/env python3
"""A fixture Jira Cloud site for the Work pages (#3260): the project SHOP, with three issues, as
forge/* reads them over Jira's REST API version 2 (/search/jql, /issue/<key> with renderedFields,
its transitions, its children) and the writes the pages make (a comment, labels, a transition), kept in memory
so the next read shows them. Scratch data only. Point a run-app host at it with a scratch
AGENTS_PERSONAL_HOME whose .agents-secrets/secrets.env says

    JIRA_URL=http://127.0.0.1:<port>
    JIRA_EMAIL=walk@example.com
    JIRA_API_TOKEN=walk

and a folder whose .agents/folder.json says {"jiraProjects": ["SHOP"]}.

    python3 Web/test/walk/forge3260-jira.py <port>
"""
import html
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8796
SITE = f"http://127.0.0.1:{PORT}"
NOW = "2026-11-02T18:00:00.000+0000"
LABELS = ["checkout", "mobile", "payments", "ux"]
STATUSES = {"To Do": "new", "In Progress": "indeterminate", "In Review": "indeterminate", "Done": "done"}
# The workflow: the moves each status allows, as (id, name, to).
WORKFLOW = {
    "To Do": [("11", "Start Progress", "In Progress"), ("31", "Done", "Done")],
    "In Progress": [("21", "Send to Review", "In Review"), ("41", "Stop Progress", "To Do"), ("31", "Done", "Done")],
    "In Review": [("51", "Back to In Progress", "In Progress"), ("31", "Done", "Done")],
    "Done": [("61", "Reopen", "To Do")],
}
KIM = {"accountId": "u-kim", "displayName": "Kim Lee", "accountType": "atlassian"}
SAM = {"accountId": "u-sam", "displayName": "Sam Ortiz", "accountType": "atlassian"}
BOT = {"accountId": "app-1", "displayName": "Automation for Jira", "accountType": "app"}

ISSUES = {
    "SHOP-12": {"summary": "Apple Pay sheet closes before the payment is confirmed", "status": "In Progress", "labels": ["payments", "mobile"],
                "creator": SAM, "assignee": KIM, "fix": "2.4", "priority": "High", "updated": "2026-11-02T17:00:00.000+0000",
                "description": "h3. Steps\n# Add an item to the cart\n# Pay with *Apple Pay*\n\nThe sheet closes and the order stays unpaid.",
                "rendered": "<h3>Steps</h3><ol><li>Add an item to the cart</li><li>Pay with <b>Apple Pay</b></li></ol>"
                            "<p>The sheet closes and the order stays unpaid. See <a href=\"https://example.com/logs\">the logs</a>.</p>",
                "comments": [(KIM, "Seen on iOS 19.1 only.", "<p>Seen on iOS 19.1 only.</p>", "2026-11-02T16:00:00.000+0000"),
                             (BOT, "Linked to the release 2.4.", "<p>Linked to the release 2.4.</p>", "2026-11-02T16:30:00.000+0000")],
                "subtasks": ["SHOP-13"]},
    "SHOP-13": {"summary": "Log the payment sheet's dismiss reason", "status": "To Do", "labels": ["payments"], "creator": KIM,
                "assignee": None, "fix": "2.4", "priority": "Medium", "updated": "2026-11-02T15:00:00.000+0000", "description": "So we can tell a cancel from a timeout.",
                "rendered": "<p>So we can tell a cancel from a timeout.</p>", "comments": [], "parent": "SHOP-12"},
    "SHOP-9": {"summary": "Coupon field hides behind the keyboard", "status": "In Review", "labels": ["checkout", "ux"], "creator": SAM,
               "assignee": SAM, "fix": None, "priority": "Low", "updated": "2026-11-02T16:00:00.000+0000", "description": "On a small phone the coupon field is under the keyboard.",
               "rendered": "<p>On a small phone the coupon field is under the keyboard.</p>", "comments": []},
}
ORDER = ["SHOP-12", "SHOP-9", "SHOP-13"]
NEXT_COMMENT = [100]


def status(name):
    return {"name": name, "statusCategory": {"key": STATUSES[name]}}


def fields(key, rendered=False):
    i = ISSUES[key]
    comments = [{"id": f"{key}-{n}", "body": c[1], "created": c[3], "author": c[0]} for n, c in enumerate(i["comments"])]
    f = {"summary": i["summary"], "status": status(i["status"]), "labels": sorted(i["labels"]), "creator": i["creator"], "reporter": i["creator"],
         "assignee": i["assignee"], "updated": i["updated"], "created": NOW, "project": {"key": "SHOP"}, "priority": {"name": i["priority"]},
         "fixVersions": [{"name": i["fix"]}] if i["fix"] else [], "comment": {"total": len(comments), "comments": comments},
         "subtasks": [{"key": s, "fields": {"status": status(ISSUES[s]["status"])}} for s in i.get("subtasks", [])]}
    if i.get("parent"):
        f["parent"] = {"key": i["parent"]}
    out = {"id": key.split("-")[1], "key": key, "fields": f}
    if rendered:
        f["description"] = i["description"]
        out["renderedFields"] = {"description": i["rendered"], "comment": {"comments": [
            {"id": f"{key}-{n}", "body": c[2]} for n, c in enumerate(i["comments"])]}}
    return out


def search(jql):
    parent = re.match(r'parent = "([^"]+)"', jql)
    if parent:
        return {"issues": [fields(k) for k in ORDER if ISSUES[k].get("parent") == parent.group(1)], "isLast": True}
    done = "statusCategory = 3" in jql
    every = "statusCategory" not in jql
    keys = [k for k in ORDER if every or (STATUSES[ISSUES[k]["status"]] == "done") == done]
    for label in re.findall(r'labels = "([^"]+)"', jql):
        keys = [k for k in keys if label in ISSUES[k]["labels"]]
    m = re.search(r'text ~ "([^"]+)"', jql)
    if m:
        keys = [k for k in keys if m.group(1).lower() in ISSUES[k]["summary"].lower()]
    return {"issues": [fields(k) for k in keys], "isLast": True}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body, code=200):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code if body is not None or code != 200 else 204)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def key(self):
        m = re.match(r"/rest/api/2/issue/([A-Z]+-\d+)", self.path)
        return m.group(1) if m and m.group(1) in ISSUES else None

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/rest/api/2/myself":
            return self.reply(KIM)
        if path == "/rest/api/2/label":
            return self.reply({"values": LABELS, "isLast": True})
        if path == "/rest/api/2/project/search":
            return self.reply({"values": [{"key": "SHOP", "name": "Shop"}]})
        key = self.key()
        if not key:
            return self.reply({"errorMessages": ["Issue does not exist or you do not have permission to see it."]}, 404)
        if path.endswith("/transitions"):
            return self.reply({"transitions": [{"id": t, "name": name, "to": status(to)} for t, name, to in WORKFLOW[ISSUES[key]["status"]]]})
        if "fields=labels" in self.path:
            return self.reply({"key": key, "fields": {"labels": sorted(ISSUES[key]["labels"])}})
        return self.reply(fields(key, rendered=True))

    def do_POST(self):
        if self.path.startswith("/rest/api/2/search"):
            return self.reply(search(self.body().get("jql", "")))
        key = self.key()
        if not key:
            return self.reply({"errorMessages": ["Issue does not exist"]}, 404)
        b = self.body()
        if self.path.endswith("/comment"):
            text = b.get("body", "")
            ISSUES[key]["comments"].append((KIM, text, "<p>" + html.escape(text) + "</p>", NOW))
            NEXT_COMMENT[0] += 1
            return self.reply({"id": str(NEXT_COMMENT[0]), "body": text}, 201)
        if self.path.endswith("/transitions"):
            want = b.get("transition", {}).get("id")
            for t, _, to in WORKFLOW[ISSUES[key]["status"]]:
                if t == want:
                    ISSUES[key]["status"] = to
                    return self.reply(None)
            return self.reply({"errorMessages": [f"Transition id '{want}' is not valid for this issue."]}, 400)
        return self.reply({"errorMessages": ["Not here"]}, 404)

    def do_PUT(self):
        key = self.key()
        if not key:
            return self.reply({"errorMessages": ["Issue does not exist"]}, 404)
        for op in self.body().get("update", {}).get("labels", []):
            if "add" in op and op["add"] not in ISSUES[key]["labels"]:
                ISSUES[key]["labels"].append(op["add"])
            if "remove" in op and op["remove"] in ISSUES[key]["labels"]:
                ISSUES[key]["labels"].remove(op["remove"])
        return self.reply(None)


if __name__ == "__main__":
    print(f"fixture Jira on {SITE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
