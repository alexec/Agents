# Security pass: a control plane on the public internet (#61)

**2026-10-18, the Go `agents-control` (#1457).** #1314 removed the Swift control plane this
pass was written for. Each finding was checked again against `Go/internal/controlplane`,
`Go/cmd/agents-control` and `deploy/`. Where it stands now:

| Finding | Now | Test |
|---|---|---|
| P1 store read per unknown id | **Fixed.** One read at a time, at most one every 3 s, for the 15 s backstop too | `TestUnknownIDsReadTheStoreOnce`, `TestAMemberPairedElsewhereIsReadAgain` |
| P2 code id costs a GET | **Not fixed; P3 covers it.** A made-up code id is a failed proof, so a source has 20 a minute | `TestSourcesRefuseAfterTwentyFailedProofs` |
| P3 in-process budget | **Fixed.** Per-source table: 20 failed proofs a minute, then 429 for a minute; 50 sockets waiting for `auth` | `TestSourcesRefuseAfterTwentyFailedProofs`, `TestSourcesCapSocketsWaitingForAuth`, `TestSourcesHoldABoundedTable`, `TestForwardedForIsTrustedOnlyFromTheProxy`, `TestAStrangerIsRefusedAfterTwentyFailedProofs` |
| P3 Caddy | **Fixed.** `request_body max_size 1MB` on every site, in `Caddyfile.public` (the Pebble walk imports it) and `Caddyfile` | `TestEveryPublicRouteCapsItsBody` |
| P3 firewall | **Fixed, #2151.** Cloudflare's proxy and rate rules sit in front of `agentloops.dev` once Alex turns them on: `deploy/gcp/up.sh --cloudflare` locks the GCP firewall to Cloudflare's ranges, and `deploy/Caddyfile.public` trusts `CF-Connecting-IP` only from them. Self-hosted, with no Cloudflare, is unchanged | — |
| P4 forwarding after a restart | **Fixed before this pass** (a mark in the store, `resumeForwardingIfMarked`); now tested | `TestAForwardingCopyForwardsAfterARestart` |
| P5 forwarding is public for 30 days | Unchanged, by design | — |
| Logs | **Fixed.** A store error on a code named its key; it is no longer logged | `TestNoSecretReachesTheLog` |
| A1–A3, §5, W1–W5 | Unchanged: no code to check yet (no webhooks or APNs in Go) | — |

The sections below are the 2026-10-02 pass. Where they name Swift (`key(for:)`,
`readAgain()`, `PhaseBox`), the Go names are `Service.key`, `Service.readAgain` and
`phaseBox`, all in `Go/internal/controlplane/service.go` and `handover.go`.

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
  already *is* the control plane, so it's the one secret on the machine that matters.
  *Go, 2026-10-18 (#1458):* on the cloud machine Google Cloud KMS seals it in the store
  (`AGENTS_CONTROL_KMS=gcpkms://…`, `kms.Kept`), so it's never on the disk in clear. A
  control plane on a Mac keeps it in a 0600 file (`kms.File`, the default).

Risks that remain:
- **A1. The control key on a rented machine.** *Go, 2026-10-18 (#1458): sealed by Cloud
  KMS. What is left is the right to use the KMS key: a service account file on the disk,
  or none on a Compute Engine VM that runs as the service account. With the file, a copy
  of the disk and the store can still open the key until the file's key is removed in
  Google Cloud.* Before: the provider, a snapshot or a backup of the disk holds it. Use a provider with encrypted disks, keep the secret out of image
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

- **P1. A stranger can make the control plane read the whole store.** *Go, 2026-10-18:
  fixed.* `Service.key` read again at most once a second, but two reads could run at once.
  Now `readGate` runs one read at a time and at most one every 3 s (`readAgainEvery`). A
  caller that comes during a read waits for it and has its result. Within 3 s of a read, an
  unknown id is refused as unavailable from memory, and the member tries again. The 15 s
  backstop (`refresh`) goes through the same gate. `TestUnknownIDsReadTheStoreOnce`: 200
  made-up client and host ids make one read (two lists), and 200 more make none.
  *2026-10-02:* In `key(for:)`, an
  unknown client or host id calls `readAgain()`, which is `methods.refresh()`: a LIST and
  GETs over the records. That runs *before* the MAC is checked, for any id the stranger
  makes up. On a bucket every attempt is billed S3 requests, and a few hundred a second
  is a real bill, and a slow control plane for everyone. *Fix:* coalesce `readAgain` (one
  refresh at a time, and at most one every few seconds, whatever the number of callers).
  An unknown id within that window is then answered from memory.
- **P2. A code id costs one or two store GETs** (*Go, 2026-10-18: not fixed. P3 covers it:
  a made-up code id is refused, which is a failed proof, so one source has 20 GETs a
  minute. The tag in the id waits for code version 2.*) (`codes.stored`), also before the MAC.
  The id has to be well formed, but any 16 bytes are. *Fix:* check the id's tag first.
  The id is random, and the secret is the id plus an HMAC of it under the control key.
  That needs the tag in the id, a change to code version 2. Or a per-source budget (P3)
  covers it.
- **P3. No per-source limits.** *Go, 2026-10-18: 1 and 2 fixed, 3 is the how-to's.* *#2151: 3
  is also Cloudflare's own ranges now, for `agentloops.dev` (`deploy/gcp/up.sh --cloudflare`).*
  `sources.go` keeps a table keyed by the source address: the peer's, or the last
  `X-Forwarded-For` entry when the peer is in `AGENTS_CONTROL_TRUSTED_PROXIES`.
  `compose.public.yaml` gives Caddy a fixed address (172.30.61.250) on its own subnet and
  trusts only that. An IPv6 source counts by its /64. A source is refused with 429, before
  the WebSocket opens, when it has 50 sockets waiting for `auth`, or for a minute after 20
  failed proofs in a minute. A failed proof is any refusal before the MAC is proved, and a
  socket that says nothing in 15 s; a store that can't be read (`notTheirs`) is not. The
  table holds 4,096 addresses at most and lets idle ones go; when every one is busy, a new
  address goes uncounted, not refused. Caddy's `request_body max_size 1MB` is on every
  site. Requests are GETs, and WebSocket frames are capped by `agents-control` itself.
  The `rate_limit` module for `/v1/hooks/*` waits for #60.
  *2026-10-02:* Open sockets, failed `auth`s and requests per address are all unbounded.
  *Fix, in this order:*
  1. In `agents-control`, a small table keyed by the source address that Caddy passes in
     `X-Forwarded-For`, trusted only from the proxy. Cap failed proofs (say 20 a minute,
     then refuse for a minute) and sockets still waiting for `auth` (say 50).
  2. Caddy: `request_body max_size` on every route (the built-in directive), and
     `rate_limit` from the module for `/v1/hooks/*` once #60 lands.
  3. The provider's firewall: only 80 and 443 open, and ssh by key from Alex's addresses,
     or through Tailscale.
- **P4. A forwarding copy forgets it's forwarding.** *Go, 2026-10-18: fixed, and now
  tested.* `handover/forward` writes `handover/forwarding-<url>` in the store with the end
  time. `Start` reads it (`resumeForwardingIfMarked`) and comes back frozen and forwarding
  to the same list until the same time. `--no-forwarding` (`AGENTS_CONTROL_FORWARDING=0`)
  deletes the mark and serves. The mark is in the store, not in Agents Host's settings, so
  a container restart forwards too. `TestAForwardingCopyForwardsAfterARestart`.
  *2026-10-02:* The phase is held in memory
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
- **P6. Limits after a peer has paired (#2150).** *Go, 2026-10-21: fixed.* The numbers
  are in `limits.go`; `limits_test.go` tests each one.
  - **Timeouts.** Both listeners (the TLS one and the web listener) have `ReadTimeout`
    30 s, `WriteTimeout` 60 s, `IdleTimeout` 2 min and `MaxHeaderBytes` 64 KiB. A
    WebSocket clears the read and write deadlines before it opens, so the timeouts close
    a slow request, never a socket in use. A download of a server's build has 10 min to
    be written.
  - **Sockets.** A copy holds at most 1,024 WebSockets. Past that, `/v1/connect` is
    answered 503 before the socket opens. A client key holds at most 8 sessions, and one
    person's clients 32. Past either, the exchange is refused `unavailable`, and the
    client tries again with its back-off. At most 512 sockets from all addresses wait for
    `auth` at once, also those that the full table of addresses does not count.
  - **Message size.** Until a socket proves a key, it reads messages of 64 KiB at most.
    After that, a client reads 40 MiB (its largest real message is a 25 MiB drop box
    file as base64), and a host or a copy reads 64 MiB.
  - **Rates.** Each client key has a token bucket: 100 lines a second (burst 1,000) and
    8 MiB a second (burst 96 MiB). It also has a smaller bucket for the costly methods
    (reports, audit, the Console, installs, pairing codes, rotation): 2 a second, burst
    20. A request over a rate is answered `tooManyRequests` (-32075), and the socket stays
    open. Hosts and bots' machines are hosts, so these rates do not apply to them.
  - **Join and sign-in places.** Each address (an IPv6 /64 as one) holds 5. One person
    named holds 10 requests to join. When all 50 places are taken, the oldest request of
    the address that holds the most ends ("expired"; a closed socket for a sign-in) before a
    newcomer is turned away.
  - **Downloads.** `install.sh`, `/v1/servers/*` and `/v1/toolsets/*` allow 30 a minute
    from each address. Past that, they are answered 429.
  - **Logs.** Each kind of refusal is logged once a minute for each source, with a count
    of the refusals that were not logged.

## 4. Logs and secrets

- *Go, 2026-10-18: checked every log line in `Go/internal/controlplane` and
  `Go/cmd/agents-control`.* Lines name members, hosts, addresses and refusal reasons,
  never a code, a code's id, a MAC or a key. One leak was found and fixed: a store error
  while reading a code was logged whole, and an S3 error names the object's key, which
  holds the code's id. Now the line says only "could not read a code". There are no
  webhooks yet, so no signature header to log. `agents-control code` prints a code on
  purpose, to whoever runs it, not into the log. `TestNoSecretReachesTheLog` pairs,
  spends twice, connects, fails a proof and fails a code's read, then looks for each code,
  id, MAC and key in every line.
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
- **Decided (Alex, 2026-10-02): APNs from the control plane.** It waits on Alex's key
  (`.p8`, Key ID and Team ID), made by him in the developer account and copied to the
  machine as a compose secret. Never put it in a code, the store or the repo.
- *Built, #1460.* `Go/internal/controlplane/apns` posts with token auth (an ES256 provider
  token made again every 40 minutes) over HTTP/2, to the one app id
  `com.alexecollins.agents.remote`. The key is `deploy/secrets/apns-key`, given with
  `make-secrets.sh --public --apns AuthKey_KEYID.p8`, and read from `AGENTS_APNS_KEY_FILE`,
  `AGENTS_APNS_KEY_ID` and `AGENTS_APNS_TEAM_ID`. Without a key the control plane sends no
  pushes, and its log says so once at start.
- **When it pushes.** Only when no relay host is online anywhere: not held by this copy, and
  not reached through another copy. Then only the copy that heard the need from its host
  pushes; another copy that hears it from a peer does nothing. With a relay host online, the
  need goes to it as before, and nothing is pushed. A withdrawal goes the way its post went.
  So one notice goes one way and arrives once. In the short time a relay host comes online
  after a push, the collapse id is the need's token, as CloudKit's subscription uses, so the
  two banners are one (a guarded change's token names a file, so its collapse id is a hash).
- **What the push carries.** `aps` has only the title "An agent needs you" (or
  `content-available` for a quiet move or a withdrawal). Under `agents` is one envelope,
  HPKE (P-256, HKDF-SHA256, AES-256-GCM) to the device's key, under its own info
  (`com.alexecollins.agents.push.v1`): the need's id, whether to buzz, and the headline.
  The need's id is sealed too, because a guarded change's id names a file.
- **Device tokens** are a field of the device's own client record (`pushToken`), set only by
  `clients/setPushToken` from that device's session, refused from a window or a browser, and
  never on `clients/list`. A token APNs says is gone is taken off the record.
- *Built, #1744.* **Live Activity updates.** A Live Activity's state is not opened by an
  extension, so Apple reads it. A `liveactivity` push (topic
  `com.alexecollins.agents.remote.push-type.liveactivity`) carries only the phase (working,
  question, approval, done, failed) and the turn's start and end times. It never carries the
  session's title or a line: the activity shows the title it was started with, and "Open
  Agents to answer it". The host says each move with `attention/turn` (no words). Only the
  copy that holds that host sends it, with or without a relay host, because CloudKit cannot
  update an activity. The tokens are the device's own record (`activityTokens`), set only by
  `clients/setActivityToken`, at most 16, each dropped after 12 hours, when its turn ends,
  or when APNs says it is gone.

**Alex's other answers, 2026-10-02:** the machine is a **DigitalOcean** droplet, at a
**subdomain of alexecollins.com** (an A record Alex makes), with records in a **folder on
the machine** (back up the volume), not a bucket. Claude creates no account, droplet or
DNS record. Alex does, and T131 starts from there.

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

*Go, 2026-10-18:* 1 and 2 are done (#1457). 3 to 5 are as before.

1. P4 (forwarding survives a restart): part of T129, since its walk restarts copies.
2. P1, then P3's in-process budget: before T131, Alex's own machine.
3. The provider's firewall and the bucket policy: in the how-to, at T131.
4. W1 to W5: with #60's first slice, after T131.
5. P2 and §5: when codes next change, and once Alex has decided about APNs.
