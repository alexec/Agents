---
diataxis: how-to
devices: [mac, web]
description: Deploy a service to Google Cloud Run from your own GitHub Actions, held for a person's approval, and see each deploy in Lineage beside the release it came from.
---

# Deploy to Cloud Run

Cloud Run is the second deploy target after TestFlight (#3654). The deploy runs in your own
GitHub Actions, never on the control plane, and Agents only watches it
([direction.md](../explanation/direction.md), "From idea to production"):

- A version tag (`v1.2.0`) starts your deploy workflow.
- A GitHub environment with required reviewers holds the deploy. It shows in **Needs You** as
  a **Deploy** row, and you approve or reject it from there (#3587).
- The workflow says what it deployed with one notice. Agents reads it when the run ends and
  links the release `deployed-as` the Cloud Run revision. The Work page of an issue, a pull
  request or a release then shows **Cloud Run web-42**, a link to the service's revisions in
  the Google Cloud console (#3588).

Your Google Cloud credentials stay in your CI. Agents holds none.

## Before you start

- A Google Cloud project with the Cloud Run API on, and a service account that may deploy
  (`roles/run.admin` and `roles/iam.serviceAccountUser`).
- Workload Identity Federation from GitHub to that service account, so that the workflow
  signs in with no key. See
  [google-github-actions/auth](https://github.com/google-github-actions/auth#preferred-direct-workload-identity-federation).
- The folder pushes to GitHub, and Agents has your GitHub connection
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
      # What this run deployed, for Lineage: <project>/<region>/<service>/<revision>.
      - name: Say the deploy
        run: echo "::notice title=deploy::cloudrun:$PROJECT/$REGION/$SERVICE/$SERVICE-${{ github.run_number }}"
```

GitHub's `ubuntu-latest` runners have `gcloud`. Deploy an image with `--image` in place of
`--source .` when another job builds it.

The notice is the only thing Agents needs. Its message is a deploy ref,
`cloudrun:<project>/<region>/<service>/<revision>`. A run can say at most 10 deploys.

## See it

1. Tag a release and push the tag.
2. **Needs You** shows **Deploy**. Open it, read what ships, and choose **Approve**.
3. When the run ends, open the release, or an issue that it fixes, on its Work page. The
   pipeline line under the title names the release, the CI run and **Cloud Run web-42**.

## When the deploy does not show

- **No deploy in the line:** the run was not on a version tag, or the notice's message is
  not a ref. Open the run's summary on GitHub: the notice is under **Annotations**, titled
  `deploy`.
- **The link opens the wrong page:** the ref needs all four parts, project, region,
  service and revision.
