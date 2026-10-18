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

- A clone of the Agents repository on a Mac with Docker running, to build the Linux
  programs: they are Go, built in a container.
- A Linux machine you rent, on x86-64 or ARM64, with Docker and Docker Compose. The
  smallest size a provider offers is plenty: 1 CPU and 1 GB of memory. The control plane
  runs no agents itself.
- A domain you control, such as `example.com`, so that you can add a DNS record for a
  name like `agents.example.com`.
- An email address for Let's Encrypt to write to about the certificate.
- A Google Cloud project with Cloud KMS turned on, and the `gcloud` command signed in to
  it. Cloud KMS keeps the key that seals the control plane's own key, so that key is never
  on the machine's disk in clear.

## Steps

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
2. Check it from your Mac:

   ```sh
   dig +short agents.example.com
   ```

   It prints the machine's address. Wait for that before you start Caddy: until the name
   resolves, Let's Encrypt can't check it, and too many failed tries make it wait an hour.

### Make the key that seals the control plane's key

The control plane's key proves to every window, phone and host that it is your control
plane. On the machine it is sealed in the store by a key in Cloud KMS, which never leaves
Google Cloud. The machine gets only the right to use that key.

On your Mac, with `gcloud` (put your project's id in place of `my-project`):

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

### Build and copy what it runs

On your Mac, in the repository:

1. Build the Linux host:

   ```sh
   scripts/build-linux-agentsd.sh
   ```

   It goes in `App/Resources/servers/`, from where the control plane hands it to every
   Linux server that joins. The control plane itself is built in its image, on the
   machine, from `Go/` and `Web/`.
2. Say which key seals the control plane's key, and give the service account's key file:

   ```sh
   deploy/make-secrets.sh --public \
       --kms projects/my-project/locations/global/keyRings/agents/cryptoKeys/control \
       --service-account sa.json
   ```

   This writes `AGENTS_CONTROL_KMS` in `deploy/.env`, and copies the key file to
   `deploy/secrets/gcp-service-account`. On a Compute Engine VM that runs as the service
   account, leave out `--service-account`. Then delete `sa.json`: anyone who has it and a
   copy of the store can open the control plane's key. Never commit either.
3. Copy the repository's `deploy/` folder (with `deploy/secrets`), `Go/`, `Web/` and
   `App/Resources/servers/` to the machine, keeping the same layout. For example:

   ```sh
   rsync -a --relative --exclude node_modules --exclude Web/dist --exclude Go/out \
       deploy Go Web App/Resources/servers you@agents.example.com:agents/
   ```

### Start it

On the machine, in the folder you copied to:

1. Say the name and your email, in `deploy/.env`:

   ```sh
   AGENTS_DOMAIN=agents.example.com
   ACME_EMAIL=you@example.com
   ```

2. Start the control plane and Caddy:

   ```sh
   docker compose -f deploy/compose.public.yaml up -d --build
   ```

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

### Enrol a Linux server

1. In the window, open **Settings ▸ Control plane**, click **Show** beside **Hosts**, then
   **Add a Server…**, and **Copy** the command.
2. On the server, as the user your agents should run as, run it. It looks like this:

   ```sh
   curl -fsSL https://agents.example.com/v1/install.sh | sh -s -- 'agents-control:2:h:…'
   ```

   There is no `--pinnedpubkey` in it: `curl`, and then the host, check the certificate
   with the server's own trusted roots. The server needs them installed, which most
   distributions do by default; on a minimal image, install `ca-certificates` first.

   The command says **devbox joined the control plane.** The server has a heading of its
   own in every window.

See [Add a server](add-a-server.md) for the rest: installing over ssh, projects on the
server, and its Claude sign-in.

### Enrol your Mac

Your Mac becomes a host of the control plane in the cloud with Agents Host.

1. In the window, open **Settings ▸ Control plane ▸ Hosts**, click **Add by Code…**, then
   **Copy**.
2. On the Mac, open Agents Host. Under **Join one elsewhere**, paste the code and click
   **Join**.

   Agents Host says **This Mac runs its agents for a control plane elsewhere.** The Mac's
   projects appear under its own heading in every window.

If Agents Host already runs a control plane on this Mac with hosts and devices paired to
it, joining one elsewhere starts afresh: those devices pair again. Moving an existing
control plane across, keeping what is paired, is the next section, still to be written.

### Move the control plane from your Mac

TODO: moving the live control plane from Agents Host to the machine, and back, with its
hosts and clients kept (#61).

The machine needs this Mac's control plane key before it first starts. Seal it in the
machine's store, with the key piped in over ssh, so that it is never written on the machine:

```sh
ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml build control'
ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
    run --rm -T control key seal --key-fd 0' < control-key
```

It says **the control key … is sealed in the store by gcpkms://…**. Then delete the saved
`control-key` on your Mac.

### Notifications

TODO: how a set-up with no Mac host gets notifications on the phone (#61). Until then, the
relay and notifications need a Mac host: with only Linux hosts, devices reach the control
plane at its address and get no notifications.

## What to know

- **The certificate renews itself.** Caddy renews it about a month before it runs out.
  Nothing needs doing: no client or host holds a pin, so a renewed certificate, even with
  a new key, is accepted like the old one, and live connections carry on.
- **Don't set `AGENTS_CONTROL_PIN`** with a publicly trusted certificate. Caddy makes a
  new key at each renewal, so a pin would stop every window, phone and host from
  connecting after the first renewal.
- **What's kept, and where.** The store, with every host and client and the sealed
  control plane key, is in the Docker volume `agents-control_data`. The certificate and the
  ACME account are in `agents-control_caddy`. Back up the store's volume. Never destroy
  the Cloud KMS key: without it, the sealed key doesn't open, and every window, phone and
  host must pair again.
- **If the machine or its disk is lost,** remove the service account's key in Google Cloud
  (**IAM ▸ Service accounts ▸ agents-control ▸ Keys**). A copy of the disk then can't
  open the control plane's key.
- **Upgrading.** Build the Linux host again on your Mac, copy `deploy/`, `Go/`, `Web/` and
  `App/Resources/servers/` across, and run the `up -d --build` line again. Hosts and clients reconnect within
  seconds. Linux servers update their host the next time they connect.

## If it doesn't work

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
