# Contract: two links, and how one is chosen

Covers FR-004, FR-004a, FR-004b, FR-004c and the two halves of SC-006.

The remote speaks one protocol — the daemon's JSON-RPC line protocol, unchanged — over two links.
Everything above `LineTransport` is identical on both: `JSONRPCConnection`, `DaemonClient`,
`AgentsModel` and every screen. The link is a routing decision and nothing else knows it was made.

## The two

| | **Direct** | **Relayed** |
|---|---|---|
| When | Device and Mac on the same local network | Any other time |
| Carried by | `NetworkLink` — Bonjour `_agents._tcp`, `NWListener` on the Mac, `NWBrowser` on the device, `includePeerToPeer` so an iPad finds it with no infrastructure at all | `MailboxTransport` over the CloudKit private database, per `mailbox.md` |
| Mac side | `agents-bridge`, a client of `agentsd` over the Unix socket | The same process, same socket |
| Round trip | Milliseconds | Seconds |
| SC-006 budget | 1 second | 3 seconds |
| Wakes a backgrounded phone | No | Yes, by push |
| Costs the user | Nothing | Their own iCloud quota |

Both are `LineTransport` implementations beside `FDTransport` and `PairedTransport`. That is the
whole reason two links cost less than twice one.

## Choosing

The device chooses. The Mac offers both and cares which it got only for the staleness clock.

1. On open, start the browser and the mailbox fetch **together**. Do not try direct first and wait
   for it to fail: a Bonjour browse on a network with no Mac on it does not fail, it stays quiet,
   and a user on a train would watch a spinner for as long as we were willing to wait.
2. Take the first link that yields a usable connection. In practice that is the direct one when it
   is there, because it resolves in well under the mailbox's first round trip.
3. Having taken direct, stop the mailbox fetch but **leave the subscription in place**, so a
   notification still arrives if the app is backgrounded and the phone leaves the network.
4. Having taken relayed, keep browsing at a low rate. Walking back into the house should move the
   session to the direct link within a few seconds, unasked.

### Handover

A link can drop under a session that is in flight — the user walks out of the house mid-answer,
which is the ordinary case, not the exotic one.

- An in-flight request is **not** retried across a handover automatically. It is reported to the
  caller as undelivered and the remote re-sends it on the new link, so that FR-036 holds: delivered
  once or not at all, never twice. The answer path is idempotent at the daemon anyway (first answer
  wins, `alreadyAnswered` to the rest), but the remote must not rely on that to be correct.
- State is re-fetched, not merged. On a new link the remote asks for the current picture rather than
  assuming what it holds is still true. It is one round trip and it removes a whole class of bug.
- The sequence counter in `Envelope` is **per link**, because the two links have no common ordering.
  A gap on one says nothing about the other.

## What the user sees

One line, where the staleness banner already is (`ui.md`, `StaleBanner.swift`):

- Direct: nothing. The fast case is the quiet case; a badge saying "connected" on every screen is
  noise.
- Relayed: "Away from your Mac's network — updates take a few seconds." Said once, calmly, as
  information. This is FR-004b, and it exists so that the speed difference reads as geography
  rather than as a fault.
- Neither: the existing out-of-touch line, with when the Mac was last heard from.

The user is never offered a choice of link and never shown a setting for one.

## Security, on both equally

FR-004c is the rule that keeps this from becoming two designs:

- **The same pairing.** A device is approved once, at the Mac, and that approval governs both links.
  There is no "trusted on the home network" state.
- **The same sealing.** Every payload is an `Envelope` sealed to the target device's public key,
  over either link. The direct link does not send cleartext because it is on the user's own Wi-Fi.
- **The same revocation.** Revoking a device stops the direct link too: the bridge drops any
  connection whose device is no longer approved, checked at accept and re-checked when the device
  list changes, so FR-010's "within seconds even for a device connected at the time" holds on the
  link where a connection is actually held open.
- **Unpaired means refused, on both.** The Bonjour service being discoverable is not an invitation.
  Discovery is public; the connection is not.

> **Today this is unmet on the direct link.** `Bridge/Sources/main.swift` accepts any connection
> and carries cleartext, by its own admission. It is usable for development and must not ship in
> that state. See `research.md` §11 and tasks T044a to T044e.
