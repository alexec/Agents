---
diataxis: how-to
devices: [server]
description: Run the hosted service, where a person signs up on the web with Apple, Google or GitHub and gets a control plane of their own, with nothing to install.
---

# Run the hosted service

The hosted service is the shortest way in: a person with only a browser signs up with
Apple, Google or GitHub, and gets a control plane of their own. They type no command and hold no key
([Direction](../explanation/direction.md)). This page is for whoever runs the service.

Each account's control plane is the same single-organisation control plane that Agent Loops
Host runs on a Mac. One `agents-hosted` process runs them all:

- **Sign-up and the account page** are at your domain, such as `agentloops.dev`.
- **Each account's control plane** is at a name of its own, such as
  `k3v9x0qa7b.cp.agentloops.dev`, with its own records under `accounts/<id>/` in the
  store, and its own control key, sealed in that place by Google Cloud KMS.
- **The person who signed up** is their control plane's first person and admin. They sign
  in to it with the same provider from the Mac app and the phone, with no code (#3386).
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
- At least one way to sign up. Each uses `https://<your domain>/signin/callback` as its
  return address:
  - **GitHub:** the GitHub App's client secret, with that address in the App's callback URLs.
    For open sign-up, give the App the **Email addresses** account permission (read-only),
    so the service can read the verified primary email.
  - **Apple:** in the Apple Developer account, a Services ID with Sign in with Apple turned
    on, your domain, and that return address; and a key with Sign in with Apple, its key id,
    and its `.p8` file. The Services ID must be in the same team as the app, so a person has
    the same Apple id here and in the app.
  - **Google:** in Google Cloud ▸ APIs & Services ▸ Credentials, an OAuth client of the
    **Web application** kind, with that return address. Its consent screen asks for the
    `openid` and `email` scopes.

  The service asks each provider who the person is and the email address the provider
  verified, never a name. It keeps only a keyed hash of the email (its mark), so that one
  email has one account, and never the address.

## Start it

1. Seal the keys with your KMS key:

    ```sh
    deploy/make-secrets.sh --public --kms projects/P/locations/L/keyRings/R/cryptoKeys/K
    ```

    It also makes `deploy/secrets/vapid-key` the first time, the VAPID key that every
    account's control plane sends Web Push to a browser with (#3515). Keep it: a new key
    ends every browser's subscription.

2. Put the names and the secret in `deploy/.env`:

    ```sh
    AGENTS_HOSTED_DOMAIN=agentloops.dev
    AGENTS_HOSTED_ACCOUNTS_DOMAIN=cp.agentloops.dev
    AGENTS_HOSTED_GITHUB_SECRET=…
    AGENTS_HOSTED_APPLE_SERVICES_ID=dev.agentloops.signin
    AGENTS_HOSTED_APPLE_TEAM_ID=…
    AGENTS_HOSTED_APPLE_KEY_ID=…
    AGENTS_HOSTED_APPLE_KEY=…
    AGENTS_HOSTED_GOOGLE_CLIENT_ID=….apps.googleusercontent.com
    AGENTS_HOSTED_GOOGLE_SECRET=…
    ACME_EMAIL=you@example.com
    ```

    `AGENTS_HOSTED_APPLE_KEY` is the `.p8` file on one line: the text between its `BEGIN` and
    `END` lines, with no line breaks. Leave out the lines of a provider you don't offer.

3. Start it:

    ```sh
    docker compose -f deploy/compose.hosted.yaml up -d --build
    ```

4. Open `https://<your domain>/` and select **Sign Up with Apple**, **Sign Up with
   Google** or **Sign Up with GitHub**.

Caddy gets a certificate for each control plane's name the first time it is asked for,
and only for a name that `agents-hosted` says is an account's. The sign-up page shows a
button for each provider whose settings are all there; with none, it says that sign-up is
not open.

## Deploy it on Google Cloud

`deploy/gcp/hosted-up.sh` makes everything the service needs in a Google Cloud project, as
`deploy/gcp/up.sh` does for the control plane: a Cloud KMS key, a service account that may use
only that key, a network, a static address, the VM (`e2-medium`, 50 GB) and a daily snapshot
of its disk, kept 7 days. The VM costs money.

1. Put a service account key with the Owner role on the project at
   `~/.agents/secrets/gcp-agents-hosted.json`, or say where it is in `AGENTS_GCP_KEY_FILE`.
2. Set the names and the secrets in the environment:

    ```sh
    export AGENTS_GCP_PROJECT=my-project AGENTS_GCP_ZONE=us-west1-b
    export AGENTS_HOSTED_DOMAIN=agentloops.dev AGENTS_HOSTED_ACCOUNTS_DOMAIN=cp.agentloops.dev
    export AGENTS_HOSTED_GITHUB_SECRET=… ACME_EMAIL=you@example.com
    ```

    Billing's three settings, the sign-up settings and the limits below are passed on when
    they are set. `AGENTS_HOSTED_MACHINE_TYPE` and `AGENTS_HOSTED_DISK_GB` size the VM.

3. Check them. With any missing, the script names each, and makes nothing:

    ```sh
    deploy/gcp/hosted-up.sh --check
    ```

4. Run it. `--dry-run` prints every command first, and runs none:

    ```sh
    deploy/gcp/hosted-up.sh
    ```

5. It prints the VM's address, and stops. Point `AGENTS_HOSTED_DOMAIN` and
   `*.AGENTS_HOSTED_ACCOUNTS_DOMAIN` at it, then run it again. It builds the image on this
   machine, copies it to the VM, starts the service, and prints the command for the first
   invite link.

The settings, secrets too, go only into `/opt/agents/deploy/.env` on the VM (mode 600).

On the VM, the admin commands below run in the service's container:

```sh
gcloud compute ssh agents-hosted --zone us-west1-b
cd /opt/agents
sudo docker compose -f deploy/compose.hosted.yaml exec -T hosted /agents-hosted admin <verb> …
```

## Update it

Run `deploy/gcp/hosted-up.sh` again from the commit you want. Each step finds what it made
before; it builds a new image, copies it, and starts the service again. Each account's
control plane starts again at its next request. Settings you set change the same names in
the VM's `.env`; the others stay.

## Who can sign up

Sign-up is by invitation at the start. A person with no invite goes on a waitlist and sees
their place in it. Agent Loops keeps no email address, so they sign in
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
- Apple and Google have no account age and no login to allow: with sign-up by invitation,
  they sign up only with an invite.
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

## Turn billing on

Billing is off until you give the service a Stripe key. With it off, every account is on
Free unless you put it on a plan by hand, and the account page has no **Upgrade**. With it
on, a Free account's page has **Upgrade**, which goes to Stripe Checkout for Pro, and an
account that has paid has **Manage Billing**, which goes to Stripe's customer portal. Stripe
keeps the cards. The service keeps only each account's Stripe customer and subscription ids.

1. In Stripe, make a product, Agent Loops Pro, with a monthly price. Keep its id, `price_…`.
2. Turn on the customer portal (Settings ▸ Billing ▸ Customer portal), so a person can
   cancel and change their card.
3. Add a webhook endpoint at `https://<your domain>/billing/webhook` with these events:
   `checkout.session.completed`, `customer.subscription.updated` and
   `customer.subscription.deleted`. Keep its signing secret, `whsec_…`.
4. Put the three values in `deploy/.env`, and start the service again:

    ```sh
    AGENTS_HOSTED_STRIPE_KEY=sk_live_…
    AGENTS_HOSTED_STRIPE_PRICE=price_…
    AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET=whsec_…
    ```

    A restricted key needs write access to Checkout Sessions and Customer portal only.
    With a key and no price or signing secret, the service does not start, and says which.

What each event does:

- **Checkout done:** the account is on Pro.
- **Subscription changed:** Pro while it is `active` or `trialing`, Free otherwise, such as
  when a payment fails for good.
- **Subscription ended:** Free. Nothing is deleted, except events older than Free keeps.

A webhook whose signature is wrong or older than five minutes is refused. Each event is
acted on once, however often Stripe sends it. An event for an account that is deleted is
ignored, and logged. Test first with Stripe's test keys (`sk_test_…`) and
`stripe trigger checkout.session.completed`.

## Back up and restore

**The whole service:** the VM's disk has a snapshot each day at 10:00 UTC, kept 7 days. The
store, every account's sealed key and Caddy's certificates are on that disk. To go back to a
snapshot, make a disk from it and start the VM from that disk
(`gcloud compute disks create … --source-snapshot …`), then run `hosted-up.sh` again: it puts
the snapshot schedule on the new disk.

**One account:** copy one account's records out of the store, and put them back later, while
every other account stays as it is.

```sh
admin backup /data/backups/2026-10-22            # every account; keep the newest 7
admin backup /data/backups/2026-10-22 <account>  # one
```

Name each backup folder by its date, so the names sort oldest first. Each backup holds every
account, so it is as large as the store. `--keep N` deletes all but the newest N backup folders
beside the new one, after the new one is whole. It deletes only folders that `admin backup`
wrote, and nothing else in `/data/backups`. Without `--keep`, the newest 7 are kept (#3648).
`--keep 0` deletes none.

`/data` is the service's volume, so a backup there is in the next snapshot too, but a loss of
the disk takes it too. To keep a copy off the disk, copy each backup to a bucket in a different
region, with a lifecycle rule that deletes objects after the days you keep:

```sh
gcloud storage cp -r /data/backups/2026-10-22 gs://<backups-bucket>/
```

The records hold each account's sealed control key, so give the bucket only to the service's
operators. To restore from the bucket, copy the folder back to `/data/backups` first. To restore:

1. `admin suspend <account> restoring`, then wait a minute, so its control plane stops.
2. `admin restore /data/backups/2026-10-22 <account>`. Each record in the backup is put back,
   and each record it did not hold is deleted. Only that account's records change.
3. `admin unsuspend <account>`.

An account that was deleted comes back whole, unless the person has signed up again:
then delete the new account first. Its control key is sealed with the service's KMS key, so a
backup restores only with the same key.

### Open sign-up

Set `AGENTS_HOSTED_SIGNUP=open` and anyone with Apple, Google or GitHub can sign up with
no invite (#3388, decided in #3387). The limits above still hold: the rates, the cap and
the waitlist, GitHub's account age, and the blocks. Open sign-up also checks these:

- **A verified email.** Google must say `email_verified`. Apple must give an email; Apple
  gives only verified ones, and a private relay address is accepted. GitHub must have a
  verified primary email, which needs the App's **Email addresses** permission. A person
  with none is refused, with a line that says why, and does not go on the waitlist. An
  invite or an allowed login needs no email.
- **One account per email.** A second sign-in, from another provider, with the same
  verified email gets the account that email has. Deleting the account frees the email.
- **Blocks by email.** `admin block` also blocks the email of the account it blocks, and
  `admin block <email>` blocks an email from every provider.
- **Cloudflare Turnstile** on the sign-up page, when `AGENTS_HOSTED_TURNSTILE_SITE_KEY` and
  `AGENTS_HOSTED_TURNSTILE_SECRET` are set. The page's buttons are one form with
  Turnstile's widget, and the service sends a browser to the provider only after Cloudflare
  says the check passed. With no keys there is no Turnstile, so a self-hosted or local
  copy needs no Cloudflare. Make the widget in the Cloudflare dashboard ▸ Turnstile, for
  your domain, in **Managed** mode.

## Suspend or block an account

Run these on the service's machine. A running service sees each change within a minute.

| Command | What it does |
| --- | --- |
| `agents-hosted admin accounts` | Lists every account, its sign-in (`apple:…`, `google:…` or `github:<id>`), GitHub login, plan and state |
| `agents-hosted admin suspend <account> <why>` | Stops its control plane, which then refuses every request. Its records are kept. The person reads why on their account page, and can delete the account |
| `agents-hosted admin unsuspend <account>` | Lets it start again |
| `agents-hosted admin block <sign-in> [why]` | Refuses that sign-in and its account's email, and suspends its account. Give `provider:subject` as `accounts` and `waitlist` list it, a GitHub id, or a GitHub login; or give an email, to refuse it from every provider |
| `agents-hosted admin unblock <sign-in>` | Lets it sign up again: `provider:subject`, a GitHub id, or an email |
| `agents-hosted admin plan <account> free\|pro` | Puts an account on a plan by hand |
| `agents-hosted admin delete <account>` | Deletes a suspended account and everything it keeps |
| `agents-hosted admin backup [--keep N] <dir> [account…]` | Copies accounts' records into a folder, and keeps the newest N backups (7 by default) |
| `agents-hosted admin restore <dir> <account>` | Puts one suspended or deleted account back |

**Delete an account:** the person deletes their own with **Delete Account** on the account
page. To delete one yourself, `admin suspend <account> deleting`, wait a minute, then
`admin delete <account>`. It deletes the account and everything its control plane keeps.
`admin backup` it first if you may need it again.

**Raise the cap:** set `AGENTS_HOSTED_MAX_ACCOUNTS` and run `hosted-up.sh` again. Nobody on
the waitlist is admitted by it: they sign in again, or you `admin allow <login>` each.

**Room on the disk (#3121):** a new account, and an upgrade to Pro, are refused when the
plans' storage over all accounts would add up to more than 90% of the store's disk, or
`AGENTS_HOSTED_STORAGE_TOTAL_GB` when set. A new account then goes on the waitlist, at the
front, as at the cap. Separately, once the disk itself is 90% full, an account's write that
grows its store is refused, so the service's own records still have room. Grow the disk
(`AGENTS_HOSTED_DISK_GB`), or set the total, to make room.

**Admit from the waitlist:** `admin waitlist`, then `admin admit <login>`. They sign in again
to make their account.

## Watch it

`agents-hosted` serves Prometheus metrics at `/metrics` on port 9795, which Caddy does not
pass. They answer only from loopback and `AGENTS_HOSTED_METRICS_FROM`. In
`compose.hosted.yaml` the port is published on the VM's `127.0.0.1` only, so Prometheus or
`curl http://127.0.0.1:9795/metrics` on the VM reads them.

| Metric | What it counts |
| --- | --- |
| `agents_hosted_accounts{plan,state}` | Accounts, by plan and state |
| `agents_hosted_waitlist` | People on the waitlist |
| `agents_hosted_copies_running` | Control planes running now |
| `agents_hosted_signups_total{kind}` | New accounts (`account`) and waitlist entries (`waitlist`) |
| `agents_hosted_refusals_total{kind}` | Refusals: `blocked`, `closed`, `no_email`, `turnstile`, `rate`, `waitlist_full`, `store`, `full`, `suspended`, `certificates`, `upgrade_full`, `disk`, and each plan limit (`machines`, `clients`, `storage`, `connections`) |
| `agents_hosted_certificates_allowed_total` | New names allowed a certificate |
| `agents_hosted_disk_bytes{kind}` | The store's disk: `total` and `free` (a file store only) |
| `agents_hosted_disk_high_water_bytes` | Used bytes past which accounts' writes are refused: 90% of the disk |
| `agents_hosted_storage_promised_bytes` | The plans' storage, added up over all accounts |
| `agents_hosted_storage_total_bytes` | The most it may add up to |
| `agents_hosted_requests_total{status}` | Requests answered, by status |

The counters start again when the service does. The log, `docker compose logs hosted`, has
one line per event, and never a code, a key, a token or an email address.

**When something breaks:**

| What you see | What to do |
| --- | --- |
| `refusals_total{kind="full"}` rises | More control planes are wanted at once than `AGENTS_HOSTED_MAX_COPIES`: raise it, or use a bigger VM |
| `disk_bytes{kind="total"}` less `disk_bytes{kind="free"}` nears `disk_high_water_bytes`, or `refusals_total{kind="disk"}` rises | The disk is nearly full and accounts can no longer write: grow the disk, run `admin backup` with a smaller `--keep`, prune old images |
| `storage_promised_bytes` nears `storage_total_bytes`, or `refusals_total{kind="upgrade_full"}` rises | New accounts wait and upgrades are refused: grow the disk, or raise `AGENTS_HOSTED_STORAGE_TOTAL_GB` |
| `refusals_total{kind="certificates"}` rises | New accounts wait for Let's Encrypt's limits: see #2227 for one wildcard certificate |
| `refusals_total{kind="rate"}` rises fast | A sign-up flood: lower the rates, or set `AGENTS_HOSTED_SIGNUP=closed` |
| `https://<domain>/healthz` does not answer | `docker compose logs caddy hosted` on the VM; `docker compose up -d` |
| One account's control plane misbehaves | Suspend it, look at its log lines, restore it from a backup if its records are wrong |
| The VM is lost | Make a new disk from the newest snapshot, as above |

## Settings

| Variable | What it is |
| --- | --- |
| `AGENTS_STORE` | Where every account's records are: `file:///data/store` (the default), or a bucket |
| `AGENTS_CONTROL_KMS` | The KMS key that seals each account's control key |
| `AGENTS_HOSTED_DOMAIN` | The sign-up and account pages' name |
| `AGENTS_HOSTED_ACCOUNTS_DOMAIN` | The control planes are at `<account>.` this name; the pages' name when unset |
| `AGENTS_HOSTED_GITHUB_CLIENT_ID` | The GitHub App's client id; `agents-loops`'s when unset |
| `AGENTS_HOSTED_GITHUB_SECRET` | Its client secret; GitHub is not offered without it |
| `AGENTS_HOSTED_APPLE_SERVICES_ID` | Sign in with Apple's Services ID; Apple is offered with this and the next three |
| `AGENTS_HOSTED_APPLE_TEAM_ID` | The Apple Developer team that has the Services ID |
| `AGENTS_HOSTED_APPLE_KEY_ID` | The Sign in with Apple key's id |
| `AGENTS_HOSTED_APPLE_KEY` | That key: the `.p8` file's text, or the text between its `BEGIN` and `END` lines on one line |
| `AGENTS_HOSTED_GOOGLE_CLIENT_ID` | Google's OAuth client, of the web kind; Google is offered with this and its secret |
| `AGENTS_HOSTED_GOOGLE_SECRET` | Its client secret |
| `AGENTS_HOSTED_VIEWS_DOMAIN` | The name where each page's MCP Apps views are drawn, or none |
| `AGENTS_HOSTED_SIGNUP` | `invite` (the default), `open` (a verified email; see [Open sign-up](#open-sign-up)) or `closed` |
| `AGENTS_HOSTED_TURNSTILE_SITE_KEY` | Cloudflare Turnstile's site key, for the sign-up page; Turnstile is on with this and its secret |
| `AGENTS_HOSTED_TURNSTILE_SECRET` | Turnstile's secret key |
| `AGENTS_HOSTED_MAX_ACCOUNTS` | The most accounts; 100 |
| `AGENTS_HOSTED_MIN_GITHUB_AGE` | The youngest GitHub account that may sign up without being allowed, in days; 30 |
| `AGENTS_HOSTED_SIGNUPS_PER_ADDRESS` | New accounts and waitlist entries an hour from one address; 3 |
| `AGENTS_HOSTED_SIGNUPS_PER_HOUR` | New accounts and waitlist entries an hour in all; 30 |
| `AGENTS_HOSTED_MAX_COPIES` | Control planes running at once; 50 |
| `AGENTS_HOSTED_CERTS_PER_HOUR` | New certificates an hour; 10 |
| `AGENTS_HOSTED_CERTS_PER_WEEK` | New certificates a week; 40 |
| `AGENTS_HOSTED_STORAGE_TOTAL_GB` | The most the plans' storage may add up to over all accounts; 90% of a file store's disk when unset |
| `AGENTS_HOSTED_STRIPE_KEY` | Stripe's secret key; billing is off without it |
| `AGENTS_HOSTED_STRIPE_PRICE` | The Pro plan's price, `price_…` |
| `AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET` | The webhook endpoint's signing secret, `whsec_…` |
| `AGENTS_HOSTED_METRICS_PORT` | The metrics' port; 9795, `off` for none |
| `AGENTS_HOSTED_METRICS_FROM` | Who else may read the metrics, besides loopback |

## Related

- [Direction](../explanation/direction.md)
- [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md)
- [The control plane](../explanation/control-plane.md)
