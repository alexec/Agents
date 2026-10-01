# Running the control plane as several copies

`agents-control` is the control plane as a service (058). Agents Host runs one copy of it on a
Mac. For more than one machine's worth of work, or to keep going when a machine stops, run
several copies over one store in a bucket, behind a load balancer. Any copy serves anyone.

This folder has everything for doing that with Docker on one machine, for walks and for trying
it out:

| File | What it is |
|---|---|
| `Containerfile` | One static `agents-control`, a user of its own, no shell. |
| `compose.yaml` | MinIO (the bucket), three copies, and Caddy in front of them. |
| `Caddyfile` | TLS, round robin, and `/readyz` health checks, so a copy that can't reach the store gets no new connections. |
| `make-secrets.sh` | The control plane's key, shared by every copy, plus Caddy's certificate and its pin. With `--public`, the key only. |
| `compose.public.yaml`, `Caddyfile.public` | One copy at a real domain, with a certificate from Let's Encrypt and no pin (#61). |
| `compose.pebble.yaml`, `pebble/` | The same with Pebble, Let's Encrypt's test CA, standing in: no domain and no real CA. |

## Bringing it up

```sh
scripts/build-linux-control.sh aarch64      # x86_64 on an Intel machine
deploy/make-secrets.sh
docker compose -f deploy/compose.yaml up -d --build
```

The control plane is at `https://127.0.0.1:8443`, pinned by `deploy/secrets/pin`. A code comes
from any copy:

```sh
docker compose -f deploy/compose.yaml exec -T cp1 /agents-control code --client operator
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
certificate from Let's Encrypt (`auto_https` on) for `AGENTS_DOMAIN`:

```sh
scripts/build-linux-control.sh x86_64        # or aarch64
scripts/build-linux-agentsd.sh               # the host that joining servers download
deploy/make-secrets.sh --public
AGENTS_DOMAIN=agents.example.com ACME_EMAIL=you@example.com \
    docker compose -f deploy/compose.public.yaml up -d --build
```

The name must point at the machine, with ports 80 and 443 open. Codes carry no pin, and a
renewal needs nothing from clients or hosts. Don't set `AGENTS_CONTROL_PIN` here: Caddy
makes a new key at each renewal (058 research R15). The how-to is
[Run the control plane in the cloud](../docs/how-to/run-the-control-plane-in-the-cloud.md).

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

## Beyond one machine

The same image runs anywhere containers do. Point `AGENTS_STORE` at a bucket of your own
(S3, R2, or MinIO), give every copy the same key and URL, let the copies reach each other at
their peer URLs, and put a load balancer that passes WebSockets through in front. Keep the key
and the bucket's keys in your platform's secrets, not in the environment of a file checked
in. The walk's keys here are for a walk only.
