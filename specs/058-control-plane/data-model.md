# Data Model: 058 Control Plane

All records are JSON under the **control root** (`~/Library/Application Support/Agents Control`
on a Mac, `--root` otherwise), written atomically, as the daemon's stores are. The host's own
root is today's root and is unchanged.

## ControlConfig (`control.json`)

| Field | Type | Notes |
|---|---|---|
| `name` | String | Shown to clients ("Alex's Mac mini"). |
| `port` | Int | Client and host listener, default 8790 (today's bridge port, so paired devices find it). |
| `publicKey` | Data (x963, 65 B) | The control plane's key; private half in the keychain (`relay-mac-key`) or `control-key` `0600`. |
| `homeHost` | HostID? | The host on the same machine; legacy clients with no `h` go there. |
| `machineID` | String | Lets a window know a host is on its own Mac (R11). |

## ClientRecord (`clients.json`, was `devices.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PSK identity `d:<id>`, as today. |
| `name` | String | |
| `kind` | `mac` \| `iphone` \| `ipad` | `mac` is new. |
| `publicKey` | Data | PSK = HKDF(ECDH(control, client), "agents-lan-v1", id). |
| `grant` | `operator` \| `device` | New. Migrated devices get `device`. |
| `paired` | Date | |
| `lastSeen` | Date? | Updated on connect; shown in Settings. |

Rules: at least one `operator` always (FR-009). Changing `grant` applies to the next call; open
channels are reopened with the new grant.

## HostRecord (`hosts.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | HostID | `mac` for the migrated home host (R11); else 8 random chars, as today. |
| `name` | String | |
| `publicKey` | Data? | Present for dial-out hosts; PSK = HKDF(ECDH, "agents-host-v1", id). |
| `reach` | `dialOut` \| `ssh(destination, hostKeyFingerprint)` | `ssh` for hosts the control plane reaches (FR-012, R8). |
| `platform` | String | `macOS arm64`, `Linux arm64`, … |
| `version` | String | From `hosts/announce` / probe. |
| `installed` | Bool | True when installed by `hosts/install` (so remove can offer to purge). |

## HostState (in memory, sent as `control/hostChanged`)

`online` · `offline(since)` · `connecting` · `needsUpdate(from,to)` · `failed(reason)`.

## PairingCode (in memory, one at a time per purpose)

| Field | Type | Notes |
|---|---|---|
| `purpose` | `client(grant)` \| `host` | Identity prefix `p:` for clients, `e:` for hosts. |
| `secret` | 32 B | |
| `expires` | Date | 5 minutes. |
| `addresses` | [String] | Where to reach the control plane (Bonjour name, host:port). |
| `controlKey` | Data | So the new party can derive its PSK afterwards. |

## Session state in the router (in memory)

- **ClientSession**: client id, grant, one `LineTransport`, `channels: [HostID: Int]`.
- **HostSession**: host id, one uplink `LineTransport` (or an ssh-forward factory for `ssh` hosts),
  `channels: [Int: ClientID]`, `nextChannel`.
- **Channel**: `(client, host, number)`; opened with `{grant, client, device?}`; on the host it is
  one virtual connection with role `control` (operator) or `device` (bound to the device id).

## Host side (in memory)

- The uplink connection has role `controlPlane`: it may send channel frames and nothing else.
- Each virtual connection is a `DaemonServer` connection in every respect (identity, role,
  lent credentials, surface, broadcast subscription), with a line transport backed by the uplink.

## Window side

- `ControlConfig` (window's own defaults, scoped by root per the scratch-defaults lesson):
  control-plane address, the window's client id; the window's key in the keychain.
- One `DaemonClient` per `HostID`, each over a `HostLink` from one `ControlLink`.
