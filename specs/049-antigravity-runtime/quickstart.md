# Quickstart: proving Antigravity works

## Prerequisites

- A Mac on this branch, built (`swift build` in `Packages/AgentsKit`; the app per the
  xcodebuild memory note).
- For turns: Alex's Google sign-in (walk) or a Gemini API key in the scratch root's Settings.
- For servers: agents-bare (x86_64) up; the devbox for arm64.

## 1. Handshake only (no sign-in)

`scripts/acp-handshake.sh antigravity` → `agentInfo.version` is the manifest's `version`,
four `authMethods`, `loadSession: true`; `session/new` → `-32000`. `~/.gemini` unchanged
(`ls -la ~/.gemini` before/after).

## 2. Install from the set-up page (scratch root, run-app skill)

Launch on a scratch root with `-ApplePersistenceIgnoreState YES`. The set-up sheet lists
Antigravity **Not on this Mac** with its size. **Install** → byte progress → tick. The root's
`tools/antigravity/current/ok` exists; `shasum -a 256` of nothing is needed (the installer
checked). Screenshot.

## 3. A turn on the Mac

Start an Antigravity agent in a scratch project. Unsigned: **Needs signing in** with the four
methods and the terms line. With a key in Settings: first reply, no browser. Ask it to create a
file and run `ls`: tool calls, a permission card, the diff. Ask it to ask a question: a card
with the answers. Stop mid-turn; resume later: history is there. `runtime-tools.sh antigravity`
does not list `start_subagent`.

## 4. Failures

A bad key → the refused-key sentence with **Replace key**, not a normal reply. Delete
`tools/antigravity/current/ok` → starting says not installed and offers **Install**. Point the
manifest at a wrong checksum (in a test bundle, not the source) → the install failure sentence.

## 5. Server

test-servers skill: add agents-bare, key in Settings, start Antigravity in a server project,
`uname -a` reply; `leak-check.sh` finds the key nowhere on the server. On the devbox (arm64):
the app says Antigravity is not available on ARM Linux and does not install.

## 6. The person's files

After all of the above, `~/.gemini` is byte for byte as before (compare a `find ~/.gemini -type f
-exec shasum {} +` taken at the start).
