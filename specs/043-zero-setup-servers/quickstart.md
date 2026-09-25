# Quickstart: proving zero-setup servers

## Prerequisites

- This worktree, re-based on main (037 is merged there as `b36226e`).
- Colima + Docker as for 037's `agents-devbox` (memory: linux-devbox-container).
- A Claude token: `claude setup-token` on the Mac (Alex's to make and paste; it is his account).

## 1. Fast checks (no network)

```sh
swift test --package-path Packages/AgentsKit --filter 'ToolsetInstall|Lend|CredentialKind|RebuiltServer'
```

Expect: install from the fixture mirror succeeds and writes `ok`; a bad checksum, no downloader,
a full disk and a failing `npm ci` each leave no `tools/claude/<id>` and give their sentence;
a lend is refused on a Mac daemon; a start with nothing lent answers `credentialWanted` and
starts nothing; a retry after lend starts exactly one session with the variable set; closing the
connection forgets the lend; the token appears in no file under the fake `HOME` or the test root.

Then the Linux build gate for both architectures, as 037.

## 2. A bare server

```sh
docker run -d --name agents-bare -p 127.0.0.1:2223:22 <image: debian:bookworm + openssh-server curl ca-certificates, user agents, your key>
```

`~/.ssh/config`: `Host agents-bare` → `127.0.0.1`, port 2223, user `agents`.
Check it is bare: `ssh agents-bare 'command -v node npx claude; ls ~/.claude'` prints nothing.

## 3. The walk (test-servers skill, scratch root)

1. Settings ▸ Servers: paste the token → "Works" within 10 s (SC-006).
2. Add a server `agents-bare` → checklist shows Install Claude with progress → ready.
3. New project on it, start Claude: "create hello.txt and run uname -a" → reply; the file is on the
   box; no command was typed on the box (SC-001, time it from step 2).
4. Leak search (SC-003): `scripts/leak-check.sh <token>` over the scratch root, preferences,
   logs, and `ssh agents-bare` home → no hits.
5. Rebuilt (SC-004): `docker rm -f agents-bare` and run it again on the same port → relaunch the
   window → "devbox has a new identity" → This server was rebuilt → a new Claude agent answers;
   the old project shows "Gone from agents-bare".
6. Refused (FR-016): replace the token with a revoked one → next server agent stops with "Claude
   refused the token in Settings. Replace it."
7. Own sign-in only: toggle it on `agents-devbox` (which has Alex's `claude login`) → agents there
   still answer and `credentials/lend` never appears in its daemon log.
8. Update (US4): bump the lock with `scripts/update-claude-toolset.sh`, rebuild, connect with an
   agent mid-turn → "update waiting for a turn to end" → swaps after.
9. Remove with purge → `ssh agents-bare 'ls -a ~'` shows no `.agents-server`.
