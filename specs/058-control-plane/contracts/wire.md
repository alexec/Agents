# Contract: the wire (re-plan)

## Transport

- **One endpoint:** `wss://<url>/v1/connect`, an HTTP/1.1 upgrade to a WebSocket. Every client,
  host, relayed device and peer copy uses it.
- **One line per message.** Every WebSocket text message is one JSON object, which is one line
  of the first build's wire. No binary messages.
- **Other endpoints:**
  - `GET /healthz` answers 200 while the process runs;
  - `GET /readyz` answers 200 once the store has answered a read, and 503 otherwise, so a load
    balancer stops sending new connections to a copy that cannot reach its store.
- **TLS.** Either the copy terminates TLS itself with NIOSSL (the host app's single copy, with
  a self-signed certificate), or the load balancer terminates it. Clients check a publicly
  trusted certificate normally, or the `pin` from their code or config (research R6). A pin is
  mandatory when the certificate is not publicly trusted.
- **Keep-alive.** WebSocket ping every 20 s. Two missed pongs close the socket.
- **Size.** A message is at most 64 MB (`LineSplitter`'s cap).

## The key exchange (research R6)

Three messages open every socket. Nothing else is accepted until the server's `ok`.

```jsonc
// 1. server
{"hello":{"v":1,"name":"Alex's control plane","control":"<base64url X9.63>","nonce":"<32 B b64url>","copy":"<copy-id>"}}
// 2. peer
{"auth":{"id":"c:<uuid>","nonce":"<32 B>","mac":"<b64url HMAC-SHA256>","kind":"mac|iphone|ipad|host|relay|copy","for":"<device uuid, relay only>"}}
// 3. server
{"ok":{"mac":"<b64url>","grant":"operator|device","host":"<host id, hosts only>","relayed":false}}
{"refused":{"reason":"unknown|forgotten|expired|spent|bad-proof|wrong-control-plane"}}
```

- **Transcript.** `T = "agents-auth-v1" | sn | pn | id | origin`, where:
  - `sn` and `pn` are the raw nonces;
  - `id` is the identity string;
  - `origin` is the dialled URL's scheme, host and port, lowercased.
- **The two MACs.** Each side proves itself with an HMAC over `T` under the key K below, with a
  different tag first:
  - the peer's is `HMAC(K, "c" | T)`;
  - the server's is `HMAC(K, "s" | T)`.

| Identity | K |
|---|---|
| `c:<uuid>`, a client | `clientKey`: HKDF(ECDH(control, client), `agents-control-client-v1`, uuid), as the first build's `ControlKeys` |
| `h:<id>`, a host | `hostKey`: HKDF(ECDH(control, host), `agents-control-host-v1`, id), as today |
| `p:<id>`, a client code | `codeKey(secret)`. The secret is the code's 16-byte id and a 16-byte tag, HMAC under a key from the control plane's private key, so any copy can make it again from the id; `id` is the hex of those 16 bytes |
| `e:<id>`, a host code | the same, for a host |
| `x:<copy-id>`, a peer copy | HKDF(control private key, `agents-copy-v1`, "") |

**After `ok` with a code identity**, the new party sends one line:
```jsonc
{"m":{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":{"id":"<uuid>","publicKey":"…","name":"…","kind":"iphone"}}}
```
or `hosts/announce`. The reply carries the record. The socket then closes, and the party
reconnects with its own identity. Using the code creates `codes/<id>.spent` first (store.md),
so a second use is `refused: spent`.

**A relayed device.** `agents-relay` opens the socket with `kind: relay` and `for: <device>`,
and passes messages 1–3 between the device and the control plane through CloudKit unchanged.
The device computes the MAC. The session is marked `relayed`, and today's away limits apply.

## Client ⇄ control plane (unchanged from the first build)

```jsonc
{"h":"mac","m":{"jsonrpc":"2.0","id":7,"method":"agents/list","params":{}}}   // to a host
{"m":{"jsonrpc":"2.0","id":8,"method":"hosts/list"}}                          // to the control plane
{"h":"k3v9x0qa","m":{…reply or notification…}}                                // from a host
{"m":{"jsonrpc":"2.0","method":"control/hostChanged","params":{…}}}           // from the control plane
```

These rules are kept as they are:
- grant check on `m.method` only;
- `hostOffline` at once;
- the client's request ids, never rewritten;
- `h` on everything from a host.

The legacy bare line goes to the home host only while a moved set-up still has old clients
(research R11).

## Control plane ⇄ host (unchanged from the first build)

```jsonc
{"c":3,"open":{"grant":"operator","client":"6f1c…"}}
{"c":4,"open":{"grant":"device","client":"a2e0…","device":"a2e0…","relayed":true}}
{"c":3,"m":{…}}
{"c":3,"close":true}
{"c":0,"m":{…}}          // host/hello, attention/need, control/ping
```

`relayed` is new: the host applies today's away limits on that channel. Channel numbers are
unique for one uplink's life. Losing the uplink closes every channel, and the host redials any
copy.

## Copy ⇄ copy (the peer link)

After the key exchange with identity `x:<copy-id>`:

```jsonc
// a proxied uplink: B asks A (the holder) to carry B's channels to host H
{"p":"H","c":12,"open":{"grant":"device","client":"…","device":"…"}}   // B → A
{"p":"H","c":12,"m":{…}}                                                // both ways
{"p":"H","c":12,"close":true}                                           // either way
{"p":"H","gone":{"epoch":8}}          // A → B: A no longer holds H (lease lost or uplink closed)
// changes and presence
{"event":{"kind":"clientForgotten","subject":"6f1c…","at":"…","by":"…"}}
{"presence":{"client":"…","state":"active|away","at":"…"}}
{"host":{"id":"H","state":"online","epoch":8}}                          // holder → everyone
```

- **B's channel numbers** (`c`) are B's own. A maps each `(B, c)` pair to a fresh channel on
  H's real uplink, and back.
- **When B receives `gone`,** it marks its proxied session for H closed, and re-reads the lease
  to find the new holder. Clients see `hostChanged` only if no copy holds H within 5 s.
- **A peer link dropping** closes every stream on it. Each copy redials the other while both are
  registered (`copies/`).
