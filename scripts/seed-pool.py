#!/usr/bin/env python3
"""Seed a scratch root with the wireframes' 02:20 moment for 052's look gate (T031).

Writes pool.json, allowances.json, switches.jsonl and three agents (one with a switch
note and a handoff in its transcript) in the store's own formats. Refuses any root under
~/Library: the real store is never touched.

    scripts/seed-pool.py --root /tmp/run-052-look --work /tmp/run-052-look/work
"""
import argparse, json, os, sys, uuid, datetime

p = argparse.ArgumentParser()
p.add_argument("--root", required=True)
p.add_argument("--work", required=True)
args = p.parse_args()
root = os.path.abspath(args.root)
if root.startswith(os.path.expanduser("~/Library")) or "Application Support" in root:
    sys.exit("refusing: that looks like a real store")

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/archived-agent.json")
now = datetime.datetime.now(datetime.timezone.utc)
def iso(t): return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"
def ago(minutes): return iso(now - datetime.timedelta(minutes=minutes))
def ahead(minutes): return iso(now + datetime.timedelta(minutes=minutes))
def uid(): return str(uuid.uuid4()).upper()

claude, copilot, codex, cursor, codexKey = (uid() for _ in range(5))
entries = [
    {"id": claude, "runtimeID": "claude", "payment": {"allowance": {"label": "Max plan"}}},
    {"id": copilot, "runtimeID": "copilot", "payment": {"allowance": {"label": "Copilot Pro"}}},
    {"id": codex, "runtimeID": "codex", "payment": {"allowance": {"label": "ChatGPT plan"}}},
    {"id": cursor, "runtimeID": "cursor", "payment": {"allowance": {}}},
    {"id": codexKey, "runtimeID": "codex", "credentialRef": "openAIAPIKey",
     "payment": {"prepaid": {"amount": {"amount": 10, "currency": "USD"}}}},
]
levels = [
    {"id": uid(), "name": "Strongest", "cells": {
        "claude": {"model": "opus", "effort": "high"}, "copilot": {"model": "claude-opus-4.5"},
        "codex": {"model": "gpt-5-codex", "effort": "high"}}},
    {"id": uid(), "name": "Everyday", "cells": {
        "claude": {"model": "sonnet"}, "copilot": {"model": "gpt-5"},
        "codex": {"model": "gpt-5-codex", "effort": "medium"}}},
]
os.makedirs(root, exist_ok=True)
json.dump({"isOn": True, "entries": entries, "levels": levels}, open(f"{root}/pool.json", "w"))

allowances = [
    {"credentialKey": "claude:sign-in", "entryID": claude, "since": ago(17), "learnedFrom": "typedFailure",
     "status": {"out": {"until": ahead(280), "why": "allowanceSpent"}}, "spent": {"known": {}}, "rateLimitStreak": []},
    {"credentialKey": "copilot:sign-in", "entryID": copilot, "since": ago(6), "learnedFrom": "words",
     "status": {"out": {"retryAfter": ahead(54), "why": "allowanceSpent"}}, "spent": {"known": {}}, "rateLimitStreak": []},
    {"credentialKey": "codex:openAIAPIKey", "entryID": codexKey, "since": ago(900), "learnedFrom": "person",
     "status": {"available": {}}, "spent": {"known": {"_0": {"amount": 3.2, "currency": "USD"}}}, "rateLimitStreak": []},
]
json.dump(allowances, open(f"{root}/allowances.json", "w"))

def agent(title, runtime, state="finished", reason="endTurn", created=30):
    aid = uid()
    # A real record's shape, from the test fixture, with this one's facts put on it.
    record = json.load(open(FIXTURE))
    for key in ("archivedReason", "runtimeSessionID", "startingPoint", "usage"):
        record.pop(key, None)
    record.update({"id": aid, "title": title, "runtimeID": runtime,
                   "cwd": "file://" + os.path.abspath(args.work) + "/",
                   "state": state, "endedReason": reason, "createdAt": ago(created), "lastActivityAt": ago(1)})
    os.makedirs(f"{root}/agents/{aid}", exist_ok=True)
    json.dump(record, open(f"{root}/agents/{aid}/agent.json", "w"))
    return aid

def line(kind, minutes): return json.dumps({"id": uid(), "at": ago(minutes), "kind": kind})

fix = agent("Fix login", "codex")
docs = agent("Docs pass", "codex")
spec = agent("Spec 051", "claude", created=1500)

switch_fix = {"id": uid(), "at": ago(17), "agentID": fix, "reason": "allowanceSpent",
              "from": {"runtimeID": "claude", "model": "opus"},
              "to": {"entryID": codex, "runtimeID": "codex", "model": "gpt-5-codex", "mode": "agent"},
              "carried": [{"optionID": "model", "name": "Model", "from": "opus", "to": "gpt-5-codex",
                           "source": {"level": {"_0": "Strongest"}}},
                          {"optionID": "mode", "name": "Mode", "from": "acceptEdits", "to": "agent",
                           "source": {"closestNoLooser": {}}}],
              "dropped": [{"alwaysAllow": {"count": 2}}],
              "billing": {"allowance": {"label": "ChatGPT plan"}}, "fromReturnsAt": ahead(280)}
switch_docs = dict(switch_fix, id=uid(), at=ago(6), agentID=docs, reason="allowanceSpent",
                   **{"from": {"runtimeID": "copilot"}, "fromReturnsAt": None})
switch_docs.pop("fromReturnsAt")
switch_spec = dict(switch_fix, id=uid(), at=ago(1400), agentID=spec, reason="byHand",
                   **{"from": {"runtimeID": "codex"}, "to": {"entryID": claude, "runtimeID": "claude", "model": "opus"}},
                   carried=[{"optionID": "model", "name": "Model", "to": "opus", "source": {"person": {}}}],
                   dropped=[], billing={"allowance": {"label": "Max plan"}})
switch_spec.pop("fromReturnsAt")
with open(f"{root}/switches.jsonl", "w") as f:
    for record in (switch_spec, switch_fix, switch_docs):
        f.write(json.dumps(record) + "\n")

handoff = ("# Conversation so far\n\nCarried over from Claude, whose allowance ran out. The files are "
           "already as described.\n\n**You:** Carry on with the redirect fix, then run the tests.\n\n"
           "**Claude:** I'll change the callback to keep the `next` parameter, then run the suite.\n\n"
           "- Edited `LoginCallback.swift` +6 −2\n")
with open(f"{root}/agents/{fix}/transcript.jsonl", "w") as f:
    f.write(line({"userMessage": {"_0": "Carry on with the redirect fix, then run the tests."}}, 20) + "\n")
    f.write(line({"agentMessage": {"text": "I'll change the callback to keep the `next` parameter, then run the suite."}}, 19) + "\n")
    # Inside an entry the record is written with a plain encoder, as the daemon does
    # (`JSONValue.encoding`): dates are seconds since 2001, not ISO text.
    def reference(text):
        t = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc)
        return (t - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()
    inner = dict(switch_fix, at=reference(switch_fix["at"]), fromReturnsAt=reference(switch_fix["fromReturnsAt"]))
    f.write(line({"poolSwitch": {"_0": inner}}, 17) + "\n")
    f.write(line({"handoff": {"markdown": handoff, "characters": len(handoff)}}, 17) + "\n")
    f.write(line({"agentMessage": {"text": "Picking up from where Claude left off: the callback edit is in place. Running the tests now."}}, 16) + "\n")
for aid, text in ((docs, "Tidy the how-to pages."), (spec, "Plan spec 051.")):
    with open(f"{root}/agents/{aid}/transcript.jsonl", "w") as f:
        f.write(line({"userMessage": {"_0": text}}, 30) + "\n")
        f.write(line({"agentMessage": {"text": "Done."}}, 29) + "\n")
print(f"FIX={fix} DOCS={docs} SPEC={spec}")
