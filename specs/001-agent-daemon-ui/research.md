# Research: how claude, grok and copilot actually speak ACP

**Date**: 2026-09-18
**Feature**: [spec.md](./spec.md)
**Method**: every claim below was produced by sending a real ACP `initialize` and `session/new`
down stdio to the CLI installed on this Mac and reading the reply. Nothing here is from memory.

## Reproducing it

```sh
probe() {                       # usage: probe copilot --acp
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true}}}'
    sleep 3
    echo '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"'"$PWD"'","mcpServers":[]}}'
    sleep 12
  } | perl -e 'alarm 45; exec @ARGV' "$@"
}
```

## What each one is

| Runtime | How it starts | Native or adapter | Version seen |
|---|---|---|---|
| Copilot | `copilot --acp` | Native. `--acp` is "Start as Agent Client Protocol server" | Copilot 1.0.86 |
| Grok | `grok agent stdio` | Native. Its own streaming format is described in its help as "one ACP session update per line, the agent's native format" | 1.0.34 |
| Claude | `npx -y @agentclientprotocol/claude-agent-acp` | **Adapter.** `claude --help` has no ACP anywhere. The adapter is a separate npm package published by the ACP project, built on the Claude Agent SDK | package 0.79.0, ran 0.78.0 |

The Claude one is the important difference: there is no flag on the `claude` binary to find. Finding
"is Claude available" means finding Node and the adapter package, not finding a CLI and a flag. A
runtime is therefore a recipe for launching something, not a binary with a switch.

## The handshake

All three answered `initialize` with `protocolVersion: 1`.

| | Copilot | Grok | Claude adapter |
|---|---|---|---|
| `loadSession` | yes | yes | yes |
| `sessionCapabilities` | close, list | list, resume, close | additionalDirectories, close, delete, fork, list, resume, subagents |
| `authMethods` | `copilot-login`, with a `_meta.terminal-auth` block naming the exact command to run | `cached_token`, `grok.com` | none (already authenticated) |
| prompt content | image, embedded context | embedded context | image, embedded context |

Two things follow. Sessions can be closed on all three, so an agent can be ended without killing a
process. And a runtime can be installed but not signed in: Copilot says so in `authMethods` and even
hands over the command that fixes it, so "found but not usable yet" is a state the app can show
honestly instead of failing at start.

## Options: one surface covers all three

Every one of them returns `configOptions` from `session/new`, in the same shape:

```json
{ "id": "model", "name": "Model", "category": "model", "type": "select",
  "currentValue": "grok-4.6", "options": [ { "value": "grok-4.6", "name": "Grok 4.6" } ] }
```

What each advertised, on this Mac, on this date:

| Runtime | configOptions (id / category / choices) |
|---|---|
| Copilot | `mode`/mode (3), `model`/model (18), `reasoning_effort`/thought_level (6), `allow_all`/permissions (2) |
| Grok | `model`/model (2), `reasoning_effort`/thought_level (4) |
| Claude adapter | `mode`/mode (5), `model`/model (5), `effort`/thought_level (6), `fast`/model_config (2) |

The older dedicated fields are inconsistent and cannot be relied on: Copilot sends `models` and
`modes`, Grok sends `models` and no `modes`, the Claude adapter sends `modes` and no `models` even
though it does offer a model choice under `configOptions`. The protocol documentation also says the
dedicated session mode methods will be removed in a future version.

**So the start form is built from `configOptions` and nothing else.** One code path, driven by
`type` and ordered by `category`, covers all three, needs no per-runtime knowledge, and picks up a
new model or a new mode on the day the runtime ships it. Options change during a session too, and
arrive as a `config_option_update` in `session/update`.

## The turn, and why "exited cleanly" does not exist

An ACP agent is a long-lived server, not a command that runs and exits. The client sends
`session/prompt`; the agent streams `session/update` notifications; the turn ends when the agent
answers the original request with a **stop reason**, and the process then sits waiting for the next
prompt. The stop reasons are exactly: `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`,
`cancelled`.

The process outliving the work has consequences for the spec:

- **Running** is "a turn is in flight", not "the process is alive".
- **Finished** is a turn ending with `end_turn`. The agent has said what it has to say and is idle.
  Nothing exits. A follow-up starts another turn in the same session.
- **Stopped** is the daemon ending it: `session/cancel`, then `session/close`, then the process goes.
  Or the process died on its own, which is a crash rather than a finish.
- Auto-archiving on "the runtime exited cleanly" cannot be implemented, because that never happens.
  It has to key off `end_turn`. See the open question in spec.md (FR-012).

## Permission requests block, and a follow-up message cannot answer them

When an agent wants to do something its mode does not already allow, it sends
`session/request_permission`: a request, not a notification. The agent stops there until the client
answers with one of the options it offered. A typed message is not an answer to it, so the
assumption that a waiting agent can be unblocked with a follow-up was wrong and is corrected in the
spec.

This is also the strongest argument for the daemon: the request can arrive while no window is open,
and something has to hold it, keep the agent alive, and hand it to the window when it opens.

Every one of the three offers a way to need fewer of these: Copilot's `allow_all` option and
Autopilot mode, Claude's `acceptEdits` and `auto` modes, Grok's `--always-approve`. All of them
arrive as ordinary `configOptions`, so the start form gets them for free.

## Left alone for now

- `availableCommands` (Copilot returned 30-odd slash commands from `session/new`). A later feature.
- Vendor `_meta` blocks: `x.ai/hooks`, `x.ai/capabilities`, Claude's `jetbrains`, `steering` and
  `goal`. Reading any of them is how one code path becomes three.
- `fs/` and `terminal` client methods, which let an agent ask the client to read and write files
  rather than doing it itself. We claimed both in the probe. Whether the app serves them or the
  agent uses its own tools is a plan decision, not a spec one.

## Stopped is not the end: every one of them can be picked up again

Tested by running a real turn, killing the process with no warning, starting the runtime again and
asking for the session back. All three gave it back, with the reply from before the kill.

| | Copilot | Grok | Claude adapter |
|---|---|---|---|
| Session survives the process being killed | yes | yes | yes |
| `session/list` finds it afterwards | yes | yes | yes |
| `session/load` (replays the history) | yes | yes | yes |
| `session/resume` (no replay) | no, `-32601 Method not found` | yes | yes |
| The runtime's own title for it | "Reply with exactly: PINEAPPLE..." | "Exact PINEAPPLE-only reply request" | "Pineapple" |

`session/list` is scoped by `cwd` and returns a `sessionId`, the folder, a title the runtime wrote
itself, and when it was last touched. `session/load` takes `sessionId`, `cwd` and `mcpServers` and
replays the whole conversation as `session/update` notifications before returning. `session/resume`
takes the same arguments and skips the replay, for a client that already has the history.

So picking a stopped agent back up is: start the runtime again, hand it the same session id and the
same folder, and carry on prompting. We keep our own history anyway, so `session/resume` is the
right call where it exists and `session/load` is the fallback where it does not. One code path, one
capability check.

Two consequences worth stating plainly:

- **Stopped does not have to be terminal.** An agent the user stopped, or one that died when the Mac
  restarted, can be continued rather than only read.
- **A finished agent does not need its process kept alive to be followed up.** The daemon can let an
  idle agent's process go and resume the session when the user types again. That makes the daemon's
  own exit rule cheap to honour, and it takes the churn out of the FR-012 question below: nothing is
  lost by putting a finished agent away, because it can always be picked up.

The runtimes' titles are worth taking too. Each one names its own session, which is a better row
label than the first line of the instruction.

## The session id belongs to the runtime, not to us

Starting every agent with a UUID of our own and resuming that UUID does not work. `session/new`
takes `cwd`, `mcpServers` and optionally `additionalDirectories`, and nothing else: there is no field
for a client-supplied id in the protocol at all. The agent mints the id and returns it.

Tested anyway, by sending a `sessionId` in the `session/new` params:

| Runtime | Asked for | Got back |
|---|---|---|
| Copilot | `034290a9-…` | a different id. Ignored, no error |
| Grok | `034290a9-…` | a different id, and not a v4 UUID at all |
| Claude adapter | `034290a9-…` | a different id. Ignored, no error |

Silently ignored by all three, so there is no version of this that works by accident either.

What we do instead gets the same thing: **the agent has our id, and the runtime's session id is
recorded against it.** Ours is the one the app shows, the one the user's history is filed under, and
the one that never changes. The runtime's is a note we keep so we can ask for the session back.

That indirection is worth having on its own. One agent can hold several runtime sessions over its
life: when a runtime has lost a session, or has been uninstalled and replaced, picking the agent up
starts a fresh runtime session and files the new id against the same agent, with the history we kept
still intact. The user sees one agent throughout. Without the indirection, losing a runtime session
would mean losing the agent.

## The open question this research created

FR-012 said an agent archives itself when it "reported its work finished and its runtime exited
cleanly". Half of that cannot happen: the runtime does not exit. The question that replaces it is
when a finished agent, sitting idle with a live process and a session that could take another
prompt, should take itself off the list.

| Option | Rule | What it costs |
|---|---|---|
| A | Archive as soon as a turn ends with `end_turn`. A follow-up brings it back to running | Truest to "it said it was done". Churns badly for back-and-forth work: every reply archives the agent |
| B | Archive when a turn ends with `end_turn` and the user has not followed up for a set quiet period | Matches how the list actually gets untidy. Needs a number, and a number is a guess until you have used it |
| C | Finished is a state of its own and nothing auto-archives. The user archives when they are done | No guessing, no churn, and the finished agents are visibly separate from the running ones. The list still needs tidying by hand |

Resuming changes what is at stake here. Archiving loses nothing now, because an archived agent can
be picked up and carried on. The question is only how tidy the list is by default, not whether work
is thrown away.

Recommendation: **C for this feature.** Finished already separates the done from the busy, which is
most of the value, and the rule that decides when done means gone is worth writing after watching
real agents finish rather than before.
