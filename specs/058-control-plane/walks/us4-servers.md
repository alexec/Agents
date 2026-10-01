# Walk 3: a server joins (US4, T075)

2026-09-29, against the `agents-devbox` container: Debian arm64 under Colima, with no systemd.

The control plane was one copy of `agents-control serve --home /tmp/w3/control` on this Mac:
- its URL was `https://192.168.0.152:18821`, this Mac's LAN address, since the container cannot
  reach the Mac's loopback;
- it had a self-signed certificate, pinned in every code;
- `AGENTS_CONTROL_SERVERS` pointed at `App/Resources/servers`, with the aarch64 Linux host rebuilt
  from this branch.

The walk is a live test, so it can be run again:

```sh
AGENTS_WALK3_URL=https://<this Mac's address>:18821 AGENTS_WALK3_HOME=/tmp/w3/control \
  AGENTS_WALK3_KEY=/tmp/w3/key swift test --package-path Packages/ControlPlane --filter Walk3
```

It pairs an operator window with a code from `agents-control code`, and drives the devbox with
`docker exec` as its `agents` user.

## The steps

| Step | Result |
|---|---|
| 1. Run the shown command on the devbox | `hosts/startEnroll` gave `curl -fsSL --insecure --pinnedpubkey sha256//… https://192.168.0.152:18821/v1/install.sh \| sh -s -- '<code>'`. The script fetched the aarch64 host from the control plane, checked its SHA-256, and started it detached (no systemd user session). It said "d900157ec616 joined the control plane." The host was online as `Linux arm64`. |
| 2. Install over ssh with a scratch key (FR-018a) | The first `hosts/install` returned `needsTrust` with the devbox's host key fingerprint. With the fingerprint sent back, the control plane installed, left the code in the host's root, stopped the host already running there, and started the new one. "devbox by ssh" joined 5 s later. |
| Afterwards | No ssh process was left on this Mac. The key was in no file under the control plane's folder or its temporary folders. |
| 3. Drop the devbox's network for 60 s | `docker network disconnect` for 60 s. The control plane showed the host offline after 59 s, and it was online again **2.1 s** after the network returned, with the same daemon (pid 911): its agents were never stopped. |
| 4. Remove the host | Gone from the list at once, and its daemon still running on the devbox. |
| Afterwards | Both hosts were removed. The devbox's `~/.agents-server` and the scratch key in `authorized_keys` were removed, and the control plane stopped. |

## Found on the way

- **The first run of step 3 saw no offline mark.** The keep-alive pings every 20 s and gives up
  after two missed pongs, so a dead connection is noticed after about 60 s. A drop just under that
  can end with the same connection carrying on, and the host is never shown offline. That is the
  contract as written (wire.md, keep-alive), so the test now notes whether the host was seen
  offline rather than requiring it.
- **A second install would have left the first host holding the root's lock**, so the new daemon
  could not start. `ServerInstaller.leaveJoinCode` now stops a running host first, as the script
  does.
- **The Linux host build does not survive a turn ending in the background.** It was built in the
  foreground in steps; the build cache kept what was already compiled.

## Not walked

- **The systemd user unit.** The devbox has no systemd, so the script's detached path was the one
  walked. The unit's text is in the script and in `scripts/host-install.sh`.
- **A publicly trusted certificate.** Every run was pinned, so the script's check for system CA
  roots was not reached.
- **`hosts/update` over the uplink.** Not built (T073). A host updates by running the command
  again.
- **Frame M on screen.** The sheet is built, and the walk drove the same calls over the socket.
