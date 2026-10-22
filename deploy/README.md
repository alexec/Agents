# Running the control plane as several copies

`agents-control` is the control plane as a service (058). Agents Host runs one copy of it on a
Mac. For more than one machine's worth of work, or to keep going when a machine stops, run
several copies over one store in a bucket, behind a load balancer. Any copy serves anyone.

This folder has everything for doing that with Docker on one machine, for walks and for trying
it out:

| File | What it is |
|---|---|
| `Containerfile` | Static `agents-control` and `workspace-commands`, built in the image from `Go/` (with the web remote from `Web/`, served at the domain by `compose.public.yaml`, #1459), on Alpine, a user of their own. Built from the repository's root. It carries the Linux host for servers that join (`/servers`), the runtimes' toolsets and the deploy files too. Each release publishes it as `ghcr.io/alexec/agents-control:<version>` (#2140), for amd64 and arm64, signed with cosign, with an SBOM and provenance. |
| `compose.yaml` | MinIO (the bucket), three copies, and Caddy in front of them. |
| `Caddyfile` | TLS, round robin, and `/readyz` health checks, so a copy that can't reach the store gets no new connections. |
| `make-secrets.sh` | The control plane's key, shared by every copy, plus Caddy's certificate and its pin. With `--public`, no key file: the Cloud KMS key's name and the service account file. |
| `compose.public.yaml`, `Caddyfile.public` | One copy at a real domain, with a certificate from Let's Encrypt and no pin (#61). It pulls the release's image, `AGENTS_VERSION`; `--build` builds this checkout. |
| `gcp/up.sh`, `gcp/down.sh` | The machine on Google Cloud (#1461): a VM, its firewall and address, and the Cloud KMS key, then `compose.public.yaml` on it, and the release's image pulled there (`--build` builds this checkout instead). `--dry-run` prints the commands only. |
| `cloudflare/dns.sh` | The A records for both names at Cloudflare, with the token from the Keychain. `--names @` is the zone itself (agentloops.dev). |
| `site/`, `gcp/site.sh` | The hand-back page for sign-ins at `https://agentloops.dev/oauth/callback` (#1343), served by the same Caddy. See below. |
| `compose.pebble.yaml`, `pebble/` | The same with Pebble, Let's Encrypt's test CA, standing in: no domain and no real CA. A local keeper stands in for Cloud KMS. |

## Bringing it up

```sh
deploy/make-secrets.sh
docker compose -f deploy/compose.yaml up -d --build   # builds the image from Go/ and Web/
```

The control plane is at `https://127.0.0.1:8443`, pinned by `deploy/secrets/pin`. A code comes
from any copy:

```sh
docker compose -f deploy/compose.yaml exec -T cp1 /agents-control code --client
docker compose -f deploy/compose.yaml exec -T cp1 /agents-control code --host
```

## What each copy is told

| Variable | Here |
|---|---|
| `AGENTS_STORE` | `s3://agents-walk/w1`, with `AGENTS_STORE_ENDPOINT` and `AGENTS_STORE_PATH_STYLE=1` for MinIO |
| `AGENTS_CONTROL_URL` | the one address every client and host is given: Caddy's |
| `AGENTS_CONTROL_PIN` | Caddy's certificate's pin, carried in every code |
| `AGENTS_CONTROL_PEER_URL` | where the other copies reach this one: `http://cpN:8791` |
| `AGENTS_CONTROL_KEY_FILE` | the shared private key; never in the store |

## At a real domain, with a public certificate

`compose.public.yaml` runs one copy over a folder on the machine, with Caddy getting its
certificate from Let's Encrypt (`auto_https` on) for `AGENTS_DOMAIN` and for
`AGENTS_VIEWS_DOMAIN`, the second name the web page's MCP Apps views are drawn at (#1484):

```sh
deploy/make-secrets.sh --public --kms projects/P/locations/L/keyRings/R/cryptoKeys/K \
    --service-account sa.json
export AGENTS_DOMAIN=agents.example.com AGENTS_VIEWS_DOMAIN=views.example.com \
    ACME_EMAIL=you@example.com AGENTS_VERSION=0.11.0
docker compose -f deploy/compose.public.yaml pull
docker compose -f deploy/compose.public.yaml up -d
```

The image is the release's (#2140). It carries the Linux host that joining servers download
(`/servers`), the runtimes' toolsets (`/toolsets`) and these deploy files (`/deploy`, which
`docker cp` takes out), so docs/how-to/run-the-control-plane-in-the-cloud.md needs no clone
of the repository. To run this checkout instead, `up -d --build`.

Both names must point at the machine, with ports 80 and 443 open. At the views name the copy
serves only the sandbox proxy (`/sandbox.html`, `/sandbox.js`), with the loopback proxy's
headers and framed by the page only; at the page's name it refuses them. Codes carry no pin, and a
renewal needs nothing from clients or hosts. Don't set `AGENTS_CONTROL_PIN` here: Caddy
makes a new key at each renewal (058 research R15).

The control key is never on this machine's disk in clear (#1458). Google Cloud KMS seals it in
the store (`v1/keys/control.sealed`), and the copy opens it at each start:

| Variable | Here |
|---|---|
| `AGENTS_CONTROL_KMS` | `gcpkms://` and the key's name, written in `deploy/.env` by `make-secrets.sh --public --kms` |
| `GOOGLE_APPLICATION_CREDENTIALS` | `/run/secrets/gcp-service-account`: the service account file that may use the key (Cloud KMS CryptoKey Encrypter/Decrypter). Without `--service-account` the file is empty, and the machine's own service account is used: then no secret of any kind is on the disk. |

With no sealed key in the store, the first start makes a new key and seals it. To bring a key
from elsewhere (a Mac's, for a move), build the image and seal the key before the first
`up`. Pipe the key in, so it is never written on the machine:

```sh
ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml build control'
ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
    run --rm -T control key seal --key-fd 0' < control-key
```

Another key given for a store that already has one is refused. For a move back to a Mac,
`key export` writes the sealed key, raw, out over ssh into a 0600 file on the Mac. Only a
shell on the machine can run it: no request gives the key out, and it writes none to a
terminal:

```sh
(umask 077; ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
    run --rm -T control key export --key-fd 1' > control-key)
```

The how-to is
[Run the control plane in the cloud](../docs/how-to/run-the-control-plane-in-the-cloud.md).

### The hand-back page for sign-ins

Linear's sign-in is the authorization code with PKCE, with no client secret (#1335, #1343). Linear
sends the person back to one fixed address, `https://agentloops.dev/oauth/callback`, which the
Agents OAuth app on Linear names. That page is `site/www/oauth/`: static, it holds nothing and
keeps nothing. It gives the code and the state back to the client that opened the browser:

- on the Mac and the Remote, to `agents://oauth/callback`, which their authentication session
  catches;
- on the web page, by `postMessage` to the window that opened it, only to the origin that the
  state names.

The host that started the sign-in holds the PKCE verifier and spends the code, so a code that
someone else catches is of no use to them. A token never reaches a client or this page.

Caddy serves it at `AGENTS_SITE_DOMAIN` with `site/site.caddy`: only the page and its two files,
no referrer, no cache, no frames, no other script. It is on only where `site.d/site.caddy` is.
`deploy/gcp/site.sh` turns it on at agentloops.dev's VM: it copies `site/`, the Caddyfile and the
compose file, sets `AGENTS_SITE_DOMAIN` and starts Caddy again. The control plane is not
touched. The name points at the VM first:

```sh
deploy/cloudflare/dns.sh --names @ 34.169.154.90   # the VM's address
deploy/gcp/site.sh
```

A copy of the control plane anywhere else does not need the page: its clients use ours.

### Trying it with no domain: Pebble

```sh
deploy/pebble/up.sh --devbox      # PEBBLE_PROFILE=renewal-walk RENEW_INTERVAL=30s for ten-minute certificates
deploy/pebble/down.sh
```

Pebble issues the certificate for `agents.127.0.0.1.sslip.io`, which public DNS answers with
127.0.0.1, so Caddy is at `https://agents.127.0.0.1.sslip.io:8444`. Its root, in
`deploy/secrets/pebble-root.pem`, stands in for a public one:
- in the devbox, `--devbox` makes it a system root and points the name at Caddy;
- on this Mac, a Debug `agentsd` or window takes it as `AGENTS_TEST_TRUST_ROOT` (PEM or
  base64 DER). This Mac's trust settings are not touched. The sandboxed window also needs an
  ATS exception for `sslip.io` in a walk copy of its own; see `specs/058-control-plane/walks/public-cert.md`.

To count pushes with no relay host (#1460), give the control plane a fake APNs key (any P-256
`.p8`, and 10-character Key and Team IDs), and `AGENTS_TEST_APNS_URL` for a fake APNs server on
the compose network whose certificate chains to the control plane's `AGENTS_TEST_TRUST_ROOT`.
Nothing then goes to Apple. `agentsctl pair -kind iPhone` and `agentsctl device` stand in for a
phone. See `specs/058-control-plane/walks/1507.md`.

## Metrics and logs

Each copy can serve Prometheus `/metrics` on a port of its own (#2176):
`AGENTS_CONTROL_METRICS=0.0.0.0:9791` with `AGENTS_CONTROL_METRICS_TOKEN` (a token is necessary
on any address but loopback), never on the port clients use. `AGENTS_CONTROL_LOG_FORMAT=json`
writes JSON log lines (`log/slog`), and `AGENTS_CONTROL_LOG_LEVEL=debug` adds a line for each
request. `compose.yaml` turns both on, with the token `walk-metrics`:

```sh
docker compose -f deploy/compose.yaml exec cp1 wget -qO- --header 'Authorization: Bearer walk-metrics' http://127.0.0.1:9791/metrics
```

`compose.public.yaml` has them off; docs/how-to/run-the-control-plane-in-the-cloud.md says how
to turn them on, what each metric counts and how Prometheus scrapes them.

## Beyond one machine

The same image runs anywhere containers do. Point `AGENTS_STORE` at a bucket of your own
(S3, R2, or MinIO), give every copy the same key and URL, let the copies reach each other at
their peer URLs, and put a load balancer that passes WebSockets through in front. Keep the key
and the bucket's keys in your platform's secrets, not in the environment of a file checked
in. The walk's keys here are for a walk only.
