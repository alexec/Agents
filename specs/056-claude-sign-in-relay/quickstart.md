# Quickstart: proving 056

Every walk runs on a scratch root (the run-app and test-servers skills), never on the real
app. The Mac's Claude sign-in is Alex's own Max sign-in. It's read, never written or
renewed by app code, and never printed.

## Prerequisites

- Claude on this Mac signed in with a Claude account: `claude auth status` says
  `"authMethod": "claude.ai"`.
- agents-bare (`.agents/skills/test-servers/scripts/bare.sh up`, then `rebuild` for a blank
  disk) and agents-devbox (`devbox.sh up`).
- No Claude credential in the scratch root's Settings (there's no longer a way to add one).

## 1. Claude on a bare server, nothing pasted (US1, SC-001, SC-002)

1. Scratch window: add `agents@127.0.0.1:2223`. The checklist runs **Install Claude**
   without asking.
2. Runtime menu for the server: `Claude: ready (installed by Agents) · signs in through
   this Mac` (contracts/ui.md).
3. Start Claude in a project on the server. Ask: "Run uname -a with the Bash tool and reply
   with its output only." Expect the box's kernel line. Time from Add to reply: under
   5 min.
4. `<root>/hosts/relay.log` shows `POST /v1/messages -> 200` lines, and no headers or
   bodies.
5. Leak search: pipe the last 24 characters of the access and refresh tokens (read with
   `security … -w | python3 …`, never echoed) into
   `scripts/leak-check.sh $ROOT ssh://agents@127.0.0.1:2223`. It must say `clean`.
6. A helper started by that agent (028) answers too. So does an agent started through the
   daemon socket as the Remote would.

## 2. The token gone (US2, SC-005)

1. Before upgrading the scratch root, save a made-up `sk-ant-oat01-…` with the previous
   build, so `agents.runtime-credential.claude` exists in the Keychain. Check with
   `security find-generic-password -s agents.runtime-credential.claude` (metadata only).
2. Start the new build on that root. The item is gone, Gemini's (if any) is kept, and
   `credentials.json` has no `claude` record.
3. Screenshot Settings ▸ Servers: no Claude row, and the new footer. This is the look gate.
4. `grep -rn "setup-token\|needs a token\|refused the token" App/ Packages/*/Sources` finds
   nothing.

## 3. The endings (US4, SC-006)

- **Mac signed out.** Use a scratch `CLAUDE_CONFIG_DIR`-style override for the Keychain
  service name (a test hook in `ClaudeKeychainSignIn`), never Alex's real sign-out. Starting
  Claude on agents-bare ends within 10 s with "Claude on this Mac isn't signed in with a
  Claude account." and the two buttons.
- **Own sign-in only.** On agents-devbox, which has its own login, mark it. A turn works,
  and `relay.log` gains no lines.
- **Not marked, server signed in.** The same box, unmarked. `relay.log` gains lines (D7).
- **Offline.** Stop the ssh master mid-turn. The turn ends with 037's offline sentence.

## 4. Nobody else (US5, SC-004)

On agents-devbox, as a second account (`useradd -m other`, via `devbox.sh ssh 'sudo …'`),
`curl -sk https://127.0.0.1:<gate port>/v1/messages` gets a refusal. `relay.log` says
`refused` with the uid. The person's own turn still works.

## 5. Renewal (US3, SC-003)

1. **Spike (research R6).** Just after the Mac's access token naturally expires (read
   `expiresAt`), with no Claude running on the Mac, run `claude auth status` and read
   `expiresAt` again. If it moved, that's the command. If not, the one-token turn is. Record
   the answer in research.md R6.
2. **Walk.** Start a long job on a server (a loop that asks Claude something every 10 min),
   leave Claude on the Mac idle across an expiry, and confirm:
   - the job carried on;
   - `relay.log` shows one `renewing` line per expiry;
   - `claude auth status` on the Mac still says logged in afterwards.
3. **Unit tests.** They cover the single in-flight renewal, with two waiters and one renewal,
   and "renewed by someone else first" with a fake source.

## Also update

- `.agents/skills/test-servers/SKILL.md`: section 1 still describes pasting a token.
- The docs listed in spec.md § Docs.
