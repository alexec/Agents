---
description: The Google Cloud steps of a new web service (#3710, epic #3656) - two hand_to_person cards, the starter's set-up script in Cloud Shell, and the two repository variables - as the start-a-new-app skill (#3712) follows them.
---

# A new app's Google Cloud (#3710)

Issue #3710, a child of epic #3656 (`spec.md`, "What each account needs"). The steps
below are for an agent. The `start-a-new-app` skill (#3712) takes them as its Google Cloud
part. They use only tools that the app has now: the browser tools, `hand_to_person`
(#3529), `ask_question` and `set_ci_variable` (#3706).

## What is there before these steps

- `make_app_repository` made the repository from the `web-service` starter (#3708), with
  `GCP_PROJECT` (for example `tidelog-1234`) and `GITHUB_REPO` (`owner/tidelog`) filled
  in. The clone has `setup-gcp.sh` at its root.
- The `production` environment has the person as its required reviewer
  (`set_environment_gate`).

## The steps

Do each step only when it is not done yet. When the person answers **Can't do it**, stop,
say what is left, and end. When the flow starts again, it goes on from the first step
that is not done.

1. **Look for the variables.** When the repository has `GCP_WIF_PROVIDER` and
   `GCP_DEPLOY_SA` already, the Google Cloud part is done: go to the next account.
2. **Sign up and give a card.** Go to `https://console.cloud.google.com/` with
   `browser_navigate`. When the page asks for a sign-in, or has no billing account
   (`https://console.cloud.google.com/billing` shows none), call `hand_to_person`:
   - step: `Sign in to Google Cloud, and add a billing account with your card`;
   - reason: `Cloud Run needs a Google Cloud account with billing. Only you can sign up and pay.`

   The person signs up and pays. The agent never types a card or a Google password.
3. **Put the script in Cloud Shell.** Go to `https://shell.cloud.google.com/?show=terminal`.
   When Cloud Shell has started, open its **⋮** menu (**More**), click **Upload**, and give
   the clone's `setup-gcp.sh` to the file field with `browser_file_upload`. Cloud Shell
   puts it in the home folder. When the upload does not work, the next card says to paste
   the file instead (the starter's README, "Set it up once").
4. **Run the script.** Call `hand_to_person`:
   - step: `In Cloud Shell, run bash setup-gcp.sh, and click Authorize when Cloud Shell asks`;
   - reason: `The script makes the project, the service account that deploys, and the sign-in from GitHub, with your own Google account. No key leaves Google Cloud.`

   The script runs with the person's own sign-in. When the project id is taken by someone
   else, the script says so and stops: the person runs it again with another id
   (`bash setup-gcp.sh tidelog-5678`). `GCP_DEPLOY_SA` then names that project, so take
   the project from it in step 5, not from the starter's value.
5. **Read the two names.** The script's last two lines are
   `GCP_WIF_PROVIDER=projects/<number>/locations/global/workloadIdentityPools/github/providers/github`
   and `GCP_DEPLOY_SA=deploy@<project>.iam.gserviceaccount.com`. Read them in this order,
   and stop at the first that gives both:
   1. `browser_snapshot` of the Cloud Shell page.
   2. Only when the project is the starter's value: the project's number on its dashboard,
      `https://console.cloud.google.com/home/dashboard?project=<project>`
      (**Project number**). The names are then the two above, with `<number>` and
      `<project>` filled in: the pool, the provider and the account always have these
      names (`github`, `github`, `deploy`).
   3. `ask_question` with free text: `Paste the two lines that setup-gcp.sh printed last.`

   Check each name against its pattern above before it goes to the repository.
6. **Set the variables.** Call `set_ci_variable` twice, on the new repository:
   `GCP_WIF_PROVIDER` and `GCP_DEPLOY_SA`. They are not secrets: GitHub signs in to
   Google Cloud with them and no key.

## What reaches the machine

No Google key, token or password: the script makes no key, and `deploy.yml` signs in
with Workload Identity Federation. The two names are not secret. The person signs in to
Google in the Agent Browser, as for every `hand_to_person` card, so the browser keeps
that sign-in as it keeps any other; Agents' daemon and the control plane never read it.

## Decisions

- **Decided: the agent uploads the script, and the person runs it.** Because Cloud Shell
  cannot open a private repository (its **Open in Cloud Shell** link clones only public
  ones, into a temporary shell with no credentials), and a copy in a public place would
  publish the person's repository name. The person runs it, so that the project and its
  roles are made by the person, with their own sign-in. Alex can overrule.
- **Decided: the agent reads the names from the page first, and asks only when it cannot.**
  Because the project number is on the console's dashboard, and the rest of the names are
  fixed by the script. The card's note is only for **Can't do it** on every client, so
  the person cannot paste the lines there. Alex can overrule.
- **Decided: no new tool and no new screen.** Because `hand_to_person`, the browser tools
  and `set_ci_variable` do each step. Alex can overrule.
