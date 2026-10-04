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

## After (the warm pool, pool of 3)

Same script and prompt, scratch host built from this branch, 2026-10-03.

| Runtime | Cold | Warm from the pool | Warmed by opening | Warmed by typing |
|---|---|---|---|---|
| Claude | 32.37 s (33.05, 31.69, 31.40, 33.88) | **1.63 s** (1.59, 1.68, 1.67, 1.58) | 29.96 s with 6 s of lead; 18.18 s with 10 s; 12.02 s with 20 s; **1.87 s** with 30 s | 30.09 s with 2 s of lead |
| Codex | 3.99 s (10.06, 3.83, 3.84, 4.15) | **1.98 s** (1.73, 1.92, 2.03, 3.54) | 3.21 s with 6 s of lead (2.44, 3.97, 2.04, 6.78) | 3.02 s with 2 s of lead (2.41, 4.11, 2.16, 3.63) |

"Lead" is how long before the prompt the window said so (`agents/prewarm`). Cold is
unchanged, as it should be: the pool is not used.

**Claude.** A runtime in the pool answers in 1.6 s, against 32 s cold: twenty times
faster. Warming on intent saves about as many seconds as the person spends before
sending. After `session/load` the adapter goes on starting Claude Code for about 30 s in
the background, and a prompt sent before that is done waits for the rest. With 30 s of
warning, the reply is as fast as from the pool. Typing two seconds before sending saves
two seconds. So for Claude, opening a session is the signal that matters, and typing
mostly refreshes it.

**Codex.** A cold start is already short (4 s). The pool halves it, and either intent
takes off a second.

## Memory per warm runtime

Peak resident memory of a runtime's whole process tree under the daemon, during a turn:
the same processes a warm runtime keeps.

| Runtime | Processes | Peak |
|---|---|---|
| Claude (npm exec, claude-agent-acp, Claude Code, the app's MCP helper) | 4 | 387–491 MB |
| Codex (the toolset's codex-acp and its children, the MCP helper) | 6 | 291 MB |

**Should N become a memory budget?** Not yet. The two differ by under two times, so the
default of 3 holds 0.9–1.5 GB at most, for no more than 30 minutes, and never while the
person is away. A budget would come to three to five runtimes either way, and a count is
what the person can predict from Settings. Revisit it if a runtime arrives that is several
times heavier.
