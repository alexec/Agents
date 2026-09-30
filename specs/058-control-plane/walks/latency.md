# Latency through the control plane (R14, SC-004, T101)

2026-09-29, on this Mac (Apple M5, macOS 27.0), from the branch after ecd1425f.
`LatencyLiveTests` in `Packages/ControlPlane`; how to run it is at the top of that file.

## What is measured

The same host server is reached four ways:
- **`daemon.sock`**: the window's path today.
- **One copy**, terminating TLS itself as Agents Host's copy does.
- **Two copies** over one store, the host at A and the window at B.
- **One copy behind Caddy**: Caddy 2 in Docker on Colima's VM, `tls internal`, proxying to
  the copy on this Mac.

The window's side dials as the apps do (`URLSession`, `WebSocketLink`). The host's side is an
uplink dialling with NIO, as `agentsd` does.

- **Keystroke:** a call to the host, whose server says it back as a notification, the way a
  shell's echo comes back as `shell/output`. Timed from the call to the echo.
- **Question:** a notification the host sends unasked, as a question arrives. Timed from the
  host sending it to the window hearing it.

A shell or a runtime takes the same time on every path, so neither is included: this is
what the path adds. Each figure is 200 samples after 20 to warm up, in milliseconds.

## Results

Three runs; the third is shown, with the range of medians over all three in brackets.

| Path | Key median | Key p90 | Question median | Question p90 |
|---|---|---|---|---|
| `daemon.sock` | 0.06 (0.06) | 0.07 | 0.10 (0.07–0.10) | 0.21 |
| One copy, TLS | 0.38 (0.38–0.50) | 0.43 | 0.27 (0.27–0.35) | 0.40 |
| Two copies | 0.50 (0.49–0.90) | 0.55 | 0.44 (0.41–0.86) | 0.66 |
| One copy behind Caddy | 0.91 (0.91–2.15) | 0.99 | 1.28 (1.28–1.37) | 2.16 |

**SC-004 passes.** Through one copy, a keystroke's echo is 0.3–0.4 ms later than on
`daemon.sock`, where the limit is 10 ms. A question is 0.2–0.3 ms later, where the limit
is 50 ms.

- The **second copy** adds about 0.1 ms more. R14's fallback, a client preferring the copy
  that holds its hosts, is not needed.
- **Caddy** adds about half a millisecond more. Most of it is the hop into Colima's VM and
  back; a Caddy on the same host as the copy would add less.
- A two-copy p90 of 6.23 ms appeared once, in the first run, and not in the other two.

## Found

- **Caddy and an address without a name.** Dialled at `https://127.0.0.1`, the NIO client
  sends no SNI, since an IP address cannot be one. Caddy then has no certificate to offer and
  refuses the handshake (`TLSV1_ALERT_INTERNAL_ERROR`). The walk set `default_sni`.
- **The deploy is not affected.** It gives Caddy a public name, which every client sends.
