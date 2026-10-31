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

3. Start it:

    ```sh
    docker compose -f deploy/compose.hosted.yaml up -d --build
    ```

4. Open `https://<your domain>/` and select **Sign Up with GitHub**.

Caddy gets a certificate for each control plane's name the first time it is asked for,
and only for a name that `agents-hosted` says is an account's. Without the client secret,
the sign-up page says that sign-up is not open.

## Who can sign up

Sign-up is by invitation at the start. A person with no invite who signs in with GitHub goes
on a waitlist and sees their place in it. Agents keeps no email address, so they sign in
again later to see if their account is ready.

- **Invite a person** with a link they can use once, within 14 days:

    ```sh
    docker compose -f deploy/compose.hosted.yaml exec hosted agents-hosted admin invite
    ```

- **Allow a GitHub login**, or admit one from the waitlist: `agents-hosted admin allow <login>`.
  An allowed login may sign up whatever its GitHub account's age.
- **See the waitlist:** `agents-hosted admin waitlist`.

These limits keep the service whole. Each is a setting below:

- A GitHub account younger than 30 days waits, unless its login is allowed.
- 3 new accounts or waitlist entries an hour from one address, and 30 an hour in all. A
  person who has an account signs in whatever the rate.
- At most 100 accounts. At the cap, even an invited person waits, at the front.
- At most 50 control planes run at once. The one idle longest stops to make room.
- At most 10 new certificates an hour and 40 a week, below Let's Encrypt's limits. A new
  account's address works once its certificate is allowed.

## Plans and limits

Each account is on a plan, Free or Pro. The service holds each control plane to its plan's
limits:

| Limit | Free | Pro |
| --- | --- | --- |
| Machines joined | 2 | 20 |
| Clients paired | 5 | 50 |
| Connections open at once | 20 | 200 |
| Storage | 1 GB | 20 GB |
| Events kept | 7 days | 90 days |
| Agents running at once (not held yet) | 3 | 30 |

At a limit, nothing is deleted. The next machine, client, write or connection is refused,
with words that name the limit and the plan, such as "Your Free plan allows 2 machines.
Remove one, or upgrade at https://agentloops.dev/account." Events older than the plan
keeps are deleted each hour. The account page shows the plan and how much of each limit
is used.

To put an account on a plan by hand, such as a free Pro account for a tester:

```sh
agents-hosted admin plan <account> pro
```

A running control plane has its new limits within a minute.

## Suspend or block an account

Run these on the service's machine. A running service sees each change within a minute.

| Command | What it does |
| --- | --- |
| `agents-hosted admin accounts` | Lists every account, its GitHub login, plan and state |
| `agents-hosted admin suspend <account> <why>` | Stops its control plane, which then refuses every request. Its records are kept. The person reads why on their account page, and can delete the account |
| `agents-hosted admin unsuspend <account>` | Lets it start again |
| `agents-hosted admin block <GitHub id or login> [why]` | Refuses that GitHub user, and suspends their account |
| `agents-hosted admin unblock <GitHub id>` | Lets them sign up again |
| `agents-hosted admin plan <account> free\|pro` | Puts an account on a plan by hand |

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
| `AGENTS_HOSTED_SIGNUP` | `invite` (the default), `open` or `closed` |
| `AGENTS_HOSTED_MAX_ACCOUNTS` | The most accounts; 100 |
| `AGENTS_HOSTED_MIN_GITHUB_AGE` | The youngest GitHub account that may sign up without being allowed, in days; 30 |
| `AGENTS_HOSTED_SIGNUPS_PER_ADDRESS` | New accounts and waitlist entries an hour from one address; 3 |
| `AGENTS_HOSTED_SIGNUPS_PER_HOUR` | New accounts and waitlist entries an hour in all; 30 |
| `AGENTS_HOSTED_MAX_COPIES` | Control planes running at once; 50 |
| `AGENTS_HOSTED_CERTS_PER_HOUR` | New certificates an hour; 10 |
| `AGENTS_HOSTED_CERTS_PER_WEEK` | New certificates a week; 40 |

## Related

- [Direction](../explanation/direction.md)
- [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md)
- [The control plane](../explanation/control-plane.md)
