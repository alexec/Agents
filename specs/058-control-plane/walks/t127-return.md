# Walk: T127, Run It Here Again (#61)

2026-10-01, 21:23–21:26 UTC, from `agents/work-first-part-github` at `1295b495`, with Pebble
and a Linux host in the devbox. **The sequence is walked; the sheet on screen is not**: this
session still has no Accessibility (`AXIsProcessTrusted` false, as in `t126-move.md`).

## Set-up

As the second half of `t126-move.md`, and then moved away first:
- **The other machine:** `deploy/pebble/up.sh --devbox` (`compose.public.yaml` behind Caddy,
  Pebble's certificate), the Linux control plane rebuilt with `handover stop`.
- **This Mac:** `agents-control serve --home` on 18791 at
  `https://alexs-macbook-air.local:18791`, pinned, as Agents Host runs it, and this Mac's
  host on it; a Linux host in the devbox, joined with the pinned install command.
- **The move away (T126):** 11 records to the cloud copy, forwarding until 31 October; both
  hosts there at epoch 2. This is where frame U starts.

The steps are the commands `MachineReturn` runs, with `--home` and `--port` as
`HandoverTool` passes them.

## What was checked

| Frame | Step | Result |
|---|---|---|
| V | `status --at <cloud>` | Serving: "answers, and holds this control plane's key". |
| V2 | `status` at port 8445 | `Connection errors`: "doesn't answer". |
| V | `prepareReturn`: the forwarding copy stopped, its store kept aside as `store-before-2026-10-01`, the copy started with `--receive` | `status --at self`: receiving, no records. `self` came from `--home` (address and pin), since the empty store says nothing. |
| W | `announce --at <cloud> --endpoint self` | Epoch 3: the cloud address, then this Mac's with its pin. **Both hosts knew it at once** (read from the cloud copy). |
| X | `freeze --at <cloud>`, `copy --from <cloud> --to self`, `take --at self`, `forward --at <cloud> --endpoint self` | 12 records copied back; this Mac took over at epoch 4; the cloud copy forwarding until 31 October. |
| Y | `status --at self` | Both hosts online at this Mac within a second, at epoch 4. The Linux host's membership: only `https://alexs-macbook-air.local:18791`, with its pin. |
| Y | `stop --at <cloud>` | Forwarding ended at once. |
| Y | this Mac's copy restarted without `--receive`, as the launcher starts it once it's back | Serving its records, epoch 4; this Mac's host reconnected. |

## Not walked

- **The sheet on screen (frames U–Y)**, for the Accessibility reason in `t126-move.md`.
- **The window and phones following back.** They use the same list as the hosts (T125).
- **Cancel part-way back.** `cancel()` unfreezes and withdraws at the cloud copy, then
  stops this Mac's empty copy; the move's equivalent was walked in T126.
