#!/usr/bin/env python3
"""Assess runtimes unattended (#47), on a daemon's root: start, answer, follow, score.

  assess.py ROOT RUNTIME [RUNTIME …] --folder PROJECT [--minutes 20] [--json OUT]
  assess.py ROOT RUNTIME --folder PROJECT --follow AGENT    carry on one whose driver stopped

For each runtime, one at a time: `runtimes/assess` starts the assessing agent in PROJECT
(which must be one of the daemon's projects). Then this answers what a person would, for
that agent and the helpers it starts only — the form (a choice gets its first option, text
gets PHRASE), the runtime's own question (its first option), and every permission card
(allow once) — and follows it until it ends a turn that is not `blocked`. Then it prints the
daemon's own score (`runtimes/assessment`) and where the agent's report is.

A runtime the daemon refuses to start (out of the pool, not installed, not signed in) is
skipped with the daemon's reason. Exit status 0 when every assessed runtime passed.
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "run-app", "scripts"))
from rpc import Client  # noqa: E402

PHRASE = "plum lantern 47"


def answer_form(elicitation):
    """The content for a form: each choice its first option, each text PHRASE."""
    content = {}
    form = ((elicitation.get("mode") or {}).get("form") or {}).get("_0") or {}
    for prop in form.get("properties") or []:
        kind = prop.get("kind") or {}
        if "multiSelect" in kind:
            items = kind["multiSelect"].get("items") or []
            content[prop["name"]] = [items[0]["value"]] if items else []
        elif "string" in kind and (kind["string"].get("choices") or []):
            content[prop["name"]] = kind["string"]["choices"][0]["value"]
        elif "boolean" in kind:
            content[prop["name"]] = True
        elif "number" in kind or "integer" in kind:
            content[prop["name"]] = 1
        else:
            content[prop["name"]] = PHRASE
    return content


def ours(client, assessor):
    """The assessing agent and every agent it started."""
    ids = {assessor}
    for agent in client.call("agents/list", {"includeArchived": True}) or []:
        if agent.get("startedByAgent") == assessor:
            ids.add(agent["id"])
    return ids


def assess(client, runtime, folder, minutes):
    try:
        started = client.call("runtimes/assess", {"runtimeID": runtime, "folder": "file://" + folder}, timeout=180)
    except Exception as e:  # the daemon's refusal, in its words
        return {"runtime": runtime, "skipped": str(e)}
    agent = started["agentID"]
    print(f"{runtime}: assessing as {agent} on {started.get('model') or 'the default model'}", flush=True)
    return follow(client, runtime, agent, started.get("model"), started.get("reportPath"), minutes)


def follow(client, runtime, agent, model, report_path, minutes):
    """Answer for the assessing agent and its helpers until its last turn, then score it."""
    end = time.time() + minutes * 60
    answered = set()
    record = None
    while time.time() < end:
        time.sleep(3)
        mine = ours(client, agent)
        for pending in client.call("permissions/pending", {}) or []:
            if pending.get("agentID") in mine and pending["id"] not in answered:
                allow = next((o["optionID"] for o in pending["options"] if o["kind"] == "allow_once"),
                             pending["options"][0]["optionID"])
                client.call("permissions/answer", {"permissionID": pending["id"], "optionID": allow})
                answered.add(pending["id"])
                print(f"  allowed: {(pending.get('toolCall') or {}).get('title', '?')}", flush=True)
        for pending in client.call("elicitations/pending", {}) or []:
            if pending.get("agentID") in mine and pending["id"] not in answered:
                content = answer_form(pending)
                client.call("elicitations/answer", {"requestID": pending["id"], "action": "accept", "content": content})
                answered.add(pending["id"])
                print(f"  answered: {pending.get('message')!r} with {json.dumps(content)}", flush=True)
        record = next((a for a in client.call("agents/list", {"includeArchived": True}) or [] if a.get("id") == agent), None)
        report = (record or {}).get("report") or {}
        if record and record.get("state") in ("finished", "stopped", "archived") and report.get("outcome") != "blocked":
            break
    else:
        print(f"  {runtime}: not finished after {minutes} min; scoring what is there", flush=True)
    time.sleep(2)  # the daemon scores behind the ending
    score = client.call("runtimes/assessment", {"agentID": agent}, timeout=60)
    return {"runtime": runtime, "agent": agent, "model": model, "reportPath": report_path,
            "state": (record or {}).get("state"), "outcome": ((record or {}).get("report") or {}).get("outcome"),
            "score": score}


def table(score):
    lines = ["| Step | Result | From the app's record |", "| --- | --- | --- |"]
    for check in score["checks"]:
        lines.append(f"| `{check['id']}` | {check['verdict']} | {check['evidence']} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root")
    parser.add_argument("runtimes", nargs="+")
    parser.add_argument("--folder", required=True)
    parser.add_argument("--minutes", type=int, default=20)
    parser.add_argument("--json", help="write every result here too")
    parser.add_argument("--follow", metavar="AGENT",
                        help="carry on an assessment already started (its driver stopped): RUNTIME is its runtime")
    args = parser.parse_args()
    client = Client(args.root)
    results = []
    for runtime in args.runtimes:
        if args.follow:
            record = next(a for a in client.call("agents/list", {"includeArchived": True}) if a["id"] == args.follow)
            result = follow(client, runtime, args.follow, (record.get("startOptions") or {}).get("values", {}).get("model"),
                            None, args.minutes)
        else:
            result = assess(client, runtime, os.path.abspath(args.folder), args.minutes)
        results.append(result)
        if "skipped" in result:
            print(f"\n## {runtime}: skipped\n\n{result['skipped']}\n", flush=True)
            continue
        checks = result["score"]["checks"]
        passed = sum(c["verdict"] == "passed" for c in checks)
        print(f"\n## {runtime} ({result['model'] or 'default model'}): {passed} of {len(checks)} passed, "
              f"ended {result['outcome']}\n\nReport: {result['reportPath']}\n\n{table(result['score'])}\n", flush=True)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=2)
    failed = [r for r in results if "score" in r and any(c["verdict"] == "failed" for c in r["score"]["checks"])]
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
