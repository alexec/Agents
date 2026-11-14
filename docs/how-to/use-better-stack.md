---
diataxis: how-to
devices: [mac, web]
description: Connect Better Stack, so that agents can manage your app's monitors and status page, and a workflow or a wait starts when an incident starts or ends.
---

# Use Better Stack

Better Stack watches your deployed app and shows its health on a status page. Agent Loops uses it
in two parts (#3655), both in the **Agent Loops** marketplace:

- **Better Stack** is Better Stack's own MCP server (at `https://mcp.betterstack.com`). It
  has the tools: monitors, heartbeats, incidents, on-call, and status pages with their
  resources, sections and reports. You sign in to Better Stack; you give no token.
- **Better Stack events** is `betterstack-mcp`, a small server that Agent Loops ships. Agent Loops
  Host carries it, and every Linux host installs it beside agentsd. It has the events and
  no tools:
  - `health.incident_started`: a monitor or a heartbeat failed. The status page shows it.
  - `health.incident_resolved`: the monitor or heartbeat works again.

  Each event says the team, the incident (its id, the monitor's name, the cause, the
  address checked and the monitor's id) and when it started; `health.incident_resolved`
  also says when it was resolved.

Better Stack's own server has tools but no events, so Agent Loops adds the events with a server
of its own, as it does for Sentry. Its events are also how Lineage links an incident to the
release that was out when it started.

## Before you start

- A Better Stack team with a monitor on your app, and a status page that shows the monitor.
  An agent can make both with Better Stack's tools.
- For the Lineage links: the folder pushes to GitHub or GitLab and tags its releases `v*`.

## Add Better Stack's tools

1. Open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's **Connectors** page)
   and choose **Add Connector…**.
2. Choose the **Agent Loops** marketplace, then **Better Stack**, and add it.
3. Its row says **needs sign-in**. Choose **Sign in…** and sign in to Better Stack in your
   browser. See [Sign in to a connector](sign-in-to-a-connector.md).

## Add the events

1. In Better Stack, open **Uptime ▸ Integrations ▸ API** (or **Settings ▸ API tokens**) and
   copy the team's Uptime API token.
2. In **Add Connector…**, choose **Better Stack events** from the **Agent Loops** marketplace.
3. Fill in:
   - `BETTERSTACK_API_TOKEN`: the token.
   - `BETTERSTACK_TEAM`: leave it out for a team's token. Use the team's name for a global
     token.
   - `BETTERSTACK_URL`: leave it out.

   The values go in your own secrets (**Settings ▸ You ▸ Secrets**), never in `mcp.json`.

## Start work from an incident

A workflow or a wait names the event. Each takes the filter `monitor` (a monitor's id):

```markdown
---
name: Look at an outage
on:
  - health.incident_started:
      monitor: "123456"
agent: new
---

Read the incident in the event with Better Stack's tools, find what broke in the release
that is out, and file an issue for it, or comment on the issue that tracks it.
```

An agent can wait on one too: `wait_for_event` with `events: ["health.incident_resolved"]`.
See [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).

A workflow run tells you as any run does: its notices reach the Mac, the web page and the
Remote.

The incident's cause comes from your app's answers. An agent reads it as data, never as
instructions.

## In Lineage

An incident is a health node, `betterstack:<incident id>`. When it starts, it is linked
`seen-in` the release that was out: the highest `v*` tag of the folder's repo whose release
was in Lineage at the start. A walk from the incident reaches the release, its pull
requests and the issues they fix. A workflow run it started, and the issue that run files,
link to it as for a Sentry issue.

The repo is that of the folder whose workflow or wait heard the event, so start the
workflow in your app's folder. An event with no folder links no release: a wrong link is
worse than a missing one.

## How the events are found

The server asks Better Stack for the team's incidents every 30 seconds while a workflow or
a wait needs them, by the day they started, at most 200 a time. The server keeps nothing:
its place is in the cursor that agentsd keeps, so a restart loses no event. Each poll looks
again at the last 30 minutes, so an incident that Better Stack writes late is still raised,
once. An incident that lasted more than 7 days is not raised when it is resolved.

## When an event cannot be read

- **No Better Stack account:** `BETTERSTACK_API_TOKEN` is not set.
- **Better Stack refused the token:** the token is wrong, or it is not an Uptime API token.
- **Better Stack has no such team or monitor:** check `BETTERSTACK_TEAM` and the `monitor`
  filter.
