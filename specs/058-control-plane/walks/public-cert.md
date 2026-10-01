# Walk: a publicly trusted certificate, with no pin (#61, first part)

2026-09-30, 21:15–21:40 (04:15–04:40 UTC), from the branch `agents/work-first-part-github`.
No real domain and no real CA: Pebble, Let's Encrypt's test CA, issued Caddy's certificate,
and its root stood in for a public one. The decision this proves is 058 research R15.

## Set-up

- `deploy/pebble/up.sh --devbox`, with `PEBBLE_PROFILE=renewal-walk RENEW_INTERVAL=30s`:
  `compose.public.yaml` (one copy, a folder store, Caddy with `auto_https` on) plus
  `compose.pebble.yaml` (Pebble as the ACME CA, Caddy on 8444, certificates for ten minutes).
  - The domain is `agents.127.0.0.1.sslip.io`. Public DNS answers 127.0.0.1 for it, so this
    Mac reaches Caddy through Colima's forward. Inside Docker the name is Caddy's network
    alias, for Pebble's TLS-ALPN challenge and for the devbox.
  - Colima did not forward the new containers' ports by itself; `up.sh` adds the forwards
    on Colima's ssh mux, and `down.sh` cancels them.
- **Linux host:** the devbox (`agents-devbox`), joined to the compose network, with Pebble's
  root in `/usr/local/share/ca-certificates` and the name in `/etc/hosts`. The host was
  installed under `HOME=/tmp/pebhost`, leaving the devbox's own `~/.agents-server` alone,
  with an `agentsd` built from this branch (`scripts/build-linux-agentsd.sh aarch64`).
- **Mac host:** the Debug `agentsd` from `build/DD`, on the scratch root `/tmp/pebmac/host`,
  launched with `env -i` and `AGENTS_MACHINE_ID=pebble-walk-mac`.
- **Store window:** the `AgentsStore` Debug build (`/tmp/fpg-store-dd`), copied to
  `/tmp/pebmac/AgentsWalk.app` and changed in that copy only:
  - **Bundle id `com.alexecollins.agents.walk`**, re-signed ad hoc with the same
    entitlements. Alex's live window is the store build, with the same bundle id and
    container. A scratch copy under that id would read his pairing and dial his live
    control plane, so it was never launched under it.
  - **An ATS exception for `sslip.io`** (`NSExceptionAllowsInsecureHTTPLoads`), because ATS
    wants a chain to a system root (see below). The delegate's own check, anchored to
    Pebble's root, with the name, still decides.
  - Paired by the walk hook: `open -n -g --env AGENTS_CONTROL=<code> --env
    AGENTS_TEST_TRUST_ROOT=<root, base64 DER>`.

## What was checked

| Check | Result |
|---|---|
| Caddy's certificate | Issued by `Pebble Intermediate CA`, for `DNS:agents.127.0.0.1.sslip.io`, within seconds of starting. `openssl s_client -CAfile pebble-root.pem` verifies it. |
| Codes | `agents-control code --host` and `code --client operator` both carry `-` in the pin field. |
| Linux host, the install command | `curl -fsSL https://agents.127.0.0.1.sslip.io:8444/v1/install.sh \| sh -s -- '<code>' pebble-linux`, with no `--pinnedpubkey` and no `--insecure`, said **pebble-linux joined the control plane.** Its log: `enrolled with agents.127.0.0.1.sslip.io as wcwddh00`, then `connected to the control plane`. |
| Linux host, without the root | Pebble's root removed from the system roots and the host restarted: `CERTIFICATE_VERIFY_FAILED`, every retry. With the root back: connected at once. |
| Mac host, without the root | `uplink: could not join the control plane: … CERTIFICATE_VERIFY_FAILED`. |
| Mac host, with `AGENTS_TEST_TRUST_ROOT` | `enrolled … as rzum6qpp`, `connected to the control plane`. `agents-control hosts` lists `pebble-linux` and `pebble-mac`. |
| Store window, without the root | `walk: could not pair: … Code=-1200`. |
| Store window, with the root and the ATS exception | `walk: paired as 3B2914D5-…`. The control plane logged `paired as operator` and the client connected. Both hosts show, with green dots (`public-cert/window-paired.png`). |
| Renewal | Caddy renewed every ~6.5 minutes (`certificate renewed successfully`, issuer `pebble:14000-dir`). Each certificate had a **new key and so a new pin**: four pins in 13 minutes. No connection dropped at a renewal. |
| Every connection made again after a renewal | `docker restart` of Caddy just after the 04:34:52 renewal. The window, the Mac host and the Linux host each logged `the control plane went` and `connected to the control plane` within a second, against the renewed certificate. |
| A Mac host's default path, with a real public certificate | A throwaway test in `ControlPlaneKitTests`, deleted after: `ControlDial.connect` with no pin and no test root to `https://www.apple.com` got through TLS (it failed only at the upgrade, `HTTP 404`), and to `https://self-signed.badssl.com` failed with `CERTIFICATE_VERIFY_FAILED`. So NIOSSL on macOS takes the system's public roots. |
| The production Caddyfile | `caddy adapt` with `AGENTS_DOMAIN=agents.example.com`: one site on :443, issuers Let's Encrypt then ZeroSSL (Caddy's default), the email set, and only a warning for the empty `acme.d` import. |

## Found

- **ATS refuses a pinned certificate at a fully qualified name.** A code whose pin matched
  Caddy's certificate at the time, given to the walk copy *before* it had the ATS
  exception: `ATS failed system trust`, -1200. The delegate had accepted (a wrong pin gives
  -999). ATS leaves IP addresses and `.local` names alone, which is why every pinned walk
  so far (127.0.0.1, `<mac>.local`) passed. This bears on R8's Tailscale name; see R15.
- **The Linux `agentsd` in the main checkout's `App/Resources/servers`** (version
  `0.1.0+1afb59fbc`, a commit this repository doesn't have) started, but never read its
  join code. The branch's own build joined at once. It was not looked into further.

## Not walked

- **A real Let's Encrypt certificate at a real domain**, and Caddy's real HTTP-01 and
  TLS-ALPN-01 challenges from the internet. Those come with the cloud machine.
- **The window trusting through the system's own roots** at the control plane. Here it
  trusted Pebble through the Debug hook and an ATS exception, because this Mac's trust
  settings were left alone. With Let's Encrypt it takes `URLSession`'s default handling.
  The Mac host's default path was checked against a public site (above), not at a control
  plane.
- **The Remote on iPhone and iPad.** Same `WebSocketLink`; no Simulator walk was possible
  with a test root.
- **Agents Host's Join one elsewhere** with a pinless code. The `agentsd` it starts is
  what was walked.

## Tests

- `ControlServiceTests` (15) pass with the `ControlDial` change.
- `TestTrustRootTests` is written but has not run: `AgentsKitTests` doesn't compile on main
  (`SessionLabelToolTests.swift:22`, "extra argument 'sink' in call"), a file this branch
  doesn't touch. The hook itself was walked above.

## Afterwards

`deploy/pebble/down.sh` removed the containers and volumes, the devbox's root, its
`/etc/hosts` line, its network and the port forwards. The walk processes were stopped by
pid, `/tmp/pebhost` and `/tmp/pebmac` removed, and the walk container's pairing deleted.
