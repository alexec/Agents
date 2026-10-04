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
- **Backpressure (#167).** Each end holds at most 8 MB for the other to read (32 MB on a host's
  uplink). A write past that, or bytes waiting 10 s with none sent, closes the socket with code
  4008 `too slow`; the other end reconnects and reads everything afresh. What arrives is read
  only while the reader keeps up: past 4 MB unread the socket stops being read until it is down
  to 1 MB, so TCP pushes back on the sender.
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

**A relayed device (T096).** `agents-relay` opens a socket of its own to the control plane's
address, with the pin, for each device session it carries, and proves nothing on it. It passes
every line between the device and the control plane through CloudKit unchanged, messages 1–3
first. The device computes the MAC and says `kind: relay` and `for: <its own id>` in its
`auth`. The control plane refuses `badMessage` when `for` is not the identity proving itself,
or when that client is not a device. Otherwise its `ok` says `relayed: true` and the session
is marked `relayed`. The relay carries one session per device at a time, so a device reaches
only its home host while relayed; the Remote's second, wrapped connection waits for the address.

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
{"f":[3,4,9],"m":{…}}    // host → control: one notification for channels 3, 4 and 9 (#167)
```

`fanOut` in an `open` (`"fanOut":true`) says the control plane reads `f` frames. A host then
says each broadcast once, naming every channel opened that way that should hear it (the host's
own filter, per connection, as before), and the control plane copies it to each. Only
notifications go this way. A control plane that leaves `fanOut` out is written to channel by
channel, as before. Between copies, a holder hands a peer its part channel by channel.

`relayed` is new: the host is told the channel came through the relay. It has no away limits
of its own today; the Remote keeps a relayed prompt's attachments under a record's size (046).
Channel numbers are unique for one uplink's life. Losing the uplink closes every channel, and
the host redials any copy.

**A relay host** (`agents-relay`, `HostRecord.relay` set) is never sent `open`. On its channel
0 it hears two notifications, which it never answers:

```jsonc
{"c":0,"m":{"jsonrpc":"2.0","method":"relay/devices","params":{"devices":[{"id":"…","publicKey":"<b64 X9.63>"}]}}}
{"c":0,"m":{"jsonrpc":"2.0","method":"relay/deliver","params":{"needID":{…},"device":"…","publicKey":"…","headline":{…},"alert":true}}}
```

`relay/devices` is every device client and its key: the devices whose zones it may read and
whose frames it may open (FR-008). It is sent when the relay says hello, when a client pairs
or is forgotten, and at every 15 s re-list. `relay/deliver` is one mailbox item: the relay
seals `headline` to `publicKey` and posts it for `device`. No `headline` is a withdrawal.

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
{"need":{"need":{…},"headline":{…},"buzz":true}}                        // T097: to the copy holding the relay host
{"host":{"id":"H","state":"online","epoch":8}}                          // holder → everyone
```

- **B's channel numbers** (`c`) are B's own. A maps each `(B, c)` pair to a fresh channel on
  H's real uplink, and back.
- **When B receives `gone`,** it marks its proxied session for H closed, and re-reads the lease
  to find the new holder. Clients see `hostChanged` only if no copy holds H within 5 s.
- **A need** is sent to every peer by a copy that holds no relay host. The copy that holds one
  chooses the device and delivers it; the others drop it. Pairing and enrolling are announced
  to the peers at once (`clientPaired`, `hostEnrolled`), so the relay's copy knows the device
  and every copy knows not to open channels on a new relay host.
- **A peer link dropping** closes every stream on it. Each copy redials the other while both are
  registered (`copies/`).
