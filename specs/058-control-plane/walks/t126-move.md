# Walk: T126, Move to Another Machine (#61)

2026-10-01, 15:40–15:50 UTC, from `agents/work-first-part-github` at `c5fbf7eb` and the
fix below. **The sequence is walked; the sheet itself is not yet**: see *Not walked*.

## Set-up, and why it isn't Pebble

- **Pebble couldn't run.** The Colima VM's disks failed writes (`EXT4-fs … I/O error`,
  containerd `input/output error`), so no container could start, Pebble's included. The Mac
  has 55 GB free. Restarting Colima would also restart the devbox, MinIO and the demo,
  which other agents use, so it is Alex's call.
- **The stand-in was the same in kind:** a local test root (`openssl`, P-256) signed a
  certificate for `agents.127.0.0.1.sslip.io`, trusted only through
  `AGENTS_TEST_TRUST_ROOT` in Debug builds, as Pebble's root was in the R15 walk.
- **The other machine:** the macOS `agents-control` from this build, run natively with
  `--receive` (`AGENTS_CONTROL_RECEIVE=1`), terminating TLS itself with that certificate on
  127.0.0.1:8444, its store in a folder of its own.
- **This Mac:** `agents-control serve --home` on port 18791 at
  `https://alexs-macbook-air.local:18791`, with its self-signed pin, as Agents Host runs it,
  and `agentsd` enrolled with a host code, as Agents Host's launch agent runs it.
- **The commands** were the ones `MachineMove` runs, with this Mac's key read from its home
  (Agents Host hands it over on a descriptor instead).

## What was checked

| Frame | Command | Result |
|---|---|---|
| Q2, wrong key | `handover status --at <cloud>` before the key was copied | `Refusal(… wrongControlPlane)`: the sheet's "It holds a different key". |
| Q2, untrusted | the same with no test root | `handshakeFailed … CERTIFICATE_VERIFY_FAILED`: "Its certificate is publicly trusted" fails. |
| Q2, nothing there | port 8445 | `connection reset`: "It answers" fails. |
| Q | after the key went across and the copy restarted | `phase receiving`, `records none`: all four ticks. |
| R | `announce --at self --endpoint <cloud>` | Epoch 1, both places listed; this Mac's host reconnected and **knows** epoch 1 (after the fix below). |
| S, called off | `freeze`, `unfreeze`, `withdraw` | Back to serving, epoch 2, this Mac's address alone; the host saved that and stayed connected. |
| S | `freeze`, `copy --from self --to <cloud>`, `take`, `forward` | 9 records copied; the cloud copy took over at epoch 4; this Mac's copy forwarding **until 31 October** (30 days). |
| T | `status --at <cloud>` | This Mac's host online there within a second, holding epoch 4, its membership saved with the new address only. |

## Found and fixed

- **A member that had just been told showed as not knowing.** It reports its epoch on the
  connection *after* the one that gives it the list, so frame R would have said "Can't
  follow" for this Mac's own host. Now a build that keeps a list always sends an epoch
  (0 for none), and the control plane counts it as told with the list it hands out. A build
  that sends none is exactly one that can't follow. Test:
  `aMemberIsCountedAsToldOnTheConnectionThatTellsIt`.
- **A copy's own `url` was overwritten by the list,** so after forwarding `self` would have
  pointed at the new machine. `url` and `pin` stay the copy's own; the list is only
  `endpoints`.

## Not walked

- **The sheet on screen (frames O–T).** This session lost Accessibility and Screen
  Recording when the app restarted: `ui.swift press` says "No Accessibility permission",
  and a screen capture is black. The window's walk copy also opened no window, so it
  couldn't pair. The sheet is built and compiles; its commands are the ones above. A
  look needs those permissions back for whatever runs this session.
- **A Linux host following, and Pebble itself**, with Colima broken. The Linux host follows
  through the same `ControlJoin.hostDial` as this Mac's host, covered by
  `aHandoverMovesEveryMemberWithoutPairingAgain`.
- **The window and the Remote following** (T125), for the same reasons.
- **Save Key…'s panel**, which needs a click.
