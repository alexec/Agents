# #3416: Coder on a real deployment

2026-11-04, on `9a85eabb8` (0.16.1-dev.36), on a scratch set-up of this Mac (`run-app`
`launch.sh --slug c3416 --lan`). The page walked is the web page, in headless Chrome
(`Web/test/walk/coder3416.mjs`). Nothing of the real Mac's set-up was used, except Claude's
sign-in, which the scratch Mac host lends through its relay as the window does (056, T091).

## The deployment

- Coder v2.38.6 (`ghcr.io/coder/coder:v2.38.6`) in Colima's Docker, with its built-in
  PostgreSQL and no volume, on port 7080, its access URL this Mac's LAN address.
- Its Docker socket mounted, so the stock `docker` template (`coder templates init --id
  docker`, with the code-server and JetBrains modules taken out and the image
  `codercom/enterprise-base:ubuntu`) makes each workspace as a container beside it.
- The first user made with `coder login --first-user-…`, a workspace `walk` made with
  `coder create`, and a session token with `coder tokens create`.
- The Coder CLI for macOS in a scratch folder, with `CODER_CONFIG_DIR` there, and
  `coder config-ssh --ssh-config-file` into a scratch ssh config: the real `~/.ssh/config`
  was not touched. The control plane and the host were started with `AGENTS_SSH_CONFIG` set
  to it.

## What was walked

| Step | Result |
| --- | --- |
| Add the provider: `coder-api`, the deployment's address, the token | Added, carried by the scratch Mac's host; the answer holds no token |
| Its machines | `walk`, running, ssh `coder.walk` |
| Add as Machine… (`hosts/install` to `coder.walk`) | The host key asked to be trusted first; then Agents installed (Linux ARM64) and the machine joined, with a tunnel |
| Link the machine to its workspace, with the trusted key | Linked: "Running · linked to walk" on the card |
| A turn | Claude, lent this Mac's sign-in, read `README.md` and ran `uname -m` (`aarch64`) in `/home/coder/src/hello` |
| Stop | The workspace stopped through the Coder API; the machine went offline; the card says "Stopped" with **Start** |
| Start | The workspace started through the API; the machine came back online by itself, the same machine, with no new code |
| A second turn, after Start | Passed, as the first |

## What it found

- A Coder workspace's ssh server is the Coder agent, not `sshd`, so a socket forwarded over
  `coder.<name>` is a stranger to the Linux host's daemon (`roles_linux.go`). That is as
  designed: a person reaches the machine through the control plane. The walk sends its turn
  that way.
- The web page's footer under Machine providers still says a provider "runs on the control
  plane". Since #3398 a machine of the person's carries it; #3496 changes the clients' words.
- `set-up-a-cloud-machine-provider.md` still said the token goes to the control plane's
  store; fixed here.

Not walked: the `coder` CLI preset, and the Mac window's Providers page.
