---
diataxis: how-to
devices: [mac]
description: Search the MCP Registry from the app, see exactly what would run, and add a connector for yourself or to a folder. Secrets stay in your own secrets.env.
---

# Add a connector from the registry

You can find a connector (an MCP server) on a registry, [GitHub's](https://github.com/mcp) by default, the
official [MCP Registry](https://registry.modelcontextprotocol.io), or one you added (see
[Choose marketplaces](choose-marketplaces.md)), and add it without leaving the app, either for yourself, so every agent you start has it, or to one
folder. The app shows the command or URL before anything is written. A secret is stored as
`${NAME}` in `mcp.json`, and the value goes in your own `~/.agents-secrets/secrets.env`, which is
never committed and never shown again.

## Before you start

- The registry is open. Nothing else is needed. If it cannot be reached, the sheet says so
  and adds nothing.

## Add a connector for yourself

1. Open **Settings ▸ Agent Configuration ▸ Connectors** and choose **Add Connector…**.
   The connectors that Agents makes (GitHub, Linear, GitLab and Email) are in the **Agents**
   marketplace: choose it in the **Marketplace** menu. They run hosted, one copy for each host,
   so their events come in when no agent runs.
2. Type what you are looking for. Results come from the marketplace chosen in the
   **Marketplace** menu, in its own order (GitHub's puts the most starred first). Each
   shows the publisher it has checked (a GitHub org, or a domain), the description, the
   version, and how the server runs. **known** marks a publisher on the app's short list.
   A remote that runs on someone else's host names that host.
   Each row also shows the five levels the connector reaches: **Tools**, **Events**,
   **Views**, **Workflows** and **Tested**. A level that is not reached is grey. A connector
   from a registry shows its levels after its host checks it. See
   [Integrations](../reference/integrations.md) for what each level means.
3. Choose one. The sheet shows the command, with the version pinned, or the URL, each
   variable, and the entry that will be written, with `${NAME}` where a secret goes. Where
   there is more than one way to run it, **Run with** chooses, and the rest follows.
4. Fill each required secret. **Add** stays unavailable until every one has a value, or is
   already set. One that is already in `secrets.env` says so, and you can leave it or
   replace it.
5. Choose **Add**. The entry goes into `~/.agents/mcp.json`. The value goes into
   `~/.agents-secrets/secrets.env`, created if it is missing, and readable only by you. The next
   agent you start has the connector, with the name filled in.

## Add a connector to a folder

1. Open the folder. Its page has a **Connectors** section, after Skills and before
   Plugins, listing what is in the folder's `.agents/mcp.json`. The line under the heading
   says the file is committed with the folder, and that it names secrets rather than
   holding them: each person sets their own.
2. Choose **Add Connector…** there. The sheet is aimed at the folder.
3. Search and add as above. The entry goes into `<folder>/.agents/mcp.json` with only
   `${NAME}` in it. The value still goes into your `~/.agents-secrets/secrets.env`, not the folder.

A connector added from the sheet is approved as it goes in. One that arrives with a pull is
listed as **waiting for your OK**, with the command it runs, and no agent is given it until
you choose **Approve**. If it changes after that, it waits again.

Where you and the folder both have a server of the same name, agents in that folder get
the folder's. A folder on a server does not show this section.

## A secret that is not set

The row names it, as **NAME not set**, and offers **Set…**. **Settings ▸ Agent Configuration** strikes
that server's reach and lists it under **Needs a look**. Agents start without the server,
rather than with an empty key. **Replace…** changes a value that is already set. Either way
the new value is not shown again.

## Take a connector out

**Remove…** is offered on every connector: one from the registry (it shows **registry** and
the version it was added at), one added on the sheet by hand (**added by hand**, see
[Add a connector by hand](add-a-connector-by-hand.md)), and one you wrote into `mcp.json`
yourself (#2154). Confirming takes the entry out of `mcp.json`; the rest of the file stays as
it is. The secret stays in `secrets.env` unless nothing else names it, in which case you can
tick **Also forget** that name. If another server still names it, the secret stays and the
sheet says so.

Your own `~/.agents/mcp.json` is in no git, so the entry that goes is kept in
`~/.agents/mcp.removed.json`, in the same shape: copy it back into `mcp.json` to have the
connector again. That file keeps the last 20 (#2195). A folder's `.agents/mcp.json` is
committed, so git brings back what was committed.

If you add a connector whose name is one you wrote into `mcp.json` yourself, the app leaves
yours alone.

A connector that is not on the registry can be added from the same sheet with **Add by
hand…**, which connects to it before anything is written: see
[Add a connector by hand](add-a-connector-by-hand.md).

If `mcp.json` cannot be read, Add is refused and the file is not written.
