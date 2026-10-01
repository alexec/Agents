# Walk: a sign-in relayed through the control plane (US8, T091)

2026-09-29, on the scratch set-up `/tmp/w9` and the `agents-devbox` container.

## Set-up

- **The control plane.** `agents-control serve` at `https://192.168.0.152:18861`, this Mac's
  LAN address so the devbox reaches it. Self-signed, with a store in `/tmp/w9/store`.
- **The Mac's host.** `agentsd` on `/tmp/w9/mac`, which became `mac`. It was started with
  `AGENTS_TEST_CLAUDE_KEYCHAIN_SERVICE=agents-walk-claude-standin`.
  - It read a stand-in Keychain item, made for the walk with `security add-generic-password`:
    Claude's shape, with an inference scope and a fake token (`sk-ant-oat01-walk-standin-…`).
  - Alex's own Claude sign-in was never read.
- **The devbox's host.** The Linux `agentsd`, rebuilt from this branch, in `~/w9` as the
  `agents` user.
  - `HOME` was an empty folder, because the devbox has a Claude sign-in of its own, which would
    have been used instead of asking.
  - It joined as `devbox w9` (`x8vjjua8`), with a project `p2`.
- **The App Store window**, paired as an operator through the walk hook and launched behind the
  windows in use.

## The steps

| Step | Result |
|---|---|
| The card (`us8-signin-card.png`) | Opening `p2` on the devbox made the window ask Claude there what it offers, and the devbox's daemon said a sign-in was wanted. The window asked: **"Let devbox w9 use this Mac's Claude sign-in?"** — "Its agents will use Claude as you, through this Mac, whenever this Mac is awake. The sign-in itself stays on this Mac. You can stop it in Settings ▸ Control plane ▸ Hosts." — with Don't Allow and Allow. |
| Allow (`us8-signin-after-allow.png`) | The control plane recorded the lend. The Mac's host logged "granted claude for a tunnel". The devbox's daemon logged "relay offered for claude through the control plane, on port 39651". The window's call was then sent again, and Claude on the devbox answered with its modes and models. |
| Bytes through the tunnel | Claude on the devbox reached the Mac's relay through the gate, the devbox's uplink, the control plane and the Mac's uplink. The relay logged each request: a `HEAD /api/hello` without the stand-in (403), then seven `POST /v1/messages` carrying the stand-in, answered by Anthropic. |
| A turn (`us8-signin-refused.png`) | "Say hello in one word." went to Anthropic with the fake token, which it refused (401). The relay tried to renew, which does nothing for a stand-in, and passed the 401 back. The agent stopped with `authentication_failed`, under Needs you. |
| Afterwards | The stand-in Keychain item was deleted (`security find-generic-password` finds nothing). Every process was stopped, and the devbox's `~/w9` removed. The store window's container has its earlier pairing back. |

A real Claude turn through this path needs Alex's own sign-in. The path itself is the one
walked here: only the token read at the end differs.

## Found and fixed

- **A server of a control plane never used a relayed sign-in, and never asked for one.**
  - The daemon took a joined server for a Mac's host (`hostsForControlPlane`, not
    `onServer`), so it never looked at a relay offer.
  - With no offer, Claude started with no sign-in.
  - Now:
    - a relay offered through the control plane is used on any host that has one;
    - a Linux host of a control plane with no sign-in of its own says a credential is wanted,
      which is what makes the window ask.
- **Renewing a stand-in would have spent a real turn.** On a 401 the relay asks the Mac's own
  `claude` to renew, which runs a one-word Haiku turn on the person's real sign-in. With a
  walk's stand-in item, the relay now never renews.

## Found, not fixed

- **The refusal's words.** After the refused turn, the window's composer said "Claude is out.
  The app checks it again at …": the allowance pool's wording for a runtime that ran out, not
  for a relayed sign-in that was refused. It should say that this Mac's sign-in was refused.
