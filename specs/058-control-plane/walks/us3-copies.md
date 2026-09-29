# Walk 2: three copies behind a load balancer (US3, T069)

Walked 2026-09-29 in Colima, from the branch after 99baa409 plus the fixes below. The stack was
`deploy/compose.yaml`:
- MinIO (`cgr.dev/chainguard/minio`), bucket `agents-walk`, prefix `w1`;
- three copies of the static `agents-control` image, linked with each other;
- Caddy on `https://127.0.0.1:8443`, with the pin from `deploy/make-secrets.sh`.

The walk is a live test, so it can be run again:

```sh
scripts/build-linux-control.sh aarch64 && deploy/make-secrets.sh
docker compose -f deploy/compose.yaml up -d --build
AGENTS_WALK_COMPOSE=$PWD/deploy/compose.yaml swift test --package-path Packages/ControlPlane --filter Walk2
```

It pairs its own host, an operator window and a device through Caddy, then stops and starts
containers as the steps say. Alongside it:
- a real scratch `agentsd` (`/tmp/w2/h1`) joined through Caddy with a host code from a copy;
- the App Store window was paired through Caddy too.

## The steps

| Step | Result |
|---|---|
| 1–3. Host, window and device paired through Caddy | Each code was made by `agents-control code` in one copy and used wherever Caddy sent it. The copies logged pairing at one copy and connecting at another. |
| The real `agentsd` host | Enrolled through Caddy as `gz6kv9bk`, and connected. |
| The App Store window | Paired at cp1 and connected at cp2, over `URLSession` with the pin. |
| 4. Leases | Read from MinIO: `leases/<host>.json` names the holding copy and its epoch. |
| 5. Kill the holder (SC-003) | The host was held by cp1 and the window was on cp3. The lease moved in **1.1 s**, the epoch went up, and the window reached the host again **1.4 s** after the kill. The real `agentsd` host, killed at its holder (cp2), was back in **1.2 s** at epoch 5: its log says "the control plane went", then "connected" a second later. |
| 6. Kill the window's copy | The window reconnected through Caddy at once, and every host was still listed online. (The app reconnects by itself; the test does what its loop does.) |
| 7. A code across copies | Used once through Caddy; the second use was refused `spent`. |
| 8. Forget the device from the window (FR-009) | Its socket, on another copy, was closed well within 2 s. |
| 9. Two grant changes at once | Across runs, one was refused `changedElsewhere` (-32093), or the two landed one after the other. Both are right. |
| 10. Stop MinIO | Live calls to the host carried on. Pairing was refused with `storeUnavailable` (-32094), and `/readyz` goes to 503 at the next re-list. |

## Found and fixed

- **One connection in five through Caddy hung for 15 s** (`couldNotConnect`).
  - NIO's client upgrade drops bytes that arrive in the same read as the `101` response. Behind a proxy that is often the server's first frame, the hello, so the key exchange waited for it until timing out.
  - Direct connections almost never coalesce, so it had not shown before.
  - `ControlDial` now adds its HTTP handlers with `leftOverBytesStrategy: .forwardBytes`.
  - 20 connections in a row through Caddy now finish in a second, and a 50-connection TLS test guards it.
  - Every host and test that dials with `ControlDial` was exposed to this, `agentsd` included.
- **A grant change at one copy, for a client paired at another moments ago, was refused** with "No client has that id".
  - `ControlRecords.setGrant`, `forget` and `remove` now read the store again before deciding a record is unknown, as the key exchange already did for a client or host it didn't know.

## Not walked, or different from the quickstart

- **The devbox as a host.** Every code carries one URL, `https://127.0.0.1:8443`, and a container cannot reach the Mac's loopback. Walking the devbox needs a name both can resolve. The Linux `agentsd` path is Walk 3's (US4).
- **The fake device.** `FakeDeviceLiveTests` still dials the first build's way until T078, so the walk's own device client stood in for it.
- **Events.** Changes are written to `events/<day>/…` and sent on every peer link. A copy that missed one catches up by reconciling its sessions against the records when a link comes up and every 15 s, rather than by replaying `events/`. That has the same effect with less to go wrong.
- **Screens.** No screenshots: nothing in this story is drawn differently. The App Store window's pairing was checked by its log and the copies' logs.
