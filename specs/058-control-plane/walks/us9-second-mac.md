# Walk: US9, another Mac as a host (T094, T095)

2026-09-29, from the branch at 67a14a2b. Agents Host (`AgentsHost`, `build/DD-host`) and the
App Store window (`AgentsStore`, `/tmp/store-dd`).

Both Macs were this one, as two scratch Agents Hosts, each launched behind with
`env -i … AGENTS_ROOT=<root> open -g -n` and driven by accessibility:
- **A**, `/tmp/w95a`: the control plane and this Mac's host.
- **B**, `/tmp/w95b`, `AGENTS_HOST_PORT=18792`: the second Mac.

Screenshots are in `walks/us9-second-mac/`.

## T094: already built

- **Agents Host.** Frame L's **Join one elsewhere** came with T054–T059 (`HostModel.joinElsewhere`).
  - It takes only a host code, and says so for any other.
  - It unregisters the control plane's job, leaves the code in the host's root and
    registers only `agentsd`, whose launch agent runs `agentsd --control-network`.
- **The App Store window.** Its `ConnectSheet` offers no host choice under `AGENTS_STORE`.
  Given a host code, Connect stays disabled, and the sheet says to give the code to Agents
  Host.

## T095: the steps

| Step | Result |
|---|---|
| A: **Run It Here** (`host-a.png`) | The control plane ran at `https://alexs-macbook-air.local:18791`, "0 clients · 1 host". |
| A host code | `agents-control code --host --home /tmp/w95a/control`, as Settings ▸ Control plane ▸ Hosts ▸ Add a Mac gives one. |
| B: paste it, **Join** (`host-b.png`) | Within a second B's host "enrolled … as w3656lya" and connected. B's frame L: "This Mac runs its agents for a control plane elsewhere." `launchctl list` showed a daemon job for B and no control job, beside A's two. |
| A project on each | `alpha` added on A's host and `bravo` on B's, over each daemon's socket. |
| A window (`window.png`) | A fresh App Store window, paired to A as operator with the Connect… sheet. **THIS MAC** listed alpha. **ALEX'S MACBOOK AIR**, with its green dot, listed bravo under its own heading. The heading is this machine's name because both hosts ran on it; a second Mac gives its own. |
| B restarted | `launchctl kickstart -k` on B's daemon: it rejoined at once with the membership in its root, and the window's channel opened again. |
| Afterwards | Every walk process was stopped and the jobs booted out; no `agentshost` job is left. The store window's container has its earlier pairing back. |

## Not walked

- **A real second Mac.** Both hosts shared this machine and its name. Nothing in the join
  reads the machine, beyond the name it offers.
- **A turn on B from the window.** Routing to a host that is not this Mac was walked in US3
  and US4, and on the demo host in T093.
- **B's relay row** still says "Not in this build yet" (T096's note).
