# US2 walk: the token is gone (2026-09-26)

**The saved token is deleted (FR-010).** Scratch root `/tmp/run-c56c` was seeded the way an
earlier version leaves it: `credentials.json` with a Claude `oauthToken` record and a Gemini
record, plus Keychain items under the root's service
(`agents.runtime-credential.<sha of the root>`). Both were made up. On this branch's first
start:
- the Claude item was gone (`security find-generic-password`, metadata only) and the Gemini
  item was still present;
- `credentials.json` held only `gemini`.

**Found**: the Gemini item had been made with `security add-generic-password -A`. When the
app read it, SecurityAgent prompted and the app hung in `SecItemCopyMatching`. Items made
by `security` sit in Apple's partition, and `-A` doesn't change that. The app and its
daemon were stopped by pid and the item deleted. This is a walk-setup hazard, not the
app's: a real Gemini key is saved by the app itself. Deleting the Claude item raised no
prompt.

**No token anywhere (FR-011)**: `grep -rn "setup-token\|needs a token\|refused the token\|sk-ant-oat\|sk-ant-api"`
over `App/Sources` and `Packages/AgentsKit/Sources` finds only the relay's stand-in constant
and a comment.

**signInWanted on a real server**: `AGENTS_BARE=1 swift test --filter aBareServerGetsClaudeAndWithNoRelaySaysTheMacIsNotSignedIn`
passed against agents-bare with this branch's Linux agentsd. With no relay and no sign-in
on the box, Claude is installed, and starting it answers `-32070` rather than asking for a
token.

**Not yet seen**: the screen was locked (idle 17 min), so window captures failed and the
accessibility tree had no windows. Still to do once it's unlocked:
- the Settings ▸ Servers screenshot (no Claude row, the new footer), which is the look gate;
- the sign-in sheet raised by `signInWanted`, which needs
  `AGENTS_TEST_CLAUDE_KEYCHAIN_SERVICE` set to a missing item (a Debug-only override).

## Look gate (2026-09-26, 10:57, Alex away)

`US2-settings-servers-mac-signed-out.png`: a scratch root with
`AGENTS_TEST_CLAUDE_KEYCHAIN_SERVICE` set to a missing item, and agents-bare added:
- **Runtime credentials** shows Gemini alone;
- the footer reads "Claude and Codex on a server use this Mac’s own sign-ins, through this
  Mac; …";
- the server reads "Claude: ready (installed by Agents) · needs this Mac signed in to it"
  beside "Codex: … · signs in through this Mac".

**The sign-in sheet was not reached.** It needs a start from the window's own Send, which
means typing into the prompt. The script that focused the prompt hung, and killing it let
the chained keystrokes run. They went to the frontmost app, which was Alex's real Agents
window (pid 43700), not the scratch one. No prompt with that text appears in the real app's
data. The sheet walk is left for Alex, or for a later walk that checks the front pid before
typing.
