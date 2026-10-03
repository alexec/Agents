# Security pass: a control plane on the public internet (#61)

2026-10-02. Written before the first real cloud machine, from the code at `445e15d1` plus
the T128 change on `agents/move-github-issue-61`. It covers `deploy/compose.public.yaml`
behind Caddy with a Let's Encrypt certificate (R15), the move between machines (R16), and
what #60's webhooks (`specs/research/060-webhooks-as-events.md`) will add. The earlier
review of the code itself is `walks/security-review.md` (T102); this one is about the
**exposure**: what changes when anyone on the internet can open a socket to it.

## Summary

- **Authentication holds up.** Nothing below lets a stranger in. Every member, code and
  copy proves a key before anything is answered (R6), and TLS is the ordinary public kind.
- **What's missing is limits.** Nothing caps connections, auth attempts or store reads
  per source. On a bucket, a stranger can make the control plane read the store over and
  over, which costs money as well as time. These are the items to fix before Alex's own
  machine goes up (T131): **P1 to P3** below.
- **One handover gap.** A forwarding copy forgets that it's forwarding when it restarts,
  and comes back serving its old records (**P4**).
- **#60 adds the first unauthenticated write path.** Its signature, replay, size and
  prompt-injection rules are already in the 060 note. This pass adds what the control
  plane itself has to provide for them (**W1 to W4**).

## 1. What is exposed

`compose.public.yaml` publishes only Caddy, on 80 and 443. Caddy's admin API is off.
Everything else reaches `agents-control` on 8791 through `reverse_proxy`.

| Path | Who can use it | What it gives |
|---|---|---|
| `GET /healthz` | anyone | `ok`. |
| `GET /readyz` | anyone | Whether the store can be reached. Tells a stranger when the bucket is down. |
| `GET /v1/install.sh` | anyone | The host install script (public, no secrets). |
| `GET /v1/servers/<file>` | anyone | The Linux `agentsd` builds. Public, but they name the exact version. |
| WebSocket upgrade, then R6 | anyone can open one | Before proving anything, the server's `hello`: its **name**, its **public key**, a nonce and its **copy id**. |
| R6 as `c:` client, `h:` host | holders of a member key | The member's grant, as on the LAN. |
| R6 as `p:` / `e:` code | holders of a live code | One pairing or enrolment. Codes last 5 minutes and are 128 random bits plus a tag keyed by the control key. |
| R6 as `x:` copy, `x:handover-…` | holders of the **control key** only | The copy mesh, and every handover step: freeze, forward, `store/get` of every record. |
| Port 80 | anyone | Caddy's redirect to https, and the HTTP-01 challenge. |

Not exposed: the web remote (071) listens on loopback only, and the container isn't given
`--web`. Bonjour isn't advertised in a container.

**Why ACME sits in Caddy, not in `agents-control`.** R15 chose Caddy's own ACME client:
TLS-ALPN-01 on 443 by default, with HTTP-01 on 80 as its fallback. Either works for a
machine with a public address and those two ports open, which is what the how-to asks
for. DNS-01 would be needed only for a machine the internet can't reach on 80 or 443, or
for a wildcard. It also means giving the machine API credentials for Alex's DNS provider,
a far stronger secret than anything else on the box. Building ACME into `agents-control`
would duplicate what Caddy does, renewal and OCSP included. It would also put ACME account
keys in the store's process. The Pebble walks (`walks/public-cert.md`) prove the Caddy
path end to end, and the apps trust the result through the system's roots, with no pin
(R15). Pairing isn't weakened: R6 still proves the control key carried in the code, so
TLS only has to stop a relay in the middle, which a public certificate for the name does.

## 2. Authentication

What holds:
- **R6 on every socket.** The server's MAC proves the control key to the member, and the
  member's MAC proves its own key. Both are bound to the origin dialled, so a captured
  exchange can't be replayed at another address (`verify(origins:)`).
- **The endpoints list** (R16) arrives only inside an `ok` that has proved the control
  key. Nobody else can redirect a member, not even with a valid certificate for another
  name.
- **Codes** are one-time (a `.spent` record, first writer wins), last 5 minutes, and are
  refused while a copy is frozen or forwarding.
- **Grants** come from the stored record, never from the client (T102).
- **Handover and copy identities** need the control key itself. Whoever holds that key
  already *is* the control plane, so it's the one secret on the machine that matters:
  `deploy/secrets/control-key`, mode 0600, mounted as a compose secret.

Risks that remain:
- **A1. The control key on a rented machine.** The provider, a snapshot or a backup of the
  disk holds it. Use a provider with encrypted disks, keep the secret out of image
  snapshots, and never bake it into an image. Rotating it means every member pairs again,
  so losing it is the expensive case. (Decided in R16: it goes by hand, once.)
- **A2. The `hello` says who it is.** Name, public key and copy id go to anyone who opens
  a socket. The name is usually the domain anyway, and the public key is public by design.
  The copy id tells a scanner how many copies run. Low; leave it.
- **A3. Version disclosure** in `/v1/servers/` and the install script. Low; leave it.

## 3. Rate limits and resource use

Nothing limits per source today. Each socket gets 15 seconds to send `auth`; frames are
capped (`maxMessage`), and the listen backlog is 256. Caddy's stock image has no
`rate_limit` directive. That needs the `caddy-ratelimit` module, built with `xcaddy`.

- **P1. A stranger can make the control plane read the whole store.** In `key(for:)`, an
  unknown client or host id calls `readAgain()`, which is `methods.refresh()`: a LIST and
  GETs over the records. That runs *before* the MAC is checked, for any id the stranger
  makes up. On a bucket every attempt is billed S3 requests, and a few hundred a second
  is a real bill, and a slow control plane for everyone. *Fix:* coalesce `readAgain` (one
  refresh at a time, and at most one every few seconds, whatever the number of callers).
  An unknown id within that window is then answered from memory.
- **P2. A code id costs one or two store GETs** (`codes.stored`), also before the MAC.
  The id has to be well formed, but any 16 bytes are. *Fix:* check the id's tag first.
  The id is random, and the secret is the id plus an HMAC of it under the control key.
  That needs the tag in the id, a change to code version 2. Or a per-source budget (P3)
  covers it.
- **P3. No per-source limits.** Open sockets, failed `auth`s and requests per address
  are all unbounded. *Fix, in this order:*
  1. In `agents-control`, a small table keyed by the source address that Caddy passes in
     `X-Forwarded-For`, trusted only from the proxy. Cap failed proofs (say 20 a minute,
     then refuse for a minute) and sockets still waiting for `auth` (say 50).
  2. Caddy: `request_body max_size` on every route (the built-in directive), and
     `rate_limit` from the module for `/v1/hooks/*` once #60 lands.
  3. The provider's firewall: only 80 and 443 open, and ssh by key from Alex's addresses,
     or through Tailscale.
- **P4. A forwarding copy forgets it's forwarding.** The phase is held in memory
  (`PhaseBox`). If Agents Host's control launch agent restarts after Move to Another
  Machine… (a crash, a reboot, an update), the copy comes back **serving its frozen
  folder store**, writable, at the old address. Members that already moved don't go
  there. One that missed the announce does, and it is served from a store that has
  stopped changing: a split. On a bucket the restarted copy serves live records, so
  nothing splits, but it is still a second front door Alex thinks is closed. *Fix:* the
  launcher passes `--forward-to <movedTo> --forward-until <date>` while Agents Host's
  settings say it's forwarding, and the copy starts frozen and forwarding. The same
  applies to the cloud copy after Run It Here Again…, through the environment. Tracked
  for T129.
- **P5. Forwarding is public for 30 days.** The old address keeps answering any member
  that proves itself, and only with the new list. That's no more than it gave before the
  move. When the old address is a `.local` name it isn't public anyway.

## 4. Logs and secrets

- T102 found nothing secret logged on the key's delivery. `control.log` and the
  container's output carry member names and ids, and the addresses announced. A full
  check that no code, MAC or signature header reaches a log belongs with W1, before
  anything logs request bodies.
- `deploy/.env` may now hold `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for a bucket
  store (T128). It's the same class as the control key: 0600, never committed (`deploy/`'s
  `.gitignore` already covers `secrets/` and `.env`). Better still, use an instance role
  where the provider has one, so no key is on disk at all.
- The bucket's keys should allow only the store's prefix: `GetObject`, `PutObject`,
  `DeleteObject` and `ListBucket` on that prefix, nothing else.

## 5. Notifications without a Mac

Today notices go out through `agents-relay`, on a Mac host, into the person's CloudKit
mailbox (R10). A cloud control plane with no Mac host sends none. Doing without the Mac
means the control plane posts to APNs itself, which adds a secret and a surface:
- **The APNs key** (`.p8`, from Alex's Apple developer account) lives on the cloud
  machine, beside the control key. It can push to every install of the app, not only
  Alex's. Scope it to the one app id, and keep it as a compose secret.
- **What the push carries.** Today's notice text is sealed to the devices. An APNs alert
  is readable by Apple and shows on a locked screen. Send a generic alert with the sealed
  payload, opened by a Notification Service Extension on the device. Never send
  plaintext headlines.
- **Device tokens** become records (one per device client), written only by that client
  over its own R6 session.
- This needs Alex's APNs key and a choice of approach, so it waits on him (#61's open
  item).

## 6. What #60's webhooks add

The 060 note already covers signatures over the raw body, replay by body hash, Slack's
timestamp window, the `from` default, and fencing outside text. What the control plane
has to provide for them:
- **W1. The first path that answers a stranger with a write.** `/v1/hooks/<source>/<id>`
  must live in its own handler, before any R6 code, and touch the store only after the
  signature checks. An unknown hook id must cost nothing more than a known one with a
  bad signature: same work, same timing, 404.
- **W2. Limits first.** P3's per-source budget and Caddy's `request_body max_size 1MB`
  must be in place before the route is. GitHub retries, so dropping is safe.
- **W3. Secrets.** Webhook signing secrets are per hook, made by the control plane and
  shown once. They're kept in the store *encrypted under a key derived from the control
  key*, not in plaintext records: the store is the thing most likely to be shared (a
  bucket) or copied (a handover).
- **W4. Holding for offline hosts** means the store grows with outside input. Cap the
  queue per host (count and age), and drop the oldest with an event saying so.
- **W5. Handover.** Hooks are records, so they move with the store. The webhook URL is the
  public domain. Moving to Agents Host on a `.local` name breaks every hook, so Run It
  Here Again… must warn when hooks exist.

## 7. Order of work

1. P4 (forwarding survives a restart): part of T129, since its walk restarts copies.
2. P1, then P3's in-process budget: before T131, Alex's own machine.
3. The provider's firewall and the bucket policy: in the how-to, at T131.
4. W1 to W5: with #60's first slice, after T131.
5. P2 and §5: when codes next change, and once Alex has decided about APNs.
