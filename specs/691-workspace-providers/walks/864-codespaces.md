# Walk: Codespaces with a real codespace, through its API and its CLI (#864, 2026-10-19)

On the Go control plane, with the API preset from #1119 (`codespaces-api`) and the CLI preset
(`codespaces`), one after the other on the same codespace.

| Step | API preset | CLI preset |
|---|---|---|
| List | the codespace, `running`, ssh `cs.<name>.main` (gh's `--config` host), tunnel | the codespace, `running`, tunnel, no ssh (it comes from the install) |
| Stop | **before the fix: "still running after 10 minutes"**; after: `ok in 38s`, and it stays Shutdown | `ok in 34s`, and it stays Shutdown |
| Start | online in **125 s**: the start call in 15 s, then the control plane starts agentsd over ssh at 2 min | online in **125 s**, the same |

So #965 holds on Go: Start brings the host back. A codespace has no systemd, so its agentsd does
not start on boot. The control plane starts it over the destination it was installed over.

## Set-up

- **Codespace:** `w864-walk-…` on `alexec/agents-walk`, branch `main`, `basicLinux32gb` (2 cores,
  the smallest), made with `gh codespace create` at 19:44 and deleted at 20:19.
- **Control plane:** `run-app` (`launch.sh --slug w864 --no-window`), with
  `AGENTS_SSH_CONFIG` pointing at the walk's own copy of `gh codespace ssh --config`. Nothing in
  `~/.ssh` was changed. After the fix, the control plane was started again from
  `Go/out/darwin/agents-control`, built from this branch.
- **Driving:** the control plane's own calls, as the Mac window makes them (`operator.mjs`):
  `providers/add`, `hosts/install` (with a tunnel: a codespace can't reach this Mac),
  `hosts/link`, `hosts/stop`, `hosts/start`. The Mac was idle, but no window was needed.
- **Token:** the API preset's `GITHUB_TOKEN` was gh's own token (it has the `codespace`
  scope), given only as the scratch provider's secret, and removed with the scratch set-up.

## Install

`hosts/install` to `cs.<name>.main`, tunnel on: `needsTrust` with the codespace's
fingerprint, then, trusted, the install ran, "tunnel to w864cs: up", and the host joined in
about 2 minutes. The walk's client gave up on the call after 30 s ("can't reach the control
plane"), but the install went on and finished.

## The bug: a stopped codespace was started again by its own tunnel

The first Stop through the API returned at once, but the codespace was still `Available` after
10 minutes. By hand, GitHub's stop worked: `ShuttingDown`, `Shutdown`, then `Available` again
20 seconds later. The log showed why:

```text
20:04:16 tunnel to w864cs: down: client_loop: send disconnect: Broken pipe
20:04:29 tunnel to w864cs: down: It did not answer: the connection timed out or was refused.
20:04:56 tunnel to w864cs: up
```

The control plane holds an ssh tunnel to the codespace and dials it again when it drops. Through
gh's relay, a connection to a codespace starts it. So every Stop was undone by the tunnel.

**Fixed in this branch:** the tunnels ask the providers whether a host is asleep: a stop under
way, or no start under way and its workspace listed as stopped or stopping. While it is asleep,
a tunnel waits and does not dial, and says "Its workspace is stopped: the tunnel waits for
Start." A Start makes it awake, and the tunnel dials again. After the fix:

```text
20:08:12 tunnel to w864cs: down: client_loop: send disconnect: Broken pipe
20:08:16 tunnel to w864cs: down: Its workspace is stopped: the tunnel waits for Start.
20:08:39 workspace: stop w864cs (walk-864-codespaces-api-…) by client …: ok in 38s
```

and the codespace stayed `Shutdown` until Start.

## Found, filed

- **#1643**: ssh through gh's ProxyCommand leaves a `gh cs ssh` relay running after each call:
  27 of them in 35 minutes, all parented to launchd. Stopped by hand after the walk.

## Cost

One `basicLinux32gb` codespace for 35 minutes: about $0.11 at $0.18 an hour, and its storage
for the same time (a fraction of a cent).

## Clean-up

The codespace was deleted (`gh codespace list` is empty), the scratch set-up stopped
(`stop.sh`), the walk's ssh config removed, and the 27 orphaned relays stopped. gh's own key,
`~/.ssh/codespaces.auto`, was already there and was left.
