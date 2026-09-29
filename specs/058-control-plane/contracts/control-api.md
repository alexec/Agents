# Contract: methods the control plane answers itself (re-plan)

The re-plan changes the rows marked below. Everything else is the first build's, and is kept.
Every method is answered by whichever copy the client is on, and reads and writes go through
the store ([store.md](store.md)).

## New host methods (answered on channels, not by the control plane)

| Method | Grant | Host | Params → Result |
|---|---|---|---|
| `mac/reveal` | operator | macOS only | `{path}` → `{}`: Reveal in Finder |
| `mac/open` | operator | macOS only | `{path, app?}` → `{}`: Open in another app |
| `mac/terminal` | operator | macOS only | `{path?, command?}` → `{}`: opens Terminal.app |
| `shared/list`, `shared/read` | any | any | the shared skills and instructions under the host's `~/.agents` |
| `shared/write`, `shared/remove` | operator | any | the same, changing them |
| `files/stat` | any | any | `{path}` → `{exists, kind, size, modified}`: replaces the window's `pathIsThere` |

Sent with no `h`. Grant column: which client grant may call it. Params and results are JSON.

| Method | Grant | Params → Result |
|---|---|---|
| `daemon/ping` | any, and pairing | → `{}` (so today's clients' liveness check works) |
| `control/status` | any | → `{name, version, url, copy, homeHost, machineID}` |
| `hosts/list` | any | → `[{id, name, platform, version, state, machineID, relay}]` (no `reach`: every host dials out) |
| `hosts/startEnroll` | operator | → `{code, command}`: the host code, and the one-line install command for a server (FR-018) |
| `hosts/install` | operator | `{name, destination, key, trust?}` → `{host}` or `{needsTrust: fingerprint}`. `key` is a private key for this install only; it is held in memory until the call ends and never stored (FR-018a). Progress comes as `control/installProgress`. The copy that takes the call does the install |
| `hosts/checkAgain` | operator | `{host}` → `{}` |
| `hosts/update` | operator | `{host}` → `{}`: asks the host to update itself over its uplink |
| `hosts/remove` | operator | `{host, purge?: Bool}` → `{}`; revokes key, closes uplink |
| `clients/list` | operator | → `[ClientRecord]` (was `devices/list`) |
| `clients/startPairing` | operator | `{grant}` → `PairingCode{purpose: client(grant)}` |
| `clients/stopPairing` | operator | → `{}` |
| `clients/announce` | pairing | `{id, publicKey, name, kind}` → `{client, controlKey, grant}` (was `devices/announce`) |
| `clients/setGrant` | operator | `{client, grant}` → `{}`; refuses to leave no operator |
| `clients/forget` | operator | `{client}` → `{}`; refuses the last operator; closes at once, home and relay |
| `presence/report` | any | as today; broadcast to peer copies, and folded for notices (R5, R10) |
| `hosts/setRelay` | operator | `{host, relay: Bool}` → `{}`: a macOS host relays for this person's devices (R10) |

Legacy names `devices/list`, `devices/startPairing`, `devices/stopPairing`, `devices/announce`,
`devices/forget` are accepted as aliases until the Remote and the window move to `clients/*`.

## Notifications from the control plane

| Notification | Params |
|---|---|
| `control/hostChanged` | `{host, state, name?, version?}` |
| `control/clientChanged` | `{client?, removed?}` (operator only) |
| `control/pairingChanged` | `{purpose, expires?}` (operator only) |
| `control/installProgress` | `{name, step, of, detail}` |

## Host methods on channel 0 (host → control plane)

| Method | Params → Result |
|---|---|
| `hosts/announce` | `{name, publicKey, platform, version, machineID}` → `{host}` (enrolment connection only) |
| `host/hello` | `{version, platform, machineID}` → `{}` |
| `attention/need` | `{need, headline, buzz}` / `{withdraw: needID}` → `{}`. The copy forwards it, with folded presence, to a relay host (R10) |
| `relay/deliver` (control plane → relay host) | `{need, presence}` → `{}`: seal to the person's devices and post to the iCloud mailbox |

## Failures (added to `DaemonAPI.Failure`)

-32070 (`signInWanted`) and -32080 (`catalogRefused`) were taken on main, so the control plane's own start at -32090.

| Code | Name | When |
|---|---|---|
| -32090 | `hostOffline` | A request for a host that is not online. |
| -32091 | `noSuchHost` | `h` names no host. |
| -32092 | `lastOperator` | Demoting or forgetting the last operator. |
| -32093 | `changedElsewhere` | A conditional write lost to another copy. Nothing was changed. Try again. |
| -32094 | `storeUnavailable` | The store cannot be reached. Live connections carry on, but nothing is remembered. |
