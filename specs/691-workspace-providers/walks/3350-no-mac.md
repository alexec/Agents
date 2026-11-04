# Walk: Agents with no Mac, a cloud control plane, the web page and a real codespace (#3350, #3369, 2026-11-03)

The no-Mac path of epic #3345, on main at `aa146c6f9` (with #3346, #3347, #3348 and #3349), and
the steps of [Run Agents with no Mac](../../../docs/how-to/run-agents-with-no-mac.md).

| Step | Result |
|---|---|
| 1. Pair the first browser with `agents-control code --client --browser` | **works** |
| 2a. Add the `codespaces-api` provider on the web page | **works** |
| 2b. Make a codespace from the web page (New Machine…) | **works**: `basicLinux32gb`, made in 3 s |
| 2c. **Add as Machine…** on the codespace | #3350: **not on the web page**. #3369: **joins**, in about 2 minutes, but the page says "That took too long. Try again." after 30 s, so the machine is **not linked** |
| 2d. The docs' way in: the command from Add a Machine ▸ A server, run in the codespace | #3350: **broken on a codespace** (found by reading). #3369: **works**: "Started in the background (no systemd user session here)." |
| 2e. Link to Machine… on a machine that joined with no link | **works** |
| 3a. Sign Claude in on the codespace from the web page | **Sign In… fails**: "Claude's own command line is not on this machine". With `npm install -g @anthropic-ai/claude-code`, as the docs say, the sheet gives Claude's link. The sign-in itself needs Alex's account: #1781 |
| 3b. One turn | not walked: no runtime signed in (#1781) |
| 4a. Stop from Agents | **works** |
| 4b. Start from GitHub; the machine comes back | **works** for a machine from Add as Machine…: online 32 s after the codespace started. **Does not** for a machine joined with the command and then linked: no trusted host key |
| 4c. Start from Agents | not walked: in this set-up the control plane stops with the codespace (#1781) |
| 5. Clean up | **done**, both times |

Steps 3 and 4 need the codespace to reach the control plane. In #3350 the control plane was on
this Mac's loopback, and a reverse ssh tunnel from this Mac into the codespace (to stand in
for a control plane with a public address) was refused by that session's safety check. #3369
ran the control plane in the codespace's own Docker instead; see "The rest (#3369)" below.

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

## The rest (#3369)

On main at `3cebe1f86` (with #3365's Add as Machine… and #3366's `install.sh`), with
`Web/test/walk/nomac3369.mjs`.

### Set-up

- **Codespace:** `w3369-walk` on `alexec/agents-walk`, `basicLinux32gb` (2 cores, the smallest),
  made with `gh codespace create` at 18:29 and deleted at 19:19.
- **Control plane:** the image from `deploy/Containerfile`, built **in the codespace** from a
  clone of this commit, and run in the codespace's own Docker with `--restart unless-stopped`,
  `AGENTS_STORE=file:///data/store` on a volume, `AGENTS_CONTROL_URL=https://localhost:18791`,
  `--self-signed`, the page at `/web`. So the codespace reaches the control plane at
  `localhost:18791`, as a machine reaches one with a public address, with nothing on this Mac
  open to anything. Its cost: the control plane stops when the codespace stops.
- **Web page:** headless Chrome on this Mac, through `gh codespace ports forward 18791:18791`
  (from this Mac to the codespace, as ssh `-L` does), trusting only the control plane's pin.
- **Token:** the provider's `GITHUB_TOKEN` was gh's own token, sent over the page's socket so it
  is in no screenshot, and kept only in the scratch store. No token was made, so none is to
  revoke.

The first image could not read its own `/toolsets`: the codespace's `/tmp` gave the clone's
folders `drwxr-xrw-`, so the image's `control` user could list them but not open them, and
Add as Machine… put no runtime on the machine. The control plane said nothing about it. A
`chmod -R a+rX` on the clone and a new image fixed that; it is this set-up's, not the product's.

### Add as Machine… (#3365)

The provider's row says **"w3369-walk Running · not joined"** with **Add as Machine…**. The
dialog fills in the name and the ssh destination; **Install** shows the codespace's host key
("This machine's host key is new to the control plane: SHA256:…"), and **Trust and Install**
starts the install over gh's ssh.

After 30 s the dialog says **"That took too long. Try again."**, with Install again. The
install was not over: it went on, put Agents, its MCP servers and Claude's toolset on, and the
machine joined about 2 minutes after the click ("host w3369-walk enrolled"). The page waits 30 s
for `hosts/install` (`Web/src/wire/link.ts`: it is not one of the slow calls), and it links
the machine to its codespace only when the call answers (`linkOnJoin` in
`Web/src/model/providers.ts`), so the machine joined **unlinked**. Twice, the same.

**Link to w3369-walk…** on the row then linked it ("linked to w3369-walk", with Stop and
Unlink).

### The command way in (#3366)

**Add a Machine… ▸ A server ▸ Next** gave the command. Run in the codespace, it said:

```text
Fetching the host for x86_64-linux from https://localhost:18791…
agentsd started under its supervisor, pid 29729
Started in the background (no systemd user session here).
codespaces-4356bd joined the control plane.
```

The machine is named after the codespace's host name, not the codespace. The row offered
**Link to Machine…** (not "Link to codespaces-4356bd…", as the names differ), and it linked.

### Claude's sign-in (#3349)

Runtimes lists the codespace's Claude as **"Not usable: not signed in"** with **Sign In…**.
**Sign In…** says **"Claude's own command line is not on this machine, so it cannot sign in
here. Install Claude on it first."**, for both machines (from Add as Machine…, with Claude's
toolset, and from the command).

Claude's executable is `npx` (`Go/internal/agentsd/runtimes.go`), and every codespace has Node,
so the host takes Claude to be there and installs no toolset from the one the command left
(`installDefaultToolsets`, `install_linux.go`). The sign-in looks for the `claude` binary in the
toolset's modules or on PATH (`runtimeTool`), and finds neither.

With `npm install -g @anthropic-ai/claude-code` in the codespace, as the how-to says, **Sign
In…** gave Claude's link (`https://claude.com/cai/oauth/authorize?…`). The sign-in itself needs
a Claude account, so it and a turn are on Alex's checklist, #1781.

### Stop and start (#3348)

- **Stop** on the linked row stopped the codespace (Shutdown within 4 minutes). In this set-up
  the control plane stopped with it.
- **Started from GitHub** (`POST /user/codespaces/…/start`), the codespace was up in 21 s and
  the control plane's container came back with it. For the machine from Add as Machine…, the
  control plane said "ssh start w3369-walk, running with its host offline: ok" 7 s after it
  started, and the machine was online **32 s** after the codespace started.
- For the machine joined with the command and then linked, it said **"ssh start
  codespaces-4356bd, running with its host offline: failed: The server's host key isn't in
  your known_hosts."** The command never used ssh, so the control plane trusts no key for the
  codespace, and nothing on the page asks to trust one. The machine stayed offline.
- **Start from Agents** could not be walked: the control plane was down with the codespace.

### Also seen (#3369)

- **Zombie `gh` processes in the control plane's container:** `agents-control` is PID 1 and
  does not reap the `gh cs ssh` processes that ssh leaves behind; 17 after one install, 16 again
  after the next. `deploy/compose.public.yaml` sets no `init: true`.
- **The page has no Remove for a machine,** while Settings ▸ Machines says "Removing a machine
  stops it connecting." The walk called `hosts/remove` over the page's socket.
- **Runtimes says Mac things with no Mac:** "Install a runtime on the Mac, in Settings ▸ Agent
  Runtimes. Sign it in on the Mac, in Runtimes."
- **Link to Machine…'s dialog says "add one in the Mac app"** when no machine is free to link
  (`noHosts`, `Web/src/model/machineProviders.ts`).
- **The provider's line still says "needs gh for ssh"**, as in #3350.
- After the control plane's container was made again, its tunnel said "ssh doesn't know that
  server" until the provider wrote gh's ssh config again, 7 s later: the control user's home is
  not on the volume.

## Cost

#3350: one `basicLinux32gb` codespace for about 5 minutes, about $0.02 at $0.18 an hour.
#3369: one for about 50 minutes, about $0.15.

## Clean-up

#3369: the codespace `w3369-walk` was deleted at 19:19, with the control plane, its image and
its volume in it; the port forward, the Chrome profile and the walk's files on this Mac were
removed. No token was made. (`machine-2` in `gh codespace list` is another session's.)

#3350: the codespace was deleted (`gh codespace list` shows only `machine-1`, which is not this
walk's). The control plane's container, its volume and its image were removed, and so were the
certificate, the Chrome profile and the walk's files. No token was made. No process of the walk
is left.
