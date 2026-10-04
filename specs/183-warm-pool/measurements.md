# #183 Warm pool: measurements

Time to first token, from `agents/prompt` to the first thing the runtime streams (text, a
thought or a tool call), measured with `scripts/measure-ttft.py` on a scratch `run-app`
host. The prompt asks the agent to call `finish_turn` and nothing else.

## Before (e6673490, every runtime let go at turn end)

Four follow-up prompts each, to a session whose last turn had ended (cold).

| Runtime | Cold, median | Runs |
|---|---|---|
| Claude | 31.15 s | 31.75, 31.33, 30.97, 29.96 |
| Codex | 3.98 s | 5.34, 3.63, 2.83, 4.33 |

Where Claude's time goes, from its transcript: about 3 s from "Starting Claude…" to
"Picked the conversation back up" (process, handshake, `session/load`), then about 28 s
from `session/prompt` to the first event. The adapter starts Claude Code itself on the
first prompt of a session it has just loaded, so most of a cold start falls after the
prompt, not before it.
