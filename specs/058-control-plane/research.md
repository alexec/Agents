# Research: A Control Plane, and the Mac Window as One More Remote

**Feature**: 058-control-plane · **Date**: 2026-09-26 · **Spec**: [spec.md](spec.md)

Each section records a decision, why, and what was rejected. File references are to the tree at
`ce575160`.

## What is there today (the facts the decisions rest on)

- **The window starts the daemon.** `SocketLink.start()` (`AgentsKit/Client/SocketLink.swift:27`)
  `posix_spawn`s `Contents/Helpers/agentsd` with the window's whole environment plus
  `AGENTS_ROOT`. `DaemonClient.connect` tries `open()`, then `start()`, then polls for 8 s.
  The daemon exits when idle unless `--serve`. No launchd, SMAppService or LaunchAgent is used
  anywhere; 005 and 021 rejected them.
- **The window joins the hosts** (037 R7). `AppModel.client(for: HostID)` returns the Mac's
  `DaemonClient` or `HostSet`'s per-server one. `ServerConnection` runs `ssh -M -N` with
  `-L <root>/hosts/<id>.sock:~/.agents-server/root/daemon.sock` and starts
  `agentsd --serve --detach` over ssh. `ServerInstaller`/`ToolsetInstaller` stream the Linux
  binary and a pinned toolset over ssh.
- **No call carries a host.** None of the ~133 methods or 33 notifications names a host. Each
  daemon is single-host and does not know its own name. The window stamps `host` on arrival
  (`AgentsModel.apply(_:_:from:)`, `ProjectSummary.host` is not in `CodingKeys`). Projects are
  addressed by folder URL; agents by daemon-made UUID. `HostID` is `"mac"` or 8 random
  characters; `ProjectKey` is `host|path`.
- **Much of the daemon's state is per connection.** Credential lending (043) is not a
  notification. It is the error reply `-32036 credentialWanted {runtime, offered}` on the
  *requesting* connection. The window's `DaemonClient` catches it, asks its `CredentialLender`,
  sends `credentials/lend` on the same connection, and retries once. Lent secrets are held per
  connection and dropped when it closes. `credentials/offer`, `surface/identify`, `presence/report`,
  the device id pinned by `mayClaim`, and `devices/forget` closing a device's connections are all
  per connection too.
- **The bridge is a line pipe with one daemon connection per device.** `Bridge/Sources/main.swift`
  admits a TLS-PSK connection (`d:<uuid>` or `p:<hash>`), opens a *new* `daemon.sock` connection
  for it, lowers it with `connection/bindDevice` (`DeviceBinder`), and copies whole lines both
  ways. It parses no JSON. It says why (`main.swift:73`): the daemon broadcasts to every
  connection, so devices sharing one would each see half. The relay (`RelayHostCore`) does the
  same per device session.
- **PSKs are derived, not stored.** The bridge's key `relay-mac-key` (keychain, service
  `com.alexecollins.agents.device`) and each device's public key in `<root>/devices.json` give
  `HKDF(ECDH(mac, device), salt "agents-lan-v1", info uuid)`. Pairing uses
  `HKDF(secret, "agents-pair-v1")` with identity `p:<sha256(secret)[0..8] hex>`. TLS 1.2 only,
  ECDHE-PSK-CHACHA20-POLY1305. Network.framework fixes PSKs when a listener is made, so the
  listener is rebuilt on every key change.
- **Roles.** `ConnectionRole` is `control`, `agent`, `device`, `pairing`, `stranger`, with
  allowlists; `hearsNotifications` is `control || device`. On `daemon.sock` a peer must have the
  same uid; a signed daemon then checks the caller's code signature (`CallerSignature.swift`):
  the app and the bridge are `control`, `agentsd` (an agent's MCP) is `agent`, anything else a
  stranger. An unsigned daemon, a scratch root and Linux are `.open`: everyone is `control`.
- **Notices are sealed by the daemon.** `DaemonCore+Attention.swift:333` seals each headline with
  HPKE to a device's public key; `MailboxTransport` in the bridge claims `mailbox/carry` and posts
  what it hears to CloudKit.
- **Linux has neither Network.framework nor CryptoKit.** The Linux `agentsd` is a static musl
  build with no package dependencies. `LinkTLS`, `NetworkLink`, `RelayHostCore`, `Envelope.seal`
  and `DeviceKey` are all gated off there. The bridge is a macOS-only Xcode `application`
  target with a CloudKit entitlement; nothing builds it for Linux.
- **The window reads this Mac's disk directly in ~15 places.** Most are already gated on
  `host == .mac` with an RPC branch for servers (the files pane, pictures, Open in…, reveal).
  Five are not: `BackgroundPane` (TextEdit on a task's output file), `AgentRow` (Show in Finder,
  `worktreeIsThere` via `fileExists`), `WorkflowPage` (reads the workflow YAML) and
  `WorkflowRow`. Settings ▸ Shared reads `~/.agents` directly. `SignInRelays` and
  `CredentialStore` keep files under the window's root.

## R1 — Reversing 037 R7: the join moves out of the window

**Decision**: one program, `agents-control`, joins every host. Clients (the Mac window, the
iPhone, the iPad) hold one connection to it. `HostSet` and every `ServerConnection` leave the
window.

**Rationale**: 037 R7 chose "client-side, not federated" for one window. It named federation as
"the natural route for the phone follow-up" and rejected it for three reasons. Each is answered:

| 037's objection | Answer now |
|---|---|
| "every one of ~90 methods and ~30 notifications needs routing" | Routing is by *channel*, not by method (R3). The router never parses params. One rule covers every method, present and future. |
| "the Mac daemon would have to stay alive, and its lifetime would decide the servers' reachability" | The router is not a daemon and holds no work. It is a separate small process kept running by launchd (R5), on whichever machine the person chooses, which can be an always-on Linux box. |
| "a bug there would take down local work too" | Agents on each host are owned by that host's `agentsd`, unchanged. The router going down stops *seeing*, not *working* (SC-007). An agent's own MCP calls stay on the local `daemon.sock` (FR-015). |

What the reversal buys: a server added once is on every screen; pairing, keys and grants live
in one place instead of three (window, bridge, each `ServerConnection`); and the window's
~70 `client(for: host)` sites keep their shape, because each host still looks like its own
`DaemonClient` (R3).

**Alternatives considered**:
- *Federation inside the Mac `agentsd`*: what 037 rejected; it makes one host special, and a
  Linux-only person has no Mac to federate in.
- *Keep R7 and teach the bridge to proxy servers too*: two joiners (window and bridge) with two
  sets of rules; the window still special. It is what we have, with more of it.

## R2 — Enrolling a host, and its key

**Decision**: a host is enrolled like a device, with a code, and gets its own key.

- The control plane's own key is today's `relay-mac-key` (renamed in prose to "the control
  plane's key", same keychain account on a Mac; a file with `0600` under the control root on
  Linux, see R8).
- `hosts/startEnroll` (operator) makes a one-time secret, 5 minutes, like `devices/startPairing`.
  The code carries the control plane's public key, its addresses, and the secret.
- The host runs `agentsd --control <code>` once. It makes a P-256 key (keychain on a Mac,
  `<root>/host-key` `0600` on Linux), connects with the pairing PSK (`e:<hash>`), and calls
  `hosts/announce {name, publicKey, platform, version}`. The control plane records it in
  `<control>/hosts.json`, spends the secret, and replies with the host's `HostID`.
- From then on the host connects with identity `h:<hostID>` and PSK
  `HKDF(ECDH(control, host), salt "agents-host-v1", info hostID)`: the device scheme with its own
  salt, so a device key can never be replayed as a host key.
- `hosts/remove` deletes the record, rebuilds the listener without that PSK, and closes the
  uplink. The host's agents keep running; it just can no longer connect (FR-014).
- `hosts/install` (R9) does enrolment itself for servers it installs, over ssh, so the person never
  types a code for a server.

**Rationale**: the same mechanism devices already use, reviewed in the security review; nothing
new to trust.

**Alternatives considered**: SSH keys as host identity (ties hosts to ssh, which FR-010 is
trying to leave); mTLS certificates (a CA to run; Network.framework's PSK path is already built
and proven).

## R3 — Routing: virtual connections, one per client per host

**Decision**: the control plane does not route *calls*; it routes *connections*. For each
(client, host) pair it opens a **channel** over that host's one uplink. On the host, `agentsd`
turns each channel into a virtual connection to its `DaemonServer`, with the same per-connection
state a `daemon.sock` connection has today. The client, for its part, keeps one physical
connection and multiplexes one logical `DaemonClient` per host over it.

Wire (both hops, one JSON object per line, so `LineTransport` and `LineSplitter` carry it):

```text
client ⇄ control:   {"h":"<hostID>","m":<a JSON-RPC message, unchanged>}
                    {"m":<message>}                         → the control plane itself
control ⇄ host:     {"c":<channel int>,"m":<message>}
                    {"c":<n>,"open":{"grant":"operator|device","client":"<id>","device":"<uuid>?"}}
                    {"c":<n>,"close":true}
```

- **Requests** from a client name a host with `h`. The control plane checks the grant (R4),
  looks up the channel for (client, host), opening it if needed, and forwards `m` untouched.
  **No request-id rewrite is needed**: ids are unique per client connection, and a channel is
  per client. This replaces the plan's "request-id rewrite per hop" with something simpler.
- **Replies**, including `-32036 credentialWanted`, come back on the channel and go to that
  client with `h` added. `DaemonClient`'s lend-and-retry works unchanged, because the lend goes
  back on the same channel, and the host holds it for that virtual connection, dropping it when
  the channel closes: credential lending needs no new code on the host.
- **Notifications** from a host arrive on every open channel for that host (the host broadcasts
  per virtual connection exactly as it does per socket today, filtered by the channel's role).
  The control plane forwards each to its client with `h` added. There is no fan-out code in the
  control plane: the host's broadcaster *is* the fan-out.
- **Messages with no `h`** go to the control plane itself: `daemon/ping`, `control/status`,
  `hosts/*`, `clients/*` (today's `devices/*` for clients), `pairing/*`. A request with no `h` for
  any other method goes to the **home host** (the host on the same machine, if any), so an
  unchanged Remote keeps working against a control plane (R7).
- **Channels open** for every online host when a client connects, so it hears notifications from
  all of them, and for a host when it comes online. On a host dropping, the control plane sends the
  client `control/hostChanged {host, state}`; the client's per-host `DaemonClient` sees its link
  end and runs today's reconnect path.
- **On the client**, a `ControlLink` (a `DaemonLink`) owns the physical connection and hands out
  a `HostLink` per `HostID`, each a `LineTransport` that wraps and unwraps `h`. `AppModel` keeps
  one `DaemonClient` per host, as it has today; only where they come from changes. `AgentsModel`
  already stamps records by host.

**Rationale**: the daemon's per-connection model is load-bearing (credentials, surface, presence,
device pinning, forget-closes-connections, broadcast filtering). A router that multiplexed
many clients onto one host connection would have to reinvent every one of them in the host with
an actor id. Channels keep all of it, keep the router ignorant of the API (FR-002 for every future
method), and match what the bridge and the relay already do per device. The cost is N×M virtual
connections: at personal scale (≤ 5 clients × ≤ 6 hosts) that is ≤ 30, each a few KB and a
broadcast subscriber.

**Alternatives considered**:
- *One host connection, request-id rewriting, `actorRole` per call* (the plan's first shape):
  every per-connection feature needs an actor-keyed twin in `DaemonCore`; notifications need a
  fan-out table in the router; credential back-routing needs a correlation map. More code, more
  places to get security wrong.
- *A `host` field inside `params`*: changes 133 param types or needs the router to edit JSON it
  otherwise never parses.

## R4 — Grants, and the host's own check

**Decision**:
- `Grant` is `operator` or `device`. Clients are stored in `<control>/clients.json` (today's
  `devices.json`, with `grant` added and `kind` gaining `mac`).
- The control plane checks every request against the grant with the existing allowlists:
  `operator` → `ConnectionRole.control.allows`, `device` → `ConnectionRole.device.allows`. A
  refusal is `Failure.notPermitted`, as today, and never reaches a host.
- The channel's `open` carries the grant. The host makes the virtual connection `control` or
  `device` accordingly and enforces the same allowlist again (defence in depth, FR-007). It
  never raises: the uplink itself has role `controlPlane`, which may open channels and nothing
  else. A channel can only be as strong as `control`, never `agent`.
- `device` channels are also `bindDevice`d with the client's device id, so `mayClaim` and
  `surface/identify` keep pinning.
- The host's `daemon.sock` roles are unchanged: agents' MCP calls are `agent`; a local `control`
  caller (a scratch app, the tests) still works on a scratch root.
- `clients/setGrant` and `clients/forget` (operator) change the record; forget closes the
  client's connection and every channel it had, then rebuilds the listener without its PSK, as
  `devices/forget` does today. `clients/forget` refuses the last operator (FR-009).

**Rationale**: no new allowlist to review; the allowlists are the security review's work.

## R5 — Keeping a host and the control plane running on a Mac

**Decision**: `SMAppService.agent(plistName:)` with two plists shipped inside the app at
`Contents/Library/LaunchAgents/`:
- `com.alexecollins.agents.host.plist`: `Contents/Helpers/agentsd --serve --control-home`
  (connects to the control plane on this Mac; `KeepAlive` on, `RunAtLoad`).
- `com.alexecollins.agents.control.plist`: `Contents/Helpers/agents-control.app/Contents/MacOS/agents-control`
  (the bridge's bundle renamed; it keeps its CloudKit entitlement, which needs the bundle).

**Run one on this Mac** calls `register()` on both, then pairs the window over loopback with a
code the control plane issues to a caller on the same uid (R7 of the plan's first-run). macOS
shows them under Login Items, where the person can turn them off; `status` tells the window if
they have been.

Before registering, the window checks for leftover jobs under the same labels
(`launchctl print gui/<uid>/<label>`), per the leftover-launchd-jobs lesson; a scratch root uses
its own labels suffixed with the root's hash, so a walk never touches the real ones.

The environment is launchd's, not the window's: this also fixes the `CLAUDE_*` leak (the
clean-environment lesson) for good, since no daemon inherits the window's environment any more.
PATH for runtimes comes from the login shell probe the daemon already does.

**Rationale**: the Mac app bundles both binaries today (agentsd) or can (the bridge); SMAppService
is the supported, sandbox-friendly way, needs no admin rights, and survives app updates because
the plist points into the bundle.

**Alternatives considered**: a plist written to `~/Library/LaunchAgents` (works, but is what
SMAppService replaced, and is left behind when the app is deleted); keeping `posix_spawn` for the
home host (makes this Mac special again, and the host would die with idle-exit when no window is
open — the reason for `--serve`).

**What changes for the person**: work on this Mac now carries on after a restart without opening
the app (the daemon's pick-up-after-restart runs at login). `window-and-daemon.md` changes
accordingly; 021's "nothing runs after a reboot until the app is opened" no longer holds.

## R6 — The relay and notices, through the control plane

**Decision**: the relay and the notice mailbox move with the bridge into `agents-control`, and
work per client, not per host.
- A relay session (`RelayHostCore`) is a client connection like any other: its lines are the
  client⇄control wire of R3. Today it opens a `daemon.sock` connection; it will instead attach to
  the router as that device's client session.
- **Notices**: today each daemon seals headlines to device keys. Hosts no longer know devices.
  Each host sends its needs unsealed over its uplink (`attention/need`, already the shape of
  `mailbox/post` before sealing) to the control plane, which chooses the device (the presence
  rule of 021, now across hosts: "at a screen" is any operator client that reported presence)
  and seals with `Envelope.seal`. The uplink is TLS, so nothing legible crosses the network
  unsealed.
- **The relay needs CloudKit, so it runs only where the control plane is on a Mac.** A control
  plane on Linux serves clients on the network only. Away from home, a device needs a Mac
  control plane, or reaches the Linux one some other way the person provides (a VPN). This is
  the spec's assumption, made explicit.

**Rationale**: sealing needs device public keys, which only the control plane should hold; one
place decides which device is told, so two hosts never buzz twice.

## R7 — Moving an existing set-up across

**Decision**: a one-shot `agents-control migrate --from <root>`, run from the window's offer
(US6), never on launch.

1. Refuse if a control root already has clients or hosts (idempotent re-run is a no-op).
2. Stop the old bridge (`launchctl`-free: it is started by hand; the window asks the person to
   quit it, or the ship-app skill does).
3. Control root: `~/Library/Application Support/Agents Control`. Copy `devices.json` to
   `clients.json` with `grant: device` for every entry; the window gets a new `mac` client with
   `grant: operator` by loopback pairing. The control plane keeps `relay-mac-key`, so **every
   device's PSK is unchanged** and it reconnects on the same Bonjour name and port without
   pairing again (SC-006).
4. The old root stays where it is and **becomes this Mac's host's root** (no files move, so no
   agent, conversation or project can be lost). The host enrols itself with a loopback code.
5. Servers: for each `<root>/hosts.json` entry, run `hosts/install` from the control plane, which
   already has the person's ssh config. A server that fails is listed with its reason (US6.4).
   `hosts.json` is renamed `hosts.json.moved`, not deleted.
6. Register the two launch agents; the window switches to a `ControlLink`.
7. On any failure before step 6, nothing in the old root has changed, and the window keeps using
   it the old way (FR-025).

Alex's live set-up is moved only with his go-ahead, once, deliberately (plan's Risks).

**Transition**: until the move, the new window build must still work the old way. `AppModel`
keeps both paths behind one switch (`ControlConfig` present or not) until the move has been
walked on Alex's set-up; the old path is removed after that, in a separate change.

## R8 — TLS-PSK and keys on Linux

**Decision**: the Mac is first; Linux follows after a spike.
- On macOS, everything uses Network.framework's TLS-PSK and CryptoKit, as the bridge does.
- **Linux hosts first join the ssh way** (R9's fallback, FR-012): the control plane, on a Mac,
  holds today's ssh forward to the server's `daemon.sock` and treats it as that host's uplink,
  running channels as separate socket connections over the forward (the daemon already accepts
  many). That ships US3 without any Linux TLS.
- **Spike S1** (Phase 4): add `swift-crypto` and `swift-nio-ssl` to a Linux-only target and check
  that BoringSSL's `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` interoperates with the
  Network.framework listener, statically linked with the musl SDK, and what it adds to the
  binary. If it works: Linux `agentsd --control` dials out, and a Linux control plane becomes
  possible (without the relay, R6). If not: Linux stays ssh-reached, and the control plane stays
  on a Mac; the spec's "Mac or Linux" becomes "Mac, with Linux hosts" and Alex is asked.

**Rationale**: keeps the whole of US1–US5 on the path already proven in the bridge, and
isolates the only new dependency to a spike with a clear fallback.

**Spike S1, 2026-09-27. Passed.** BoringSSL speaks the one suite the control plane's
listener offers, and a statically linked musl binary does it from Linux.

`psk-dial` in `Packages/AgentsKit/Sources/ControlUplinkLinux` is a TLS 1.2 client with
the cipher string `ECDHE-PSK-CHACHA20-POLY1305` and a PSK identity callback, built on
`swift-nio-ssl` and `swift-crypto`. `psk-listen` is the listener `LinkTLS` describes:
TLS 1.2 only, suite `0xCCAC`, one pre-shared key, no resumption. The listener reported
the negotiated suite as `ccac`, and the client exchanged a line with it.

The same dialer, built with the Swift 6.4 static Linux SDK for aarch64 and stripped,
was run in a Linux container against that listener on this Mac. It dialed. The binary
is 59,820,992 bytes. A Swift program that only prints a line, built the same way, is
5,786,992 bytes, so the two libraries add 51.5 MB. Today's `agentsd-linux-aarch64` is
62,389,184 bytes, and linking this in would roughly double it. The build compiles
BoringSSL twice, once inside `swift-crypto` and once inside `swift-nio-ssl`. A dialer
that ships should keep one of them.

Linux `agentsd --control` can dial out (T044). The ssh path stays for a host that cannot.

## R9 — Installing a host from the control plane

**Decision**: `hosts/install {name, ssh destination, trust}` (operator) runs on the control
plane: `SSHMaster` + `ServerInstaller` + `ToolsetInstaller` move from the window's `HostSet`
into `agents-control`, unchanged apart from their home. Progress streams as
`control/installProgress` notifications with today's four steps; `AddServerFlow` renders them.
The binaries come from the control plane's own bundle (`Resources/servers`) on a Mac.

A host-key prompt (the first-connection trust step) is a `hosts/install` reply of
`needsTrust {fingerprint}` and a second call with `trust` set, since the control plane has no
screen.

Server credentials (043 lending) no longer travel as ssh reverse-forwards: an operator window's
channel to the server lends them as it lends to this Mac today. `SignInRelays` (the Mac's
ChatGPT/Codex sign-in proxy) needs a TCP path from the server back to this Mac; through the
control plane that is a stream channel (R10), deferred: until then servers use their own
sign-in or a lent key, and the Sign-in relay is shown as "needs this Mac on the same network"
(a stated regression, to be closed after R10).

## R10 — Latency, and the terminal

**Decision**: measure before optimising.
- The extra hop for this Mac's own work is loopback both ways (client → control → host on one
  machine): expected well under 1 ms.
- For devices, today's bridge is already a hop; the router adds parsing of a one-level JSON
  wrapper per line. For servers, today's path is ssh-forwarded; the new one is TLS to the
  control plane then the uplink.
- The perf-transport approach (a harness timing a byte round trip through a shell) runs on the
  scratch walk for: today's direct socket, the channel through a loopback control plane, and the
  devbox through each path. SC-004 is the gate.
- If the terminal fails SC-004, a **stream channel** (raw bytes, no JSON wrap) is the next step;
  it is also what R9's sign-in relay needs. Out of scope unless the measurement says otherwise.

## R11 — The window's own disk reads

**Decision**:
- Already gated on `host == .mac` (the files pane, pictures, Open in…, reveal): keep the gate,
  but make it "this Mac's host", `HostID` of the host whose `hosts/list` entry says it is on the
  same machine as the window (same machine id), since `.mac` is no longer special in the model.
  The home host keeps the id `mac` after the move (R7), so persisted selections survive.
- Not gated today (`BackgroundPane`, `AgentRow` Show in Finder and `worktreeIsThere`,
  `WorkflowPage`, `WorkflowRow`): gate them the same way, with the RPC path (`files/read`) for
  other hosts. `worktreeIsThere` asks the host.
- Settings ▸ Shared stays this Mac's `~/.agents` (it describes the person's home on this Mac);
  054's per-host view is a later feature.
- The window's own files (`credentials.json`, relay certificates, `hosts.log`) move to the
  window's own support folder, not the host's root: the window no longer has a root.

## Open for the look gate

- Settings ▸ Control plane: one pane or split into Hosts and Clients (wireframes show one pane
  with two cards, and the alternative).
- Where the control plane runs is shown in the title bar and in the sidebar's host headers
  only when it is not this Mac.
