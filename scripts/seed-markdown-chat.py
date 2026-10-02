#!/usr/bin/env python3
"""Rewrite one agent's transcript in a scratch root as a chat of long Markdown replies (#90).

  scripts/seed-markdown-chat.py ROOT AGENT_ID [TURNS]

TURNS defaults to 97. Each turn is a prompt and one reply of about 2 KB with what agents
write: a heading, paragraphs with inline marks, a list, a code fence and a table. This is
the chat opened to time the window's text (seed-long-transcript.py is the long record).
Refuses any root under ~/Library.
"""
import json, os, sys, uuid, datetime

root, agent = sys.argv[1], sys.argv[2]
turns = int(sys.argv[3]) if len(sys.argv) > 3 else 97
if os.path.realpath(root).startswith(os.path.expanduser("~/Library")):
    sys.exit("refusing to seed under ~/Library")
path = os.path.join(root, "agents", agent, "transcript.jsonl")
if not os.path.exists(os.path.dirname(path)):
    sys.exit(f"no agent at {os.path.dirname(path)}")

start = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
n = 0
def stamp():
    return (start + datetime.timedelta(seconds=n)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

def reply(t):
    return f"""## Step {t}: what changed

I read the **parser** and the `Store` once more, and the slow part is where the list is
redrawn: every pass of the body *folds the whole record again*, which costs nothing for a
short chat and a great deal for a long one. Turn {t} moves the fold to where entries land.

- `Store.append` keeps the folded turns, so a redraw reads them rather than making them.
- The row keeps its parsed blocks, keyed by the entry and its text.
- A streamed chunk re-parses only the message it belongs to, not the rest of the turn.
- Nothing else moves: the look, the selection and follow mode are what they were.

```swift
func fold(_ entries: [Entry]) -> [Turn] {{
    var turns: [Turn] = []
    for entry in entries where entry.isShown {{
        if entry.startsTurn {{ turns.append(Turn(ask: entry)) }}
        else {{ turns[turns.count - 1].items.append(entry) }}
    }}
    return turns
}}
```

| Case | Before | After |
|---|---:|---:|
| Short chat | 40 ms | 30 ms |
| Long chat | 350 ms | 80 ms |

1. Build it and open the long chat.
2. Scroll to the top and back, then stream a reply.
3. Select a paragraph across two lines and copy it.

> The numbers are from a Debug build, so a Release build will be quicker still; what
> matters is the shape, which is that the cost no longer grows with the chat.

That is turn {t}. The next one looks at the earlier page, which is fetched as the reader
reaches the top and must not move the line they are on.
"""

with open(path, "w") as out:
    def put(kind, **extra):
        global n
        out.write(json.dumps({"at": stamp(), "id": str(uuid.uuid4()).upper(), "kind": kind, **extra},
                             separators=(",", ":")) + "\n")
        n += 1
    for t in range(1, turns + 1):
        put({"userMessage": {"_0": f"Turn {t}: carry on, and tell me what you changed."}})
        put({"stateChanged": {"_0": "running"}})
        put({"agentMessage": {"messageID": f"msg_{t:04d}", "text": reply(t)}})
        put({"stateChanged": {"_0": "finished", "reason": "endTurn"}})
print(f"{n} entries in {turns} turns: {path}")
