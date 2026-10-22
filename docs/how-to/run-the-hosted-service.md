---
diataxis: how-to
devices: [server]
description: Run the hosted service, where a person signs up on the web with GitHub and gets a control plane of their own, with nothing to install.
---

# Run the hosted service

The hosted service is the shortest way in: a person with only a browser signs up with
GitHub, and gets a control plane of their own. They type no command and hold no key
([Direction](../explanation/direction.md)). This page is for whoever runs the service.

Each account's control plane is the same single-organisation control plane that Agents
Host runs on a Mac. One `agents-hosted` process runs them all:

- **Sign-up and the account page** are at your domain, such as `agentloops.dev`.
- **Each account's control plane** is at a name of its own, such as
  `k3v9x0qa7b.cp.agentloops.dev`, with its own records under `accounts/<id>/` in the
  store, and its own control key, sealed in that place by Google Cloud KMS.
- **The browser that signed up** is sent to its control plane with a pairing code in the
  address, and pairs itself. Nobody types a code. Any other browser pairs with **Open in
  This Browser** on the account page, after it signs in.
- **Delete Account** stops the control plane and deletes everything it keeps. It asks for
  the account's name first.

A hosted control plane has no ssh: it can't install, find or list machines over the
service's own ssh. Machines join with a code or their join command, from the web page.

## Before you start

- A machine with Docker, and ports 80 and 443 open to the internet.
- Two DNS names pointing at it: the pages' name, and a wildcard for the control planes, such
  as `agentloops.dev` and `*.cp.agentloops.dev`.
- A Google Cloud KMS key, as for [running a control plane in the cloud](run-the-control-plane-in-the-cloud.md).
- The GitHub App's client secret, and `https://<your domain>/signin/callback` added to the
  App's callback URLs.

## Start it

1. Seal the keys with your KMS key:

    ```sh
    deploy/make-secrets.sh --public --kms projects/P/locations/L/keyRings/R/cryptoKeys/K
    ```

2. Put the names and the secret in `deploy/.env`:

    ```sh
    AGENTS_HOSTED_DOMAIN=agentloops.dev
    AGENTS_HOSTED_ACCOUNTS_DOMAIN=cp.agentloops.dev
    AGENTS_HOSTED_GITHUB_SECRET=…
    ACME_EMAIL=you@example.com
    ```

3. Get the release's image, `ghcr.io/alexec/agents-control` (set `AGENTS_VERSION` in
    `deploy/.env` for a release other than the newest), and start it:

    ```sh
    docker compose -f deploy/compose.hosted.yaml pull
    docker compose -f deploy/compose.hosted.yaml up -d
    ```

    To run a commit that no release has, give `--build` to `up` in a clone of the
    repository: it builds the image there.

4. Open `https://<your domain>/` and select **Sign Up with GitHub**.

Caddy gets a certificate for each control plane's name the first time it is asked for,
and only for a name that `agents-hosted` says is an account's. Without the client secret,
the sign-up page says that sign-up is not open.

## Settings

| Variable | What it is |
| --- | --- |
| `AGENTS_STORE` | Where every account's records are: `file:///data/store` (the default), or a bucket |
| `AGENTS_CONTROL_KMS` | The KMS key that seals each account's control key |
| `AGENTS_HOSTED_DOMAIN` | The sign-up and account pages' name |
| `AGENTS_HOSTED_ACCOUNTS_DOMAIN` | The control planes are at `<account>.` this name; the pages' name when unset |
| `AGENTS_HOSTED_GITHUB_CLIENT_ID` | The GitHub App's client id; `agents-loops`'s when unset |
| `AGENTS_HOSTED_GITHUB_SECRET` | Its client secret |
| `AGENTS_HOSTED_VIEWS_DOMAIN` | The name where each page's MCP Apps views are drawn, or none |

## Related

- [Direction](../explanation/direction.md)
- [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md)
- [The control plane](../explanation/control-plane.md)
