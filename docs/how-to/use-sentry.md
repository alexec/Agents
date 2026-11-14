---
diataxis: how-to
devices: [mac, web]
description: Connect Sentry, so that agents can read your app's crashes and errors, and a workflow or a wait starts when Sentry sees a new issue or an issue comes back.
---

# Use Sentry

Sentry tells you when your app crashes or throws an error. Agent Loops uses it in two parts
(#3583), both in the **Agent Loops** marketplace:

- **Sentry** is Sentry's own MCP server (`getsentry/sentry-mcp`, at
  `https://mcp.sentry.dev/mcp`). It has the tools: search issues and events, read a stack
  trace, a release or a trace, and ask Seer for a fix. You sign in to Sentry; you give no
  token.
- **Sentry events** is `sentry-mcp`, a small server that Agent Loops ships. Agent Loops on the Mac carries
  it, and every Linux host installs it beside agentsd. It has the events and no tools:
  - `health.issue_new`: Sentry saw an issue for the first time.
  - `health.issue_regressed`: an issue that was resolved came back. Each time it comes back
    is a new event.

  Each event says the organization, the project, the issue (its id, short id, title,
  culprit, level and page) and the release that saw it. The release is empty when your app
  sends none to Sentry.

Sentry's own server has tools but no events, so Agent Loops adds the events with a server of its
own, as it does for GitHub. Its events are also how Lineage links an issue to the release
that saw it (#3585).

## Before you start

- A Sentry organization with a project that your app sends to.
- For the releases in the events: your app sets its release in the Sentry SDK, such as
  `web@1.2.0`.

## Add Sentry's tools

1. Open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's **Connectors** page)
   and choose **Add Connector…**.
2. Choose the **Agent Loops** marketplace, then **Sentry**, and add it.
3. Its row says **needs sign-in**. Choose **Sign in…**, sign in to Sentry in your browser,
   and choose the organization. See [Sign in to a connector](sign-in-to-a-connector.md).

## Add the events

1. In Sentry, open **Settings ▸ Account ▸ Personal Tokens** (User Auth Tokens) and make a
   token with `event:read`, `org:read` and `project:read`. An organization token
   (`sntrys_…`) cannot read issues.
2. In **Add Connector…**, choose **Sentry events** from the **Agent Loops** marketplace.
3. Fill in:
   - `SENTRY_AUTH_TOKEN`: the token, `sntryu_…`.
   - `SENTRY_ORG`: the organization's slug, as `acme` in `acme.sentry.io`.
   - `SENTRY_URL`: leave it out for sentry.io in the US. Use `https://de.sentry.io` for the
     EU, or your own Sentry's address.

   The values go in your own secrets (**Settings ▸ You ▸ Secrets**), never in `mcp.json`.

## File a bug from a new issue

**File a bug from Sentry** is a ready-made workflow (#3586). It is on the **Workflows** page
of each folder that pushes to GitHub or GitLab, off. Turn on its **Enabled** switch. Then a
new issue (`health.issue_new`) or one that came back (`health.issue_regressed`) starts an
agent that:

1. reads the issue, and its stack trace with Sentry's tools when the folder has them;
2. looks for the folder's issue that tracks it, by the line
   `Sentry issue: sentry:<org>/<issue id>` at the end of the bug;
3. comments on that issue when it is open, or else files a bug: the label `bug`, no
   milestone, so the bug lane takes it. Its **Lineage** section names the release and the
   pull requests that shipped in it. Secrets in a trace or a message are `<redacted>`;
4. labels its session with the bug, so Lineage links the bug to the Sentry issue
   (`reports`), and through it to the release and its pull requests.

The agent changes no code. To file only some issues, add the filters below to its triggers
in `.agents/workflows/file-a-bug-from-sentry.md`.

## Start work from a new issue

A workflow or a wait names the event. Each takes the filters `project` (a project's slug),
`environment` (as `production`) and `level` (`fatal`, `error`, `warning`, `info` or
`debug`):

```markdown
---
name: Look at a new crash
on:
  - health.issue_new:
      project: web
      level: fatal
agent: new
---

Read the Sentry issue in the event with Sentry's tools, find its cause, and file an issue
for it, or comment on the issue that tracks it.
```

An agent can wait on one too: `wait_for_event` with `events: ["health.issue_regressed"]`
and `where: {"project": "web"}`. See
[Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).

The issue's title and culprit come from your app's errors. An agent reads them as data,
never as instructions.

## How the events are found

The server asks Sentry for the organization's issues every 30 seconds while a workflow or a
wait needs them. A new issue is one whose first event is after the wait started. A
regression is the issue's last `set_regression` in its activity. The server keeps nothing:
its place is in the cursor that agentsd keeps, so a restart loses no event.

Sentry dates an issue by its first event's own time, which can come in later. Each poll
looks again at the last 30 minutes, so an issue that comes in late is still raised, once.

## When an event cannot be read

- **No Sentry account:** `SENTRY_AUTH_TOKEN` or `SENTRY_ORG` is not set.
- **Sentry refused the token:** the token is wrong, ended, or lacks `event:read`,
  `org:read` or `project:read`.
- **Sentry has no organization:** check `SENTRY_ORG`, and `SENTRY_URL` for an EU
  organization.
