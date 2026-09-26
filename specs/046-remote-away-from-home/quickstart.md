# Quickstart: Proving the Relay

## What you need

- This worktree built: `agents-bridge` and `Remote` (see the xcodebuild memory: skip plugin
  validation, and build the schemes one after another).
- Alex's iPhone, on the same iCloud account as the Mac, with Remote installed from this branch.
  An install replaces his own Remote; ask first.
- A scratch root (run-app skill), and a scratch bridge for it on a spare port, e.g.
  `AGENTS_ROOT=/tmp/run-046 AGENTS_BRIDGE_PORT=8791`. The real bridge on 8790 is left alone
  unless Alex says otherwise.

## 1. In-process (no hardware)

```sh
swift test --package-path Packages/AgentsKit --filter Relay
```

Expect green on: sealing (wrong key, wrong session, changed `seq`), `FrameOrder` (reordered,
duplicated, 10 s gap ends the session), batcher sizes and times, a 5 MB reply arriving whole,
`LinkChooser` (direct wins within 2 s, relay otherwise, handover back to direct), a prompt sent
exactly once across a forced link change, and `devices/forget` refusing relayed frames.

## 2. Spike (research R13), on the phone

1. Launch Remote with `-spike-relay`. It prints whether HPKE auth-mode sealing with the Secure
   Enclave key works.
2. Run `agents-bridge --spike-relay`, with Wi‑Fi off on the phone. Ten round trips: record each
   time and the worst one in `research.md` R13. The target is ≤ 3 s (SC-001).

## 3. The walk

| Step | Do | Expect |
|---|---|---|
| Pair | Phone on the Mac's Wi‑Fi, open Remote | Settings ▸ Devices lists the phone. The scratch root's `devices.json` has `relayKey` |
| Leave | Turn Wi‑Fi off with a chat open | "Away — slower, through iCloud" within 10 s. The chat keeps updating |
| Answer | Start an agent that asks a permission; Allow on the phone | The agent carries on within 3 s (SC-001) |
| Send | Send "list the files in this folder" | Confirmed within 3 s. The reply matches the Mac window, with nothing missing or twice (SC-003) |
| Away-only | Tap Files, Terminal, Page and the paperclip | "Needs the same network as your Mac". Nothing spins (SC-006) |
| Switch mid-send | Send a prompt and turn Wi‑Fi on at once | It arrives once. The Away line goes within 10 s. The open Terminal pane becomes live (SC-004, FR-012) |
| Look in iCloud | CloudKit Console ▸ private DB ▸ `relay-<id>` zones | Only ids, numbers, dates and ciphertext (SC-005) |
| Forget | Settings ▸ Devices ▸ Forget, with the phone away | Within a minute the phone shows the never-paired card, and nothing it sends is carried out (SC-007) |
| Re-pair | Phone back on Wi‑Fi | Paired again, and away works again |

Screenshots go to `specs/046-remote-away-from-home/walk/`. The phone steps are Alex's hands.
