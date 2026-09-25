# Contract: Daemon API for Leases

These are additions to `DaemonAPI` (AgentsKitCore). JSON-RPC over `daemon.sock`, as today.

## Methods

| Method | Request | Result | Called by |
|---|---|---|---|
| `leases/lease` | `LeaseRequest { token, name, minutes?, wait? }` | `{ note }` | helper (`lease_resource`). May stay open up to `LeaseLimits.waitLimit`. |
| `leases/release` | `LeaseNameRequest { token, name }` | `{ note }` | helper (`release_resource`) |
| `leases/list` | `LeaseTokenRequest { token }` | `{ note }` | helper (`list_resources`) |
| `leases/snapshot` | none | `LeaseSnapshot` | Mac app and phone on connect |
| `leases/end` | `PersonEndRequest { name }` | `LeaseSnapshot` | Mac Resources page. Ends whoever holds it. |
| `leases/removeWaiter` | `PersonRemoveRequest { name, agentID }` | `LeaseSnapshot` | Mac Resources page |

The three agent methods resolve the caller from `token` exactly as `agents/startHelper` does,
with the same "conversation not open any more" refusal. The two person methods take no token,
because the person is whoever holds the socket, as with every other window method.

## Notification

`leases/changed`, whose params are the whole `LeaseSnapshot`. It is sent after every change to
the book, and also once a minute while any lease is held, so the "minutes left" and "ending
soon" shown on the page stay correct without each client running its own timer against its own
clock. Clients replace, never merge.

`AgentsModel.Update.leasesChanged(LeaseSnapshot)` is decoded in the shared switch, so the Mac and
the phone handle it the same way.

## Failures

`DaemonAPI.Failure.leaseRefused` (next free code) covers: an end on a resource nobody holds, an
empty name, and a remove for an agent not in that line.
The existing `noSuchAgent` covers a stale token.

## Transcript notes (FR-016)

These are written with `record(.runtimeNote(...), for: agentID)`:

| Event | Note |
|---|---|
| granted | `Leased {display} until {HH:mm}.` |
| extended | `Extended the lease on {display} to {HH:mm}.` |
| released | `Released {display}.` |
| expired | `The lease on {display} ran out at {HH:mm}.` |
| endedByPerson | `You ended this agent's lease on {display}.` |
| holderStopped / holderArchived | `Let go of {display} when it was stopped.` / `…archived.` |
| couldNotStart | `{display} came to this agent but it could not be started ({reason}), so it was passed on.` |
