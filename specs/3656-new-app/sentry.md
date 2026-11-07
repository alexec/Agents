---
description: The Sentry steps of a new app (#3711, epic #3656) - the sign-up card, Sentry's MCP server for the project and its DSN, an organization token as a CI secret, and the Sentry events - as the start-a-new-app skill (#3712) follows them.
---

# A new app's Sentry (#3711)

Issue #3711, a child of epic #3656 (`spec.md`, "What each account needs"). The steps
below are for an agent. The `start-a-new-app` skill (#3712) takes them as its Sentry part,
after Apple and Google Cloud. They use only tools that the app has now: the browser tools,
`hand_to_person` (#3529), `ask_question`, `ask_secret` (#3548), `start_session`,
`set_ci_variable` and `set_ci_secret` (#3706), and Sentry's own MCP server (#3583).

## What is there before these steps

- `make_app_repository` made the repository from the `iphone-app` or the `web-service`
  starter (#3708), or one of each. Both starters have Sentry's SDK, which sends nothing
  until the repository has the variable `SENTRY_DSN`.
- The iPhone app's `release.yml` also uploads the debug symbols when the repository has the
  variable `SENTRY_PROJECT` and the secret `SENTRY_AUTH_TOKEN`. The web service has no
  build step and no source maps, so it needs no token.

## What the repository gets

| Starter | Variables | Secret |
| --- | --- | --- |
| `iphone-app` | `SENTRY_DSN`, `SENTRY_PROJECT` | `SENTRY_AUTH_TOKEN`: an organization token (`sntrys_…`) |
| `web-service` | `SENTRY_DSN` | none |

One Sentry project for each repository, named as the repository (`tidelog`), with the
platform `apple-ios` or `node`.

## The steps

Do each step only when it is not done yet. When the person answers **Can't do it**, stop,
say what is left, and end. When the flow starts again, it goes on from the first step
that is not done.

1. **Look for what is there.** When the repository has `SENTRY_DSN` (and, for an iPhone
   app, `SENTRY_PROJECT` and the secret `SENTRY_AUTH_TOKEN`), go to step 6.
2. **Sign up.** Go to `https://sentry.io/auth/login/` with `browser_navigate`. When the
   page asks for a sign-in, call `hand_to_person`:
   - step: `Sign in to Sentry, or sign up on the free plan`;
   - reason: `Sentry tells you when the app crashes or throws an error. The free plan needs no card. Only you can sign up.`

   After **Done**, read the organization's slug from the page's address
   (`https://<org>.sentry.io/…`). The agent never types a Sentry password.
3. **Sign in to Sentry's MCP server.** When the agent has no Sentry tools (no
   `find_organizations`), call `ask_question` with the options **Done** and **Can't do it**:
   - question: `Add Sentry in Settings ▸ Agent Configuration ▸ Connectors (Add Connector…, the Agents marketplace), then choose Sign in… and choose the organization <org>. Done?`

   The sign-in runs on the Mac's own host (`docs/how-to/sign-in-to-a-connector.md`), so
   this card is for the Mac app. The token stays in the person's
   `~/.agents-secrets/mcp-sign-ins.json`; the agent never sees it.
4. **Make the project and its DSN.** A connector that is added during a session reaches
   only the agents that start after it. So when the agent has no Sentry tools, it starts
   a helper in the new folder with `start_session`, and waits for it with
   `wait_for_agents`. The agent, or its helper, with Sentry's tools:
   1. `find_organizations`: the organization from step 2. When there is more than one,
      take the one the person chose in step 3.
   2. `find_teams`: the organization's first team. With none, `create_team` with the
      organization's slug as its name.
   3. `find_projects`: a project named as the repository is used again. Else
      `create_project` with that name, the team, and the platform `apple-ios` or `node`.
   4. `find_dsns` for the project (or the DSN that `create_project` gave): the public DSN,
      `https://<key>@o<number>.ingest.<region>.sentry.io/<project id>`.
   5. `set_ci_variable` on the new repository: `SENTRY_DSN` with the DSN, and, for an
      iPhone app, `SENTRY_PROJECT` with the project's slug. A DSN is not a secret: the app
      sends it with each crash.

   The helper reports the organization's slug and the project's slug, and ends.
5. **The token for the debug symbols** (an iPhone app only). Go to
   `https://<org>.sentry.io/settings/auth-tokens/` with `browser_navigate`, and call
   `hand_to_person`:
   - step: `Make an organization token named <repo> CI, and copy it`;
   - reason: `The release workflow uploads the app's debug symbols with it, so Sentry shows each crash with names and lines. Sentry shows the token only once.`

   Then call `ask_secret` for `SENTRY_CI_TOKEN`, **this session only**, with the same page as
   its link. Then `set_ci_secret` with `secret: SENTRY_CI_TOKEN` and
   `name: SENTRY_AUTH_TOKEN` on the new repository. The token is in no argument, result or
   transcript, and the session's copy is deleted when the session is archived.
6. **Add the Sentry events** (#3583). When the person has **Sentry events** for this
   organization already (`SENTRY_ORG` is set), the Sentry part is done. Else go to
   `https://<org>.sentry.io/settings/account/api/auth-tokens/` with `browser_navigate`, and
   call `hand_to_person`:
   - step: `Make a personal token with event:read, org:read and project:read, and copy it`;
   - reason: `Agents reads the new crashes and errors with it, so that a workflow can start on one. An organization token cannot read issues.`

   Then call `ask_secret` for `SENTRY_AUTH_TOKEN` with **Save securely**: the events
   server reads it from the person's `secrets.env`. Then `ask_question` with **Done** and
   **Can't do it**:
   - question: `Add Sentry events in Settings ▸ Agent Configuration ▸ Connectors (Add Connector…, the Agents marketplace). SENTRY_AUTH_TOKEN is set already; type <org> as SENTRY_ORG. Done?`

   The ready-made workflow **File a bug from Sentry** (#3586) is on the folder's
   **Workflows** page, off. The agent says so, and leaves it for the person to turn on.

## What reaches the machine

- **The organization token** reaches the machine only as the session's secret, and goes to
  the repository's CI. It is never in `secrets.env` (spec, Alex's answer 2).
- **The personal token** for the events is in the person's `secrets.env`. That is the
  events integration's own set-up, as in `docs/how-to/use-sentry.md`; the spec keeps it out
  of the flow's rule ("Sentry's token is the one secret that is also on the machine").
- **The sign-in to Sentry's MCP server** is in `~/.agents-secrets/mcp-sign-ins.json`, as
  for every connector.
- The DSN and the slugs are not secret.

## Decisions

- **Decided: the web service gets no Sentry token.** Because it has no build step and no
  source maps, so a token would be a secret with no use (principle 7). Its errors reach
  Sentry with the DSN only. A later starter with a build step adds the token as the iPhone
  app does. Alex can overrule.
- **Decided: the iPhone app's `release.yml` uploads the debug symbols, with a pinned
  `sentry-cli` (3.8.2, as XcodeGen is pinned), and adds the variable `SENTRY_PROJECT`.**
  Because without the symbols a crash shows addresses, not names, and an organization token
  names its organization but not the project. The step does not fail the release: the
  build is out already. Alex can overrule.
- **Decided: the session's secret is `SENTRY_CI_TOKEN`, not `SENTRY_AUTH_TOKEN`.** Because
  the events server's token is `SENTRY_AUTH_TOKEN` in `secrets.env`, and the two are
  different tokens: an organization token cannot read issues, and a personal token is not
  for CI. `set_ci_secret` gives it the CI name `SENTRY_AUTH_TOKEN`. Alex can overrule.
- **Decided: a helper makes the project when the agent has no Sentry tools.** Because a
  connector added during a session reaches only the agents that start after it, and
  Sentry's MCP server, not the browser, is the spec's way to make the project. Alex can
  overrule.
- **Decided: no new tool and no new screen.** Because `hand_to_person`, `ask_question`,
  `ask_secret`, the browser tools, `start_session`, `set_ci_variable`, `set_ci_secret` and
  Sentry's own tools do each step. Alex can overrule.
