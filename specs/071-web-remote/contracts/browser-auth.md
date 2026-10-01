# Contract: a browser on the wire

The browser speaks 058's wire ([wire.md](../../058-control-plane/contracts/wire.md)) unchanged.
This contract covers only what is specific to it. Research R4, R5.

## Origin

`O = "http://localhost:<port>"`, the loopback listener's canonical origin. The server takes it
from the listener the socket arrived on, never from the request. A transcript bound to `O`
fails on the TLS listener, and the other way round.

## Pairing with a code

The code text is unchanged:
`agents-control:2:c:<grant>:<key>:<secret>:<url>:<pin>:<name>`. The browser uses `key` and
`secret`, ignores `url` and `pin`, and shows `name` on the pairing screen once paired.

```jsonc
// server
{"hello":{"v":1,"name":"Alex's control plane","control":"<key'>","nonce":"<sn>","copy":"…"}}
// browser: if key' ≠ key → stop, say "This code is for another control plane", send nothing
{"auth":{"id":"p:<hex(secret[0..<16])>","nonce":"<pn>","mac":"<HMAC(codeKey(secret), "c"|T)>","kind":"browser"}}
// server
{"ok":{"mac":"<HMAC(codeKey(secret), "s"|T)>","grant":"device"}}     // browser verifies, else stops
// browser: make the key, store it, read it back, check extractable === false
{"m":{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":{"id":"<uuid>","publicKey":"<b64 X9.63>","name":"Safari","kind":"browser"}}}
// server
{"m":{"jsonrpc":"2.0","id":1,"result":{"client":{…ClientRecord, "name":"Safari on Alex's MacBook","kind":"browser"…},"controlKey":"…","grant":"device"}}}
// server closes; the browser reconnects as c:<uuid>
```

- `T = "agents-auth-v1" | sn | pn | id | O`. Nonces are raw bytes, the rest is UTF-8.
- `codeKey(s) = HKDF-SHA256(ikm: s, salt: "agents-control-code-v1", info: "", 32)`.
- What the page says for each refusal:

  | `refused.reason` | The page says |
  |---|---|
  | `expired` | This code has expired. Get a new one. |
  | `spent` | This code has been used. Get a new one. |
  | `unknown`, `bad-proof` | That isn't a code from this control plane. |
  | `wrong-control-plane` | This code is for another control plane. |

  A code that does not parse never opens a socket: "That isn't an Agents code."
- If the browser makes or reads back its key and finds `extractable !== false`, it deletes the
  key and the database, and sends nothing more. The page says the browser isn't supported.

## Connecting with its key

```jsonc
{"hello":{…,"control":"<key'>",…}}   // key' must equal the stored control, else stop: "not the control plane this browser paired with"
{"auth":{"id":"c:<uuid>","nonce":"<pn>","mac":"<HMAC(K, "c"|T)>","kind":"browser"}}
{"ok":{"mac":"<HMAC(K, "s"|T)>","grant":"device|operator"}}
```

- `K = HKDF-SHA256(ikm: ECDH_x(browserPrivate, control), salt: "agents-control-client-v1", info: uuid, 32)`.
- **The UUID is upper case** everywhere: in `clients/announce`'s `id`, in `c:<uuid>` and in HKDF's info, as Swift's `uuidString` writes it. The browser upper-cases `crypto.randomUUID()` once, at pairing, and stores it that way (spike S1: a lower-case UUID gives a different MAC).
- In WebCrypto: `deriveBits({name:"ECDH", public: control}, privateKey, 256)`, then
  `importKey("raw", bits, "HKDF", false, ["deriveKey"])`, then
  `deriveKey({name:"HKDF", hash:"SHA-256", salt, info}, …, {name:"HMAC", hash:"SHA-256", length:256}, false, ["sign","verify"])`.
- `ok.grant` is stored and shown. A grant change (FR-013, scenario 7) shows on the next
  connection, and every call is judged by the current grant whatever the page shows.

## Closing

| Close | Meaning to the page |
|---|---|
| code `4403`, reason `forgotten` | Forgotten. Delete the key, tell other tabs, show **This browser was forgotten**. |
| `refused: forgotten` or `refused: unknown` on `c:` | The same. |
| Any other close, error or ping timeout | Down. Grey out, keep the draft, reconnect with backoff (1, 2, 4, 8, then 10 s at most, plus jitter up to 20%; SC-009 needs at most 5 s once the server is back, so the cap is 10 s and a `visibilitychange` to visible retries at once). |

The control plane sends `4403` to every session of a client when `clients/forget` or
`clients/forgetSelf` forgets it, on any copy (058's broadcast `clientForgotten`). This is new
for all client kinds, and harmless for the window and the Remote, which treat any close as a
drop and then get `refused`.

## `clients/forgetSelf` (new)

| Method | Grant | Params → Result |
|---|---|---|
| `clients/forgetSelf` | any paired client | `{}` → `{}`. It forgets the calling client only, and refuses with `lastOperator` (-32092) if that client is the last operator. Then every session of the client is closed with 4403, the reply first. |

It is added to `contracts/control-api.md`'s table in 058 when this lands, and to
`WebSignatures` as a `controlRequest`.

## Tests

- `ControlServiceTests` (Swift):
  - a browser pairs and reconnects through the loopback listener;
  - its proof fails on the TLS listener;
  - a TLS client's proof fails on the loopback listener;
  - `kind: browser` is refused through TLS, and `kind: iphone` through loopback;
  - `forgetSelf` works for a device and is refused for the last operator;
  - forgetting closes with 4403 within 2 s;
  - two sockets of one browser both work, and both close on forget.
- `ControlAgreementVectorTests` (Swift) writes `Web/test/vectors.json`. It is checked in, and
  the test fails when the file differs.
- `Web/test/auth.test.mjs` runs the browser's exchange against the vectors, and against a fake
  server for each refusal and each close.
