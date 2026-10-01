# Spike S2 — the sandboxed window's WebSocket (T022)

Run 2026-09-28 on Alexs-MacBook-Air (macOS 27, Darwin 27.0.0). **All six checks PASS.**

| Check | Result |
|---|---|
| Sandbox applied | PASS: home = `~/Library/Containers/com.alexecollins.agents.spike.s2/Data`, `APP_SANDBOX_CONTAINER_ID` set, reading `~/Desktop` denied ("you don't have permission to view it") |
| Loopback pinned dial (`wss://127.0.0.1:8797`) | PASS: delegate saw the expected pin, `useCredential`, socket opened |
| A line each way | PASS on every dial: client sent `{"client":"hello from sandbox via …"}`, server logged it and answered `{"server":"got …"}`, client received it |
| Wrong pin rejected | PASS: delegate answered `.cancelAuthenticationChallenge`, task failed `NSURLErrorDomain -999 cancelled`; server logged `handshakeFailed(... EOF during handshake)`; nothing reached the WebSocket layer |
| `.local` pinned dial (`wss://Alexs-MacBook-Air.local:8797`) | PASS, **but it went over loopback**: the Mac's own .local name resolves to `::1` first, and the server saw the peer as `::1`. A second run dialled the LAN address `wss://192.168.0.238:8797` and also PASSED (server saw `::ffff:192.168.0.238`) |
| Bonjour browse (`NWBrowser`, `_agents-control._tcp`, `local.`) | PASS: state `ready`, then found `S2 spike._agents-control._tcp.local.` in under 0.1 s (advertised by `dns-sd -R`) |

No Local Network prompt appeared, and there was no `waiting` state or policy error.

## Caveats

- **Local Network privacy was probably not exercised.** macOS attributes Local Network access to
  the *responsible* process. The client ran from a shell under the Claude agent (node → Agents
  app), not through LaunchServices, so any existing grant for that chain probably covered it. All
  traffic also stayed on this Mac: its own .local name, its own LAN IP, and its own Bonjour
  record. A Store build launched from Finder, dialling *another* Mac, still needs one walk. That
  walk would show the prompt and what happens when access is denied.
- **The certificate is P-256 only.** The client builds the SPKI by putting the fixed P-256 DER
  header in front of `SecKeyCopyExternalRepresentation`. It rejects any other key type. The
  server must make P-256 keys, or the client needs a DER walk of the certificate.
- **No hostname check.** With a pin, `useCredential` accepts the trust without checking the host
  name or the chain. That is the intent, because the pin is the whole check. The certificate's
  SAN (`Alexs-MacBook-Air.local`, `127.0.0.1`) was not needed for the LAN-IP dial.
- **No ATS exception was needed** for `wss://` to an IP address or a `.local` name, with custom
  trust handling.
- **The container shell stays behind.** Deleting `~/Library/Containers/com.alexecollins.agents.spike.s2`
  removed `Data/`. `.com.apple.containermanagerd.metadata.plist` is protected ("Operation not
  permitted"), so it needs removing from Finder or by containermanagerd.

## What was built

- `cert/`: the self-signed ECDSA P-256 certificate. CN and SAN are `Alexs-MacBook-Air.local`,
  and the SAN also has IP `127.0.0.1`. Also `key.pem`, and `wrong-key.pem`, an unrelated key for
  the wrong pin. These came from the earlier, cut-off run.
- `server/`: a SwiftPM executable `S2Server` built on swift-nio (`NIOWebSocket`, `NIOHTTP1`) and
  NIOSSL.
  - It serves `wss://[::]:<port>/v1/connect`, dual stack.
  - On each text frame it logs the line and answers one line.
  - On start it prints the SPKI SHA-256 pin, in base64url with no padding. It computes this with
    `extractPublicKey().toSPKIBytes()` and CryptoKit SHA256.
  - It was kept from the earlier run. This run added the pin print.
- `client/`: `main.swift`, `Info.plist`, `S2Client.entitlements` and `build.sh`, which builds
  `client/build/S2Client.app`.
  - The bundle id is `com.alexecollins.agents.spike.s2`, and `LSUIElement` is set.
  - `NSBonjourServices` is `[_agents-control._tcp]`, and `NSLocalNetworkUsageDescription` is set.
  - The entitlements are only `app-sandbox` and `network.client`.
  - The client uses `URLSessionWebSocketTask` with a `URLSessionWebSocketDelegate`. The delegate
    takes the leaf from `SecTrustCopyCertificateChain` and computes the SPKI SHA-256. If it
    matches the pin, the delegate calls `useCredential`. Otherwise it calls
    `cancelAuthenticationChallenge`.
  - Each network step has a 20 s timeout, and the whole run has a 58 s hard cap.
  - It logs to stdout and to `<container>/Data/s2-client.log`.
- `logs/`: the server, dns-sd, both client runs and the log copied out of the container.

## Commands

```sh
cd specs/058-control-plane/spikes/s2-sandbox-ws
(cd server && swift build)
client/build.sh      # swiftc -O; codesign --force --sign - --entitlements S2Client.entitlements --options runtime; codesign -d --entitlements -
# codesign -d --entitlements - showed exactly app-sandbox=true, network.client=true; flags=0x10002(adhoc,runtime)

# pin cross-check with openssl (matches the server's own print):
openssl x509 -in cert/cert.pem -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='   # lklbR2Vetu2K7unZQaxWKvokpS5yRzKtUGxgu78bB2A
openssl pkey -in cert/wrong-key.pem -pubout -outform der \
  | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='   # IqqPkAymSO7MUOc3ZSxZJF4_iheQyjXglyhADzQ0tZo (wrong pin)

server/.build/debug/S2Server cert/cert.pem cert/key.pem 8797 &          # prints the pin, listens on [::]:8797
dns-sd -R "S2 spike" _agents-control._tcp local 8797 v=1 &

client/build/S2Client.app/Contents/MacOS/S2Client \
  lklbR2Vetu2K7unZQaxWKvokpS5yRzKtUGxgu78bB2A IqqPkAymSO7MUOc3ZSxZJF4_iheQyjXglyhADzQ0tZo 8797 Alexs-MacBook-Air.local
client/build/S2Client.app/Contents/MacOS/S2Client \
  lklbR2Vetu2K7unZQaxWKvokpS5yRzKtUGxgu78bB2A IqqPkAymSO7MUOc3ZSxZJF4_iheQyjXglyhADzQ0tZo 8797 192.168.0.238
# each run exited 0 in under 3 s

kill <server pid> <dns-sd pid>; rm -rf ~/Library/Containers/com.alexecollins.agents.spike.s2
```

## For research R6–R8

- R7 holds: `URLSessionWebSocketTask`, a pin delegate and `network.client` are enough in the
  sandbox.
- R8 holds: `NWBrowser` works with `NSBonjourServices` and no extra entitlement.
- R6 should pin the key type to P-256, or the app needs a DER parser.
- R8 should note that the pin makes the certificate's names irrelevant. Adding a Tailscale name
  needs no new certificate.
  - *Corrected 2026-09-30:* true for our pin check, not for App Transport Security. ATS
    refuses a self-signed certificate at a fully qualified name such as `*.ts.net`, even with
    the pin accepted. IP addresses and `.local` names, which this spike dialled, are exempt.
    See research R8 ("Extra addresses for Agents Host") and R15.
- The walk still missing is a Finder-launched build dialling another machine, to see the Local
  Network prompt and what a denial does.
