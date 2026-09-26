# US1 — a bare server runs Claude

## Headless, against the real bare box (2026-09-25)

`AGENTS_BARE=1 swift test --filter BareServerLiveTests` after `bare.sh rebuild` (a new Debian
container: ssh, curl, xz, git; no Node, no Claude, no sign-in), with the real Linux `agentsd`
(aarch64, sha 9114420d…) and the pinned toolset (`c2d518996dc5368e`: Node v24.21.0,
claude-agent-acp 0.81.2), over real `/usr/bin/ssh` through a wrapper that writes no known_hosts.

Passed in **12.6 s** from the first connect: daemon installed and started, Claude's toolset
downloaded, checked, installed and swapped in (`bin/npx` shim written), project added, and
`agents/start` for Claude:

1. the server answered `credentialWanted {claude, offered: true}` and started nothing;
2. `DaemonClient`'s lender lent the (made-up) token on that connection, **once**;
3. the same start, sent again, made one agent;
4. its first prompt came back from Anthropic as a 401; the transcript says
   "Claude refused the token in Settings. Replace it in Settings ▸ Servers." and not
   "stopped answering";
5. `grep -rF` for the token over the server's `$HOME` and `/tmp`: nothing. `~/.claude/` has
   only what the SDK makes for a session (`projects/`, `sessions/`, `backups/`), no
   `.credentials.json`.

Still to do with the window and a real token (Alex's): a turn that answers (SC-001), the
Settings check saying Works, the ask-in-place card, and SC-003's leak search after real use.
