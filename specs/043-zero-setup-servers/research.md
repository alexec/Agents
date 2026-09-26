# Research: Zero-Setup Servers

Defaults D1–D5 from the spec are taken as written. Each decision below says which it rests on.
Items marked **(spike)** are confirmed by hand in Phase 0 before anything is built on them.

## R1. What Claude needs on a server

**Decision**: Node.js plus the `@agentclientprotocol/claude-agent-acp` npm tree, and nothing
else. The tree brings `@anthropic-ai/claude-agent-sdk`, which carries Claude Code itself as a
per-platform optional dependency (`claude-agent-sdk-linux-x64`, `-linux-arm64`, and `-musl`
variants). No separate `claude` CLI is installed.

**Rationale**: It is what the Mac already runs (`RuntimeCatalog.claude` is
`npx -y @agentclientprotocol/claude-agent-acp`), so behaviour on a server matches the Mac. Checked
2026-09-25: claude-agent-acp 0.81.2 → claude-agent-sdk 0.3.280, whose optional dependencies are
the eight platform packages above.

**Alternatives considered**: Anthropic's native `claude` installer script — installs the CLI,
which has no ACP mode, so the adapter would still be needed. A Node single-executable bundle
built by the app — the SDK's native binary is still separate, and it is another thing to build.

## R2. Pinning and checksums (FR-003, D2)

**Decision**: The app bundle carries `toolsets/claude/manifest.json` (Node version, and the
SHA-256 of `node-v<ver>-linux-x64.tar.xz` and `-linux-arm64.tar.xz` from nodejs.org's
`SHASUMS256.txt`) and a `package.json` + `package-lock.json` for claude-agent-acp. The lockfile's
`integrity` (sha512) fields are npm's own checks for every tarball, and `npm ci` refuses a
mismatch. The toolset id is the first 16 hex characters of the SHA-256 of manifest + lockfile.
`scripts/update-claude-toolset.sh` regenerates all three for a new pin.

Node's official Linux builds need glibc ≥ 2.28. A musl server (Alpine) is told "Claude can't be
installed on Alpine (musl); install it yourself to use it here" and keeps 037's behaviour.

`npm ci --ignore-scripts --omit=dev --no-audit --no-fund`: no install scripts run. **Spike, confirmed**
(walk/spike.md T006): the native binary arrives as a plain optional-dependency package, npm takes
only the server's own platform, and the adapter starts. The toolset is ~484 MB unpacked (Node
204 MB, native Claude 223 MB), so 800 MB free is required.

**Rationale**: Every byte is checked against something the app shipped; nothing is "latest".

**Alternatives considered**: unofficial-builds.nodejs.org musl tarballs — not official (FR-003
says official sources). `npx -y` on the server — unpinned, unchecked, and reaches the network on
every start.

## R3. Who downloads, and with what (D2)

**Decision**: The server, with `curl -fsSL` or, failing that, `wget -qO-`, from
`https://nodejs.org/dist/` and the npm registry. The probe reports which downloader exists. With
neither, the step fails with "devbox has neither curl nor wget to download Claude". No
network code is added to `agentsd` (037's rule).

**Rationale**: D2. The server needs the internet to reach Anthropic anyway. Almost every image
that runs `sshd` has one of the two.

**Alternatives considered**: the daemon downloads with `URLSession` — breaks 037's no-network
rule and drags FoundationNetworking/libcurl into the static binary. The Mac downloads and streams
(D2's alternative) — noted as the fallback for firewalled servers in a later version; building it
now doubles the install paths.

## R4. How Claude is started from the toolset

**Decision**: On a server, `RuntimeDiscovery` for `claude` looks first for
`~/.agents-server/tools/claude/current/`, and if complete (its `ok` marker exists), starts
`current/node/bin/node current/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js`
with `current/node/bin` prepended to that process's PATH only. If there is no toolset, it falls
back to 037's `npx` on the login PATH (FR-005: the person's own install is used as it is). The
Mac's discovery is unchanged.

**Rationale**: No network on start, and the person's own Node is neither used nor changed
(spec edge case).

## R5. Where the token lives and what reaches the server (D1, D5)

**Decision**: The window stores the secret in the login Keychain (generic password; service
`agents.runtime-credential.<root-id>`, account = runtime id), so a scratch copy on another root
never finds the real one. `credentials.json` in the root holds only kind, last four characters,
added and last-worked dates. The secret crosses to a server only through `credentials/lend` on the
SSH-forwarded daemon socket, only after that server's daemon has asked for it (R6).

The runtime gets it as an environment variable of its own process: `CLAUDE_CODE_OAUTH_TOKEN` for
a `sk-ant-oat…` token (made with `claude setup-token`), `ANTHROPIC_API_KEY` for a `sk-ant-api…`
key. The kind is read from the prefix; anything else is refused at paste with a sentence.
**(spike)** that the env variable wins over a `~/.claude/.credentials.json` sign-in (spec US1-3).

**Rationale**: No file, no argv (argv is world-readable in `ps`). Environment is readable only by
the same user, which the spec's Assumptions already state.

**Alternatives considered**: write `~/.claude/.credentials.json` on the server — on disk,
FR-012. Pass as an argument — visible to every user.

## R6. Lend on demand, per connection (FR-012, FR-015, two-Macs edge case)

**Decision**: When a server daemon must *start a Claude process* for a request (start, a prompt
that relaunches, an answer that resumes, a helper), it looks for a token lent **on the
connection that made the request**. If there is none, it does not start the process and answers
`credentialWanted {runtime}`. The window, on that answer:

- has a token and the server is not "own sign-in only" → `credentials/lend`, then repeats the
  request with the same `sendID` (037's exactly-once), so nothing is started twice;
- has none → shows the in-place ask (FR-015), and after it is pasted does the same;
- server is "own sign-in only" → never gets `credentialWanted`, because the window says so when
  it connects (`credentials/offer` with `ownSignInOnly`), and the daemon then starts Claude with the server's
  own sign-in.

A lent token lives only in the daemon's memory, keyed by connection, and is dropped when that
connection closes. A process already running keeps it in its environment until it exits. Starts
with no connection behind them (a scheduled workflow) use a token lent by the connection that
started the agent if it is still open, else the server's own sign-in; if that fails, the agent
ends with `credentialWanted` shown as "Claude on devbox needs a token — open the app".

The daemon asks only when it cannot find the server's own sign-in *or* the window has said a
Settings token exists (`credentials/offer {runtimes}` on connect, names only), which keeps
D1's "Settings token wins" without sending it ahead.

`credentials/lend` is refused unless the daemon runs with `--serve` (D5).

**Rationale**: Meets "only as part of starting that runtime", "for that run", "neither's token
left behind", and works for every call that might launch, not just `agents/start`.

**Alternatives considered**: a `credential` field on `agents/start` — misses relaunches and
helpers. Lend on connect — sends the token when nothing is starting. A daemon-wide token — the
second Mac's agents would use the first Mac's token.

## R7. Telling a refused token from a dead runtime (FR-016)

**Decision**: The launcher marks sessions started with a lent token. For those, an ACP
`authenticate`-required error, or a prompt error whose message carries 401 /
`authentication_error` / `invalid x-api-key` / `OAuth token has expired`, is mapped to a new
failure `credentialRefused {runtime}`, and the window shows "Claude refused the token in Settings.
Replace it" with a button to Settings ▸ Servers. The window also marks the token's
`lastRefused` date. **Spike, confirmed** (walk/spike.md T009): a refused token of either kind ends the prompt with
`-32603` and `data.errorKind == "authentication_failed"`; that is the matcher. `-32000
Authentication required` is *no* sign-in (→ `credentialWanted`). A bad API key takes ~3 min of
retries before it is refused, so R9's check at save is the early warning.

## R8. A rebuilt server (FR-017–019)

**Decision**: 037 already refuses a changed host key (`HostProblem.hostKeyChanged`, and
`HostKeyCheck` never offers a changed key). The rebuilt sheet shows the new fingerprint (from
`ssh-keyscan`, as 037's add flow does) beside the old one saved in `ServerHost.trustedFingerprint`.
"This server was rebuilt" runs `ssh-keygen -R <name>` (and `-R [host]:port` when the resolved
port is not 22) on the person's own `known_hosts`, then 037's `trust`, then a normal connect —
which finds no `install.json` and installs everything, toolset included.

Project paths: the window records, per server, the paths of the projects it last saw
(`ServerHost.knownProjects`). After a connect, any recorded path the server does not list and
whose folder `files/stat` says is missing is shown as **gone** with Remove; a path the server
lists is live; nothing is ever shown as offline once the server answers.

**Alternatives considered**: `StrictHostKeyChecking=accept-new` with auto-removal — silently
trusts an attacker at the same address, which FR-017 forbids.

## R9. Checking a token (FR-011, SC-006)

**Decision**: The window (not the daemon) calls `GET https://api.anthropic.com/v1/models` with
the credential — `x-api-key` for an API key; `Authorization: Bearer` plus the OAuth beta header for
a subscription token — with a 10 s timeout. 200 → works; 401/403 → refused; anything else → "Can't
check right now", and the token is still saved. **(spike)** which header the OAuth token needs; if
the models endpoint will not take one, an OAuth token shows "Checked the first time a server agent
uses it", and `lastWorked` is set by the first good session instead.

## R10. Updates, purge, and leaks (FR-007, FR-008, SC-003)

**Decision**: The probe's new line reports the installed toolset id. A different id from the
app's is installed beside the old one; `current` moves when no Claude agent on that server is
mid-turn (037's `updateWaiting`, extended to ask the daemon about Claude sessions only); old
toolsets are removed after the next good start. Purge is 037's `rm -rf ~/.agents-server`, which
now holds the tools too, and never the person's own Node.

`scripts/leak-check.sh <token-suffix>` greps the Mac root, `~/Library/Preferences`, the app's logs
and every server's home (over ssh) for the full token, for the SC-003 walk and as a test on the
fake-ssh `HOME`.
