---
description: A person says the app they want, and an agent on their own machine makes the repository, walks them through the outside accounts, and puts each secret into the repository's CI, so that the first deploy can run (#3656).
---

# A new app from nothing, by voice (#3656)

Issue #3656, feature `feature:delivery`. A follow-up of epic #3579 (closed), from
`specs/3579-outer-loop/spec.md`, "Later, filed by the lead when the loop works". Docs
only: no product code. The children below build it.

## The question

A person says "make me an app that …". What does Agents do to get from nothing to a first
deploy: a repository, the outside accounts (Apple, Sentry, Google Cloud) and the CI
secrets that the outer loop needs?

## Today

The outer loop works for a repository that is already set up (#3579):

- **TestFlight:** the repository's `release.yml` uploads a build and says
  `::notice title=deploy::testflight:<bundle id>/<build>` (#3584). For Agents itself,
  that needs nine signing secrets and the `PROFILE_*` profiles (`release.yml`,
  `scripts/release-secrets.sh`).
- **App Store:** `app-store.yml` waits at the `app-store` environment's gate, then submits
  (#3657).
- **Cloud Run:** `deploy.yml` signs in to Google Cloud with Workload Identity Federation:
  no key, only the repository variables `GCP_WIF_PROVIDER` and `GCP_DEPLOY_SA`
  (`docs/how-to/deploy-to-cloud-run.md`, #3654).
- **Health:** Sentry (`docs/how-to/use-sentry.md`, #3583) and Better Stack (#3655).
- **A step for the person:** `hand_to_person` shows a card with the step and opens its
  page in the Agent Browser; the agent waits for **Done** or **Can't do it** (#3529).
- **A secret from the person:** `ask_secret` shows a masked form on every client. With
  **this session only** (#3548), the value stays on the session's machine, in
  `~/.agents-secrets/sessions/<agent>.json`, and is deleted when the session is archived.
  The control plane forwards it sealed to the machine (#3397).

What is missing:

- No code makes a repository. The GitHub server's `create_repository` is offered, but
  nothing uses it.
- No code writes a repository's CI secrets or variables. Only
  `scripts/release-secrets.sh` does that, for this repository, by hand.
- No starter: each repository writes its own `release.yml` and `deploy.yml` from the
  how-to pages.
- No flow puts these steps in order.

## Alex's answers (form on #3656, 2026-11-06)

1. **A step that needs the person's hands is a card, one at a time.** The agent calls
   `hand_to_person` at the moment it needs the step (enrol in the Apple Developer Program
   and pay, sign up to Google Cloud and give a card, a CAPTCHA, a code), and waits. There
   is no checklist issue: `alex-todo` is this repository's own process, not the product's.
   The person pays and signs up; the agent never does.
2. **A secret lives only in the repository's CI.** The person types it in an `ask_secret`
   form, for **this session only**. The agent's host writes it into the repository's CI
   secrets and the session's copy is deleted when the session is archived. It is never in
   the machine's `secrets.env`, and the control plane sees only ciphertext
   (principles 6 and 7).
3. **This spec, then an epic.** #3656 becomes an epic with the children below, and a lead
   runs it.

## The flow

The person says what they want in voice mode, or types it. The agent runs on one of the
person's machines, never on the control plane (principle 1, principle 5).

1. **The kind of app.** The agent asks one question: an iPhone app (TestFlight, then the
   App Store), a web service (Cloud Run), or both. It also asks the name.
2. **The repository.** The agent makes a private GitHub repository from a starter, with
   the person's own GitHub connection. The repository is cloned on the machine and shows
   as a folder.
3. **The gates.** The agent makes the environments that hold a deploy (`testflight`,
   `app-store`, `production`) with the person as the required reviewer, so that nothing
   deploys before they approve it (#3587).
4. **The accounts, one card at a time.** For each account the app needs, in this order:
   Apple, then Google Cloud, then Sentry. Each step the person must do is a
   `hand_to_person` card. Each secret is an `ask_secret` form, for this session only,
   then a CI secret.
5. **The first deploy.** The agent pushes the first change, tags `v0.1.0`, and the
   person approves the deploy in **Needs You**. Lineage shows the release, the CI run and
   the deploy (#3588).
6. **The features.** The person dictates features; the Product Owner files them as
   issues, and the inner loop takes them.

The agent stops with a card when a step fails ("Can't do it"), and says what is left.
The person can start again later: each step checks what is already there and skips it.

## What each account needs

| Account | The person does (a card each) | The agent does | In the repository's CI |
| --- | --- | --- | --- |
| GitHub | nothing more: they are signed in | makes the repository, the environments and the reviewers | — |
| Apple | enrols in the Apple Developer Program and pays; makes the app's record in App Store Connect; makes a team API key and downloads it | registers the bundle id with the key, from a one-time CI job | secrets `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID` |
| Google Cloud | signs up and gives a card; runs the starter's set-up script in Cloud Shell, which makes the project, the deploy service account and Workload Identity Federation | reads the two names the script prints | variables `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA` (no secret) |
| Sentry | signs up (the free plan needs no card); signs in to Sentry's MCP server; makes an organization auth token | makes the project and its DSN with Sentry's MCP server; adds Sentry events (#3583) | variable `SENTRY_DSN`; for an iPhone app, also variable `SENTRY_PROJECT` and secret `SENTRY_AUTH_TOKEN` (debug symbols; [sentry.md](sentry.md)) |

- **Apple signing has 3 secrets, not 9.** The starter's `release.yml` uses Xcode's
  cloud-managed signing: `xcodebuild -allowProvisioningUpdates` with the API key's
  `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID`. Apple
  makes the certificate and the profile, so there is no `.p12` and no profile to keep.
  The key needs a role that may make certificates; the Apple child finds the smallest one.
- **The app's record is a card,** because App Store Connect's API has no call that makes
  one.
- **Google Cloud has no key at all.** The script runs in the person's Cloud Shell, with
  their own sign-in, so no Google credential reaches the machine or the control plane.
- **Sentry's token is the one secret that is also on the machine,** in the Sentry events
  integration, which reads new issues (#3583). That is the integration's own set-up, as
  now, and not part of this flow's rule.

## Decisions

- **Decided: GitHub first.** Because the outer loop's deploys and gates are GitHub's
  (#3581, #3587), and GitHub's API makes repositories, secrets, variables and
  environments. GitLab (CI/CD variables, protected environments) is a later child. Alex
  can overrule.
- **Decided: the host writes a CI secret, not the agent.** A new app tool,
  `set_ci_secret`, takes the repository, the CI secret's name and the name of a
  session-only secret. agentsd reads the value, seals it to the repository's public key
  and puts it with GitHub's API. The value never goes in the agent's context or the
  transcript. Because the agent would otherwise have to read the value, and could print
  it. Alex can overrule.
  - The seal is libsodium's sealed box, as GitHub asks: `golang.org/x/crypto/nacl/box`,
    `SealAnonymous` (BSD-3-Clause, `golang.org/x/crypto` is already in `go.mod`). No new
    library.
  - `set_ci_variable` does the same for a variable, which is not secret, and
    `set_environment_gate` makes an environment with required reviewers.
  - Each tool gets a line in the brief (`Go/internal/agentsd/brief.go`), gated as the
    GitHub tools are.
- **The starters are GitHub template repositories (Alex, 2026-11-10, #4561),**
  `alexec/iphone-app-starter` and `alexec/web-service-starter`, public and marked as
  templates. This replaces "the starters live in this repository, under `templates/`, and
  agentsd embeds them": a baked-in starter changes only with a release of Agents. A template
  repository changes on its own, anyone can name their own or a fork, GitHub's **Use this
  template** works without Agents, and Dependabot keeps its dependencies current.
  - `make_app_repository`'s `starter` is a repository, `owner/name`, with `iphone-app` and
    `web-service` as short names for ours. agentsd fetches its default branch (a shallow
    clone with the person's GitHub connection), fills the placeholders and pushes the result
    as the new repository's first commit, as before. Not GitHub's generate-from-template,
    which copies the placeholders unfilled and shows "generated from" the template.
  - A template's `.starterignore` names its own files, which a new app does not get: its
    CI (`.github/workflows/template.yml`, which fills sample values, checks the workflows and
    builds), `.github/template/` and `.github/README.md` (what GitHub shows on the template's
    page, with the placeholders; the app's own `README.md` is at the root).
  - Decided: agentsd takes the default branch, not a tag, because a fix then reaches the next
    new app at once; a person who wants a fixed version names a fork. Alex can overrule.
- **Decided: the flow is a ready-made skill, `start-a-new-app`,** with no workflow, as
  `map-a-docs-server` is (#3307), and a line in the brief that says to follow it when a
  person asks for a new app. Because the steps are judgment (which accounts, what is there
  already) and an agent follows a skill; a fixed program could not skip what is already
  set up. Alex can overrule.
- **Decided: the repository is private.** Because the person's idea is theirs until they
  say so. They can make it public on GitHub. Alex can overrule.
- **Decided: no new screen.** The cards, the forms, **Needs You** and the folder in the
  session list are there now. Alex can overrule.

## Principles (direction.md)

- **1, nothing relies on the Mac:** the agent runs on any of the person's machines; the
  web page shows every card and form. Voice mode is on the Mac app, and typing the same
  thing on the web works the same.
- **5, customers bring their own:** every account is the person's own, made by them.
- **6, the control plane holds nothing it could misuse:** it forwards the sealed secret
  (#3397) and never sees a value; it makes no account and no repository.
- **7, keep nothing that can stay on the customer's systems:** a secret is in the
  repository's CI only, and the session's copy goes when the session is archived.
- **3 and 4:** the person is signed in to Agents and GitHub before the flow starts.

## The plan (the epic's children)

The children are sub-issues of #3656, with "blocked by" links. Step 1 can start at once.
The lead owns the plan from here.

| Step | Child | Level | Blocked by |
| --- | --- | --- | --- |
| 1 | #3706 CI secrets, variables and gates as app tools: `set_ci_secret`, `set_ci_variable`, `set_environment_gate` (GitHub) | task | — |
| 1 | #3707 Starters: an iPhone app (TestFlight and App Store with cloud-managed signing) and a web service (Cloud Run), each with Sentry, now the template repositories `alexec/iphone-app-starter` and `alexec/web-service-starter` (#4561) | task | — |
| 2 | #3708 A repository from a starter: made on GitHub, cloned on the machine, shown as a folder | story | #3707 |
| 3 | #3709 Apple: the cards, the key as a CI secret, the bundle id from a one-time CI job ([apple.md](apple.md)) | story | #3706, #3708 |
| 3 | #3710 Google Cloud: the Cloud Shell card and the two variables ([google-cloud.md](google-cloud.md)) | story | #3706, #3708 |
| 3 | #3711 Sentry: the cards, the project and DSN, the token as a CI secret ([sentry.md](sentry.md)) | story | #3706, #3708 |
| 4 | #3712 `start-a-new-app`: the ready-made skill and its brief line, from the first question to the approved first deploy | story | #3709, #3710, #3711 |

Later, filed by the lead when the flow works: GitLab as the forge; Android (Google Play)
as a deploy target; Better Stack in the flow (#3655).

## Clients

Docs only. mac: docs only, remote: docs only, web: docs only.

The children are Mac + web (#2796): voice mode is the Mac app, and the web page does it
all by typing. The cards and the secret forms that the flow uses are Core and are on the
Remote now; the Remote gets no parity issue for the flow.
