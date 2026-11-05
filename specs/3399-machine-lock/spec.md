# The machine lock (#3399)

A machine accepts only clients that the person's own devices signed. The control plane
routes requests and keeps the directory, but it cannot add a client, act as a client, or
give a client a key of its own. This is the decision of the spike #3399. The build is
#3400 (epic #3401). The model is Tailscale's
[Tailnet Lock](https://tailscale.com/kb/1226/tailnet-lock).

Nothing here is built yet.

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

Decided: a machine that a provider starts with no client there (a schedule, a workflow)
waits for approval, with a notice on every client ("Approve the new machine dev-3?"),
because a standing invite that lasts for hours is a key that a machine could steal. This
leaves nothing out of P5.

### D4. Recovery when every signer is lost

Decided: when the root is made, the client shows a **recovery key**: a 128-bit secret, as
a line of words, shown once, to keep in a password manager. Its public half is a signer.
To use it, the person types it on a new client, which then adds itself. The client asks
again until the person has saved it or added a second device. The person can skip it.

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
