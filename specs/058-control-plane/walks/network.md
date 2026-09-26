# Network walk — pairing a Mac and enrolling a host by code (2026-09-26)

Build `dcfe57e4`. There were three scratch roots on this one Mac, each playing a separate machine:

- **A**, `/tmp/run-na`: a window that ran Run one on this Mac. Its control plane listened with TLS on port 8798.
- **B**, `/tmp/run-nb`: a fresh window that joined A's control plane over the network.
- **studio**, `/tmp/run-nc`: an `agentsd` posing as another machine (`AGENTS_MACHINE_ID=studio-machine`). It enrolled with a host code.

Buttons were pressed by AX by exact title; codes were read off the sheets' accessibility values.

## What was seen

1. **Nothing listens until it has to.** With no client key and no code, A's control plane had no network listener. Only its local sockets were open.
2. **A · Pair a Mac** ([net-g-pair-a-mac.png](net-g-pair-a-mac.png)) showed a live operator code. It said where to reach the control plane (`alexs-macbook-air.local:8798`, `127.0.0.1:8798`) and counted down from 4:56. The TLS listener came up on 8798 as soon as the code existed.
3. **B · Connect** ([net-c-connect.png](net-c-connect.png)): Bonjour listed A's control plane by name (`_agents-control._tcp`), and the code was pasted.
   - Connect paired B: A logged "paired as operator", and B wrote `control-client.json` and `control-client-key`.
   - B then connected with its own key: "client … connected over the network". It started no daemon of its own.
4. **B sees A's work** ([net-b-sees-a.png](net-b-sees-a.png)): a project added on A's host appeared in B's window at once.
5. **Add by Code** ([net-e-host-joined.png](net-e-host-joined.png)): A's Hosts ▸ Add by Code… gave a host code.
   - `agentsd --control-code <code> --host-name studio` enrolled (as `xgkhesos`), saved its membership and key in its own root, and dialled in over TLS.
   - Its first dial landed while the listener was being remade for its new key; the uplink's one-second retry got in.
   - A's Hosts page showed studio as "connects out" within a second.
6. **B's Settings** ([net-b-hosts.png](net-b-hosts.png), [net-b-clients.png](net-b-clients.png)): B saw the same two hosts, and itself as "This window · you".
7. **Forget** ([net-b-forgotten.png](net-b-forgotten.png)): A forgot B from its Clients page.
   - B's window said "Not connected to the daemon" at once.
   - A's listener was remade with only studio's key, so B's key no longer opens it.

## Fixed after the walk (tests pass; not re-walked on screen)

- A's own window was listed to others as "This Mac". It is now named for the Mac. The local window's record is found by being the only client with no key.
- The code sheet kept showing a spent code. It now says who joined with it and that it can't be used again.

## Tests

- `ControlNetTests` (5), over real TLS on loopback:
  - a code reads back as written;
  - a host enrols and a paired window reaches it through the control plane, as an operator, and `control/status` names it;
  - a code works once;
  - a device-grant client is refused `credentials/lend`;
  - a forgotten client's key stops being taken, and its next dial fails.

## Open

- Keys and memberships are `0600` files in each root, not the keychain (R8 had it in the keychain on a Mac).
- A window paired with a control plane elsewhere still treats host `mac` as its own Mac (R11, T025).
- Phones still pair with the bridge on 8790. Moving them onto the control plane is US4.
- Linux hosts can't dial out yet (spike S1); they join over ssh in US3.
- The codes are long, one line to paste. Frame G drew a short `AGT-…` code.
