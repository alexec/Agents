# Feature Specification: The web page on this Mac, served by this Mac's host

**Feature Branch**: `agents/spec-1480-local-page`

**Created**: 2026-10-21

**Status**: Draft

**Input**: Issue #1480, "Web: the page on this Mac reaches this Mac's host directly, as the window
does". Option 1 of the issue (relay through agentsd's uplink), decided on 2026-10-21.

## Why this feature exists

Today the web page at `http://localhost:8792` is served by Agents Host's copy of the control
plane (`agents-control --home … --web …`). When the control plane runs elsewhere (#61, Settings ▸
Control plane ▸ Join elsewhere), no control plane runs on this Mac. Then nothing serves the page on
localhost: a person at this Mac must use the public page (https://control.agentloops.dev), and the
page's calls to this Mac's host go out to the cloud and back.

The Mac window already has a direct path to this Mac's host (#1118): a Unix socket that only the
window can open. A browser cannot open that socket. This feature gives the browser the same
nearness: this Mac's host (agentsd) serves the page on loopback, and answers the page's calls to
itself directly.

## How the page connects today (the facts this spec builds on)

- The page opens `ws://localhost:8792/v1/connect`. The server says `{hello:{name, control,
  nonce}}`. The page checks that `control` is the public key of the control plane it paired with,
  and proves its key with a MAC over `"agents-auth-v1" ‖ server nonce ‖ its nonce ‖ identity ‖
  origin` (`Web/src/wire/auth.ts:46-90`). The MAC key is `clientKey`: HKDF of ECDH(browser
  private, control public) (`Web/src/wire/keys.ts:55-59`).
- Only the control plane can check that proof: it needs the control plane's private key. agentsd
  does not have it, and must never have it.
- The control plane's loopback listener (`Go/internal/controlplane/web/`) checks the Host header,
  the Origin (`http://localhost:P`), serves only the manifest's files with a strict CSP, and binds
  the exchange to its own origin (`Service.accept`, `service.go:969-976`). A browser client is
  admitted only on that listener (`service.go:1009`).
- agentsd keeps an uplink to the control plane (`controllink.Uplink`). On its channel 0, the host
  can ask the control plane (`Uplink.Ask`) and the control plane can ask the host (`Router.Ask`).
  Each client session reaches the host on a channel of its own.

## The design in one paragraph

When this Mac's host has joined a control plane elsewhere, Agents Host starts agentsd with the
page's files and port. agentsd serves the page on `127.0.0.1` and `::1` with the control plane's
listener code (the `web` package: the same Host and Origin checks, manifest and CSP). For a page's
socket, agentsd **relays the key exchange** to the control plane on its uplink: it passes the
control plane's hello to the page, and the page's auth back, marked "from this host's loopback
listener, origin `http://localhost:8792`". The control plane checks the proof as it checks one on
its own loopback listener, and opens a client session for that browser **through this host's
uplink**. After that, the page's calls to this Mac's host (`{h: <this host>}`) are answered by
agentsd itself; every other call (`{m:}` to the control plane, `{h:}` to another host) goes up the
uplink in that session, and their answers and notifications come back the same way.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Open the page on this Mac with the control plane elsewhere (Priority: P1)

A person whose control plane runs in the cloud opens `http://localhost:8792` on this Mac, in a
browser that paired with that control plane. The page opens, says it is connected, and shows every
host's projects and sessions, as the public page does.

**Why this priority**: It is the whole feature. Without it there is no page on localhost when the
control plane is elsewhere.

**Independent Test**: Join a scratch control plane elsewhere (a second root), pair a headless
browser at `http://localhost:8792`, and open a session of this Mac's host and of another host.

**Acceptance Scenarios**:

1. **Given** this Mac's host joined a control plane elsewhere, **when** a browser opens
   `http://localhost:8792`, **then** agentsd serves the page, with the same files, headers and CSP
   as the control plane's loopback listener.
2. **Given** a browser that paired with that control plane at `http://localhost:8792`, **when** it
   connects, **then** the control plane checks its proof (bound to `http://localhost:8792`) and the
   page is connected.
3. **Given** a connected page, **when** it calls this Mac's host, **then** agentsd answers it
   without the call going to the control plane.
4. **Given** a connected page, **when** it calls the control plane or another host, **then** the
   call goes up this host's uplink and the answer comes back.
5. **Given** the control plane runs on this Mac (`Run here`), **then** agentsd serves no page, and
   the control plane's listener serves it as today.

---

### User Story 2 - Pair a new browser at localhost (Priority: P1)

A person pastes a browser code from the Mac window into the page at `http://localhost:8792`. The
browser pairs with the control plane elsewhere, and connects.

**Why this priority**: A browser must pair before it can connect, and a browser that paired at the
public page has its key under another origin.

**Independent Test**: Make a browser code with `agents-control code --client --browser`, pair at
`http://localhost:8792` in a fresh headless browser, then connect.

**Acceptance Scenarios**:

1. **Given** a browser code, **when** the page spends it at `http://localhost:8792`, **then** agentsd
   relays the code's exchange and `clients/announce` to the control plane, which accepts it as a
   code spent from a page.
2. **Given** a browser code, **when** it is spent anywhere but a page (agentsctl, a phone), **then**
   it is refused, as today.

---

### User Story 3 - The control plane is away (Priority: P3)

The control plane cannot be reached. The page at `http://localhost:8792` says so and shows what it
showed last, as the public page does when it loses its control plane.

**Why this priority**: A page that worked for this Mac's agents while the cloud was away would be
better, but it needs the host to check a browser's proof by itself, which needs a key the host
does not have (see "Not in this feature").

**Acceptance Scenarios**:

1. **Given** the uplink is down, **when** the page connects, **then** agentsd refuses the socket
   with the reason the page already says for a control plane that does not answer.

### Edge Cases

- Port 8792 is taken: agentsd says so in its log and in `daemon/status`, and tries again on
  `RetryWeb`, as the control plane's listener does (071 R3).
- The person moves the control plane back to this Mac: Agents Host stops passing the page to
  agentsd, and the control plane's own listener takes the port.
- A browser that this host relayed is forgotten: the control plane closes its session (4403), and
  agentsd closes the socket.
- A page socket that has not proved within 15 s is closed, and counts against the per-source
  budget, as on the control plane's listener.
- The uplink drops while pages are connected: agentsd closes their sockets; each page reconnects
  as it does today.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: agentsd MUST serve the page only when Agents Host gives it the page's folder and port
  (`--web DIR --web-port N`), which Agents Host does only when its role is `joinElsewhere`.
- **FR-002**: agentsd MUST serve the page with the control plane's `web` package unchanged: loopback
  addresses only, the Host and Origin checks, the manifest, the headers and the CSP.
- **FR-003**: agentsd MUST NOT check a browser's proof itself, and MUST NOT hold the control plane's
  private key or any key derived from it for a browser.
- **FR-004**: agentsd MUST relay a page socket's key exchange to the control plane on its uplink
  (a new channel-0 request, `host/relayPage`), with the origin from its own listener. Nothing the
  page says decides the origin.
- **FR-005**: The control plane MUST accept a relayed exchange only from a host that runs agents,
  is online, and has the capability for it, and MUST bind the proof to the origin
  `http://localhost:<port>` the host names, where the port is one the control plane was told when
  the host said hello. It MUST admit only `c:` (a paired client) and `p:` (a code) identities there,
  and only browser-kind clients, as on its own loopback listener.
- **FR-006**: The control plane MUST say in its log, and in the client's record, that a browser
  session came through a host's loopback listener, and which host.
- **FR-007**: For a relayed session, agentsd MUST answer the page's calls to itself locally, and
  carry every other call, and every answer and notification, through the uplink.
- **FR-008**: A browser that paired at the control plane's own loopback listener (when it ran on this
  Mac) MUST keep working after the control plane moves elsewhere, because its key is kept under the
  same origin and the control plane's key does not change on a move.
- **FR-009**: When the control plane cannot be reached, agentsd MUST refuse a page socket with a
  reason the page already shows.
- **FR-010**: The page MUST need no change, or only a change both its servers take, so one build of
  `Web/dist` works on both.

### Key Entities

- **A relayed page session**: a browser's socket on agentsd's loopback listener, the client id it
  proved, and the session the control plane opened for it through this host's uplink.
- **`host/relayPage`** (control, channel 0): the host's request to check a page's auth for an
  origin, and its answer (the server MAC, the client id, or a refusal).
- **The page's origin for a host**: `http://localhost:<port>`, named by the host when it says
  hello, and the only origin the control plane binds a relayed exchange to.

## Security *(mandatory for this feature)*

The new trust rule is FR-005: the control plane takes a host's word that a socket came in on that
host's loopback listener with the origin `http://localhost:<port>`. Without the rule, a browser's
proof is bound only to origins the control plane serves itself.

- **What a bad host could do with it**: relay a socket from anywhere and claim the localhost
  origin. It still needs a browser's proof, which only the browser's non-extractable key can make
  for that origin. So a host can only relay sessions of browsers that paired at
  `http://localhost:<port>`, and only to the host's own loopback listener's port. A host can
  already read and answer everything its own agents do, so the rule gives a host no browser it
  could not already serve.
- **What a page from another site could do**: nothing new. The Origin check (FR-002) refuses its
  socket before any exchange, as on the control plane's listener.
- **Review**: the security review (`.agents/skills/security-audit/`) reads this feature's PRs in
  its `tokens` and `socket-roles` threats before the release that ships it.

## Not in this feature

- **The page working with the control plane away** (User Story 3 says it is refused). It needs the
  host to check a browser's proof by itself: either a per-browser key the control plane hands the
  host, or a pairing of the browser with the host. Both are new keys on the host and need their own
  decision.
- **Serving the page from a server's host** to a browser on that server: a server has no browser.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the control plane elsewhere, a browser paired at `http://localhost:8792` opens
  the page and a session of this Mac's host, in a walk on a scratch set-up, with no call for this
  Mac's host leaving the Mac (the control plane's log shows none).
- **SC-002**: A page socket whose Origin is not `http://localhost:8792` is refused before any
  exchange, in a test.
- **SC-003**: A relayed exchange from a host for a port it did not name, or for a `mac`-kind client,
  is refused by the control plane, in a test.
- **SC-004**: The same `Web/dist` serves on both listeners (the manifest test passes on both).

## Tasks, each its own PR

1. Control plane: `host/relayPage` (schema in `Packages/Wire/control.openrpc.json`, the trust rule
   of FR-005, the log of FR-006), with tests for SC-003.
2. agentsd: the loopback listener (`--web`, `--web-port`, the `web` package), the relayed exchange,
   and the session through the uplink (FR-001 to FR-009), with tests for SC-002.
3. Agents Host: pass `--web` and `--web-port` to agentsd when the role is `joinElsewhere`, and stop
   passing them on a move back.
4. A walk (SC-001), and the docs: `docs/how-to/` for the page on this Mac, `docs/explanation/`
   for the trust rule, and the parity row.
