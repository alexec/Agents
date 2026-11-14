---
diataxis: how-to
devices: [mac, web]
description: Deploy a service to Google Cloud Run from your own GitHub Actions, held for a person's approval, and see each deploy in Lineage beside the release it came from.
---

# Deploy to Cloud Run

Cloud Run is the second deploy target after TestFlight (#3654). The deploy runs in your own
GitHub Actions, never on the control plane, and Agent Loops only watches it
([direction.md](../explanation/direction.md), "From idea to production"):

- A version tag (`v1.2.0`) starts your deploy workflow.
- A GitHub environment with required reviewers holds the deploy. It shows in **Needs You** as
  a **Deploy** row, and you approve or reject it from there (#3587).
- The deploy job's GitHub environment is the place Agent Loops shows it in. The workflow says
  which revision it deployed with one notice. Agent Loops reads it when the deploy's
  job ends and adds the Cloud Run revision to the deploy, which deploys the release (#5241). The Work page of an issue, a pull
  request or a release then shows **Cloud Run web-42**, a link to the service's revisions in
  the Google Cloud console (#3588).

Your Google Cloud credentials stay in your CI. Agent Loops holds none.

## Before you start

- A Google Cloud project with the Cloud Run API on, and a service account that may deploy
  (`roles/run.admin` and `roles/iam.serviceAccountUser`).
- Workload Identity Federation from GitHub to that service account, so that the workflow
  signs in with no key. See
  [google-github-actions/auth](https://github.com/google-github-actions/auth#preferred-direct-workload-identity-federation).
- The folder pushes to GitHub, and Agent Loops has your GitHub connection
  ([Use GitHub](use-github.md)).

## Hold the deploy for a person

1. In GitHub, open the repository's **Settings ▸ Environments** and make `production`.
2. Turn on **Required reviewers** and add the people who approve a deploy.

## Add the workflow

Put this in `.github/workflows/deploy.yml`, with your project, region and service:

```yaml
name: Deploy
on:
  push:
    tags: ["v*"]

jobs:
  cloud-run:
    runs-on: ubuntu-latest
    environment: production
    permissions:
      contents: read
      id-token: write
    env:
      PROJECT: acme-prod
      REGION: us-central1
      SERVICE: web
    steps:
      - uses: actions/checkout@v5
      - uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_DEPLOY_SA }}
      - name: Deploy
        run: |
          gcloud run deploy "$SERVICE" --project "$PROJECT" --region "$REGION" \
            --source . --revision-suffix "${{ github.run_number }}" --quiet
      # What this run deployed, for Lineage: <environment>=cloudrun:<project>/<region>/<service>/<revision>.
      - name: Say the deploy
        run: echo "::notice title=deploy::production=cloudrun:$PROJECT/$REGION/$SERVICE/$SERVICE-${{ github.run_number }}"
```

GitHub's `ubuntu-latest` runners have `gcloud`. Deploy an image with `--image` in place of
`--source .` when another job builds it.

The notice's message is `<environment>=<deploy ref>`: the environment the job deployed to,
then the Cloud Run revision, `cloudrun:<project>/<region>/<service>/<revision>`. A run can say
at most 10 deploys.

- **A job with `environment:` needs no notice.** Agent Loops sees the deploy from the job's
  GitHub environment, `production` here. The notice only adds the revision, so the Work page
  can name it and link to it. Give the same name before the `=` as in `environment:`.
- **Name the environment when it is not the job's.** When the job's `environment:` only holds
  secrets or a gate, or the job has none, the name before the `=` is the place it deployed to.
- **The old form, `cloudrun:<…>` with no name,** still works, but puts the deploy in an
  environment called `cloudrun`, not the job's.

## See it

1. Tag a release and push the tag.
2. **Needs You** shows **Deploy**. Open it, read what ships, and choose **Approve**.
3. When the run ends, open the release, or an issue that it fixes, on its Work page. The
   pipeline line under the title names the release, the CI run and **Cloud Run web-42**.

## When the deploy does not show

- **No deploy in the line:** the run was not on a version tag, or the notice's message is
  not `<environment>=<deploy ref>`. Open the run's summary on GitHub: the notice is under **Annotations**, titled
  `deploy`.
- **The link opens the wrong page:** the ref needs all four parts, project, region,
  service and revision.
