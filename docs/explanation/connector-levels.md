---
diataxis: explanation
description: What the five levels on every connector mean (Tools, Events, Views, Workflows, Tested), where they come from, why they exist, and where the connectors that Agents makes come from.
devices: [mac, iphone, ipad, web]
---

# Connector levels

Every connector (an MCP server) shows five levels under its name: **Tools**, **Events**,
**Views**, **Workflows** and **Tested**. A level that the connector reaches is in the
accent colour. A level that it does not reach is grey. This page explains what each level means for you,
where the app gets it, and why the levels are there at all.

## Why there are levels

A connector can do much more than give an agent tools. It can tell the app that something
happened, so that a workflow starts. It can draw a page that you work with. Before the
levels, nothing in the app said which connector did which. The connectors that Agents
makes did more than most, and they could look like a separate product, or like any other
server. Neither was true.

So every connector is one kind of thing. You add it, sign in to it and remove it in the
same way, whoever made it. The levels then tell you, at a glance, how far a connector
goes. Each level is a thing you can count on, not a promise in a description.

The levels are also the bar for the integrations that Agents ships. Each integration for
1.0 is to reach all five.

## What each level means

**Tools.** Agents can call the connector's tools. This is what every MCP server does. The
app reads it from the server's `tools/list`.

**Events.** The connector tells the app when something happens, such as "a pull request's
checks failed" or "an issue got a label". A workflow or a wait can start on that, with no
agent running and polling for it. The app reads it from the `events` that the server
declares when it starts, as the MCP events draft describes.

**Views.** The connector has pages of its own (`ui://` views, MCP Apps) that the app draws
in a chat or as a pin, on the Mac, the Remote and the web page. A view is where you act
yourself: merge a pull request, start an agent on an issue. The app reads it from the
tools and resources that name a `ui://` view. See
[Views in a conversation](views.md).

**Workflows.** One of Agents' ready-made workflows starts on one of the connector's
events. You turn the workflow on, and the dev loop runs: an issue is worked, a failed
check is fixed, review comments are answered. The events that count are `issue.labelled`,
`checks.failed`, `review.posted`, `review.comment` and `email.received`. A workflow names
events, never a server. So a connector from anyone that declares one of these events
reaches this level by itself.

**Tested.** The connector was tested on a real account, not only against a stand-in. It is
the one level that a server can't declare. The date is in the catalogue entry of a
connector that Agents makes, and the same branch changes its row in
[Integrations](../reference/integrations.md). The host reads the level from the catalogue
entry, not from the docs, because a Linux host has no copy of the docs.

## Where the levels come from

The first four levels come from what a server declares, never from who made it. A
third-party server that adds events or views lights up those levels with no change in
Agents. That keeps the levels honest: they say what the server does now, on your host.

The host checks each connector. A hosted connector keeps the state of its one running
copy. Any other connector is checked every four hours, and when its entry changes. Until
its host has checked it, a connector from a registry shows all five levels in grey, and
its tooltip says "Its levels show once its host has checked it." A connector that Agents
makes shows what it is written to declare before its host has checked it, and a test
holds that to the server's own list.

Hold the pointer over the levels on the Mac, or let VoiceOver read them, for a sentence
such as "Reaches Tools, Events, Views. Not yet Workflows, Tested."

## Where you see them

- On every **Connectors** page, for a folder and your own, on the Mac, the
  Remote and the web page.
- In the Mac's catalogue (**Add Connector…**), on each row and on a connector's detail.
  The catalogue is on the Mac only.

## The connectors that Agents makes

Agents makes four connectors: **GitHub**, **Linear**, **GitLab** and **Email**. They are rows
like any other, with no mark and no group of their own (#2155). They are in the **Agents**
marketplace, a file that every host carries (`Go/internal/agentsd/mcpcatalog/agents.json`),
with **Agents** as their publisher. Choose **Agents** in the catalogue's **Marketplace** menu to
see them. Their levels before a host checks a copy come from that file.

They are added in the same way as any other connector: an entry in an `mcp.json`, with a
secret named, never written in. They run hosted, one copy on each host, so their events
keep coming when no agent runs. Each one reads a connection that you made once on
**Connectors**, so it needs no token of its own.

If you add GitHub's own server next to the GitHub connector that Agents makes, the app
leaves both. It does not offer to replace one with the other, because you may want both.

## See also

- [Use GitHub](../how-to/use-github.md)
- [Use GitLab](../how-to/use-gitlab.md)
- [Use Linear issues](../how-to/use-linear-issues.md)
- [Start a workflow from an MCP event](../how-to/start-a-workflow-from-an-mcp-event.md)
- [Add a connector from the registry](../how-to/add-a-connector-from-the-registry.md)
- [Integrations](../reference/integrations.md)
