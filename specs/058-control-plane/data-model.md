# Data Model: 058 Control Plane (re-plan)

Records live in the `ControlStore` (a folder or an S3-compatible bucket). The layout and write
rules are in [contracts/store.md](contracts/store.md). Every record is one JSON object. Every
record a person owns carries `owner` (FR-012) and `rev`, a revision the store bumps on each write
and checks through the ETag. Host roots are unchanged.

## ControlSettings (`control.json`, written once)

| Field | Type | Notes |
|---|---|---|
| `name` | String | Shown to clients ("Alex's control plane"). |
| `url` | String | The one address (R8), e.g. `https://agents.example.com` or `https://mini.local:8791`. |
| `pin` | String? | SHA-256 of the certificate's public key, base64url. Absent when the certificate is publicly trusted. |
| `controlKey` | Data (X9.63, 65 B) | The public half. The private half is never in the store (FR-010). |
| `owner` | PersonID | The one person, for now. |
| `created` | Date | |

## Person (`people/<id>.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | PersonID | Random. |
| `name` | String | |

Only one exists now. The model is here so records can name their owner (FR-012).

## ClientRecord (`clients/<uuid>.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Identity `c:<id>`. |
| `owner` | PersonID | |
| `name` | String | |
| `kind` | `mac` \| `iphone` \| `ipad` | |
| `publicKey` | Data | K = HKDF(ECDH(control, client), `agents-lan-v1`, id), as today. |
| `grant` | `operator` \| `device` | |
| `paired` | Date | |
| `lastSeen` | Date? | Written at most hourly (R4). |
| `rev` | Int | |

Rules:
- At least one `operator` must exist for each owner (FR-016). This is checked on the version
  that was read, and a concurrent change gets `changedElsewhere`.
- Forgetting writes a tombstone (`forgotten: true`, `rev` bumped) with `.matching`, then
  broadcasts `clientForgotten`. Removing a host does the same. Tombstones are read as absent,
  and deleted after seven days (contracts/store.md rule 11).

## HostRecord (`hosts/<id>.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | HostID | `mac` for a migrated home host, otherwise 8 random characters. |
| `owner` | PersonID | |
| `name` | String | |
| `publicKey` | Data | K = HKDF(ECDH(control, host), `agents-host-v1`, id). |
| `platform` | String | `macOS arm64`, `Linux x86_64`, … |
| `version` | String | From `host/hello`. |
| `machineID` | String? | Lets a window know a host is on its own Mac (`ThisMacHost`). |
| `relay` | Bool | This Mac host runs `agents-relay` for the owner's devices (R10). |
| `installedBy` | `command` \| `ssh(destination)` | ssh is kept only to show how the host was installed. No key or session is kept (FR-018a). |
| `rev` | Int | |

`reach` (`dialOut` or `ssh`) from the first build is gone: every host dials out.

## Code (`codes/<sha256(secret)>.json`, and `.spent`)

| Field | Type | Notes |
|---|---|---|
| `purpose` | `client(grant)` \| `host` | Identity `p:` or `e:` plus the hash. |
| `owner` | PersonID | |
| `expires` | Date | Five minutes, or longer for the App Review demo code (R13). |
| `issuedBy` | ClientID | Who asked for it (shown in Settings). |

- **The secret itself** is never stored. The code text a person sees is
  `agents-control:2:<c|h>:<grant|->:<url>:<pin|->:<secret>:<name>`.
- **Using a code** creates `<hash>.spent` with `If-None-Match: *`, so it works once, at any
  copy.
- **Expired codes** are deleted by any copy that lists them.

## Lease (`leases/<host-id>.json`)

| Field | Type | Notes |
|---|---|---|
| `host` | HostID | |
| `copy` | CopyID | The holder of the uplink. |
| `epoch` | Int | Bumped on every takeover. |
| `expires` | Date | 30 s ahead, renewed every 10 s. |

State:
- **None → held.** A host's uplink is authenticated at copy X. X creates the lease
  (`If-None-Match`), or takes over an existing one with `If-Match` (epoch + 1).
- **Held → held, renewed.** X renews every 10 s (`If-Match`).
- **Held → lost.** X's renewal is refused (someone took over). X closes its uplink and
  broadcasts `hostMoved`.
- **Held → expired.** No renewal for 30 s. Any copy may mark the host offline.

## Copy (`copies/<copy-id>.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | CopyID | Random at each start. |
| `peerURL` | String | Where other copies dial it. |
| `started` | Date | |
| `heartbeat` | Date | Renewed every 10 s. The copy is gone after 30 s. |

## Event (`events/<yyyy-mm-dd>/<ulid>.json`)

`{kind, subject, at, by}`, where `kind` is one of:
- `clientForgotten`, `grantChanged`, `clientPaired`;
- `hostEnrolled`, `hostRemoved`, `hostMoved`.

Broadcast on peer links first, and written here for a copy that missed it. Events are kept
seven days.

## In memory, per copy

- **ClientSession**: client id, grant, owner, whether it is relayed, the WebSocket,
  `channels: [HostID: Int]`.
- **HostSession**, one of two kinds:
  - **local**: the host's uplink WebSocket, `channels: [Int: session]`, `nextChannel`, the
    lease epoch;
  - **proxied**: a stream on the peer link to the holding copy. Channel numbers are this
    copy's own, and the holder maps them onto the real uplink.
- **PeerLink**: copy id, WebSocket, proxied streams, and the events it has sent and received.
- **Folded presence**: from its own clients, plus presence broadcast by peers (R5, R10).
- **Record cache**: clients and hosts with their ETags, refreshed from events and every 15 s.

## Host side

- **The uplink.** It has role `controlPlane` and may carry channel frames only (kept). Each
  channel is a virtual `DaemonServer` connection with role `control` (operator) or `device`
  (kept).
- **New host methods**, answered on channels:
  - `mac/reveal`, `mac/open`, `mac/terminal`: operator only, macOS hosts only;
  - `shared/*`: operator; device is read-only.
- **Enrolment state** (kept from T044): `controlHostKey` (0600) and `controlHostMembership`,
  which now carries `url` and `pin` instead of addresses.

## Window side

- **`ControlConfig`**, in the sandbox container's defaults:
  - the control plane's `url` and `pin`;
  - the window's client id;
  - the window's key, in its own keychain.
- **One `DaemonClient` per `HostID`,** each over a `HostLink` from one `ControlLink`, over one
  `URLSessionWebSocketTask`.
