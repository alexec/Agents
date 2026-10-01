# Security review (T102)

2026-09-29, `security-review` on `agents/control-plane` against `main`, at 2b41febb.

It ran in two steps: one pass found candidates, and a second checked each against the
false-positive rules. Only findings rated 8 or higher in that second check are reported.

## Result

**None were reported.** One candidate was confirmed as real but rated 6/10 (Medium), below the
bar. It was fixed anyway.

### Fixed: a host could make itself a relay with its own `host/hello`

- **Where:** `ControlMethods.hostSaid(.hostHello)` set `record.relay = true` whenever a
  host's hello said `relay: true` and it had no relay setting yet. Every host that runs
  agents has none.
- **The contract:** "A host that runs agents cannot be made one." `hosts/setRelay` kept to
  that; the hello did not.
- **What the stolen host key would give.** Someone holding one server's host key could
  promote that server. From then on it:
  - heard `relay/deliver`, with other hosts' plaintext headlines (project, agent title, what
    is wanted);
  - heard `relay/devices`;
  - could drop every device's notices, if its id sorted first;
  - could advertise its key as `relayKey`.
- **What it could not do.** Relayed device sessions stay end to end with the control plane
  (`ControlRelayDial`), so a false relay could carry or drop them, never read them.
- **The fix.** The hello no longer changes whether a host relays. That is settled at
  enrolment (`hosts/announce`) and changed only by an operator (`hosts/setRelay`). The
  control-plane tests (33) and the AgentsKit `Control` tests (95) pass.

## What held up

- **The operator role from the network.**
  - `ControlMethods.answer` lets any grant call only `daemon/ping`, `control/status` and
    `hosts/list`.
  - `ControlRouter.toHost` checks the grant on every call and notification.
  - `acceptVirtual` binds device channels to `.device`.
  - The grant always comes from the stored code or record, never from the client.
- **The key exchange.**
  - MACs are bound to both nonces, the identity and the dialled origin, and compared in
    constant time.
  - A code's secret is derived again from its id, and the code is spent before the record
    is written.
  - Points are checked to be on the curve.
  - With no pin, both `WebSocketLink` and `ControlDial` fall back to full system trust,
    never to accepting anything.
  - The missing TLS channel binding is covered by the pin or by public trust, as designed.
- **Copies.**
  - `x:` needs a key derived from the control plane's private key, and the origin binding
    stops a forged `copies/` record re-pointing it.
  - A single copy refuses `x:`.
- **The key's delivery.** On inherited descriptors, or from the keychain. Nothing secret is
  logged.
- **The store.**
  - `FileStore.url` refuses `..`, dot segments and absolute keys.
  - Keys are built from UUIDs, hex ids and generated host ids.
  - `/v1/servers/` serves only allow-listed names.
- **The ssh install.**
  - `--` comes before the destination, and every value is shell-quoted.
  - The one-liner's code is base64url inside single quotes.
  - `--pinnedpubkey` holds even with `--insecure`.
- **Tunnels.**
  - `tunnel/open` works only for a lend an operator allowed.
  - The lender connects only to its own relay port for a runtime it granted.
  - The stand-in bearer is still required.
- **The relay (T096).** A relayed session must be a device client that names itself.

## Below the bar, noted

- **The other `host/hello` fields are the host's own word too.** A host can rename itself.
  With the control plane's `machineID`, it could also become home on a control plane of
  servers alone; clients see that ID, hosts do not.
- **`ControlPlane.attachDevice` on the bridge path** reuses an existing record's grant for a
  device id. It would give operator only if a device chose an operator's UUID, which
  devices cannot list.
