# 056 research: Claude on a server through the Mac's own sign-in

Alex asked whether a server's Claude could use this Mac's own Claude sign-in through a relay,
the way Codex does in 047 (R12), so the pasted `claude setup-token` in Settings ▸ Servers
could go. He allowed the Mac's sign-in to be read from the Keychain for this spike.
Files: `walk/relay-spike/` (`relay.py`, the relay's log, the trial's output). None of them
holds a token.

## R1. The spike (2026-09-26)

**How it was wired**
- On the Mac, `relay.py` listened on `127.0.0.1:18766` (plain HTTP) and forwarded every
  request to `https://api.anthropic.com`. It replaced `Authorization` with
  `Bearer <the Mac's access token>` and dropped any `x-api-key`. It read the token from the
  Keychain item `Claude Code-credentials` (`claudeAiOauth.accessToken`) on every request.
- `ssh -R 18766:127.0.0.1:18766` carried the port to agents-devbox (Claude Code 2.1.282,
  aarch64).
- On the box, Claude ran with an empty `HOME` and `CLAUDE_CONFIG_DIR`, so the box's own
  login could not be used. It was given `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-relay-standin-no-secret`
  and `ANTHROPIC_BASE_URL=http://127.0.0.1:18766`.

**Measured**
1. **It works.** `claude -p "Run uname -a…" --allowedTools Bash` ran a real two-step turn
   on the box (claude-sonnet-5, 3.3 s). It returned
   `Linux d900157ec616 6.8.0-117-generic … aarch64`.
2. **Every call went through the relay using the stand-in:** `HEAD /api/hello` 200, then
   `POST /v1/messages` 200 twice. There were no other paths: no profile, no claude.ai and
   no telemetry.
3. **Nothing of the real sign-in reached the box.** I searched `/tmp` and `/home/agents` on
   the box for the last 24 characters of the real access token and of the refresh token.
   No file held either.
4. **Plain HTTP is accepted.** Claude Code takes an `http://` base URL on loopback, so
   unlike Codex (R12 finding 3) there is no CA, certificate or `NODE_EXTRA_CA_CERTS`. The
   ssh tunnel is the encryption. `MacSignInRelay` can still use TLS if we want one code
   path, but Claude does not need it.
5. **The app can read the Keychain item without a prompt.** Claude Code writes it with
   `/usr/bin/security`, so `security find-generic-password -s "Claude Code-credentials" -w`
   reads it silently. This matches how 047 reads Codex's `auth.json`, but the source is the
   Keychain, not a file (`MacSignIn` reads a file today).

## R2. What the spike did not settle

- **Renewal.** The access token lasts hours, not days (it had 5.5 h left at the time). The Mac's
  own Claude renews it when used. If nobody uses Claude on the Mac, the relay starts
  getting 401s. Renewing from the relay spends the refresh token, which rotates, and means
  writing the Keychain item back. That can race the Mac's own `claude`, and a lost race
  signs the Mac out. The spike did not renew, on purpose. 047 solved the same problem for
  Codex (re-read, renew once on a 401), and it would need the same care here, against the
  Keychain.
- **Who on the server may use it.** Any process on the box that can reach the forwarded
  loopback port spends Alex's Max plan. 047's `RelayGate` (by uid, from `/proc/net/tcp`)
  is the guard to reuse. The spike had no guard.
- **Through the ACP adapter.** The app runs Claude on servers via `claude-agent-acp`, not
  `claude -p`. The adapter's SDK reads the same environment, and 043's lending already
  depends on `CLAUDE_CODE_OAUTH_TOKEN` reaching it. So `ANTHROPIC_BASE_URL` should reach it
  too, but I haven't checked that.
- **Anthropic's terms.** `setup-token` is Anthropic's documented way to sign in on a
  machine with no browser. Sending the Mac's interactive subscription sign-in through
  our own proxy to other machines is a different use, and it needs a check against the
  consumer terms before we ship it. It's Alex's call.
- **Mac asleep or offline.** Like Codex, a server's Claude only works while the Mac is
  connected. A pasted token keeps working without the Mac, if 043 ever lets servers run
  on their own.

## First sketch: what a build would change (superseded by R3–R8 below)

- `ToolPolicyCatalog`: give Claude a `relay` policy (origin `api.anthropic.com`, header
  `Authorization`, no account header, no TLS required).
- `MacSignIn`: read from the Keychain as well as from a file, and write back on renewal.
- `SignInRelays.grant()`: it is hard-wired to Codex today. It needs to grant per runtime.
- Server side: set `ANTHROPIC_BASE_URL` and a stand-in `CLAUDE_CODE_OAUTH_TOKEN` in place
  of the lent token. The gate is as in 047.
- Settings ▸ Servers: Claude's row reads "Uses this Mac's sign-in". The pasted token
  either goes, or stays as the fallback for when the Mac is signed out. That's a decision
  for the spec.

## R3. Over TLS, sharing Codex's relay (measured 2026-09-26)

**Decision**: Claude goes through the same TLS listener and the same app-made CA as Codex's
relay. On the server it's pointed at `https://127.0.0.1:<gate port>`, and
`NODE_EXTRA_CA_CERTS` names the CA.

**Measured** on agents-devbox, with a throwaway CA and a CA-signed server certificate
(`serverAuth`, IP SAN `127.0.0.1`), the same shape `RelayCertificates` makes for Codex:
- Without `NODE_EXTRA_CA_CERTS`, Claude refuses at once:
  `SSL certificate verification failed (UNABLE_TO_VERIFY_LEAF_SIGNATURE)`. The request
  never reaches the relay.
- With it, `claude -p "Reply with the word ok."` answers `ok` in 1.3 s. The relay saw
  `HEAD /api/hello` and `POST /v1/messages` (200) using the stand-in.

**Rationale**: One listener, one certificate set and one code path on the Mac. The traffic
inside the ssh socket is encrypted end to end as Codex's is, so the server's gate relays
bytes it can't read.

**Alternatives**: plain HTTP (R1 finding 4). It works, but it needs a second listener,
and the gate would carry the stand-in in the clear. The stand-in is no secret, but then
nothing on the server could read our traffic only because the gate is well behaved.

## R4. Through the ACP adapter (measured 2026-09-26)

**Decision**: No change to how the adapter is started. The relay's variables go into the
environment the server's daemon already builds for a runtime (`launchEnvironment`).

**Measured**: `claude-agent-acp` was started on agents-devbox with the relay's variables and
driven over stdio (`initialize`, `session/new`, `session/prompt`). The Claude it spawned
(`claude-agent-sdk-linux-arm64/claude … --output-format stream-json`) had
`ANTHROPIC_BASE_URL=https://127.0.0.1:18767` and the throwaway `CLAUDE_CONFIG_DIR` in its
`/proc/<pid>/environ`. The relay logged `HEAD /api/hello` three times and
`POST /v1/messages` twice, all 200, using the stand-in. The driver's printed reply was lost
to an app restart mid-run. The relay log is the evidence. The two orphaned processes were
stopped by pid afterwards.

## R5. Reading the Mac's sign-in

**Decision**: Read the Keychain item `Claude Code-credentials` (account = the Mac user) by
running `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. Parse
`claudeAiOauth.accessToken`, `expiresAt` and `scopes`. Hold the result in memory until
60 s before `expiresAt`, and re-read at once on any 401.

**Rationale**: The item is written by `claude` through `/usr/bin/security`, so reading it the
same way raised no prompt in the spike (R1 finding 5). Reading it with `SecItemCopyMatching`
from the app would be a different client in the item's access list, and would prompt on
every unsigned build (the security review's "unsigned builds are strangers"). A subprocess
per request would add tens of milliseconds to each model call, so the relay caches. The 401
re-read keeps FR-005's promise: a renewal by the Mac's Claude is picked up on the next
refused request at the latest.

**Measured (T016, 2026-09-26)**: 20 reads took 17.1 ms median and 36.2 ms at worst, and the
item's scopes include `user:inference`. A read per request would add about 17 ms to every
model call. The cache stays.

**What counts as signed in (D3)**: the item exists, parses, and its scopes include
`user:inference`. `claude auth status --json` (`authMethod: "claude.ai"`) says the same, but
it starts a Claude process. It's kept for the Settings line only, not per request.

**Alternatives**: `SecItemCopyMatching` (prompts, above). Copying the item into the app's own
Keychain (a second copy of a rotating secret: the problem R12 avoided).

## R6. Renewing: let the Mac's Claude do it

**Decision**: The relay never exchanges the refresh token itself. When the access token is
expired or refused, the relay asks the Mac's own `claude` to renew. Then it re-reads the
item. How it asks is measured before it's built (T-spike, below). The candidates, cheapest
first:
1. `claude auth status`, if it renews an expired token as a side effect;
2. a one-token turn: `claude -p . --max-turns 1 --model haiku`, which renews before calling
   the API. It's certain to renew, but it spends a small turn against the plan.

The relay runs one renewal at a time (a single in-flight task every waiter awaits), so two
servers finding it expired together cause one renewal (spec edge case).

**Rationale**: The sign-in is Claude's, and so is the lock that stops two renewals racing.
A second renewer, the app, is what could sign the Mac out (spec D4). Letting Claude do it
means the app never writes the Keychain item, never needs Claude's client id or token
endpoint, and can't spend a refresh token Claude is also spending. Codex's relay renews
itself (047) because Codex's sign-in is a plain file with no lock of its own. That reason
doesn't carry over.

**How it's measured, safely**: the Mac's access token expired at about 15:00 on 2026-09-26
(expiresAt read in R1). Just after a natural expiry, with nothing else using Claude, run
candidate 1 and read `expiresAt` before and after. This is Claude renewing its own item,
which it does several times a day anyway, so it puts nothing at risk. No test ever renews
Alex's sign-in from app code.

**Alternatives**: the app renews with the OAuth exchange and writes the item back with
`security add-generic-password -U`. Rejected: it races Claude's own renewal, needs values
read out of Claude's binary, and a mistake signs Alex out.

## R7. What the server's Claude is started with

**Decision**: On a relayed run the server's daemon sets:
- `ANTHROPIC_BASE_URL=https://127.0.0.1:<gate port>`
- `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-agents-relay-standin`
- `NODE_EXTRA_CA_CERTS=<root>/runtimes/claude-relay-ca.pem`

It takes out `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK` and
`CLAUDE_CODE_USE_VERTEX` (spec edge case: the relay replaces any sign-in in the server's
environment). No home folder or file is written for Claude, unlike Codex. The stand-in
starts `sk-ant-oat`, so Claude sends the subscription headers the relay passes on as-is.

**Measured**: with `CLAUDE_CODE_OAUTH_TOKEN` set, the server's Claude made no sign-in or
profile calls. It made only `/api/hello` and `/v1/messages` (R1, R3, R4), so there's nothing
for it to renew and nothing the relay has to fake.

## R8. Removing the token

**Decision**: `CredentialKind` loses `.oauthToken` and `.apiKey`. Gemini's key is the only
kind left. Everything that exists only for Claude's token goes with them:
- the Claude check in `CredentialCheck`;
- the "needs a token" `TokenAskCard` (Gemini's ask becomes "needs a key");
- `claudeLine`'s token wording. Claude joins `toolsetLine`, which already speaks for relayed
  runtimes.

`CredentialStore` already drops a record of a kind it no longer knows, one at a time
(f10cd50). 056 adds deleting that runtime's Keychain item
(`agents.runtime-credential.claude`) on first start.

The server's own-sign-in check (`ServerSignIn.exists`), which read Claude's variables off
`CredentialKind`, reads them from Claude's relay policy instead.

**New failure**: `signInWanted` (`-32070`, clear of the codes on every branch today, highest
`-32060`). The server's daemon raises it before starting Claude when no relay is offered,
the server isn't "own sign-in only", and the server has no Claude sign-in of its own. The
window shows the 053 sign-in sheet for Claude on the Mac.

## R6, measured (T035, 2026-09-26)

- **The token lives 8 hours.** The Mac's token was due at 15:00:08. At 14:55:09 it was
  renewed, to 22:55:09, by one of the Claude processes running on the Mac: Claude renews
  its own sign-in in the last five minutes before expiry whenever it runs.
- **`claude auth status` did not renew it** at 14:51:35, eight and a half minutes out,
  outside that window. My second run, at 14:55:14, came five seconds after Claude had
  already renewed it, so it proved nothing either way.
- **What was built**: the relay asks the Mac's Claude with `claude auth status` first. If
  the token is unchanged, it runs a one-word turn on the smallest model
  (`claude -p . --max-turns 1 --model haiku`), which certainly renews, for a few tokens.
  The second step only runs when the first left the sign-in as it was.
- **In practice** a relayed token rarely expires while Claude runs on the Mac, because any
  Claude running there renews it in time. The relay's renewal covers a Mac where no Claude
  runs for hours. That case wasn't walked end to end: it needs a natural expiry with no
  Claude running on the Mac, which this Mac, running agents all day, doesn't have.
