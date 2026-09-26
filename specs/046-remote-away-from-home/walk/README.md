# 046 walk

## Done here, on 2026-09-25

- **Kit suites**: 51 relay tests across 8 suites, all green. They cover sealing, order,
  batching, the channel's rules, pairing and forgetting, link choice, and the whole chain
  phone → fake iCloud → Mac → a real daemon on its own socket. That chain includes a
  permission answered once, a prompt sent once with iCloud reordering and repeating frames,
  a 5 MB reply arriving whole, a busy turn kept to a few posts a second, and a forgotten
  phone being cut off.
- **Through the real iCloud**: `agents-bridge --spike-relay` gave a median of 2.57 s and a
  worst of 2.90 s over ten round trips. A 3 MB reply came back whole as an asset, and the
  zone was deleted afterwards. See research R13.
- **Secure Enclave**: HPKE auth mode works with an enclave key in both directions, on this
  Mac's enclave (R13).
- **Builds**: `Agents`, `agents-bridge`, `Remote` (generic iOS Simulator) and the Linux gate
  all build after merging main.
- **Full suite**, three runs after the merge (2040 tests): these failures are all main's.
  - `BlockedTests` (resume and stop timing)
  - `UnreportedEndingTests.theEndingAPersonsPromptOvertook…`
  - `WorktreeStartTests.anAgentCanStartInANewWorktreeOnALocalBranch`
  - `DaemonTests.aListCanLeaveThemOffArchivedAgentsOnly`
  - `PTYTests.aProgramSeesATerminalOnItsOutput`

  Two failures were 046's own, 3 of 3 runs each, and both are fixed:
  - the consistency rules (a decorative glyph's size, and the Away colour);
  - a timing bound in `LinkChooserTests` that was too tight under load.

## Alex's phone (T006, T028, T032, T038, T044, T051, T054)

In one sitting, with a scratch bridge on this branch's build:

    AGENTS_ROOT="$HOME/Library/Application Support/Agents" \
      build/DD/Build/Products/Debug/agents-bridge.app/Contents/MacOS/agents-bridge

That uses the real root, so the real daemon's agents appear. Stop the live bridge on 8790
first, or set `AGENTS_BRIDGE_PORT=8791`. Only one bridge should run the relay for a root.

1. **Pair.** Install Remote from this branch on the phone, which replaces the installed
   Remote. Open it on home Wi‑Fi. Settings ▸ Devices on the Mac lists it, and the root has
   `relay.json`.
2. **Away.** Turn off Wi‑Fi. Within about 10 s the line reads "Away — slower, through
   iCloud".
3. **Answer (SC-001).** Answer a permission from mobile data. It should reach the Mac
   within about 3 s.
4. **Send (SC-003).** Send a prompt. The reply should follow in steps, with nothing missing
   or twice.
5. **Away-only (SC-006).** Try Terminal, Page, Files and the paperclip.
6. **Home (SC-004).** Turn Wi‑Fi back on. The line goes within about 10 s, and an open
   Terminal pane comes alive.
7. **Forget (SC-007).** With the phone away, use Settings ▸ Devices ▸ Forget…. The phone
   shows "Open Agents once on your Mac's Wi-Fi".
8. **CloudKit Console (SC-005).** In the private database, the `relay-*` zones should hold
   only ids, numbers, dates and ciphertext.

## Walked on Alex's iPhone, 2026-09-25 (scratch root)

The scratch root was `/tmp/run-046`, with this branch's app, daemon and bridge. Alex's real
bridge was paused for the walk and restarted afterwards from main's build. The phone was
Alex's iPhone, running this branch's Remote. Every step was on mobile data with Wi‑Fi off
unless it says otherwise.

| Step | Result |
|---|---|
| Pair (Wi‑Fi) | The phone announced and was listed. The daemon wrote `relay.json`, and the bridge was "carrying". |
| Away | A new session came over the relay a few seconds after Wi‑Fi went off: `lastSeenAt` was 03:24:37 UTC. Alex saw "Away — slower, through iCloud". |
| Answer (SC-001) | The agent asked to write `hello.txt`, and Alex tapped Yes on the phone. The daemon took it at 03:25:35 and the agent finished 3.7 s later. The card went "quick" (Alex). The file says "hello from away". |
| Send (SC-003) | "Say hi in one line" is on the record once, at 03:26:45, and "Hi!" came back at 03:26:49. |
| Away-only (SC-006) | Terminal and Files said "Needs the same network as your Mac", and the prompt bar's paperclip was greyed. |
| Home (SC-004) | The Away line went when Wi‑Fi came back. |
| Forget (SC-007) | The first try found a bug: the pair-at-home card was only the empty project list's, so a forgotten phone that still held its list showed "Last heard…" instead. Now the top line on every screen says "Open Agents once on your Mac's Wi-Fi to reach it from anywhere". Reinstalled and walked again: forgotten at 03:36:24, and Alex saw that line. It paired again by itself on Wi‑Fi. |
| Secure Enclave (T006) | The phone's enclave key sealed and opened relayed frames: every step above depends on it. |

Still open: T054, a look in the CloudKit Console, which needs Alex's sign-in. T056, restarting
the real app and bridge onto this work, comes with the merge.
