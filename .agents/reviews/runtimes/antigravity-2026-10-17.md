# Antigravity 1.4.1, 2026-10-17 (weekly runtime check)

1.2.1 → 1.4.1, on main de6857a49d, run 2026-10-17-223754, by `scripts/nightly-runtimes.py` (#39, #1284).

| Step | Result |
| --- | --- |
| update | passed |
| build | passed |
| tests | passed |
| install | passed |
| handshake | passed |
| tools | passed |
| turn | **failed** (default model) |

## Assessment (#47)

Not assessed: it failed at turn.

```
agent 1279ABC7-7D17-4BA4-B0DF-2B57F215A911 on the default model: stopped, and the reply had no OK in it
{"id": "1279ABC7-7D17-4BA4-B0DF-2B57F215A911", "runtimeID": "antigravity", "cwd": "file:///tmp/run-n39-223754/work", "title": "Reply with the single word OK and nothing else. Do not use a\u2026", "state": "stopped", "startOptions": {"values": {}, "extraArguments": []}, "advertisedOptions": [], "availableCommands": [], "createdAt": 813994887.362929, "lastActivityAt": 813994890.478708, "isUnread": false, "endedReason": "processDied", "queuedPrompts": [{"id": "3A443BD6-200C-4D48-A123-7E9A18F431D9", "text": "Reply with the single word OK and nothing else. Do not use any tools.", "attachments": [], "queuedAt": 813994887.362929, "from": "person"}], "madeInRoot": "DB9E261B-3C47-44D9-BF2D-EBFAA41591E3"}
replied:
```
