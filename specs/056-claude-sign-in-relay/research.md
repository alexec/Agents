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

## R3. What a build would change

- `ToolPolicyCatalog`: give Claude a `relay` policy (origin `api.anthropic.com`, header
  `Authorization`, no account header, no TLS required).
- `MacSignIn`: read from the Keychain as well as from a file, and write back on renewal.
- `SignInRelays.grant()`: it is hard-wired to Codex today. It needs to grant per runtime.
- Server side: set `ANTHROPIC_BASE_URL` and a stand-in `CLAUDE_CODE_OAUTH_TOKEN` in place
  of the lent token. The gate is as in 047.
- Settings ▸ Servers: Claude's row reads "Uses this Mac's sign-in". The pasted token
  either goes, or stays as the fallback for when the Mac is signed out. That's a decision
  for the spec.
