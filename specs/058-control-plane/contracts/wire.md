# Contract: the wire

One JSON object per line, UTF-8, `\n`-terminated, on every hop (TLS-PSK at home, sealed frames
through the relay, a Unix socket on loopback). `LineSplitter`'s 64 MB cap applies.

## Client ⇄ control plane

```jsonc
// to a host: m is a JSON-RPC 2.0 message, byte-for-byte what a daemon.sock client sends today
{"h":"mac","m":{"jsonrpc":"2.0","id":7,"method":"agents/list","params":{}}}
// to the control plane itself
{"m":{"jsonrpc":"2.0","id":8,"method":"hosts/list"}}
// from a host: reply or notification, with the host it came from
{"h":"k3v9x0qa","m":{"jsonrpc":"2.0","method":"agent/updated","params":{…}}}
// from the control plane itself
{"m":{"jsonrpc":"2.0","method":"control/hostChanged","params":{"host":"k3v9x0qa","state":"online"}}}
```

**Legacy line** (no wrapper, i.e. the object has `jsonrpc`): treated as `{"h":<homeHost>,"m":line}`
when the method is not one the control plane answers, and replies go back unwrapped. This is
how an unchanged Remote keeps working (R7). A client that has sent one wrapped line is wrapped
from then on.

Rules:
1. The control plane reads `m.method` (and nothing else in `m`) to check the grant. A refused
   request is answered by the control plane with `Failure.notPermitted` and `h` set.
2. A request for a host that is not online is answered by the control plane with
   `Failure.hostOffline` (new, -32070) at once.
3. Request ids are the client's; the control plane never rewrites them. Ids need only be unique
   per (client connection, host), as they are per `DaemonClient` today.
4. Replies and notifications from a host carry `h`. The client's `ControlLink` strips it and
   hands `m` to that host's `HostLink`.

## Control plane ⇄ host (the uplink)

```jsonc
{"c":3,"open":{"grant":"operator","client":"6f1c…"}}           // control → host
{"c":4,"open":{"grant":"device","client":"a2e0…","device":"a2e0…"}}
{"c":3,"m":{…JSON-RPC…}}                                        // both ways
{"c":3,"close":true}                                            // either way
{"c":0,"m":{…}}                                                 // channel 0: the uplink itself
```

- Channel numbers are chosen by the control plane, never reused within an uplink's life.
- On the host, `open` makes a virtual `DaemonServer` connection: role `control` for
  `operator`, `device` bound to `device` for `device`. It is never `agent`, `pairing` or
  `stranger`, and nothing but `open` can set a role.
- The host checks each request against the channel's role (defence in depth, FR-007).
- Channel 0 carries the host's own conversation with the control plane: `hosts/announce` on
  enrolment, `host/hello {version, platform, machineID}` on every connect, `attention/need`
  (unsealed needs, R6), and `control/ping`.
- Losing the uplink closes every channel; the host keeps running (FR-011) and redials with
  backoff 1 s → 30 s, plus at once on network change.

## ssh-reached hosts (FR-012)

The control plane holds today's `ssh -M` master with the `-L` forward to the host's `daemon.sock`.
Each channel is a separate socket connection over the forward, bound with
`connection/bindDevice` for `device` grants, exactly as the bridge binds devices today. Channel
0 is a `control` connection used for `mailbox/carry` so needs still reach the control plane.
