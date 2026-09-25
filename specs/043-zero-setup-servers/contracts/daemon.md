# Contract: daemon changes

Codes are the next free ones on main when this is built (after 036's -32035 and whatever 042
takes); names are fixed here.

## `credentials/offer` (window → server daemon, on every connect)

```json
{ "runtimes": ["claude"], "ownSignInOnly": false }
```

Names only, never a secret. Tells the daemon which runtimes the window *could* lend for and
whether this server takes lends at all. Replaces any earlier offer on the same connection. A
Mac daemon (no `--serve`) accepts and ignores it.

## `credentials/lend` (window → server daemon, only after `credentialWanted`)

```json
{ "runtime": "claude", "kind": "oauthToken", "secret": "sk-ant-oat…" }
```

- Refused with `notAServer` unless the daemon runs with `--serve` (D5).
- Refused with `notOffered` if this connection's offer had `ownSignInOnly` or did not list the
  runtime.
- Stored in memory for this connection only; dropped on close. Result: `{}`.
- The request's params are never logged; `DaemonServer`'s request log prints the method name only
  for this method.

## Failure `credentialWanted`

Returned by any call that would start a Claude process on a server daemon when:
the connection offered `claude` and is not `ownSignInOnly`, and has lent nothing yet; **or** the
server has no own sign-in and nothing was lent.

```json
{ "code": -320xx, "message": "Claude on this server needs a token.",
  "data": { "runtime": "claude", "offered": true } }
```

No process was started and no agent state changed, so a retry with the same `sendID` after
`credentials/lend` is the same request. `offered: false` means the window has no token: it shows
the ask (ui.md § 3).

Which calls: `agents/start`, `agents/prompt`, `agents/answer*` and `agents/startHelper` when they
must launch; `agents/resume`. Workflows firing with no connection: the agent ends `needs_answer`
with the same message and `data`.

## Failure `credentialRefused`

Raised as an agent-ending event (not a call error) for a session started with a lent token when the
runtime reports an authentication failure (research R7).

```json
{ "reason": "credentialRefused", "runtime": "claude",
  "message": "Claude refused the token in Settings. Replace it." }
```

The agent's status is Stopped with this reason; other agents are untouched.

## Launch environment

`ProcessSessionLauncher.launch` gains `extraEnvironment: [String: String]`. For a lent credential
it holds exactly one of `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`, and when set, the other
is removed from the inherited environment so the Settings token wins (D1). The dictionary is
never logged, and `ACPSession` does not echo its environment.

## Discovery order on a server (`--serve` only)

1. `~/.agents-server/tools/claude/current/` with `ok` → `node <entry>` (research R4).
2. 037's `npx` on the login PATH.
3. `runtimeNotFound`, now with `data.installable: true`, so the window offers to install (FR-002's
   "when the person first chooses that runtime").

## `daemon/status` (037)

Gains `tools: { "claude": { "toolset": "<id>|null", "busy": <Claude agents mid-turn> } }`, used by
the window to decide when to swap (FR-007).
