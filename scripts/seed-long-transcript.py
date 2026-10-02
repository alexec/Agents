#!/usr/bin/env python3
"""Rewrite one agent's transcript in a scratch root as a long, realistic conversation.

  scripts/seed-long-transcript.py ROOT AGENT_ID [ENTRIES]

ENTRIES defaults to 100000. Turns are shaped like real ones (a prompt, streamed message
chunks, thoughts, tool calls with an in-progress and a completed update, a report, the
end of the turn), with synthetic words. Refuses any root under ~/Library (073).
"""
import json, os, sys, uuid, datetime

root, agent = sys.argv[1], sys.argv[2]
want = int(sys.argv[3]) if len(sys.argv) > 3 else 100_000
if os.path.realpath(root).startswith(os.path.expanduser("~/Library")):
    sys.exit("refusing to seed under ~/Library")
path = os.path.join(root, "agents", agent, "transcript.jsonl")
if not os.path.exists(os.path.dirname(path)):
    sys.exit(f"no agent at {os.path.dirname(path)}")

start = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
n = 0
def stamp():
    return (start + datetime.timedelta(milliseconds=250 * n)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
words = ("the build reads every file once and keeps the parsed tree so a second pass "
         "costs nothing while the list redraws only what changed ").split()
def text(k):
    return " ".join(words[(i * 7 + k) % len(words)] for i in range(12)) + " "

with open(path, "w") as out:
    def put(kind, **extra):
        global n
        entry = {"at": stamp(), "id": str(uuid.uuid4()).upper(), "kind": kind, **extra}
        out.write(json.dumps(entry, separators=(",", ":")) + "\n")
        n += 1
    turn = 0
    while n < want:
        turn += 1
        put({"userMessage": {"_0": f"Turn {turn}: carry on with the next part, and tell me what you changed."}})
        put({"stateChanged": {"_0": "running"}})
        for step in range(30):
            if n >= want: break
            mid = f"msg_{turn:05d}_{step:02d}"
            for k in range(3):
                put({"agentThought": {"messageID": mid + "t", "text": text(k)}})
            call = f"toolu_{turn:05d}{step:02d}"
            put({"toolCall": {"_0": {"content": [], "kind": "execute", "locations": [], "name": "Bash",
                                     "raw": {"kind": "execute", "name": "Bash", "sessionUpdate": "tool_call",
                                             "status": "pending", "title": "Terminal", "toolCallId": call},
                                     "rawInput": {}, "status": "pending", "title": "Terminal", "toolCallID": call}}})
            put({"toolCallUpdate": {"_0": {"content": [], "locations": [],
                                           "raw": {"sessionUpdate": "tool_call_update", "status": "in_progress", "toolCallId": call},
                                           "status": "in_progress", "title": "Tool call", "toolCallID": call}}})
            output = "\n".join(text(i) for i in range(20))
            put({"toolCallUpdate": {"_0": {"content": [{"content": {"text": "```console\n" + output + "\n```", "type": "text"}, "type": "content"}],
                                           "kind": "execute", "locations": [],
                                           "raw": {"sessionUpdate": "tool_call_update", "status": "completed", "toolCallId": call},
                                           "rawInput": {"command": f"swift build --target Step{step}"},
                                           "rawOutput": output, "status": "completed",
                                           "title": f"swift build --target Step{step}", "toolCallID": call}}})
            for k in range(4):
                put({"agentMessage": {"messageID": mid, "text": text(k + 3)}})
        put({"workReported": {"_0": {"at": 812346643.0 + turn, "message": f"Turn {turn} done: thirty steps, all green.", "outcome": "done"}}})
        put({"usageRecorded": {"_0": {"cachedReadTokens": 1000, "cachedWriteTokens": 100, "inputTokens": 10, "outputTokens": 500, "totalTokens": 1610}}})
        put({"stateChanged": {"_0": "finished", "reason": "endTurn"}})
print(f"{n} entries in {turn} turns, {os.path.getsize(path) // 1_000_000} MB: {path}")
