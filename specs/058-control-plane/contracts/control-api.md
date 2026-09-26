# Contract: methods the control plane answers itself

Sent with no `h`. Grant column: which client grant may call it. Params and results are JSON.

| Method | Grant | Params → Result |
|---|---|---|
| `daemon/ping` | any, and pairing | → `{}` (so today's clients' liveness check works) |
| `control/status` | any | → `{name, version, homeHost, machineID}` |
| `hosts/list` | any | → `[{id, name, platform, version, state, reach}]` |
| `hosts/startEnroll` | operator | → `PairingCode{purpose: host}` |
| `hosts/install` | operator | `{name, destination, trust?}` → `{host}` or `{needsTrust: fingerprint}`; progress as `control/installProgress {name, step, of, detail}` |
| `hosts/checkAgain` | operator | `{host}` → `{}` |
| `hosts/update` | operator | `{host}` → `{}` (ssh-reached and installed hosts) |
| `hosts/remove` | operator | `{host, purge?: Bool}` → `{}`; revokes key, closes uplink |
| `clients/list` | operator | → `[ClientRecord]` (was `devices/list`) |
| `clients/startPairing` | operator | `{grant}` → `PairingCode{purpose: client(grant)}` |
| `clients/stopPairing` | operator | → `{}` |
| `clients/announce` | pairing | `{id, publicKey, name, kind}` → `{client, controlKey, grant}` (was `devices/announce`) |
| `clients/setGrant` | operator | `{client, grant}` → `{}`; refuses to leave no operator |
| `clients/forget` | operator | `{client}` → `{}`; refuses the last operator; closes at once, home and relay |
| `presence/report` | any | as today; the control plane uses it to choose who is told (R6) |

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
| `attention/need` | `{need, headline, buzz}` / `{withdraw: needID}` → `{}` |

## Failures (added to `DaemonAPI.Failure`)

| Code | Name | When |
|---|---|---|
| -32070 | `hostOffline` | A request for a host that is not online. |
| -32071 | `noSuchHost` | `h` names no host. |
| -32072 | `lastOperator` | Demoting or forgetting the last operator. |
