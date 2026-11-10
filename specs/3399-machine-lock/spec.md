# The machine lock (#3399)

A machine accepts only clients that the person's own devices signed. The control plane
routes requests and keeps the directory, but it cannot add a client, act as a client, or
give a client a key of its own. This is the decision of the spike #3399. The build is
#3400 (epic #3401). The model is Tailscale's
[Tailnet Lock](https://tailscale.com/kb/1226/tailnet-lock).

Every step of "The build" is built: the chain (#3489), clients that sign (#3490), machines
that join signed (#3491), machines that check each request (#3492) and recovery (#3493).
Step 6's docs went with step 4.

How step 2 is built (#3490):

- `lock/join`, `lock/joinAnswer`, `lock/joinReveal`, `lock/joinDeny` and `lock/joinRequests`
  (capability `lock-join/1`), with `control/lockJoinRequested` and `control/lockJoinDecided`.
  The control plane keeps each request at `v1/lockjoins/<id>.json` and passes the commitment
  and the nonces on; Approve is the signer's own `addClient` through `lock/add`.
- The commitment is SHA-256 of `agents-lock-join/1\n`, the key and a 16-byte nonce. The
  digits are the first four bytes of SHA-256 of `agents-lock-digits/1\n`, the key, the new
  client's nonce and the signer's nonce, modulo a million. A signer makes the digits with the
  nonce it sent, never the one the control plane sends back. Go, AgentsKit and the web page
  read the same vectors (`Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/lock/vectors.json`).
- Decided: joining the lock is a step of its own after sign-in, on the paired connection, and
  not part of `signIn/approve`, because the control plane's sign-in and the lock are two
  trusts: every sign-in method then needs the lock's approval (D2), and the sign-in flow is
  unchanged.
- Decided: a signer presses **Compare Digits** before its nonce is sent, and only the first
  signer's nonce is taken, because a nonce sent by every open device at once would leave the
  person comparing on a device they are not looking at, and a second nonce would be a second
  try at the digits.
- Decided: each client pins the head it last checked (defaults on the Mac and the Remote,
  `localStorage` on the web page), and signs nothing on a lock that does not follow it.
- Nothing refused yet (step 4 refuses); the fingerprint in Settings ▸ Clients (D1) is not built yet.

How step 3 is built (#3491):

- **The invite in a join code.** When a signer shows a host code (Add a Machine on the Mac
  and the web page), it puts an `invite` on the lock, signed with its own key, and adds the
  invite's private key and the lock's pin to the code: a version 4 code,
  `agents-control:4:h:-:<key>:<secret>:<url>:<pin>:<name>:<personKey or ->:<invite>:<person>:<count>:<head>`.
  The control plane makes the version 2 code; the invite's key never goes through it.
  `agentsd` keeps the invite at `<root>/lock-invite.json` (0600), pins the lock from the
  code's head, and when `host/lock` comes signs its own `addMachine` with the invite key
  and sends it with `host/lockAdd`. The control plane takes only the machine's own
  `addMachine` there.
- **A machine that asks.** A machine that is not in the lock and has no invite (it asked
  to join, a provider or `hosts/install` made its code, or it joined before the lock) asks
  as a client does, on its channel 0: `host/lockJoin` with its own key and a commitment.
  The request is a `lock/joinRequests` row with `machine` set, so every client of the
  person shows "Approve the new machine dev-3?". A signer's Compare Digits reaches the
  machine as `host/lockJoinChanged`; it reveals with `host/lockJoinReveal`, and writes the
  six digits to its log and to `<root>/lock-join-shown`. Approve signs the machine's
  `addMachine`. Capability `host.lock/2`.
- **The sealing key in the lock (D8).** A machine's key is also its sealing key: the key
  org routes and secrets are sealed to. A client seals to a machine only when its owner's
  lock names that key as an `addMachine`'s sealing key; `SealRecipient.owner` says whose
  lock, and an admin's client reads another person's lock with `lock/get {person}` and pins
  it on first use. A machine left out gets its copy through `sealing/work` once it is in
  the lock. A client recipient's key is still the control plane's: `addClient` names a
  client's signing key, not its sealing key.
- Decided: a machine that asks to join the control plane (`/v1/join`) joins the lock as a
  step of its own after it is approved, through the same request a client makes, because
  one flow then serves every machine with no invite: one that asked, one a provider
  started with no client there, and one that joined before the lock (D9).
- Decided: a provider's machine asks too, and `AGENTS_JOIN_TOKEN` is not built here,
  because today the control plane, not a client, makes a provider machine's code
  (`workspaces.go` `HostCommand`), so an invite in it would go through the control plane.
  When a provider runs on the customer's machine with a client there (#3398), that client
  can put a version 4 code in `AGENTS_JOIN_TOKEN`.
- Decided: a machine's key and sealing key are the same key, the one it proves itself
  with, because org routes and secrets are sealed to that key today, and a second key is
  one more thing to keep on every machine for no gain while nothing refuses (step 4).

How step 4 is built (#3492):

- **The channel.** `lock/hello` (capability `host.lock/3`) carries the client's lock key, a
  new ECDH P-256 key and an ECDSA signature over `agents-lock-channel/1\nclient\n` and that
  key. The machine checks the key is a client of its lock and answers with its own key, a
  new ECDH key and a signature over `agents-lock-channel/1\nmachine\n`, both ephemeral keys
  and the client's key. HKDF-SHA256 (salt: both ephemeral keys; info
  `agents-lock-channel/1 client` or `… machine`) makes a key for each direction. Each request
  and answer then ends with `"lock":{"n":N,"mac":M}`: HMAC-SHA256 over N (8 bytes, big-endian)
  and the message without that member. The control plane passes each message on as it came,
  so the bytes MAC'd are the bytes read. Go (`machinelock/channel.go`), CryptoKit
  (`LockChannel.swift`, `LockedLink.swift`) and WebCrypto (`Web/src/wire/lockChannel.ts`,
  `link.ts`) read the same vectors (`Fixtures/lock/channel.json`).
- **Signed requests** (`LockSignature`): ECDSA over `agents-lock-request/1\n`, the machine's
  id, the time in seconds, the method and the params as sent. A client signs a prompt or a
  start for a machine it has no channel to; `hosts/keep` and the router's keeper keep it as a
  `LockDelivery` and deliver it byte for byte. The machine takes one at most a day old, once
  (`<root>/lock-seen.json`).
- **The machine** keeps the lock it took (`<root>/lock.json`), so it checks requests after a
  restart before the control plane sends it again. Once it holds a lock, a request on a
  channel from the control plane, or on the window's local socket, is refused with
  `notInLock` (-32104) unless it has the channel's MAC or a signature of the lock, or is one
  the control plane asks for itself. `daemon.sock` is not checked.
- **The clients** open a channel at the first call to each machine on each connection, once
  the device is in its lock. The Mac and the Remote keep the lock they last checked with its
  pin, so the window's channel to its own machine opens with the control plane away.
- Decided: a peer machine's call (D7) is a signed request, not an HMAC from a channel
  between the two machines, because no channel runs between two machines (each talks only to
  the control plane) and a start can be kept for a machine that is away. The asking machine
  writes what the other is to get, in its own words (its name from its join code), and signs
  it (`MachineWorkspaceCall.deliver`); the control plane delivers it as it is. A machine may
  leave out `to`, since an agent names the other machine by name.
- Decided: a peer machine may call `agents/start`, `agents/fromStarter`,
  `agents/endedElsewhere`, and the steps of send and bring back (`folders/receiveState`,
  `receiveUpload`, `receive`, `sendFacts`, `sendPack`, `sendRead`), because those are the
  steps of `start_session` (#2887, #2927) and of send and bring_back (#2929, #2947), which
  would stop working with D7's two methods alone. Terminals and every other file method stay
  out.
- Decided: a peer machine may also call `agents/moveIn` (#3717), because it is the last step
  of `move_session`, after the steps of send: it restores one session from an export the same
  machine uploaded with `folders/receiveUpload`, and starts nothing but that session's next
  turn there.
- Decided: the control plane may ask, unsigned, `daemon/ping`, `daemon/status`,
  `agents/list`, `worktrees/all`, `agents/summaryFacts`, `backups/make` and `folders/clone`,
  because the Console, projects, reports, a backup before a delete and a new workspace's
  clone ask for them in its own name, and none starts an agent, runs a command or reads a
  file. A provider draft's agent on a Mac control plane (`drafts.go`) is a start, and is
  refused once the person has a lock; it waits on #3542.
- Decided: the machine MACs what it says unasked (`agent/changed`, `agent/entry`, a question
  card) as it MACs its answers, on the same count (#3541). A fan-out frame (#167) carries a
  lock member for each channel that has one, `{"f":[1,2],"l":[null,{"n":…,"mac":…}],"m":…}`,
  and the control plane adds it last to that channel's copy, so the message goes up the
  uplink once and only the 60-byte members are per channel. The control plane says it reads
  them with `ChannelOpen.fanOutLock`; to one that does not, the machine writes those channels
  one by one. Once lock/hello is answered, a client takes a notification from that machine
  only with its MAC (the control plane's own, `control/…`, are not the machine's). Not a
  signature by the machine key once per frame, because an HMAC costs 1.4 µs for 2 KB (Go,
  `BenchmarkTail`) against 19 µs to sign and 37 µs for each client to verify, and the count
  stops a replay with no list of ids.
- Decided: a client takes an error with no MAC (the control plane's own: offline, no such
  machine), and refuses a result with none from a machine it has a channel to, or that its
  lock names, because the control plane can always refuse to route.
- Decided: a client opens a channel with a machine its lock does not name yet (one that
  waits for approval, D9) and takes its key on its word, because the machine holds the lock
  from its first `host/lock` and would otherwise refuse every client of its person until a
  signer approves it. The requests to it are still the client's alone; its answers are only
  as good as the control plane's, as before the lock. A machine the lock names must answer
  with its addMachine's key. The window's `.mac` and the web page's `mac` name no id, so they
  take any machine of the lock, or one it does not name.
- Decided: who did it in the audit names the device from the lock (#3543). A root and an
  addClient carry the client's id (`id`), as an addMachine does: the signer puts in the asking
  client's `LockJoinRequest.client`, and a client that signs its own entry (the root, Use
  Recovery Key) its own. The machine refuses a hello on a channel whose `ChannelOpen.actor`
  names another client than the lock member, and writes that member's id and name into each
  event's actor; the person stays the control plane's word. An entry made before #3543 names
  no id, so the actor stays the control plane's until that device joins again.

How step 5 is built (#3493):

- **The recovery key.** The client that signs the root puts a `recovery` entry on with it, in
  the same `lock/add`, and shows the key once: "Save your recovery key." with Copy, I Saved It
  and Skip. The person sees 16 random bytes and a 4-byte check (SHA-256 of
  `agents-lock-recovery-check/1\n` and the bytes) as 32 letters and digits in groups of four,
  Crockford's base32, so a typo is found before anything is sent; O reads as 0, I and L as 1.
- **The recovery key is a P-256 key made at random**, its public half the entry's `key`. The
  entry's `sealed` is its private half under AES-256-GCM, with a key that HKDF-SHA256 makes from
  the 16 bytes (info `agents-lock-recovery/1\n` and the public half), the public half as the
  additional data: a 12-byte nonce, then the sealed bytes and the tag. **Use Recovery Key**, on
  a client that is not in the lock, opens it and signs that client's own `addClient`. Go
  (`machinelock/recovery.go`), CryptoKit and WebCrypto read the same vectors
  (`Fixtures/lock/recovery.json`).
- **Start a New Lock** (`lock/reset`, capability `lock-reset/1`): the control plane drops the
  person's lock; the client forgets its pin and signs a new root and recovery key. Each client
  and machine that pinned the old lock refuses the new one ("The lock changed in a way your
  devices did not sign.").
- **`agentsd lock reset`** calls `daemon/lockReset` on `daemon.sock`, any process of the
  machine's own account (the stranger role), and is refused on a channel from the control
  plane or the window's local socket, also one a client of the lock signed. The machine drops
  its pin, the lock it kept, its invite and its request to join, and asks again with
  `host/lockAgain` (capability `host.lock/4`); it then pins the next lock on first use and asks
  to join. With no agentsd running, the command removes the files itself.
- Decided: the recovery key is a random key whose private half the lock keeps sealed, not a
  key made from the secret, because WebCrypto cannot make a P-256 public key from a private
  one in every browser, and a sealed key needs only HKDF and AES-GCM, which all three
  platforms have. The control plane keeps the sealed key; without the 128-bit secret it
  cannot open it.
- Decided: letters and digits in groups of four (as Apple's recovery key), not a line of
  words, because a word list would be one more file to keep the same in Go, Swift and the web
  page, and a password manager keeps either.
- Decided: a device asks again, with "Make a recovery key." (Make Recovery Key, Skip), while
  the lock has one client and the person neither saved nor skipped a key on that device. A key
  that was shown and not saved is gone once the app closes, so Make Recovery Key puts a new
  `recovery` entry on, which takes the old key's place.
- Decided: Use Recovery Key and Start a New Lock are on the card of a device that waits for
  approval, and Start a New Lock asks first, because a person who still has a device should
  approve the new one from it.
- Not built: a device that pinned the old lock (the broken card) has no way to forget it but
  removing the app's data; the fingerprint in Settings ▸ Clients and in `agentsd status` (D1).

## What is wrong today

- **The machine believes the control plane.** TLS ends at the control plane. The router
  writes the client's identity into `ChannelOpen{Client, Device, Actor}`, unsigned
  (`Go/internal/controlplane/router.go`), and agentsd uses that actor
  (`Go/internal/agentsd/actors.go`). Nothing that a client sends is signed to the machine.
- **Every client may do everything** (#111). So whoever controls the control plane can
  start an agent, run a command or read a file on every machine, as any client.
- **The control plane adds clients.** It makes the join codes, approves the sign-ins and
  keeps the list of keys. The approval code that both screens show
  (`Web/src/wire/signIn.ts` `approvalCode`) is a hash of the new client's key and the
  control key. A control plane that wants to put in a key of its own can try keys until
  the six characters match.
- **The control plane gives out the machine keys.** A client that seals a secret to a
  machine (#3397) gets the machine's key from the control plane, which can give a key of
  its own.

What is already safe: runtime sign-ins stay on the machine; the person's policy layer is
signed by the person key (#2957), which the control plane cannot forge; the Mac window
proves its own key to its own machine.

## The parts

- **Signing key.** Each client has a new ECDSA P-256 key, used only to sign. The key
  cannot leave the device: the Secure Enclave on the iPhone, iPad and Mac
  (`SecureEnclave.P256.Signing`), else the Keychain (this device only); a non-extractable
  WebCrypto key in IndexedDB in the browser. The ECDH key that a client uses today to prove
  itself to the control plane stays as it is.
- **Machine key.** The machine's key of today (`controllink/hostkey.go`), with its sealing
  key. A machine never signs for a client.
- **The lock.** One for each person. It is a chain of entries. Each entry names the hash of
  the entry before it, says one change, and is signed. The first entry (the **root**) names
  the first signing key. The control plane keeps the chain at `v1/locks/<person>/` and
  writes each entry with a conditional write on the head, so two entries cannot both follow
  one head.
- **Signers.** The keys that may add an entry. Every one of the person's clients is a
  signer, and the recovery key is a signer. A machine is never a signer.
- **The head.** The hash of the newest entry. Each client and each machine keeps the head
  it last checked, and takes only a chain that grows from it.

| Entry | Says | Signed by |
|---|---|---|
| `root` | the first signing key, the person's id | that key |
| `addClient` | a client's signing key, its kind and name | a signer |
| `addMachine` | a machine's key and sealing key, its name | a signer, or an invite (below) |
| `invite` | a one-use key that may add one machine, and when it expires | a signer |
| `remove` | a client, a machine or an invite that is no longer trusted | a signer |
| `recovery` | the recovery key's public half, or a new one | a signer |

## Decisions

Each decision is checked against the principles in `docs/explanation/direction.md`
(P1 to P8). Alex can overrule each one.

### D1. The roster: every client of the person signs

Decided: every client of the person is a signer, and machines never sign, because a
person has few clients, all of them can do everything already (#111), and P1 says that a
person who uses only the web page must be able to add a device. A separate set of signing
devices (as Tailnet Lock allows) adds a choice on every screen for little gain. A machine
runs agents and code from the internet, so it signs nothing.

Decided: the first client at sign-up makes the root (trust on first use), because there
is nothing to check it against. Each client and machine shows the lock's **fingerprint**
(the root's hash, as four words) in Settings ▸ Clients and in `agentsd status`, so a
person can compare two screens.

Decided: a chain, not a set of separate certificates, because a chain puts the changes in
one order (a removal cannot be put before the add it undoes), and one head is easy to
compare. A fork can come only from a control plane that does wrong. A machine that sees
one keeps its own head and says "The lock changed in a way your devices did not sign".

### D2. Adding a client: approval on a device the person already has

- The new client makes its signing key and asks to join, as sign-in approval does today
  (R3, `signin_approvals.go`). A signer shows the request.
- **The six digits on both screens come from a commitment**, not from a hash that the
  control plane can try again and again. The new client first sends a hash of its key and a
  random number. The signer then sends a random number of its own. The new client then
  shows its random number. Each screen makes the six digits from the key and both random
  numbers. A control plane in the middle must choose its key before it sees the signer's
  number, so it has one chance in a million, and a failed try shows on the screen. This is
  how Bluetooth's numeric comparison works.
- When the digits are the same and the person taps **Approve**, the signer adds
  `addClient`.

Decided: approval is required for every sign-in method (Apple, Google, GitHub, single
sign-on), because a sign-in proves who the person is to the control plane, not to the
machines. P3 stays: everyone signs in first.

Decided: no QR code in the first build, because six digits work on every pair of devices.
A QR code (the phone scans the browser) is a later choice.

### D3. Adding a machine

- **A join code** made on a signer: the client adds an `invite` entry, and puts the
  invite's private key in the code. The code never goes through the control plane: the
  person copies it to the machine. The machine adds its own `addMachine`, signed with the
  invite key. An invite works once and expires in 5 minutes, as a code does today. The code
  also carries the lock's head, so the machine pins the lock from the code, not from the
  control plane.
- **A machine that asks to join** (`hosts/requestJoin`, R5): a signer approves it with the
  same six digits as in D2. The machine shows its digits in its log and in `agentsd join`.
  When the person cannot see the machine's screen, the digits come through the control
  plane, and this is trust on first use.
- **A machine that a provider starts** (#3398): the client that asks for it adds an
  `invite`, and the invite's key goes in `AGENTS_JOIN_TOKEN`. The provider runs on the
  customer's machine (#3398), so the key does not go through the control plane.

Decided: the Mac window that makes the root puts an invite for this Mac's own host in the
same `lock/add`, and keeps it in the host's root as a join code would (Alex, 2026-11-09,
#4248). The code never goes through the control plane, so the host adds itself with no
digits to compare between two parts of one app.

Decided: a machine that a provider starts with no client there (a schedule, a workflow)
waits for approval, with a notice on every client ("Approve the new machine dev-3?"),
because a standing invite that lasts for hours is a key that a machine could steal. This
leaves nothing out of P5.

### D4. Recovery when every signer is lost

Decided: a client offers to make a **recovery key**: a 128-bit secret, as a line of words,
shown once, to keep in a password manager. Its public half is a signer. To use it, the
person types it on a new client, which then adds itself. The client offers it while it is
the lock's only client and the lock names a machine other than this Mac's own host, until
the person has saved it or skipped it (Alex, 2026-11-09, #4248). With only this Mac and its
own host, a lost Mac loses nothing that a key could get back, so the first open asks
nothing; a second client is a way back of its own, so it ends the offer.

Decided: with no signer and no recovery key, the person **starts a new lock**. Each machine
then joins again: a provider makes its machines again, and on a machine of their own the
person runs `agentsd lock reset` in its shell. That command is the only way to turn the
lock off on a machine, and only the machine's own Unix user can run it (as Tailnet Lock's
disablement secret, but kept on the machine).

What it costs: the recovery key is one more thing to keep. Without it, a person who loses
every device makes each machine join again.

Decided: no passkey as a signer in the first build, because a passkey asks for Touch ID on
every use, and the screen does not show what it signs. A passkey that syncs with iCloud or
Google is a good later choice for recovery.

### D5. The browser

- The signing key is a non-extractable WebCrypto key in IndexedDB, as the ECDH key is
  today. Script on the page can use it but not read it. The page asks for
  `navigator.storage.persist()` so that the browser does not clear it to free space.
- **When the site data is cleared**, the key is gone. The browser is a new client and asks
  for approval again (D2). The old entry stays until a client removes it, and its key
  expires after 90 days of no use, as every key does today (#997). A person whose only
  signer was that browser uses the recovery key (D4).

Decided: browsers sign, as every other client does, because P1 makes the web page a full
client and a person who uses only the web page needs a way to add a device.

**What the lock does not stop in the browser.** The control plane serves the web page. A
control plane that serves a changed page can sign what it wants with that browser's key
while the page is open. Every web product with keys in the browser has this limit. The
lock stops a control plane that is broken into, a person with access to the store, and a
leaked store. It does not stop an operator who ships a changed page. The Mac and the Remote
are signed apps, so they do not have this limit. The docs say so (P6).

Decided: serving the page from a place the control plane cannot change (a fixed, versioned
build with a public list of hashes) is a later issue, not part of #3400, because the lock
is useful without it and it changes how the web page is shipped.

### D6. Requests: signed end to end, not encrypted

Decided: each request from a client is checked end to end by the machine; requests are not
encrypted, because P8 makes end-to-end encryption a later product choice, and encryption
breaks the features that read content in the control plane (table below). Signing is
enough for P6: the control plane cannot act as a client.

How:

- **A live channel.** When a client opens a channel to a machine, the two make a key for the
  channel: each sends a new ECDH P-256 key, signed with its signing key (the client) or
  machine key (the machine), and each checks the other against the lock. HKDF-SHA256 makes
  one key for each direction. Each request and each answer then carries an HMAC-SHA256 and a
  count. The machine refuses a request with no HMAC, a bad one, or a count it saw before.
  The client checks the answers too, so the control plane cannot forge what a machine said
  (a question card, an approval).
- **A kept request** (a prompt for a stopped workspace, `providers/kept.go`): the client
  signs the request itself with its signing key, with the machine's id, a time and an id.
  The machine checks it when it starts, and refuses one older than the kept request's limit
  or one it saw before.
- **Requests to the control plane itself** (forget a client, add a machine): these become
  lock entries. The control plane can still refuse to route anything; the lock does not
  stop a denial of service.

Decided: one handshake for each channel and an HMAC for each message, not an ECDSA
signature on each message, because an HMAC is quicker on every device, the count stops a
replay with no list of ids, and the same key can encrypt the channel later. We use the
platform libraries only: WebCrypto, CryptoKit and the Go standard library
(`crypto/ecdh`, `crypto/ecdsa`, `crypto/hkdf`, `crypto/hmac`). Noise libraries were
considered (`flynn/noise` in Go), but there is no browser and Swift library of the same
kind that we would trust more than the platform's own primitives.

What each feature does when requests are signed:

| Feature | With signing (D6) | With encryption (later) |
|---|---|---|
| Reports (`usage/rollup`) | works: the machine sends them | works: they are not requests |
| Search across machines (fan-out) | works: each request has its own HMAC | the control plane cannot read the answers |
| Kept requests | works: signed by the client (above) | must be sealed to the machine |
| Last-heard copies (#962) | works | the control plane cannot keep them |
| Notices and pushes | works: answering from a notice is a signed request | the control plane cannot write the push text |
| The page a machine serves (#1480) | works: the handshake runs on the machine's socket | works |
| The Mac window's local link | works: the machine takes window keys from the lock, not from a list the control plane pushes | works |

### D7. Organisations

Decided: an admin signs nothing for a member. Each person's machines trust only that
person's devices, because P5 says that the operator, and so the organisation's service,
cannot act for the customer, and a member's machine is that member's (`direction.md`,
Tenancy).

- **Org policy** stays signed by the control key (#998). A policy is only a ceiling: it can
  make a machine do less, not more. A forged policy can stop work, which a control plane
  can already do by not routing. A policy signed by the admins' own devices is a later
  choice.
- **An org route** (#3397) is sealed by an admin's client to each machine's sealing key. The
  admin's client gets that key from the member's lock, which the control plane cannot
  change (D8).
- **`start_session` on another machine** (#2887): machine A asks machine B through the
  control plane. B accepts it only when A is an `addMachine` in the same person's lock and
  A's request carries an HMAC from a channel between the two machines. A peer machine may
  call only `agents/start` and `agents/fromStarter`, not terminals or files. Decided,
  because an agent on A that starts an agent on B is the feature, and the other methods are
  not needed for it.

### D8. Machine keys for sealing

Decided: `addMachine` carries the machine's sealing key. A client that seals a secret
(#3397) takes the key from the lock and checks it, because then the control plane cannot
give a key of its own. This closes the known limit in #3397.

### D9. All three shapes

Decided: the lock is the same, and on, in every shape (hosted, self-hosted, a control
plane on a Mac), because P2 says one product, and one way of trust is less code to test.
On a Mac control plane it stops nothing new for one person, but it costs nothing more than
one approval for each new device.

Decided: no move of old data (v0.x). After the update, the first client that signs in
makes the root. Every other client asks for approval (D2), and every machine that is
already joined asks to join (D3, `requestJoin`). An existing machine with no lock pins the
first lock that the control plane sends, which is trust on first use. The release notes
say so.

## What the control plane can and cannot do with the lock

| It can | It cannot |
|---|---|
| route, or refuse to route, any request | add a client or a machine to a lock |
| read requests and answers (they are signed, not encrypted) | send a request that a machine takes as a client's |
| keep the chain, and keep it back from a machine | change or remove an entry, or put one in a different order |
| sign the org policy, which can only make a machine do less | give a client a machine key of its own to seal to |
| serve a changed web page (D5) | sign with a Mac's or a phone's key |

## Principles

The spec agrees with P1 to P8. P8 says that end-to-end encryption is for later; D6 signs
and does not encrypt, so it agrees. P6 is met for the Mac and the Remote, and for the web
page with the limit in D5, which the docs say.

## The build (#3400)

#3400 is a stack, one PR for each step, each by its own agent:

1. **The chain** (task): entries, signing, the checks, the store at `v1/locks/<person>/`,
   the wire types in `Packages/Wire`, and `agentsd` pinning the head. Nothing refuses yet.
2. **Clients sign** (story, Core): the signing key on each client, the root at sign-up,
   and approving a new client with the commitment digits. Mac, Remote and web.
3. **Machines join signed** (story, Core): the invite in a join code and in
   `AGENTS_JOIN_TOKEN`, approving a machine that asks, the notice for one with no client,
   and the sealing key that #3397 reads from the lock.
4. **Machines check each request** (task): the channel handshake and HMAC, signed kept
   requests, peer machines for `start_session`, the window's keys from the lock. The test
   from #3400 ("a control plane that forges a client is refused") is in this step.
5. **Recovery** (story, Core): the recovery key, and `agentsd lock reset`.
6. **Docs**: `docs/explanation/control-plane.md` and
   `docs/explanation/compliance/security-overview.md` say what the control plane can and
   cannot do (the table above). This can go with step 4.

Later, not in #3400: a QR code to approve, passkeys as signers, a web page that the control
plane cannot change, an org policy signed by admins' devices, and encryption of the channel.
