# US1 walk: Claude on agents-bare with nothing pasted (2026-09-26)

Scratch roots `/tmp/run-c56` then `/tmp/run-c56b`, this branch's build. agents-bare rebuilt
blank (`bare.sh rebuild`). No Claude credential anywhere in Settings. The Mac's Claude is
signed in with Alex's Max account.

1. **Add a server** (`agents@127.0.0.1:2223`): the fingerprint matched `bare.sh rebuild`'s,
   and the checklist ran **Install Claude** without asking. Runtimes found: Claude and
   Codex. See `US1/add-server-checklist.png`.
2. **Found in the walk and fixed**: on the first root, no relay was offered on the first
   connection, for Codex either. `HostSet.relayFor` treated a host not yet saved as "own
   sign-in only", and the Add flow saves the host only after it connects. The fix treats
   a host being added as not marked. On the second root the server's daemon logged
   `relay offered for claude` and `relay offered for codex` on the first connection.
3. **A real turn**: `agents/start claude` "Run uname -a…" finished in 6 s and replied
   `Linux 78d08dc49875 6.8.0-117-generic … aarch64 GNU/Linux`. `relay.log`
   (`US1/relay.log`) has `HEAD /api/hello` and `POST /v1/messages -> 200` lines, and
   nothing but method, path and status.
4. **Leak search**: `scripts/leak-check.sh /tmp/run-c56b ssh://agents@127.0.0.1:2223`,
   with the Mac's access token and then its refresh token on stdin: `clean` both times.
5. **Codex unchanged (T015)**: a Codex turn on the same server went through its relay
   (`POST /backend-api/codex/responses -> 200`) and finished.
6. **Settings ▸ Servers** (`US1/settings-servers.png`): "Claude: ready (installed by
   Agents) · signs in through this Mac", beside Codex's same line. The Claude token row is
   still there until US2.

Not walked separately:
- A helper started by the server agent (028) and an agent started from the Remote. Both
  start through the same `launchEnvironment`. The start above came over a connection of
  its own (not the window's), and was served by the window's offer, which is the path
  both take.
