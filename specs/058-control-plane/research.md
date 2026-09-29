# Research: 058 Control Plane (re-plan, 2026-09-28)

This replaces the first research of 2026-09-26. That research's R1–R11 were written for one
control plane inside the phone bridge on a Mac, speaking pre-shared-key TLS. Where one of its
decisions still holds, it is carried into a section below and named there. The first research is
in git at `117f858f`.

Two surveys of the branch at `f5e79a30` are the facts this rests on:
- **The App Store survey.** The Mac app has no sandbox. It starts `agentsd` and the bridge,
  registers launch agents, and runs ssh, `security` and `openssl`. It carries Linux programs and
  install scripts, and reads project files and `~/.agents` directly in about twenty places. The
  Remote is already close to App Store ready.
- **The scaling survey.** A client and the host it talks to must be connected to the same
  process. The stores are whole JSON files read once at start-up. Codes, presence and pending
  trust live only in memory. The control plane runs only on a Mac: its listener is
  Network.framework and its relay is CloudKit.

## R1 — Why a hub (kept from the first R1)

**Decision**: one service, the control plane, joins every host. Clients (the Mac window, the
iPhone, the iPad) connect only to it. Hosts connect out to it.

**Rationale**: unchanged from the first research. Joining in the window cannot reach the
phone. Joining in one `agentsd` makes one host special. The re-spec strengthens the case: a
sandboxed app cannot join anything itself.

## R2 — What to keep from the first build

**Decision**: keep the parts that are about *what* is routed and *who* may do it. Replace the
parts that are about *how* bytes travel and *where* state lives.

| Part (file) | Fate | Why |
|---|---|---|
| `ControlRouter`, `ControlWire` (`AgentsKitCore/Control`) | **Keep**, and give the router a second kind of host session: a host whose uplink another copy holds (R5) | Channels per client and host (first R3) are what keep the daemon's per-connection model: credentials, surface, presence, device pinning |
| `Grant`, `ClientRecord`, `HostRecord`, `ControlMethods` | **Keep**. Records gain `owner` and `version`; `ControlMethods` reads through the store (R4) | Grants and methods are unchanged by the spec |
| `GrantStore` (whole-file JSON) | **Replace** with `ControlStore` (R4) | Two copies cannot share a whole file safely |
| `ControlCode` | **Keep the idea, change the text**: a URL and a certificate pin instead of a list of `host:port` | One stable address (spec Assumptions) |
| `ControlAgreement` (pure-Swift P-256, HKDF, HMAC) | **Keep**. It becomes the proof of keys (R6) | It already matches CryptoKit byte for byte and needs no second BoringSSL on Linux |
| `ControlNet` (NWListener, TLS-PSK), `ControlDialling`, `LinkTLS` for control | **Replace** with HTTPS and WebSockets (R6, R7) | An ordinary load balancer cannot carry TLS-PSK |
| `LinuxControlDial` (NIO + NIOSSL, TLS-PSK) | **Rework** into the NIO WebSocket dialer for hosts (R7) | Same libraries, different handshake |
| `ControlUplink` (reconnect, backoff, channel demux) | **Keep**, over a new transport | It is transport-agnostic already |
| Host side: virtual connections, `.controlPlane` role, `attention/need` on channel 0 | **Keep** | Unchanged by the spec |
| `ControlLink`, `HostLink` (client side) | **Keep**, over a new transport | Same |
| `ThisMacHost`, `HostListHeading`, `ControlAwayStrip`, Settings ▸ Control plane (US5 frames D–G) | **Keep** | UI the spec still describes |
| `SSHHosts` install path (`hosts/install`, trust asked back) | **Keep**, with the key given for the one install and dropped afterwards (FR-018a) | Alex's choice |
| `SSHUplink`, ssh-reached hosts, ssh masters in the control plane | **Remove** | Spec Assumptions |
| `ControlMove` | **Keep**, run by the host app (R9) | The window can no longer read the old root |
| `LocalServices` (`SMAppService` launch agents) | **Move** to the host app (R9) | A sandboxed app cannot register them |
| `RelayHost`, `MailboxTransport` (bridge, CloudKit) | **Move** to the host app's relay helper (R10) | Relay and mailbox need a Mac (spec) |
| Bridge `DirectLink` (TLS-PSK phone link on 8790), the control plane inside the bridge | **Remove** once the move is walked | Devices reach the control plane directly |
| `UnixSocketListener` with signature roles, for the control plane | **Remove** for the control plane. It stays for `agentsd`'s own `daemon.sock` (agent tools, FR-021) | Clients reach the control plane over HTTPS, even on this Mac |
| `WindowFiles` (the window's files under `window/`) | **Remove**. The sandbox container is the window's folder | — |

**Rationale**: about 1,600 lines of router, wire, grants, codes and methods are portable and
tested (63 tests). What does not survive is transport and storage, which is exactly what the
two goals change.

## R3 — The control plane as a service: process, language, where it builds

**Decision**: a new SwiftPM package, `Packages/ControlPlane`, with one executable,
`agents-control`, and a library, `ControlPlaneKit`.
- **Dependencies:**
  - `AgentsKitCore` (router, wire, records, `ControlAgreement`);
  - swift-nio (`NIOHTTP1`, `NIOWebSocket`, `NIOPosix`);
  - swift-nio-ssl, for a copy that terminates TLS itself;
  - async-http-client, for the S3 store.
- **Platforms:** it builds for macOS and for Linux (musl, static).
- **Two ways to run it:**
  - The Linux build is shipped as a container image.
  - The macOS build is embedded in the host app (R9), which runs it as a single copy.
- It has no Network.framework, CryptoKit, CloudKit or `Security` imports.

**Rationale**:
- *One program for both places.* The single copy on a Mac and many copies on rented hosting
  run the same code with a different store, so FR-006's "a single copy behaves as several do"
  holds by construction.
- *NIO, not a web framework.* The service has one WebSocket endpoint and two plain ones
  (health, and a readiness probe for load balancers). NIO is already in the tree (T044).
- *A package of its own.* Nothing in the App Store apps can link it by accident. `AgentsKit`
  is linked by `agentsd` and must not grow a server.

**Alternatives considered**:
- *Hummingbird 2 or Vapor*: both are NIO underneath. Vapor is far larger than three endpoints
  need. Hummingbird is a fair fallback if hand-written HTTP upgrade handling grows past a few
  hundred lines.
- *Keep it inside the bridge*: the bridge is a Mac app bundle with a CloudKit entitlement. It
  cannot run on Linux or behind a load balancer.

## R4 — The store: one object per record, conditional writes

**Decision**: a `ControlStore` protocol with two implementations, a folder and an S3-compatible
bucket, under one key layout:

```text
<prefix>/v1/
  control.json                      name, owner, created           (write once)
  people/<owner>.json               the one person, for now (FR-012)
  clients/<client-id>.json          ClientRecord + owner + version
  hosts/<host-id>.json              HostRecord + owner + version
  codes/<sha256(secret)>.json       a code: purpose, grant, expires
  codes/<sha256(secret)>.spent      written once, when the code is used
  leases/<host-id>.json             which copy holds this host's uplink, epoch, expires
  copies/<copy-id>.json             a live copy: internal address, heartbeat
  events/<yyyy-mm-dd>/<ulid>.json   changes, for copies that missed a broadcast (R5)
```

- **Writes are conditional** (FR-008).
  - *Create:* `If-None-Match: *`.
  - *Update:* `If-Match: <etag>`.
  - A refused write means someone else changed the record first. The copy re-reads and either
    retries (a lease renewal) or refuses the call with `-32071 changedElsewhere` (a grant
    change).
  - AWS S3, Cloudflare R2 and MinIO all honour both headers. A bucket that does not is refused
    at start-up by a probe write.
- **A code is used once:** `codes/<h>.spent` is created with `If-None-Match: *`, and the copy
  that succeeds admits the client (US3-3). No conditional delete is needed.
- **The folder store** uses the same keys as files. A write takes an advisory lock on
  `<key>.lock`, compares the stored version, and renames a temporary file into place. It is
  for one machine only: the host app's single copy, or several copies on one server. Folders
  shared over NFS are not supported, because advisory locks there are unreliable.
- **Caching.**
  - Each copy lists `clients/` and `hosts/` at start-up and keeps them in memory.
  - It applies changes from peer broadcasts at once (R5).
  - As a backstop, it re-lists every 15 seconds, reading only objects whose ETag changed.
  - `lastSeen` is not written on every connect as it is today. It is written at most once an
    hour per client.
- **Secrets** (FR-010).
  - The control plane's private key is not in the store. It comes from the environment or a
    mounted secret file, and the host app keeps it in the keychain.
  - The store holds public keys, grants, code hashes and leases. A leaked bucket does not
    let anyone in:
    - a client's key is derived from its private key, which only the client holds, and the
      control plane's private key (R6);
    - a code is stored only as the hash of its secret.

**Rationale**:
- *No database.* Alex asked for disk or S3 and nothing more. Conditional writes (S3 has had
  both since late 2024) are enough for a few dozen records changed by hand.
- *One object per record.* Records do not contend with each other, and the "read once,
  rewrite whole file" problem from the survey goes away.

**Alternatives considered**:
- *One JSON file in the bucket for everything*: every change contends, and one bad write loses
  everything.
- *A database, or Redis for pub/sub*: an extra service to run, which the spec rules out
  (FR-007).
- *Write-ahead log objects only, compacted*: more machinery than a few dozen records need.

## R5 — Many copies: who holds a host, and routing between copies

**Decision**: a host's uplink is held by one copy at a time, named by a **lease**. Copies reach
each other over **peer links**. A client's copy routes to a host held elsewhere by proxying
that host's channels through the holder.

- **Copies register.**
  - At start-up, each copy writes `copies/<id>.json` with the address other copies reach it at
    (`AGENTS_CONTROL_PEER_URL`, for example the pod's own IP) and renews it every 10 seconds.
  - A copy whose heartbeat is 30 seconds old is gone.
- **Leases.**
  - When a host's uplink is authenticated, its copy writes `leases/<host>.json`: copy, epoch,
    and an expiry 30 seconds ahead. It creates the lease, or updates it with `If-Match`.
  - The copy renews the lease every 10 seconds.
  - A host that reconnects to another copy always wins. The new copy bumps the epoch over
    whatever lease is there, because a fresh authenticated uplink beats any old lease.
  - The old copy, if alive, loses its renewal (the ETag changed), closes its stale uplink and
    tells its peers.
- **Peer links.**
  - Each pair of live copies keeps one WebSocket between them.
  - Each side proves it holds the control plane's key with the same exchange as R6, using the
    identity `x:<copy-id>`.
- **Routing.**
  - The router in copy B sees every host. For a host copy A holds, B's host session is a
    **proxied uplink**: a stream over the peer link to A.
  - A treats that stream as an extra user of the real uplink. It gives B's channels uplink
    channel numbers of its own and maps them back.
  - The client's grant is checked at B, where the client is, and again by the host, as today.
    A only forwards.
  - Nothing in the wire to the host changes: the host sees channels, as today.
- **Changes reach every copy** (FR-009, within 2 seconds).
  - A copy that forgets a client, changes a grant, or enrols or removes a host writes the
    store first, then broadcasts `{"event":…}` on every peer link.
  - Each peer applies it: it closes sessions, reopens channels with the new grant, or marks a
    host.
  - The event is also written under `events/`, so a copy that was cut off catches up when it
    rejoins. It also re-lists every 15 seconds (R4).
- **Host state** (online, offline) is broadcast by the holding copy. A copy that sees a lease
  expire with no broadcast marks the host offline itself.
- **Presence.** Each copy broadcasts its clients' presence changes. Every copy keeps the folded
  view, which the notice path needs (R10).

**Rationale**:
- *Clients talk to every host.* The load balancer cannot route a client to "its host's copy",
  so copies must reach each other.
- *Proxying channels, not calls,* keeps first R3's property. The router stays ignorant of the
  API, and per-connection state lives on the host.
- *At one person's scale* (a handful of clients, twenty hosts, two or three copies) there are
  only a few peer links.

**Alternatives considered**:
- *Pub/sub through a broker* (Redis, NATS): a service the spec rules out.
- *Polling the store for messages*: far too slow for a keystroke (SC-004).
- *Sticky routing at the load balancer by host*: a client needs every host at once.
- *Clients connect to every copy*: this pushes the topology onto every client, and each would
  need every copy's address.

## R6 — Proving keys: a MAC from the keys already there

**Decision**: over the WebSocket, both sides prove their keys with **HMAC-SHA256 under the key
first R2 already derives**, HKDF(ECDH(control, peer)), in a three-message exchange:

```text
server → {"hello":{"v":1,"name":…,"control":<pub>,"nonce":<32 B>,"copy":<id>}}
peer   → {"auth":{"id":"c:<uuid>"|"h:<id>"|"p:<code-hash>"|"e:<code-hash>"|"x:<copy>",
                  "nonce":<32 B>,"mac":HMAC(K, "agents-auth-v1|c|" + sn + pn + id + origin)}}
server → {"ok":{"mac":HMAC(K, "agents-auth-v1|s|" + sn + pn + id + origin),
                "grant":…,"host":…}}   or   {"refused":{"reason":…}}
```

- **The key K** for each kind of identity:
  - *Clients and hosts:* K is the key they have today. That is `clientKey` (label
    `agents-lan-v1`) or `hostKey` (`agents-host-v1`), from `ControlAgreement`.
  - *Devices paired before the move:* their key is already a client key under the Mac's
    relay key, which becomes the control plane's key (R9). They prove themselves without
    pairing again (FR-038).
  - *Codes:* K is `codeKey(secret)`. After the `ok`, the new party sends its public key, and
    the server stores the record and answers with its id and grant. This is today's
    enrolment, moved over.
  - *Copies:* K is derived from the control plane's private key alone (label
    `agents-copy-v1`). Only holders of the secret can compute it.
- **The server's `mac`** proves it holds the control plane's key, so a client knows it reached
  its own control plane, not merely some TLS endpoint.
- **`origin`** is the URL the peer dialled, so a proof made for one control plane cannot be
  replayed to another.
- **TLS.** The HMAC exchange runs inside TLS, and TLS is checked in one of two ways:
  - *A publicly trusted certificate* at the load balancer (rented hosting, Let's Encrypt).
  - *A pin*: the SHA-256 of the certificate's public key, carried in the code. This is for
    the host app's single copy, which makes a self-signed certificate.
  - Either way, the HMAC exchange is not bound to the TLS session, so the TLS check is what
    stops a relay in the middle.
  - The pin is mandatory whenever the certificate is not publicly trusted.

**Rationale**:
- *It proves possession of the P-256 keys the spec names,* with keys every existing client
  already holds.
- *It needs no signature code on Linux.* `ControlAgreement` already does ECDH, HKDF and HMAC
  in pure Swift, and matches CryptoKit (`keysMatchCryptoKit`). Hosts avoid a second BoringSSL
  (first R8, S1).
- *Signatures would add nothing here.* The verifier always holds the control plane's key, so a
  shared-key MAC gives the same assurance.

**Alternatives considered**:
- *ECDSA signatures over the nonce*: equal assurance. On Linux it needs swift-crypto (a second
  BoringSSL, about 25 MB) or hand-written ECDSA, where nonce handling is the classic way to get
  signatures wrong.
- *Mutual TLS with client certificates*: many load balancers terminate TLS and drop client
  certificates, and `URLSession` client identities need the keychain in ways the sandbox makes
  awkward.
- *Bearer tokens*: a stolen token is a key. The spec asks for proof of keys.

## R7 — The wire: WebSockets carrying today's lines

**Decision**: one WebSocket per client or host, at `wss://<address>/v1/connect`. After R6's
exchange, every text message is one line of today's wire:
- clients send `{h,m}`;
- hosts send `{c,m|open|close}`;
- peer links send `{host,c,…}`.

- The first R3 wire is unchanged inside the socket. The legacy bare line (an old Remote)
  still goes to the home host during the move.
- **Pings.** The WebSocket sends a ping every 20 seconds, and a peer that misses two is closed.
  Load balancers' idle timeouts (often 60 seconds) never cut a quiet uplink.
- **Reconnect.** Hosts and clients reconnect with backoff (1 → 30 seconds, and at once on a
  network change, as `ControlUplink` does today) to *any* copy.
- **Dialers.**
  - *The apps:* `URLSessionWebSocketTask`, with a delegate that checks the pin (R6). This
    works in the sandbox with `com.apple.security.network.client`.
  - *Hosts on the Mac and on Linux:* one NIO dialer (`NIOWebSocket` over NIOSSL), from
    `LinuxControlDial` reworked, so both platforms run the same code.
- **Size.** S3 measured it: NIOSSL and the WebSocket stack add about 5.9 MB to a static Linux
  binary. S1's 51.5 MB was almost all Foundation (48.2 MB on its own), which `agentsd` links
  anyway.

**Rationale**: HTTPS and WebSockets are what every load balancer, TLS terminator, tunnel and
proxy understands (FR-011). Keeping the lines inside means the router, the host and every
`DaemonClient` are untouched.

**Alternatives considered**:
- *HTTP/2 or gRPC streams*: more machinery, weaker in `URLSession` on the Mac for a
  long-lived two-way stream, and nothing gained over WebSockets.
- *A request/response HTTP API for calls, plus a stream for updates*: this breaks the
  channel model and credential lending (first R3).

## R8 — Addresses and discovery

**Decision**:
- **A control plane has one address,** a URL. In rented hosting it is the load balancer's DNS
  name.
- **The host app's single copy** listens on port 8791. Its address is
  `https://<this Mac's .local name>:8791`, plus whatever name the person adds (for example
  their Tailscale name).
- **Codes and records** carry the URL and the pin.
- **Bonjour** (`_agents-control._tcp`) stays only so a window on the same network finds the
  host app's control plane without typing (US2-2). The app declares it in
  `NSBonjourServices`.

**Rationale**: a stable name is what a load balancer gives, and what a phone away from home
needs. A list of IP addresses (today's code format) goes stale.

## R9 — The host download: an app outside the Store

**Decision**: **Agents Host.app**, signed with Developer ID and notarized, shipped as a disk
image and a Homebrew cask.

- **Contents:**
  - `agentsd`;
  - `agents-control` (macOS build, R3);
  - `agents-relay`, which is today's `agents-bridge` without `DirectLink` (R10);
  - the Linux `agentsd` builds and toolset resources that `hosts/install` pushes to servers
    (these leave the window's bundle).
- **What it runs.**
  - It registers `agentsd` with `SMAppService` as a launch agent. `LocalServices` moves here,
    unchanged in substance.
  - If the person chooses **Run the control plane here**, it also registers `agents-control`
    (single copy) and `agents-relay` as launch agents.
- **Where the single copy keeps its store** (FR-024a). The person chooses when they set it up:
  - **This Mac** (the default): a folder, `~/Library/Application Support/Agents Control/store`.
  - **A bucket**: an S3-compatible endpoint (AWS, R2, B2, or MinIO on a NAS), bucket, prefix,
    access key and secret. The host app checks them with the start-up probe (R4) before
    saving. The access key and secret go in the host app's keychain and reach
    `agents-control` through the same inherited descriptor as the control key, never in a file
    or the environment of a launch agent's plist.
  - **Switching later** stops the copy, copies every object from one store to the other
    (`agents-control store copy --from … --to …`, which refuses a destination that is not
    empty), checks the counts and ETags, points the copy at the new store and starts it. Nothing
    in the store names where it lives, so clients and hosts notice nothing. The old store is
    kept until the person removes it.
  - **Why a bucket at home.** What the control plane remembers outlives this Mac. A copy on
    rented hosting can later join the same bucket, so a person can grow from one Mac to
    several copies without moving anything.
- **Its window** is small. It shows:
  - this host's state;
  - the code to pair a window or phone;
  - the choice to run the control plane here, or join one elsewhere with a host code;
  - the move across (R11);
  - a menu-bar item while anything needs attention.
- **The control plane's key.**
  - The host app keeps it in its keychain. It is today's `relay-mac-key`, so devices paired
    before the move keep working (R6).
  - It hands the key to `agents-control` through an inherited file descriptor at launch. The
    key is never written to disk.
- **Things the window used to do on this Mac** now run in the Mac host, answering over the
  control plane:
  - reading this Mac's Claude sign-in (`/usr/bin/security`), and the sign-in relay listener;
  - `openssl`;
  - Reveal in Finder, Open with, and opening Terminal: new methods `mac/reveal`, `mac/open`
    and `mac/terminal`, operator only, answered only by a macOS host.
- **Linux** gets the same pieces as a tarball, a container image for `agents-control`, and the
  one-line install command FR-018 shows.

**Rationale**:
- *A Developer ID app can do everything the store app may not,* and it can carry the CloudKit
  entitlement the relay needs (with a Developer ID provisioning profile).
- *An app, not a bare pkg,* because `SMAppService` launch agents are registered from inside a
  bundle, and the person needs somewhere to see a code and choose.
- *Homebrew* suits the developers alpha is aimed at (see the alpha scope memory).

**Alternatives considered**:
- *A pkg that writes plists into `~/Library/LaunchAgents`*: launchd jobs outside
  `SMAppService` show up as unknown background items, need an uninstaller, and cannot carry a
  CloudKit entitlement.
- *Two Mac apps* (a store client and a full direct app): Alex chose the separate host download.

## R10 — Relay and notices from a Mac host

**Decision**: the iCloud relay and the notice mailbox run in `agents-relay`, inside the host
app, on any Mac that is a host of the control plane and has turned **Relay for my devices** on.
It is on by default for the Mac that runs the control plane.

- **The relay.**
  - A device away from home posts sealed frames to CloudKit, as today.
  - `agents-relay` opens a WebSocket to the control plane for that device, and passes the R6
    exchange through untouched. The control plane therefore checks the device's own key, and
    the Mac only carries bytes.
  - The session is marked `relayed`, and today's away limits apply to it.
- **Notices** (FR-034).
  - A host sends `attention/need` unsealed on channel 0, as T056 built.
  - Its copy forwards it, with the folded presence view (R5), to the relay host's uplink on
    channel 0.
  - `agents-relay` there seals it to the person's devices and posts to the CloudKit mailbox,
    as `MailboxTransport` does today.
  - If there is no relay host, needs are shown only to connected clients.
- **Devices first try** the control plane's address, and use the relay only when it cannot be
  reached (FR-033).

**Rationale**: CloudKit and the person's iCloud need an Apple-signed process. The spec keeps
relay and mailbox (Alex's answers) without anything that we run.

## R11 — The move across

**Decision**:
- **Who runs it.** The host app runs the move (`ControlMove`, built in US6), not the window.
- **The existing root.** Installing the host app on a Mac with today's set-up points its
  `agentsd` at the existing root, `~/Library/Application Support/Agents`. Nothing is copied
  (FR-025).
- **Devices.**
  - Each paired device becomes a client record with a device grant and its existing public
    key.
  - The old bridge stays up until every paired device has been told the new address and pin,
    over its existing link or through the relay, or until the person ends it.
- **Servers** added in the old window are enrolled over ssh (FR-018a). If one cannot be
  enrolled, it is listed with the command to run on it.
- **The old window** keeps working the old way until the move ends (FR-039). A new App Store
  window pairs afterwards.

## R12 — The sandboxed Mac window

**Decision**: the Mac app target links **`AgentsKitCore` and `Shared` only**, as the Remote
does, and turns on the App Sandbox. Its entitlements:
- `com.apple.security.app-sandbox`;
- `network.client`;
- `device.audio-input` (dictation);
- `files.user-selected.read-only`, for the folder pickers, which pass paths to the host and
  never read them.

What leaves the window (survey classes):

| Today | Where it goes |
|---|---|
| `SocketLink` spawning `agentsd`, `DaemonLock` | Gone. The window has only `ControlLink` |
| `LocalServices`, launch agents, `launchctl` | Host app (R9) |
| `HostSet`, `ServerConnection`, ssh, `ssh-add`, `SSHMaster` | Gone from the window. `hosts/install` runs in the control plane |
| `ServerBinaries`, `Resources/servers`, `Resources/toolsets` | Host app and the container image |
| `ClaudeKeychainSignIn` (`security`), `MacSignInRelay` (`openssl`, NWListener) | Mac host (R9). Lending to servers goes host to host through the control plane, approved by an operator |
| The `isOnThisMac` direct reads: `textFile`, `pathIsThere`, workflow files, background pane, agent row | `files/read` and `files/stat` on the host, for this Mac as for any host |
| `SharedSkillsPage`, `SharedInstructionsPage` reading `~/.agents` | New `shared/*` methods on the host |
| `NSWorkspace` reveal and open of paths outside the container, opening Terminal.app | `mac/reveal`, `mac/open`, `mac/terminal` on the Mac host (R9) |
| `PresenceReporter` screen-lock probe (undocumented key) | The Mac host reports lock state (it already watches power). The window reports only its own activity |
| `CredentialStore` (keychain, no access group) | Stays. The window's own keychain is allowed in the sandbox |
| Dictation, SwiftTerm's view, Bonjour browsing | Stay |

**Rationale**:
- *The survey's classes 1 and 2 map onto hosts and entitlements.*
- *Linking only `AgentsKitCore`* makes a leftover `Process` or `posix_spawn` a build error
  rather than a review rejection.
- *The window stays one code base with the developer build.* During the transition, a build
  setting `AGENTS_STORE` turns the sandbox and the reduced link on. It is removed with the old
  path (plan Phase 9).

**Alternatives considered**:
- *Security-scoped bookmarks for project folders*: this keeps disk reads in the window, but
  every project on a server needs the RPC path anyway, so this would be a second path to keep
  working.

## R13 — App Store review

**Decision**:
- **Checks.** Each app is archived with App Store signing and checked with `xcrun altool
  --validate-app` (or Xcode's Validate). The Mac archive is also checked for any Mach-O other
  than the app's own.
- **Remote pushes.** The Remote's `aps-environment` comes from the distribution profile.
- **A demo for App Review:**
  - a demo control plane runs as a container on the person's own hosting. It is Alex's, not a
    service for users;
  - it has one demo host with a canned runtime;
  - a device code with a long expiry goes in the review notes.
- **Export compliance.** `ITSAppUsesNonExemptEncryption` stays `false`: the apps use only
  standard HTTPS and Apple's own cryptography (CryptoKit, and HMAC for authentication), which
  are exempt.

**Rationale**: FR-035 and FR-036. Review of an app that is useless without a server needs a
working demo in the notes.

## R14 — Latency (kept from the first R10)

**Decision**: measure before optimising, now over the paths the spec creates. Terminal echo
and question delivery are measured three ways, each against the direct socket:
- through one copy;
- through two copies (client on B, host on A);
- through a load balancer.

SC-004 applies to the one-copy path. The two-copy path is reported. If it fails badly, the
first fix is a client preferring the copy that holds its hosts, via a hint in `hello`, which
needs no change to the wire.

## Spikes

These run before the code they gate (plan Phase 0):

- **S2: the sandboxed window's WebSocket.**
  - A sandboxed test app dials a self-signed, pinned `wss://` on the local network and on
    loopback with `URLSessionWebSocketTask`.
  - It browses Bonjour with only `network.client`.
  - This proves R7 and R8 in the sandbox.
  - **Result, 2026-09-28: passed** ([spikes/s2-sandbox-ws/RESULTS.md](spikes/s2-sandbox-ws/RESULTS.md)).
    - An ad-hoc-signed app with only `app-sandbox` and `network.client` was confirmed
      sandboxed: its home was the container, and reading `~/Desktop` was denied.
    - It dialled a self-signed `wss://` by SPKI pin over loopback and over the LAN address,
      and a line went each way. A wrong pin was refused (`-999 cancelled`).
    - Bonjour browse found the service in under 0.1 s.
    - No App Transport Security exception was needed.
    - Three consequences for this design:
      - **Pins are P-256 only** (R6). The client builds the SPKI from the raw key with the
        fixed P-256 header; another key type would need a DER parser.
      - **Names on the certificate do not matter under a pin** (R8), so adding a Tailscale
        name needs no new certificate.
      - **The Local Network prompt was not seen.** The client was started from a shell that
        likely already had access, and every dial stayed on this Mac. A walk of the real
        store build, opened from Finder and dialling another machine, must still show the
        prompt and what a refusal does (T053).
- **S3: the Linux host dialer.** A static musl `agentsd` with `NIOWebSocket` and NIOSSL
  dials a copy behind a TLS-terminating proxy (Caddy) and a pinned self-signed copy. Measure
  the growth in binary size.
  - **Result, 2026-09-28: passed** ([spikes/s3-linux-ws/RESULTS.md](spikes/s3-linux-ws/RESULTS.md)).
    - Through Caddy's internal CA, with full verification including the host name, a line
      went each way, and a wrong root was refused.
    - Direct to a self-signed server, it was accepted by SPKI pin
      (`.noHostnameVerification`, an empty trust store, and `customVerificationCallback`),
      and a wrong pin was refused before any line was sent.
    - **Size:** the stripped dialer is 11,652,464 bytes, against 5,786,992 for a print-only
      binary: **+5.9 MB**. With Foundation linked on both sides it adds 5.0 MB.
    - **One snag for the host dialer:** with default trust roots, NIOSSL fails on a box without
      `ca-certificates`. The pinned path must set an empty trust store. The publicly trusted
      path needs system roots, so the install command checks for them (T070).
- **S4: conditional writes.**
  - `If-None-Match` and `If-Match` against MinIO (in Colima, beside the devbox) and against
    one real S3 bucket.
  - Two writers racing a lease, and a spent code written twice.
  - **Result, 2026-09-28: passed on MinIO, with five rules to add**
    ([spikes/s4-conditional/RESULTS.md](spikes/s4-conditional/RESULTS.md)). A Swift SigV4
    signer of our own worked over URLSession, path-style.
    - **Races:** create-once and update-if-match each had exactly one winner in 100 of 100
      rounds, with 2 writers and with 8, and the stored bytes were always the winner's.
    - **Statuses:** a stale ETag or a second create gets 412. `If-Match` on a missing key gets
      404. AWS documents 409 under concurrency.
    - **The five rules**, now in contracts/store.md:
      - 412, 409 and 404 on a conditional put all mean `conflict`;
      - ETags are passed back exactly as received;
      - every write changes the bytes (`rev` or `epoch` goes up), because identical bytes keep
        the same ETag, so A→B→A would let a stale write through;
      - the start-up probe also tries a stale `If-Match`;
      - conditional delete is never relied on: MinIO ignores it, and AWS added it only in
        2025. Forgetting and removing write a tombstone instead.
    - **The MinIO image is gone.** `minio/minio` left Docker Hub on 2026-09-11, and open-source
      MinIO is archived. Walks use `cgr.dev/chainguard/minio`, built from MinIO's source.
    - **Cloudflare R2** documents both headers, but not whether they hold under a race. Race it
      before relying on R2 for leases.
- **S5: a sandboxed archive.** Archive the Mac app with the sandbox on and the reduced link,
  and list what fails to build. That list is the real size of R12.
  - **Result, 2026-09-28** ([spikes/s5-sandbox-build/RESULTS.md](spikes/s5-sandbox-build/RESULTS.md)):
    **48 app files fail.**
    - Linking only `AgentsKitCore` gave 271 errors in 37 files, and 11 more files appeared
      once `HostSet` was taken away. Every app and `Shared/UI` file (95) also has to import
      `AgentsKitCore` instead of `AgentsKit`.
    - Moving eight pure types into Core leaves 107 errors in 24 files, all of them host
      management:
      - `HostSet` and the ssh servers UI;
      - sign-in relays;
      - `LocalServices` and the move;
      - the local endpoint in `ControlConfig`;
      - `model.hosts` in about 20 views.
    - **The types to move into Core:** `CredentialStore` and `CredentialCheck`,
      `MCPCatalogWords`, `BrowserPolicy`, the `FileProbe` value type, the path part of
      `WorkflowFile`, `ControlNet.serviceType`, a window-root part of `StoreLocations`, and
      `MachineID` if the sandbox allows its `gethostuuid`.
    - **Linking only Core does not catch disk access.** `FileManager` and `contentsOf` reads,
      `NSWorkspace` on paths and `PresenceReporter`'s `dlsym` all compile against Core and
      would fail quietly at run time. Some are in files R12 did not list: `AgentsSetup`,
      `ProjectRow`, `ImageFile`, `MacPageActions`, `PluginsSection`, `SharedSettingsView` and
      `ChatView`. A grep gate is needed as well as the link.
    - **Tooling:** Xcode stops compiling other batches after the first failure. Build with
      `-IDEBuildingContinueBuildingAfterErrors=YES`, and add `-continue-building-after-errors`
      to the target's Swift flags while working through US1.
