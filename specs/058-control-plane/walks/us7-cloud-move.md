# Walk: T129, the control plane to the cloud and back (#61)

2026-10-02, 19:55–20:20 local (02:55–03:20 UTC), from `agents/move-github-issue-61` at
`0dc1355e` plus the fix found here (`f54aaf33`). It ran by command sequence: the steps
`MachineMove` and `MachineReturn` run, through `agents-control handover`. **The sheets on
screen were not walked:** Alex was at the keyboard. See *Not walked*.

## Set-up

- **The cloud machine:** `deploy/pebble/up.sh --devbox` with `AGENTS_CONTROL_RECEIVE=1`.
  That is `compose.public.yaml` behind Caddy, with a certificate from Pebble standing in for
  Let's Encrypt at `https://agents.127.0.0.1.sslip.io:8444`. Its store is a folder in the
  data volume, as Alex chose for his own machine.
- **This Mac:** run-app's scratch root, `launch.sh --slug t129 --lan`: `agents-control serve
  --home` at `https://192.168.0.168:56536`, pinned and self-signed, as Agents Host runs it.
  Its host is enrolled with a code, and trusts Pebble's root through
  `AGENTS_TEST_TRUST_ROOT`.
- **A Linux host:** in the devbox, joined with the pinned install command, under
  `HOME=/tmp/t129host`, so the box's own `~/.agents-server` was left alone.
- **The store window:** the `AgentsStore` Debug build, copied and re-signed ad hoc as
  `com.alexecollins.agents.walk`, with an ATS exception for `sslip.io` (as in
  `public-cert.md`). Launched behind, paired by the walk hook.
- **The key:** this Mac's `control/control-key` copied to `deploy/secrets/control-key`,
  and the cloud copy recreated (frame P).

## What was checked

| Frame | Step | Result |
|---|---|---|
| Q | `status` at the cloud and at `self` | Cloud: receiving, no records. This Mac: serving; the window, this Mac's host and the Linux host online, each at epoch 0 (a build that keeps a list). |
| — | Linux host stopped (`kill` by its lock) | Offline through the whole announce: **the member offline through the announce**. |
| R | `announce --at self --endpoint <cloud>` | Epoch 1: this Mac's address with its pin, then the cloud's with none. Within 5 s **the window** and this Mac's host held epoch 1. This is the first time a window was seen taking a list (T125). The Linux host stayed at 0. |
| — | One record planted in the cloud's store (`copy --from` a one-record folder), then `freeze`, then `copy --from self --to <cloud>` | `conflict(key: "v1/people/…")`, part-way through: **the copy failure**. |
| — | `unfreeze --at self` (what `stop(at:)` does) | Serving at epoch 1 again. Every member was still online with the same epoch: nothing had changed for anyone. The cloud copy now held partial records, so frame Q would refuse it ("It already holds a control plane"). Its volume was emptied and it started again, receiving. |
| S | `freeze`, `copy`, `take --at <cloud>`, `forward --at self` | 16 records copied (leases and copies left out). The cloud copy took over at epoch 2, and this Mac's copy is forwarding until 2 November. Within 6 s the window and this Mac's host were online at the cloud copy at epoch 2, **with the same ids**. |
| T | The Linux host started again | Its membership said only this Mac's address. Its log: `a host of run-t129 at https://192.168.0.168:56536` → `the control plane is now at https://agents.127.0.0.1.sslip.io:8444` → `connected`. **It came back through the forwarder**, and is online at the cloud as `ud7o02ga`, epoch 2. |
| — | This Mac's forwarding copy killed and started again, the same way | `phase forwarding`, `until` unchanged (#61 P4, `da99ed0e`). Before P4 it would have come back serving its frozen store. |
| — | A turn on each host | This Mac's host: `finished`. The Linux host: `finished`, after it was restarted with the box's own `HOME` for Claude's sign-in, on the same root and id. The window's channel to it opened through the cloud copy. |
| V–W | This Mac's copy stopped, its store kept aside as `store-before-t129`, started with `--receive`; `announce --at <cloud> --endpoint self` | This Mac: receiving, no records. The cloud copy at epoch 3, with the cloud's address and then this Mac's, with its pin. All three members held epoch 3 within 5 s. |
| X | `freeze --at <cloud>`, `copy --from <cloud> --to self`, `take --at self`, `forward --at <cloud> --endpoint self` | 17 records back. This Mac took over at epoch 4, and the cloud copy is forwarding. All three members are online at this Mac at epoch 4, with the same ids. |
| Y | This Mac's copy started again as Agents Host would (no `--receive`, with `--no-forwarding`); a turn on each host | Serving; all three online; both turns `finished`. |
| Y | The cloud container restarted | **Failed. Fixed in `f54aaf33`**, see below. After the fix: `forwarding again until …`. Then `stop --at <cloud>`: forwarding ended. |

### T128 on a real bucket (MinIO), the same evening

- Two copies served one bucket prefix, `s3://agents-walk/t128-…` on the `agents-minio`
  container, at different addresses. A third copy, with the same key, served a folder.
- `handover shares`: the two bucket copies are `the same store`. The folder copy: `not the
  same store`.
- `announce` at the first copy listed its own address first, though the second copy had
  written its own `url` into the shared settings when it started (the bug fixed in
  `da99ed0e`).
- `freeze` and `forward`, with no copy and no take: the second copy serves epoch 2 with
  only its own address, once its 15-second refresh has read the settings.

## Found and fixed

- **A cloud copy started with `--receive` crash-looped once it had forwarded back.** Move to
  Another Machine… tells the person to start the cloud copy with
  `AGENTS_CONTROL_RECEIVE=1`, and that stays in its environment. After the return, the
  records' first address is this Mac's. So on a restart, the receive check took the store
  for a half-finished handover (`this store holds records from a handover that didn't
  finish`) and exited, before the forwarding note was read. Now a receiving copy whose
  store holds its own forwarding note serves and forwards again. Tested
  (`aForwardingCopyForwardsAgainAfterARestart`), and walked with `docker restart`.

## Not walked

- **One move refused by a host on an older build.** No Linux `agentsd` from before lists
  was at hand: the stale one in `App/Resources/servers` doesn't read its join code. The
  refusal (`0dc1355e`) is proven by `anAnnounceIsRefusedWhileAHostCantFollow`, a host
  enrolled that never said an epoch. A real older host would need an `agentsd` built from
  before T122.
- **The sheets on screen** (frames O–Y): Alex was active throughout. This session now has
  Accessibility (`AXIsProcessTrusted` true), which `t126-move.md` lacked. So the sheet
  walk can run, with the screen leased, once Alex is away. It needs a scratch Agents Host
  on `AGENTS_ROOT` and AX setting the address field, which may not reach SwiftUI's
  binding.
- **The Remote on a phone** over the public certificate: it needs a real Let's Encrypt
  certificate on a real name (T131).
- **The bucket move through the sheets.** The commands and the MinIO run above stand in.
