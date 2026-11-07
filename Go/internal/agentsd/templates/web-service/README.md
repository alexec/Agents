# __APP_NAME__

A web service on Cloud Run, in Node.js. Each version tag (`v1.2.0`) deploys it, when a
person approves the deploy. Errors go to Sentry.

## Run it on your computer

```sh
npm install
npm start
```

It listens on `PORT`, 8080 when not set. `/healthz` says `ok`.

## Set it up once

1. In GitHub, make the environment `production` (**Settings ▸ Environments**) with
   **Required reviewers**. Nothing deploys before a reviewer approves it.
2. Open [Cloud Shell](https://shell.cloud.google.com), signed in to your Google account.
   Put `setup-gcp.sh` from this repository in it (the **⋮ ▸ Upload** menu, or paste it
   into `nano setup-gcp.sh`), and run it:

   ```sh
   bash setup-gcp.sh
   ```

   It makes the project, the service account that deploys, and Workload Identity
   Federation from this repository to it. It is safe to run again. It prints two lines.
3. Put them in the repository's variables (**Settings ▸ Secrets and variables ▸ Actions ▸
   Variables**): `GCP_WIF_PROVIDER` and `GCP_DEPLOY_SA`. They are not secrets: GitHub
   signs in to Google Cloud with no key.
4. For Sentry, put the project's DSN in the repository variable `SENTRY_DSN`. With no DSN,
   the service sends nothing.

## Deploy a version

```sh
git tag -a v0.1.0 -m "What is new in this version"
git push origin v0.1.0
```

`deploy.yml` waits for a reviewer of `production`, then deploys revision
`__SERVICE__-<run number>` in `__GCP_REGION__`, with the Sentry release
`__SERVICE__@0.1.0`. It says what it deployed with a notice, such as
`::notice title=deploy::cloudrun:<project>/__GCP_REGION__/__SERVICE__/__SERVICE__-42`.
Agents reads it and shows the revision beside the release that it came from.
