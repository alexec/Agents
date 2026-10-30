---
diataxis: how-to
devices: [server]
description: Run the control plane on a machine you rent, at your own domain with a publicly trusted certificate, so windows, phones and hosts reach it from anywhere.
---

# Run the control plane in the cloud

The control plane that Agents Host runs on your Mac can only be reached while the Mac is
awake and online. Run it on a machine you rent instead, at a domain of your own, and it is
always there. Windows, phones and hosts reach it at one address from anywhere. Its
certificate comes from Let's Encrypt, so it is trusted like any website's, and codes carry
no pin.

This guide runs one copy, with its store on the machine's own disk, behind Caddy. For
several copies over a bucket, see [Run the control plane as several
copies](run-several-copies.md).

## Before you start

- Nothing to build or clone. Each release of Agents publishes the control plane as a
  signed image, `ghcr.io/alexec/agents-control:<version>`, for x86-64 and ARM64. It
  carries the Linux host that it hands to servers that join, and the files to run it
  with. See [The image](#the-image).
- A Linux machine you rent, on x86-64 or ARM64, with Docker and Docker Compose. The
  smallest size a provider offers is plenty: 1 CPU and 1 GB of memory. The control plane
  runs no agents itself.
- A domain you control, such as `example.com`, so that you can add DNS records for two
  names like `agents.example.com` and `views.example.com`. The second is where the web
  page draws MCP Apps views.
- An email address for Let's Encrypt to write to about the certificate.
- A Google Cloud project with Cloud KMS turned on, and the `gcloud` command signed in to
  it. Cloud KMS keeps the key that seals the control plane's own key, so that key is never
  on the machine's disk in clear.

## Google Cloud

On Google Cloud, three scripts do most of the steps below for you: they make the machine,
its firewall, its address, the Cloud KMS key and the DNS records, then build and start the
control plane. They run from a clone of the Agents repository on your Mac. Each script looks first for what it makes, so you can run it again safely.
Each takes `--dry-run`, which prints every command and runs none.

### What you make first

1. A Google Cloud project, with a billing account linked to it. Link it in the console
   (**Billing ▸ Link a billing account**). A billing account that is not linked to the
   project is not sufficient: without the link, `up.sh` can't turn on Compute Engine or
   Cloud KMS.
2. In that project, a service account for the scripts, with these roles: **Service Usage
   Admin**, **Compute Admin**, **Cloud KMS Admin**, **Service Account Admin** and **Service
   Account User**. Make a JSON key for it, and put the key in
   `~/.agents/secrets/gcp-agents-control.json` (`chmod 600`). The scripts read the project
   from this file. They use a gcloud configuration of their own, in
   `~/.agents/gcloud/agents-control`, and do not change yours.
3. The domain, such as `agentloops.dev`, on Cloudflare's DNS, and a Cloudflare API token
   from the **Edit zone DNS** template, for that zone only. Put the token in the Keychain:

   ```sh
   security add-generic-password -a "$USER" -s agents-cloudflare-token -w
   ```

4. For notices on iPhone and iPad with no Mac host: the APNs `.p8` key, as in
   [Get what it runs](#get-what-it-runs). Its name gives the Key ID.
5. On your Mac: `gcloud` (`brew install --cask gcloud-cli`). Docker only to build a commit
   that no release has
   (`up.sh --build`): then Docker, running, with the `buildx` plugin. The image is for
   `linux/amd64`, and on an Apple silicon Mac only BuildKit can build it.
   `docker buildx version` tells you if you have the plugin. If not:

   ```sh
   brew install docker-buildx
   mkdir -p ~/.docker/cli-plugins
   ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
   ```

### Run the scripts

In the repository on your Mac:

1. Look at what `up.sh` will do:

   ```sh
   deploy/gcp/up.sh --dry-run
   ```

2. Make the machine:

   ```sh
   deploy/gcp/up.sh --apns AuthKey_KEYID.p8
   ```

   It turns on Compute Engine, Cloud KMS and IAM. The IAM API needs about a minute after
   it is first turned on, so `up.sh` waits until IAM answers. Then it makes:
   - the Cloud KMS key ring `agents` and key `control`;
   - the service account `agents-control-vm`, which may only encrypt and decrypt with that
     key. The machine runs as this account, so no key file for it is on the machine;
   - the network `agents-control`, with ports 80 and 443 open to all, and port 22 open
     only to your Mac's IPv4 address;
   - a static IPv4 address;
   - an e2-micro machine in `us-west1-b`, running Debian, with a 30 GB *standard* disk.
     A startup script puts Docker on it;
   - the snapshot schedule `agents-control-daily` on that disk: a snapshot every day at
     10:00 UTC, each kept 7 days. See
     [Restore the disk from a snapshot](#restore-the-disk-from-a-snapshot).

   It prints the machine's address, then stops: the names do not point at it yet.
3. Make the DNS records, with the address that `up.sh` printed:

   ```sh
   deploy/cloudflare/dns.sh <the address>
   ```

   It makes an **A** record for `control.agentloops.dev` and one for
   `views.agentloops.dev`, DNS only (not proxied), and never prints the token. Use
   `--zone` and `--names` for other names.
4. Run `up.sh` again, with the same options:

   ```sh
   deploy/gcp/up.sh --apns AuthKey_KEYID.p8
   ```

   When both names point at the machine, it copies `deploy/compose.public.yaml` and the
   secrets to `/opt/agents` on the machine, has the machine pull the release's image, and
   starts the control plane and Caddy. It waits until
   `https://control.agentloops.dev/healthz` answers. Let's Encrypt's address for notices is
   your git email, or give `--email`. Use `--domain` and `--views-domain` for other names.

   To keep the control plane key from your Mac, give `--seal-key control-key` at this
   step, before the first start. See
   [Move the control plane from your Mac](#move-the-control-plane-from-your-mac).
5. Get the first code with the command that `up.sh` prints, then go on at
   [Pair your first window](#pair-your-first-window).

`up.sh` runs the release in `AGENTS_VERSION`, such as `0.11.0`. Without it,
`scripts/version.sh` says, which is a release's version only in a checkout of its tag. For
a commit that no release has, give `--build`: it builds the image on your Mac from the
checkout, stamps that version on it, and copies it to the machine.

To upgrade, run `up.sh` again with the new version: the machine pulls the new image, and
keeps the store, the APNs key and the snapshot schedule. At the end, `up.sh` checks that the
control plane on the machine says that version, the one **Settings ▸ Control plane** shows.

Every release of Agents deploys control.agentloops.dev this way (#2100). After the tag,
and after the GitHub release and both TestFlight builds pass, the release runs, in a
checkout of the tag:

```sh
AGENTS_VERSION=<version> deploy/gcp/up.sh
```

Then it checks that `https://control.agentloops.dev/healthz` answers and that the version
served is the new one. If either check fails, the release report says so and a
`priority:high` bug is filed. The store is never rolled back.

To remove it all, run `deploy/gcp/down.sh`. It asks first. **The store is on the
machine's disk,** so after `down.sh` every window, phone and host must pair again. It
removes the snapshot schedule, but keeps the snapshots, as the last copy of the store, and
prints the command that deletes them. The
Cloud KMS key stays, unless you give `--destroy-key`. Remove the DNS records at Cloudflare
yourself.

### What it costs

| Item | Cost |
| --- | --- |
| The static IPv4 address | about $3.65 a month |
| The e2-micro machine in us-west1 | free tier (one a month) |
| The 30 GB standard disk | free tier (30 GB a month); a *balanced* disk, the console's default, is billed |
| The Cloud KMS key | about $0.06 a month, and $0.03 for each 10,000 uses |
| The disk's snapshots | billed by the GB a month that they hold: each snapshot after the first holds only what changed |
| Traffic out | free tier (1 GB a month), then billed |

## Steps

On another provider, or to do it by hand, follow these steps.

### Get the machine ready

1. Rent the machine, and note its public IPv4 address (and its IPv6 address, if it has
   one).
2. Open ports **80** and **443** to the internet, in the provider's firewall and in the
   machine's own if it has one. Caddy needs both: 443 for connections and for proving the
   name to Let's Encrypt, and 80 for its other challenge and its redirect to HTTPS. Keep
   every other port closed. The control plane's own port, 8791, is only reached by Caddy
   inside Docker.
3. Install Docker and the Compose plugin, following Docker's guide for the machine's
   distribution.

### Point the name at it

1. At your DNS provider, add an **A** record for the name, such as `agents.example.com`,
   with the machine's IPv4 address. If the machine has IPv6, add an **AAAA** record too.
   If it has no IPv6, add no AAAA record: Let's Encrypt prefers IPv6, and a record that
   reaches nothing makes the certificate fail.
2. Add the same records for the views name, such as `views.example.com`. The web page
   draws MCP Apps views from this name, because a view must have an origin of its own,
   apart from the page. A **CNAME** record to the first name is also correct.
3. Check both from your Mac:

   ```sh
   dig +short agents.example.com
   dig +short views.example.com
   ```

   Each prints the machine's address. Wait for that before you start Caddy: until the name
   resolves, Let's Encrypt can't check it, and too many failed tries make it wait an hour.

### Make the key that seals the control plane's key

The control plane's key proves to every window, phone and host that it is your control
plane. On the machine it is sealed in the store by a key in Cloud KMS, which never leaves
Google Cloud. The machine gets only the right to use that key.

On your Mac, with `gcloud` (put your Google Cloud project's id in place of `my-project`):

1. Make a key ring and a key:

   ```sh
   gcloud kms keyrings create agents --location global --project my-project
   gcloud kms keys create control --keyring agents --location global \
       --purpose encryption --project my-project
   ```

2. Make a service account that may use only that key:

   ```sh
   gcloud iam service-accounts create agents-control --project my-project
   gcloud kms keys add-iam-policy-binding control --keyring agents --location global \
       --member serviceAccount:agents-control@my-project.iam.gserviceaccount.com \
       --role roles/cloudkms.cryptoKeyEncrypterDecrypter --project my-project
   ```

3. If the machine is not a Google Compute Engine VM that runs as that service account,
   make a key file for the service account:

   ```sh
   gcloud iam service-accounts keys create sa.json \
       --iam-account agents-control@my-project.iam.gserviceaccount.com
   ```

   On a Compute Engine VM that runs as the service account, make no key file: the VM gets
   its right to use the key from Google Cloud, and no secret of any kind is on its disk.

### Get what it runs

On the machine, in a folder of its own such as `~/agents`, take the files to run it with out
of the release's image (here 0.11.0):

```sh
docker create --name agents-files ghcr.io/alexec/agents-control:0.11.0
docker cp agents-files:/deploy ./deploy
docker rm agents-files
```

`deploy/` has the compose files, the Caddyfiles and `make-secrets.sh`. The image itself
carries the rest: the Linux host, which the control plane hands to every Linux server that
joins, and the runtimes' toolsets, so that the server installs Claude by itself.

1. Say which key seals the control plane's key, and give the service account's key file:

   ```sh
   deploy/make-secrets.sh --public \
       --kms projects/my-project/locations/global/keyRings/agents/cryptoKeys/control \
       --service-account sa.json
   ```

   This writes `AGENTS_CONTROL_KMS` in `deploy/.env`, and copies the key file to
   `deploy/secrets/gcp-service-account`. On a Compute Engine VM that runs as the service
   account, leave out `--service-account`. Then delete `sa.json`: anyone who has it and a
   copy of the store can open the control plane's key. Never commit either.

   For notices on your iPhone and iPad when no Mac host relays them, give the APNs key
   from your Apple developer account (Certificates, Identifiers & Profiles ▸ Keys, with
   Apple Push Notification service on). Do it now or later, with or without the rest:

   ```sh
   deploy/make-secrets.sh --public --apns AuthKey_KEYID.p8
   ```

   This copies the key to `deploy/secrets/apns-key`, and writes `AGENTS_APNS_KEY_ID` (read
   from the file's name) and `AGENTS_APNS_TEAM_ID` in `deploy/.env`. Give `--apns-key-id`
   when the file has another name. Without it, the control plane sends no pushes, and its
   log says so once when it starts. Never put the key in a code, the store or the repo.

   `make-secrets.sh` is a zsh script: install `zsh` on the machine first
   (`sudo apt-get install zsh` on Debian or Ubuntu). Copy `sa.json` and the `.p8` key to
   the machine for it, and delete them there afterwards.

To run a commit that no release has, build from source instead: copy the repository's
`deploy/`, `Go/`, `Web/` and `App/Resources/toolsets/` to the machine with the same layout,
and give `--build` to `docker compose up` below. The image is then built on the machine.

### Start it

On the machine, in the folder you copied to:

1. Say the two names, your email and the release, in `deploy/.env`:

   ```sh
   AGENTS_DOMAIN=agents.example.com
   AGENTS_VIEWS_DOMAIN=views.example.com
   ACME_EMAIL=you@example.com
   AGENTS_VERSION=0.11.0
   ```

   Caddy gets a certificate for each name. `AGENTS_VERSION` is the image's tag: a release
   such as `0.11.0`, `0.11` for the newest 0.11 release, or `latest`. Without it, `latest`.

2. Get the image, and start the control plane and Caddy:

   ```sh
   docker compose -f deploy/compose.public.yaml pull
   docker compose -f deploy/compose.public.yaml up -d
   ```

   To upgrade, take the new release's `deploy/` folder out of its image as above (keep
   `deploy/.env` and `deploy/secrets/`), set the new `AGENTS_VERSION`, and run both
   commands again. The store and the certificate stay.

   At its first start the control plane makes its key and seals it in the store. To keep
   a key from elsewhere, seal it before this step: see
   [Move the control plane from your Mac](#move-the-control-plane-from-your-mac).

3. Within a minute Caddy has its certificate. Check from your Mac:

   ```sh
   curl https://agents.example.com/healthz
   ```

   It prints `ok`. If it doesn't, look at what Caddy says:
   `docker compose -f deploy/compose.public.yaml logs caddy`.

### Pair your first window

The first code comes from the machine. After that, every code comes from a paired window.

1. On the machine:

   ```sh
   docker compose -f deploy/compose.public.yaml exec control /agents-control code --client
   ```

   It prints a code, which works once, for five minutes. Its eighth field is `-`: it
   carries no pin, because the certificate is publicly trusted.
2. In Agents on your Mac, choose **Connect…** under **Connect to a control plane**,
   paste the code under **CODE**, and click **Connect**.

   The window is paired. It has no hosts yet.

Pair your iPhone and iPad from that window, as in
[Connect a window or phone](connect-a-window-or-phone.md).

### Use Agents in a browser

The control plane serves the Agents page at its own address, `https://agents.example.com/`,
so a browser anywhere can use it. A browser pairs by a code from a window or phone that is
already paired:

1. In Agents on your Mac, open **Settings ▸ Control plane ▸ Clients** and click
   **Add a Browser…**. On an iPhone or iPad, tap **Add a Browser…** at the foot of the
   sidebar.
2. In the browser, open `https://agents.example.com/`, paste the code, and click
   **Connect**. The code works once, for five minutes.

The browser shows in **Clients** as *Chrome on the web* (or its own name). It can do all a
window can. To cut it off, click **Forget…** on its row. To serve no page, set
`AGENTS_CONTROL_PUBLIC_WEB=` (empty) in `deploy/.env`. Sign-in with an account comes later
(#995).

### Enrol a Linux server

1. In the window, open **Settings ▸ Machines**, then
   **Add a Machine…**, and **Copy** the command.
2. On the server, as the user your agents should run as, run it. It looks like this:

   ```sh
   curl -fsSL https://agents.example.com/v1/install.sh | sh -s -- 'agents-control:2:h:…'
   ```

   There is no `--pinnedpubkey` in it: `curl`, and then the host, check the certificate
   with the server's own trusted roots. The server needs them installed, which most
   distributions do by default; on a minimal image, install `ca-certificates` first.

   The command says **devbox joined the control plane.** The server has a heading of its
   own in every window.

See [Add a machine](add-a-machine.md) for the rest: installing over ssh, folders on the
server, and its Claude sign-in.

### Enrol your Mac

Your Mac becomes a host of the control plane in the cloud with Agents Host.

1. In the window, open **Settings ▸ Machines**, click **Add by Code…**, then
   **Copy**.
2. On the Mac, open Agents Host. Under **Join one elsewhere**, paste the code and click
   **Join**.

   Agents Host says **This Mac runs its agents for a control plane elsewhere.** The Mac's
   folders appear under its own heading in every window.

If Agents Host already runs a control plane on this Mac with hosts and devices paired to
it, joining one elsewhere starts afresh: those devices pair again. To move an existing
control plane across and keep what is paired, see the next section.

### Move the control plane from your Mac

If Agents Host already runs the control plane on your Mac, you can move it to the machine
and keep every window, phone and host paired. The machine gets this Mac's control plane
key, so everything that is paired trusts it. Agents keep working while it moves.

Get the machine ready first, as above, with its names and certificate. If the control
plane on the machine has already started (it has a store and a key of its own), empty it
first.

1. On the machine, stop the control plane and remove its store:

   ```sh
   docker compose -f deploy/compose.public.yaml down
   docker volume rm agents-control_data
   ```

   This removes everything that the machine's control plane keeps: its hosts, its
   clients and its own key. The certificate is in another volume and stays.
2. In `deploy/.env` on the machine, add this line. It starts the control plane empty, to
   wait for this Mac's records:

   ```sh
   AGENTS_CONTROL_RECEIVE=1
   ```

3. In Agents Host on your Mac, click **Move to Another Machine…**. The sheet opens at
   step 1.
4. Click **Save Key…**, and save the key as `control-key`. Then seal the key in the
   machine's store, with the key piped in over ssh, so that it is never written on the
   machine:

   ```sh
   ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml pull control'
   ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
       run --rm -T control key seal --key-fd 0' < control-key
   ```

   It says **the control key … is sealed in the store by gcpkms://…**. On Google Cloud,
   `deploy/gcp/up.sh --seal-key control-key` seals the key, and starts the control plane.
   Then delete the saved `control-key` on your Mac. Anyone who has it can pose as your
   control plane.

   On Google Cloud, `deploy/gcp/move.sh receive control-key` does steps 1, 2, 4 and 5 in
   one command. It saves the machine's old store to `/opt/agents/saved/` on the machine
   before it empties it, and it deletes `control-key` when the key is sealed. After
   **Move Now**, `deploy/gcp/move.sh done` takes `AGENTS_CONTROL_RECEIVE=1` out again.
5. Start the control plane on the machine, if it is not running:

   ```sh
   docker compose -f deploy/compose.public.yaml up -d
   ```

6. In the sheet, click **Continue**. Type the machine's address, such as
   `https://agents.example.com`, and click **Check**. Each line must get a tick: **It
   answers**, **Its certificate is publicly trusted**, **It holds this control plane's
   key** and **It's empty, and waiting for this one**.
7. Click **Tell Everyone**. Every window, phone and host that is paired gets the new
   address. The sheet counts who knows. You can move when some have not heard yet: this
   Mac sends them on later.
8. Click **Move Now**. The sheet shows each stage: records held still, records copied, the
   machine takes over, this Mac's host and relay go there, and this Mac forwards anyone
   who still comes to it.

When the move is done, Agents Host says **Joined** and the machine's address. Windows,
phones and hosts connect to the machine in a few seconds, and nothing pairs again. This
Mac's copy of the control plane keeps running only to send members on to the machine, for
30 days. It does this again after the Mac restarts.

**After the move, take `AGENTS_CONTROL_RECEIVE=1` out of `deploy/.env`.** On a store that
it has already taken, the setting has no effect. But if the store is lost, a control plane
with this setting waits for a move and does not start a store of its own.

#### Bring it back to your Mac

1. In Agents Host, click **Run It Here Again…**. The sheet checks both ends: the machine
   answers and holds this control plane's key, and this Mac's copy is ready and empty.
2. Only if the machine made a key of its own (it started with an empty store and no key
   sealed), the sheet says so. Then write that key to a file on your Mac, piped out over
   ssh, so that it is never written on the machine:

   ```sh
   (umask 077; ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
       run --rm -T control key export --key-fd 1' > control-key)
   ```

   Click **Use Key…** in the sheet, choose the file, and then delete the file. Agents Host
   keeps the Mac's earlier key aside in the keychain. Only a shell on the machine can
   export the key: no request to the control plane gives it out. After a move from your
   Mac, the machine holds this Mac's key, and you do not do this step.
3. Click **Tell Everyone**, and then **Move Now**.

Every window, phone and host comes back to the Mac, with nothing paired again. Away from
home, the iPhone and iPad then reach the Mac only through your iCloud, and only while
**Relay for my devices** is on.

### Notifications

With the APNs key (`--apns`), the control plane sends notifications to the iPhone and iPad
through Apple, so that a phone can get them with no Mac host. In v0.5.0 this does not work
yet: with **Relay for my devices** off, a need from a host does not get to the locked phone
(#1509, to be fixed in v0.5.1). Until then, keep **Relay for my devices** on, on a Mac host.
With only Linux hosts, devices reach the control plane at its address and get no
notifications.

The web page gets notifications by Web Push (#1486). `make-secrets.sh` makes the VAPID key
once, in `deploy/secrets/vapid-key`, and `up.sh` makes it on the VM and never replaces it: a
new key ends every browser's subscription. Allow notifications in the page's Settings ▸
Notifications; when no iPhone gets a need, that browser shows it, also with the page closed.
On an iPhone or iPad, Safari gives Web Push only to the page added to the Home Screen.
`AGENTS_WEBPUSH_SUBJECT` in `deploy/.env` is the `mailto:` or `https:` address a push service
may write to about it; without it, the project's page.

## What to know

- **The certificate renews itself.** Caddy renews it about a month before it runs out.
  Nothing needs doing: no client or host holds a pin, so a renewed certificate, even with
  a new key, is accepted like the old one, and live connections carry on.
- **The page and the control plane are one version.** The image builds the page from the
  same checkout, so an upgrade changes both. A browser that has the page open loads it
  again when it reconnects.
- **MCP Apps views on the page come from the views name.** At `views.example.com` the
  control plane serves only the two files that hold a view (`/sandbox.html` and
  `/sandbox.js`), and only the page may frame them. At `agents.example.com` it refuses
  them. If the views name has no DNS record or no certificate, the page loads, but each
  view stays empty.
- **Don't set `AGENTS_CONTROL_PIN`** with a publicly trusted certificate. Caddy makes a
  new key at each renewal, so a pin would stop every window, phone and host from
  connecting after the first renewal.
- **What's kept, and where.** The store, with every host and client and the sealed
  control plane key, is in the Docker volume `agents-control_data`. The certificate and the
  ACME account are in `agents-control_caddy`. Both are on the machine's disk, which the
  daily snapshots copy. Never destroy the Cloud KMS key: without it, the sealed key doesn't
  open, and every window, phone and host must pair again.
- **If the machine or its disk is lost,** remove the service account's key in Google Cloud
  (**IAM ▸ Service accounts ▸ agents-control ▸ Keys**). A copy of the disk then can't
  open the control plane's key.
- **Upgrading.** Set the new release in `AGENTS_VERSION`, and run the `pull` and `up -d`
  lines again (see [Start it](#start-it)). Hosts and clients reconnect within
  seconds. Linux servers update their host the next time they connect.

## On a corporate network

On a network where machines reach the internet through a proxy, and where the network may
re-sign TLS with the organisation's own certificate authority (CA), every part of Agents
can still reach the control plane:

| What dials | Its proxy | The organisation's CA |
| --- | --- | --- |
| The Agents window on a Mac | The Mac's: System Settings ▸ Network ▸ Proxies, a PAC file too | The Mac's keychain |
| Agents on iPhone and iPad | The device's | The device's trusted certificates |
| A browser | The browser's | The browser's |
| The Mac's host (agentsd) and relay (Agents Host) | `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` when set; otherwise the Mac's web proxies and their exceptions. A PAC file is not read | The Mac's keychain |
| A Linux server's host | `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` | The system's roots, and the PEM file in `AGENTS_CA_FILE`, or else `/etc/agents/ca.pem` |

The tunnel through a proxy is HTTP `CONNECT`, so TLS goes from end to end. A proxy that
re-signs TLS breaks a pinned control plane: its codes carry a pin, which only the
control plane's own certificate matches. Use a control plane with a publicly trusted
certificate, as in this guide, or exempt its name from the re-signing. Whichever CA signs
the certificate, each window, phone and host also checks the control plane's own key at
each connection, so a proxy can't stand in for the control plane.

On a Mac:

1. If the network uses a PAC file and no fixed proxy, also set the **Secure web proxy
   (HTTPS)** in System Settings ▸ Network ▸ Details ▸ Proxies. The window follows the PAC
   file. The host and the relay follow the fixed proxy.
2. To trust the organisation's CA, open its certificate in Keychain Access, add it to the
   **System** keychain, and set **When using this certificate** to **Always Trust**. Most
   organisations do this for you with a configuration profile.

On a Linux server:

1. Export the proxy in the shell where you run the install command:

   ```sh
   export HTTPS_PROXY=http://proxy.example.com:3128
   export NO_PROXY=localhost,.internal.example.com
   ```

   The install command's `curl` follows them. The host started in the background (with no
   systemd user session) has them too.
2. Put the organisation's CA, as PEM, in `/etc/agents/ca.pem` (one or more certificates
   in one file). To keep it elsewhere, set `AGENTS_CA_FILE` to its path. Add it to the
   system's roots too (`update-ca-certificates` on Debian and Ubuntu), so that the install
   command's `curl` trusts it.
3. After the install command, if it started the host as the systemd user service
   `agents-host`, give the service the same variables (and `AGENTS_CA_FILE`, if you set
   it), as systemd does not read your shell's:

   ```sh
   mkdir -p ~/.config/systemd/user/agents-host.service.d
   cat > ~/.config/systemd/user/agents-host.service.d/proxy.conf <<'EOF'
   [Service]
   Environment=HTTPS_PROXY=http://proxy.example.com:3128
   Environment=NO_PROXY=localhost,.internal.example.com
   EOF
   systemctl --user daemon-reload
   systemctl --user restart agents-host
   ```

   Running the install command again keeps this file.

The control plane itself also dials: other copies of it, with several copies. If its
machine has `HTTPS_PROXY` or `HTTP_PROXY` set, put the copies' names in `NO_PROXY`.

## Metrics and logs

To scrape the control plane with Prometheus and ship its logs, set these in `deploy/.env`,
then run `docker compose -f deploy/compose.public.yaml up -d` again:

```sh
AGENTS_CONTROL_METRICS=0.0.0.0:9791
AGENTS_CONTROL_METRICS_TOKEN=<a long random string, such as from openssl rand -hex 32>
AGENTS_CONTROL_LOG_FORMAT=json
AGENTS_CONTROL_LOG_LEVEL=info
```

**Metrics.** The control plane serves `/metrics`, in the Prometheus text format, on a port
of its own, `9791`. It is off unless `AGENTS_CONTROL_METRICS` is set. Caddy does not serve
it, and the compose file does not publish it, so only a container on the same Docker
network reaches it, at `http://control:9791/metrics`. On an address other than loopback, a
token is necessary: the control plane does not start without one. Prometheus sends it as a
bearer token:

```yaml
scrape_configs:
  - job_name: agents-control
    authorization:
      credentials_file: /etc/prometheus/agents-control-token
    static_configs:
      - targets: ["control:9791"]
```

The metrics are:

| Metric | What it counts |
| --- | --- |
| `agents_control_requests_total{method,result}` | Requests from clients. `result` is `ok` or `error` for the control plane's own methods, `routed` for a call sent on to a machine, `refused` or `offline` for one that was not |
| `agents_control_request_seconds{method}` | A histogram of the time that the control plane took for its own methods |
| `agents_control_events_sent_total{method}` | Notifications sent to clients, one for each client |
| `agents_control_store_operations_total{op}`, `agents_control_store_errors_total{op}`, `agents_control_store_seconds{op}` | Store reads, writes, deletes and lists, the ones that failed, and their times |
| `agents_control_hosts_connected`, `agents_control_hosts_known` | Machines connected to this copy, and machines in the store |
| `agents_control_clients_connected`, `agents_control_client_sessions` | Windows, phones and browsers connected, and their sessions |
| `agents_control_relay_sessions` | Mac relays connected |
| `agents_control_leases_held`, `agents_control_copies` | With several copies: machine leases that this copy holds, and the copies it knows |
| `agents_control_phase{phase}` | 1 for this copy's phase: `serving`, `receiving`, `frozen` or `forwarding` |
| `agents_control_up_seconds`, `agents_control_build_info{version}` | How long it has run, and its version |

A method name gets a label of its own for the first 300 names only. After that, the count
goes to `other`, so a client can't make the metrics grow without end.

**Logs.** With `AGENTS_CONTROL_LOG_FORMAT=json`, each line of `docker compose logs control`
is one JSON object, from Go's `log/slog`, with `time`, `level` and `msg`. A line also has
`copy`, `method`, `client_id`, `person_id`, `host_id` and `request_id` when they apply.
`AGENTS_CONTROL_LOG_LEVEL` is `debug`, `info`, `warn` or `error`. At `debug`, each request
from a client gets a line `request`, with its method, result and time. A line never holds
a request's parameters, a prompt, a code, a bearer token, or a `token=`, `secret=` or
`password=` value: these are cut out before the line is written.

`agents-control serve` takes the same settings as flags: `--metrics`, `--log-format` and
`--log-level`.

## Restore the disk from a snapshot

`up.sh` keeps a snapshot of the machine's disk for each of the last 7 days. The disk holds
the store, the sealed control plane key and Caddy's certificate, so a restore brings the
whole control plane back. Every window, phone and host stays paired. What changed after the
snapshot is lost: at most a day.

Run these on your Mac, in the scripts' own gcloud configuration:

```sh
export CLOUDSDK_CONFIG=~/.agents/gcloud/agents-control
zone=us-west1-b
```

1. Find the snapshot to restore. The newest is last:

   ```sh
   gcloud compute snapshots list --filter "sourceDisk~/agents-control" \
       --sort-by creationTimestamp --format "table(name,creationTimestamp,diskSizeGb)"
   ```

2. Make a new disk from it, beside the old one:

   ```sh
   gcloud compute disks create agents-control-restored --zone $zone \
       --source-snapshot <snapshot> --type pd-standard
   ```

3. Stop the machine, and put the new disk in the place of the old one:

   ```sh
   old=$(gcloud compute instances describe agents-control --zone $zone \
       --format 'value(disks[0].source.basename())')
   gcloud compute instances stop agents-control --zone $zone
   gcloud compute instances detach-disk agents-control --zone $zone --disk "$old"
   gcloud compute instances attach-disk agents-control --zone $zone \
       --disk agents-control-restored --boot
   gcloud compute instances start agents-control --zone $zone
   ```

4. Run `deploy/gcp/up.sh` again, with the options you gave before. It puts the snapshot
   schedule on the new disk, and checks that `https://control.agentloops.dev/healthz`
   answers.
5. When the control plane works, delete the old disk. Until then it is kept, and two
   disks are more than the free tier's 30 GB:

   ```sh
   gcloud compute disks delete "$old" --zone $zone
   ```

If the zone itself is down, make the disk from the snapshot in another zone of
`us-west1` (`--zone us-west1-a`). The snapshots are kept in the region, not in the zone.
Then make a machine there that starts from that disk, with the flags of `up.sh`'s
`instances create`, but `--disk name=agents-control-restored,boot=yes` in place of the
`--image-family`, `--image-project` and `--boot-disk-*` flags. Set `zone` in
`deploy/gcp/common.sh` to the new zone before you run `up.sh` again.

## The image

Each release pushes `ghcr.io/alexec/agents-control` from the release workflow (#2140), for
`linux/amd64` and `linux/arm64`, with three tags: `0.11.0`, `0.11` and `latest`. All in it is
of the same version:

| Path | What it is |
| --- | --- |
| `/agents-control`, `/workspace-commands`, `/agents-hosted` | The control plane, the command machine provider, and the hosted service |
| `/web` | The web page |
| `/servers` | The Linux host and the MCP servers beside it, for x86-64 and ARM64 servers |
| `/toolsets` | The runtimes' toolsets, which a server that joins installs |
| `/deploy` | The compose files, the Caddyfiles and `make-secrets.sh` |

It is signed with cosign, keyless: the signature names the release workflow that pushed
it. Check it before you run it:

```sh
cosign verify ghcr.io/alexec/agents-control:0.11.0 \
    --certificate-identity-regexp '^https://github\.com/alexec/Agents/\.github/workflows/release\.yml@' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The image also carries an SBOM (SPDX) and its build's provenance (SLSA), as BuildKit
attestations. To read them:

```sh
docker buildx imagetools inspect ghcr.io/alexec/agents-control:0.11.0 --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/alexec/agents-control:0.11.0 --format '{{ json .Provenance }}'
```

The image is public, and pulling it needs no account. If the repository becomes private
(#1064), the package stays public: its visibility is set on the package, apart from the
repository's.

To add the CLIs that your workspace commands call, make an image of your own `FROM` this
one, and `apk add` them.

## If it doesn't work

- **`docker compose pull` says `manifest unknown`.** No release has that
  `AGENTS_VERSION`. Give a release's version, such as `0.11.0`, or `latest`.

- **The control plane stops at start with `could not find default credentials`.** It has no
  right to use the Cloud KMS key: `deploy/secrets/gcp-service-account` is empty and the
  machine isn't a Compute Engine VM with the service account. Run `make-secrets.sh` again
  with `--service-account`.
- **It stops with `PermissionDenied`.** The service account may not use the key. Give it
  the role `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key, as above.
- **It stops with `the key given is not the one sealed in the store`.** The store already
  has a control plane key, and `key seal` was given another one. Give the store's own, or
  start with an empty store.

- **`curl` says the certificate can't be verified,** or Caddy's log says
  `challenge failed`. The name doesn't point at the machine yet, or port 80 or 443 is
  closed. Check `dig +short` and the firewall, then restart Caddy:
  `docker compose -f deploy/compose.public.yaml restart caddy`.
- **Caddy's log says `rateLimited`.** Let's Encrypt allows only a few failed tries an hour.
  Fix the cause, then wait for the time it gives.
- **The install command says `This machine has no CA certificates`.** Install
  `ca-certificates` on the server, and run the command again with a fresh code.
- **A host's log says `CERTIFICATE_VERIFY_FAILED`.** The server's trusted roots are
  missing or out of date. Update `ca-certificates` there.

## Related

- [Run the control plane as several copies](run-several-copies.md).
- [The control plane](../explanation/control-plane.md).
