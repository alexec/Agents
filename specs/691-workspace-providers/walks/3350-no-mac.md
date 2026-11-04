# Walk: Agents with no Mac, a cloud control plane, the web page and a real codespace (#3350, 2026-11-03)

The no-Mac path of epic #3345, on main at `aa146c6f9` (with #3346, #3347, #3348 and #3349), and
the steps of [Run Agents with no Mac](../../../docs/how-to/run-agents-with-no-mac.md).

| Step | Result |
|---|---|
| 1. Pair the first browser with `agents-control code --client --browser` | **works** |
| 2a. Add the `codespaces-api` provider on the web page | **works** |
| 2b. Make a codespace from the web page (New Machine…) | **works**: `basicLinux32gb`, made in 3 s |
| 2c. **Add as Machine…** on the codespace | **not on the web page**: it says "add it as a machine in the Mac app" |
| 2d. The docs' way in: the command from Add a Machine ▸ A server, run in the codespace | **broken on a codespace** (found by reading, not run): `install.sh` takes the codespace's `systemctl` shim for systemd and starts no host |
| 3. Sign Claude in on the codespace from the web page; one turn | not walked: no machine joined |
| 4. Stop, Start from Agents and from GitHub; the machine comes back | not walked: no machine joined |
| 5. Clean up | **done** |

Steps 3 and 4 need the codespace to reach the control plane. This walk's control plane was on
this Mac's loopback, and a reverse ssh tunnel from this Mac into the codespace (to stand in
for a control plane with a public address) was refused by this session's safety check. They
are on Alex's checklist, #1781, to walk after the two problems below are fixed.

## Set-up

- **Control plane:** the image from `deploy/Containerfile` at this commit, as a Linux container
  in Colima: `AGENTS_STORE=file:///data/store`, `AGENTS_CONTROL_PUBLIC_WEB=/web`,
  `AGENTS_CONTROL_PROVIDER_HOME=/data/providers`, and a self-signed certificate with its pin
  (`AGENTS_CONTROL_TLS_CERT`, `_KEY`, `AGENTS_CONTROL_PIN`, as `deploy/make-secrets.sh` makes
  them), at `https://localhost:18791`. With an `http://` address the control plane serves no
  page ("is not an https address, which the page needs"), as it should.
- **Web page:** headless Chrome (`Web/test/walk/cdp.mjs`) on a throwaway profile, trusting
  only that certificate (`--ignore-certificate-errors-spki-list`).
- **Codespace:** `w3350-walk` on `alexec/agents-walk`, `basicLinux32gb` (2 cores, the
  smallest), made from the web page at 15:56 and deleted at 16:01.
- **Token:** the provider's `GITHUB_TOKEN` was gh's own token (it has the `codespace` scope),
  typed into the page's password field and kept only in the scratch store. No token was made,
  so none is to revoke.

## 1. Pair the first browser

`docker exec … /agents-control code --client --browser` printed a code. On the page, **Connect
this browser to your agents** took it, and the page opened on **Overview**, named after the
control plane, with 0 machines. As the docs say.

## 2. The provider, the codespace and the join

**Settings ▸ Machine providers ▸ Add Provider… ▸ GitHub Codespaces** asks for a name, a token
and an optional repository, and says which token scopes it needs. With `alexec/agents-walk`
it was added: "provider: added github-codespaces-fmso (commands, preset codespaces-api), 0
workspaces".

**New Machine…** on the provider row asks for a name and an optional repository. With
`w3350-walk` and `https://github.com/alexec/agents-walk` it made the codespace in 3 s
(`workspace: create w3350-walk … ok in 3s`), and **List Again** showed it: "w3350-walk Running ·
not joined".

The row then says **"Not joined yet: add it as a machine in the Mac app, in Settings ▸ Machine
Providers."** The web page has no **Add as Machine…** (`Web/src/model/machineProviders.ts:99`).
#3347 made the control plane able to install over gh's ssh, but only the Mac window calls
`hosts/install`, so with no Mac nobody can. **Add a Machine ▸ From a machine provider** makes a
new machine; it does not add one that exists.

The docs' way in is **Add a Machine ▸ A server**: the page showed the command, with the
control plane's pin in it:

```sh
curl -fsSL --insecure --pinnedpubkey sha256//… https://localhost:18791/v1/install.sh | sh -s -- 'agents-control:2:h:…'
```

Run in a codespace, that command does not start the host. The codespace (the default
universal image) has a `systemctl` that is a shim, `/usr/local/bin/systemctl`:

```sh
if [ -d "/run/systemd/system" ]; then
    exec /bin/systemctl "$@"
else
    echo '…"systemd" is not running in this container due to its overhead…'
fi
```

It exits 0 for any arguments. `install.sh` (`Go/internal/controlplane/install.sh:127`) takes
systemd to be there when `systemctl --user show-environment` exits 0, which it did in the
codespace (`user-rc=0`). So the script writes a unit, "starts" it through the shim, and says
**"Started as the systemd user service agents-host."**, while no host runs. The docs say it
says "Started in the background (no systemd user session here)". The install over ssh (#3347)
and the start after a restart (#3348) run `agentsd --serve --detach` and do not use
`install.sh`'s test, so they are not hit.

## Also seen

- The provider's line says **"needs gh for ssh"** for every `codespaces-api` provider
  (`Web/src/model/machineProviders.ts:185`), also on the control plane's image, which has had
  gh since #3347. It reads as a problem when there is none.
- On a control plane with no Mac, Settings says Mac things: **"No machine is called mac."**
  under Agents ▸ Policy and Agent Runtimes, and the Skills, Personas and Workflows editors say
  **"This Mac's"** and **"Files could not be loaded."**
- Machine providers says Docker, Cloud Workstations, command and MCP providers "are added in
  the Mac app": with no Mac, they cannot be added.
- Not walked: a notice reaching the phone (no agent ran).

## Cost

One `basicLinux32gb` codespace for about 5 minutes: about $0.02 at $0.18 an hour.

## Clean-up

The codespace was deleted (`gh codespace list` shows only `machine-1`, which is not this
walk's). The control plane's container, its volume and its image were removed, and so were the
certificate, the Chrome profile and the walk's files. No token was made. No process of the walk
is left.
