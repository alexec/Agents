# Walk: Agents with no Mac, a cloud control plane, the web page and a real codespace (#3350, #3369, #3384, 2026-11-03)

The no-Mac path of epic #3345, on main at `aa146c6f9` (with #3346, #3347, #3348 and #3349), and
the steps of [Run Agents with no Mac](../../../docs/how-to/run-agents-with-no-mac.md).

| Step | Result |
|---|---|
| 1. Pair the first browser with `agents-control code --client --browser` | **works** |
| 2a. Add the `codespaces-api` provider on the web page | **works** |
| 2b. Make a codespace from the web page (New Machine…) | **works**: `basicLinux32gb`, made in 3 s |
| 2c. **Add as Machine…** on the codespace | #3350: **not on the web page**. #3369: **joins**, in about 2 minutes, but the page says "That took too long. Try again." after 30 s, so the machine is **not linked**. #3384: **works**: "Installed on w3384-walk" after 1 min 50 s, and linked when it joined |
| 2d. The docs' way in: the command from Add a Machine ▸ A server, run in the codespace | #3350: **broken on a codespace** (found by reading). #3369: **works**: "Started in the background (no systemd user session here)." |
| 2e. Link to Machine… on a machine that joined with no link | **works**. #3384: it shows the codespace's host key and asks **Trust and Link** |
| 3a. Sign Claude in on the codespace from the web page | #3369: **Sign In… fails**: "Claude's own command line is not on this machine", until `npm install -g @anthropic-ai/claude-code`. #3384: **works** with nothing installed by hand: the sheet gives Claude's link. The sign-in itself needs Alex's account: #1781 |
| 3b. One turn | not walked: no runtime signed in (#1781) |
| 4a. Stop from Agents | **works** |
| 4b. Start from GitHub; the machine comes back | **works** for a machine from Add as Machine…: online 32 s after the codespace started. #3369: **does not** for a machine joined with the command and then linked: no trusted host key. #3384: **works** for that machine too: online 15 s after the codespace was up |
| 4c. Start from Agents | not walked: in this set-up the control plane stops with the codespace (#1781) |
| 5. Clean up | **done**, each time |

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

## The third walk (#3384)

On main at `c084734bc`, with #3377 (Add as Machine… waits), #3378 (Claude's toolset on a server),
#3379 (Link to Machine… trusts the host key), #3380 (tini), #3381 (Remove…), #3382 and #3383, and
`Web/test/walk/nomac3369.mjs` (its `link` stage now presses **Trust and Link**).

### Set-up

As #3369's: the codespace `w3384-walk` on `alexec/agents-walk`, `basicLinux32gb`, made with
`gh codespace create` at 20:54 and deleted at 21:11; the control plane's image built in the
codespace from a clone of this commit, **with no `chmod`** this time, run in its Docker at
`https://localhost:18791` with `--self-signed` and `AGENTS_CONTROL_KEY_FILE` on the volume; headless
Chrome on this Mac through `gh codespace ports forward`. The provider's token was gh's own, sent
over the page's socket. No token was made, so none is to revoke.

The image's PID 1 is `tini`, and `agents-control` is PID 7 (#3380). After an install, a link and
an ssh start, the container had **no zombie processes**.

### Add as Machine… (#3377)

**Install** showed the host key, **Trust and Install** started the install, and the dialog waited:
**"Installed on w3384-walk. It is linked to this machine when it joins."** 1 min 50 s after the
click. **Done**, and the row said **"Running · linked to w3384-walk"** at once ("host w3384-walk
enrolled", then "workspace: w3384-walk linked to …" 3 s later).

### Sign In… (#3378)

Nothing was installed by hand, and `claude` is not on the codespace's PATH. Runtimes listed Claude
as **"Not usable: not signed in"** with **Sign In…**, and the sheet gave Claude's link
(`https://claude.com/cai/oauth/authorize?…`): the host now installs Claude's toolset, and the
control plane could read it with no `chmod` on the clone (#3383). The sign-in itself and a turn
stay Alex's, on #1781.

### A machine joined with the command, linked, back after a stop (#3379)

The machine from Add as Machine… was removed over the page's socket (by its id; the page's own
**Remove…** is #3381's), and the command from **Add a Machine… ▸ A server** run in the codespace:
"Started in the background (no systemd user session here). codespaces-fddd96 joined the control
plane."

**Link to Machine…** on the row, then **Link**: the dialog showed **"This machine's host key is new
to the control plane: SHA256:YVurI…. Link only if this is the key the machine shows (ssh-keygen -lf
on its host key): its provider starts it over ssh with this key."** and **Trust and Link**. That
linked it.

**Stop** on the row stopped the codespace (Shutdown within 4 minutes), with the control plane in it.
Started from GitHub (`POST /user/codespaces/…/start`), the codespace was up in 32 s, and the
control plane said **"ssh start codespaces-fddd96, running with its host offline: ok"** 14 s later
and "host ibrjcqwg connected" a second after that: online 15 s after the codespace was up. The row
said "Running · linked to codespaces-fddd96" with Stop and Unlink.

**Start from Agents** could not be walked, as before: the control plane stops with the codespace.

### Also seen (#3384)

- **The same codespace's key is new again at Link to Machine…**, after the machine that Add as
  Machine… joined was removed: the key the install trusted went with that machine. One more click,
  and it is the same key; it is not wrong.
- **`hosts/remove` by the machine's name says "No machine is called w3384-walk."**; it takes the
  id. The page's Remove… gives the id, so a person does not meet this.
- **Machine providers still says** "Docker, Cloud Workstations, your own commands and MCP servers
  are added in the Mac app." (#3382's PR lists it for the lead.)
- The control plane needs `AGENTS_CONTROL_KEY_FILE` (or a key) when it runs with no `--home`: the
  container restarted with "say where the control plane's key is" until it had one. As it should;
  the walk's set-up had left it out.

## Cost

#3350: one `basicLinux32gb` codespace for about 5 minutes, about $0.02 at $0.18 an hour.
#3369: one for about 50 minutes, about $0.15.
#3384: one for about 17 minutes, about $0.05.

## Clean-up

#3384: the codespace `w3384-walk` was deleted at 21:11, with the control plane, its image
and its volume in it; the port forward and the Chrome profile on this Mac were removed. No token
was made.

#3369: the codespace `w3369-walk` was deleted at 19:19, with the control plane, its image and
its volume in it; the port forward, the Chrome profile and the walk's files on this Mac were
removed. No token was made. (`machine-2` in `gh codespace list` is another session's.)

#3350: the codespace was deleted (`gh codespace list` shows only `machine-1`, which is not this
walk's). The control plane's container, its volume and its image were removed, and so were the
certificate, the Chrome profile and the walk's files. No token was made. No process of the walk
is left.
