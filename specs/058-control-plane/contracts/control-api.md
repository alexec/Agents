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
| `control/status` | any | → `{name, version, url, copy, homeHost, machineID, relayKey?}`. `relayKey` is the relaying host's public key, which a device keeps so it can come through the relay when the address can't be reached (T077) |
| `hosts/list` | any | → `[{id, name, platform, version, state, machineID, relay}]` (no `reach`: every host dials out) |
| `hosts/startEnroll` | operator | → `{code, command}`: the host code, and the one-line install command for a server (FR-018) |
| `hosts/install` | operator | `{name, destination, key, trust?}` → `{host}` or `{needsTrust: fingerprint}`. `key`, optional, is a private key for this install only; it is held in memory until the call ends and never stored (FR-018a). Without it, the control plane's ssh logs in as `ssh user@host` would for the person running it: agent, `~/.ssh/config`, default identity (#413). The host key is confirmed either way Progress comes as `control/installProgress`. The copy that takes the call does the install |
| `hosts/checkAgain` | operator | `{host}` → `{}` |
| `hosts/update` | operator | `{host}` → `{}`: asks the host to update itself over its uplink |
| `hosts/remove` | operator | `{host, purge?: Bool}` → `{}`; revokes key, closes uplink |
| `clients/list` | operator | → `[ClientRecord]` (was `devices/list`) |
| `clients/startPairing` | operator | `{grant, kind?}` → `PairingCode{purpose: client(grant)}`; `kind: "browser"` (071) makes a code good only through the loopback listener, and any other code is good only over TLS (071 security review, R2) |
| `clients/stopPairing` | operator | → `{}` |
| `clients/announce` | pairing | `{id, publicKey, name, kind}` → `{client, controlKey, grant}` (was `devices/announce`) |
| `clients/setGrant` | operator | `{client, grant}` → `{}`; refuses to leave no operator |
| `clients/forget` | operator | `{client}` → `{}`; refuses the last operator; closes at once, home and relay |
| `clients/forgetSelf` | any | `{}` → `{}`: the caller forgets itself (071 **Forget This Browser…**); refuses the last operator; the reply is sent, then every socket of the caller closes with 4403 `forgotten`, on every copy |
| `presence/report` | any | as today; broadcast to peer copies, and folded for notices (R5, R10) |
| `hosts/setRelay` | operator | `{host, relay: Bool}` → `{}`: switches a relay host (`agents-relay`) on or off. A host that runs agents cannot be made one: `invalidParams` (R10, T097) |

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
| `hosts/announce` | `{name, publicKey, platform, version, machineID, relay?}` → `{host}` (enrolment connection only). `relay: true` is `agents-relay`: never the home host, relaying from the start |
| `host/hello` | `{version, platform, machineID, name?, relay?}` → `{}` |
| `attention/need` | `{need, headline, buzz}` / `{withdraw: needID}` → `{}`. The copy that holds the relay host chooses the device from folded presence, with the ladder (`NoticeDesk`), and sends `relay/deliver`; any other copy passes the need to its peers. With no relay host, a need reaches only the clients connected to its host (R10, T097) |
| `relay/devices` (control plane → relay host, notification) | `{devices: [{id, publicKey}]}`: whom it may carry for |
| `relay/deliver` (control plane → relay host, notification) | `{needID, device, publicKey?, headline?, alert}`: seal `headline` to `publicKey` and post it to the iCloud mailbox for `device`; no `headline` is a withdrawal |

## Failures (added to `DaemonAPI.Failure`)

-32070 (`signInWanted`) and -32080 (`catalogRefused`) were taken on main, so the control plane's own start at -32090.

| Code | Name | When |
|---|---|---|
| -32090 | `hostOffline` | A request for a host that is not online. |
| -32091 | `noSuchHost` | `h` names no host. |
| -32092 | `lastOperator` | Demoting or forgetting the last operator. |
| -32093 | `changedElsewhere` | A conditional write lost to another copy. Nothing was changed. Try again. |
| -32094 | `storeUnavailable` | The store cannot be reached. Live connections carry on, but nothing is remembered. |
