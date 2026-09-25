# Contract: The Lease Tools

These three tools are served by `AppService` on the `agents` MCP server that every agent already
has. They're offered to every agent, including agents that another agent started (028) and
agents in worktrees (030). The helper relays each call to the daemon, and whatever the daemon
returns becomes the tool result text. A daemon failure becomes an `isError` result carrying the
same plain sentence.

Every reply begins with any pending notices for the caller (data-model `LeaseNotice`), one line
each, then a blank line. For example:

> You no longer hold Screen, mouse and keyboard: the person ended your lease at 14:02.

Times are local wall-clock `HH:mm`. Durations are whole minutes.

## `lease_resource`

**Description (as the agent reads it)**:
Take a turn with something on this Mac that only one agent should use at a time: a simulator, a
browser, the screen (mouse, keyboard, front window), or anything you name, such as a port. Lease
it before you use it, and release it as soon as you are done. If you already hold it, this
extends your lease. If someone else holds it, this waits for up to 45 seconds. If it is still not
yours after that, you keep your place in line. You can call this again to go on waiting, or end
your turn, and you will be started again when it is yours. Take several resources in the same
order every time. Use `list_resources` to see the names.

**Input**:

| Name | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | A name from `list_resources`, a simulator's UDID, a browser's name, or any name of your own. Case and surrounding spaces don't matter. |
| `minutes` | integer | no | How long. Default 30, at most 240. |
| `wait` | boolean | no | Default `true`. With `false`, you are told at once whether you got it, and you don't join the line. |

**Replies**:

| Case | Text |
|---|---|
| Granted | `You hold {display} until {HH:mm} ({n} minutes). Release it with release_resource when you are done.` |
| Granted after waiting | `{display} is yours now, until {HH:mm} ({n} minutes). You waited {s} seconds.` |
| Extended | `You still hold {display}, now until {HH:mm}.` |
| Capped | Adds `That is the longest a lease can run; extend it again before then if you need more.` |
| Still in line (limit reached) | `{display} is held by {holder} until {HH:mm}. You are {ordinal} in line and keep your place. Call lease_resource again to go on waiting, or end your turn — you will be started again when it is yours.` |
| Refused (wait false) | `{display} is held by {holder} until {HH:mm}. You are not in line.` |
| Stopped while waiting | `You were stopped, so you left the line for {display}.` (error) |
| Empty name | `Nothing was leased: say which resource.` (error) |
| No such conversation | `That conversation is not open any more, so nothing was leased.` (error) |

`{holder}` is the holding agent's title, as `“{title}”`.

## `release_resource`

**Description**: Give back a lease you hold, or leave the line for a resource you are waiting
for. Do this as soon as you are done with it, so the next agent can have it.

**Input**: `name` (string, required).

**Replies**:

| Case | Text |
|---|---|
| Released, nobody waiting | `Released {display}.` |
| Released, passed on | `Released {display}. It has gone to {holder}.` |
| Left the line | `You left the line for {display}.` |
| Neither | `You neither hold nor are waiting for {display}; nothing changed.` (not an error) |

## `list_resources`

**Description**: List what can be leased on this Mac and who holds what, with your own leases and
waits first.

**Input**: none.

**Reply**:

```text
Yours:
- Holding iPhone 17 Pro · iOS 26.0 (simulator:8a1f…) until 14:30.
- Waiting for Screen, mouse and keyboard (screen): held by “Fix login” until 14:12, you are 2nd.

On this Mac:
- screen — Screen, mouse and keyboard: held by “Fix login” until 14:12; 2 waiting.
- simulator:8a1f… — iPhone 17 Pro · iOS 26.0: held by you until 14:30.
- simulator:c03e… — iPad Pro 13-inch · iOS 26.0: free.
- browser:com.apple.safari — Safari: free.
- port 8080 (named by an agent): held by “API server” until 15:00.
```

`Yours:` is left out when the caller holds and waits for nothing.

## Wake prompt (sent by the app, not a tool)

This is queued on the agent `from: .app` when a lease reaches it after its call has closed
(research R4):

> {display} is yours now. You hold it until {HH:mm} ({n} minutes). You asked for it at {HH:mm}
> and were waiting in line. Carry on with what you needed it for, and release it with
> release_resource when you are done.

## Briefing paragraph (FR-015)

> Some things on this Mac can only be used by one agent at a time: the simulators, the browsers,
> and the screen (mouse, keyboard and front window). Before you use one, lease it with
> lease_resource. Release it with release_resource the moment you are done. Keep leases short and
> extend them rather than asking for hours. If you need more than one, take them in the same
> order every time. If you are told you are in line, you may end your turn: you will be started
> again when it is yours.
