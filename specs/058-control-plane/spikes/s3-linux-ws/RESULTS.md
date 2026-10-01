# Spike S3 — the Linux host dialer (058, R7, T023)

Run 2026-09-28 on Alex's Mac (Apple silicon), Colima Docker (aarch64 Linux VM).

## What was built

A standalone SwiftPM package (`Package.swift` here; not linked into anything else):

| Product | What it is |
|---|---|
| `ws-dial` | The dialer being measured. swift-nio `NIOPosix` + `NIOHTTP1` + `NIOWebSocket` (client upgrade via `addHTTPClientHandlers(withClientUpgrade:)` + `NIOWebSocketClientUpgrader`) over `NIOSSL`. **No swift-crypto, no Foundation.** Dials `wss://`, sends one text line (`{"h":"spike-s3","m":"hello from ws-dial"}`), prints the one line that comes back, closes. `--ca <root.pem>` or `--pin <sha256 hex of SPKI>`. |
| `ws-echo` | Test server, own Linux build (same package, same SDK). WebSocket echo (`{"echo":<text>}`) on any path; plain `ws://`, or `wss://` with `--tls cert key`. |
| `print-base` | `print("print-base")`, the size baseline. |
| `print-foundation`, `ws-dial-foundation` | The same two with Foundation linked and kept live, because the real `agentsd` links Foundation (see Sizes). |

Versions: swift-nio 2.103.0, swift-nio-ssl 2.37.5, toolchain swift-6.4.0-RELEASE, SDK
`swift-6.4.0-RELEASE_static-linux-0.1.0` (`aarch64-swift-linux-musl`).

The pin's SHA-256 is a 50-line pure-Swift SHA-256 (`Sources/WSDial/SHA256.swift`). The real
dialer would reuse the pure-Swift hash beside `ControlAgreement`.

## Commands

```sh
cd specs/058-control-plane/spikes/s3-linux-ws
TC=~/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/bin/swift
$TC build -c release --swift-sdk aarch64-swift-linux-musl -Xswiftc -gnone -Xlinker -s
B=.build/out/Products/Release-staticlinux-aarch64     # file: "statically linked … stripped"
mkdir -p run && cp $B/{ws-dial,ws-echo,print-base} run/

# self-signed certificate for (b) and its pin (SHA-256 of the DER SubjectPublicKeyInfo)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj "/CN=s3-spike-pinned" -keyout run/pinned.key -out run/pinned.crt
openssl x509 -in run/pinned.crt -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -hex | awk '{print $NF}' > run/pin.txt

R=$PWD/run
docker network create s3-spike
docker run -d --name s3-spike-echo   --network s3-spike -v $R:/s3:ro debian:bookworm-slim /s3/ws-echo 8080
docker run -d --name s3-spike-pinned --network s3-spike -v $R:/s3:ro debian:bookworm-slim \
  /s3/ws-echo 8443 --tls /s3/pinned.crt /s3/pinned.key
docker run -d --name s3-spike-caddy  --network s3-spike -v $R/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2
docker run -d --name s3-spike-runner --network s3-spike -v $R:/s3:ro debian:bookworm-slim sleep infinity
docker cp s3-spike-caddy:/data/caddy/pki/authorities/local/root.crt $R/caddy-root.crt

docker exec s3-spike-runner /s3/ws-dial wss://s3-spike-caddy/v1/connect --ca /s3/caddy-root.crt        # (a)
docker exec s3-spike-runner /s3/ws-dial wss://s3-spike-caddy/v1/connect --ca /s3/pinned.crt            # (a) wrong root
docker exec s3-spike-runner /s3/ws-dial wss://s3-spike-pinned:8443/v1/connect --pin $(cat $R/pin.txt)  # (b)
docker exec s3-spike-runner /s3/ws-dial wss://s3-spike-pinned:8443/v1/connect --pin 000…000 (64 zeros)  # (b) wrong pin

docker rm -f s3-spike-echo s3-spike-pinned s3-spike-caddy s3-spike-runner; docker network rm s3-spike
```

`run/Caddyfile` is kept (`tls internal`, `reverse_proxy s3-spike-echo:8080`); Caddy proxies
the WebSocket upgrade with no extra configuration. The binaries, key, certificates and pin
were deleted after the run (no test keys in the tree).

## Results

| Case | Result | Output |
|---|---|---|
| (a) through Caddy `tls internal`, client trusts only Caddy's root (`Caddy Local Authority - 2026 ECC Root`), full verification incl. hostname | **PASS** | `received {"echo":{"h":"spike-s3","m":"hello from ws-dial"}}`, exit 0; echo server logged `upgrade /v1/connect` and the line |
| (a) wrong root | **PASS (rejected)** | `handshakeFailed(… CERTIFICATE_VERIFY_FAILED)`, exit 1 |
| (b) self-signed P-256 server, pin by SPKI SHA-256 | **PASS** | `server SPKI sha256 7a962f73…8372` (matches openssl), line echoed, exit 0 |
| (b) wrong pin rejected | **PASS** | callback returns `.failed` → `handshakeFailed(… CERTIFICATE_VERIFY_FAILED)`, exit 1; server never received a line |

What worked for the pin: `certificateVerification = .noHostnameVerification`,
`trustRoots = .certificates([])`, and `NIOSSLClientHandler(context:serverHostname:customVerificationCallback:)`
whose callback hashes `certificates.first!.extractPublicKey().toSPKIBytes()`. The callback
replaces BoringSSL's chain check (a self-signed leaf with an empty trust store passes when the
pin matches). One snag: with the default `trustRoots` (`.default`), `NIOSSLContext` init
**fails with `unknownError([])` on a box without `ca-certificates`** (debian:bookworm-slim),
because it tries to load the system store. The pinned path must set an explicit (empty) trust
store; the public-CA path on a real host needs the system roots installed, or bundled roots.

## Sizes (stripped by the linker, `-Xlinker -s`; `file` says "statically linked, stripped")

| Binary | Bytes | Over its baseline |
|---|---:|---:|
| `print-base` | 5,786,992 | — (same as S1's baseline) |
| `ws-dial` (NIO + HTTP1 + WebSocket + NIOSSL) | 11,652,464 | **+5,865,472 (5.6 MiB)** |
| `print-foundation` | 54,016,960 | Foundation alone: +48,229,968 |
| `ws-dial-foundation` | 59,026,368 | **+5,009,408 (4.8 MiB)** over `print-foundation` |
| `ws-echo` (server, for reference) | 11,631,984 | |

So the dialer costs about 5–6 MB. Against an `agentsd` that already links Foundation (and some
NIO pieces, if any), the growth is about 5 MB.

## R7's size guess

R7 guessed "NIOSSL alone is roughly half" of S1's 51.5 MB (~25 MB). **It does not hold.**
NIOSSL with NIO, HTTP/1 and WebSocket adds ~5.9 MB to a bare binary and ~5.0 MB to a
Foundation one. S1's PSKDial imported Foundation, and Foundation alone adds 48.2 MB here, so
S1's 51.5 MB was almost all Foundation, not BoringSSL (inferred; S1's binaries were not rebuilt).
