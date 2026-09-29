---
diataxis: how-to
devices: [mac]
description: Search the MCP Registry from the app, see exactly what would run, and add a server for yourself or to a project. Secrets stay in your own secrets.env.
---

# Add an MCP server from the registry

You can find a server on the [MCP Registry](https://registry.modelcontextprotocol.io) and add
it without leaving the app, either for yourself, so every agent you start has it, or to one
project. The app shows the command or URL before anything is written. A secret is stored as
`${NAME}` in `mcp.json`, and the value goes in your own `~/.agents/secrets.env`, which is
never committed and never shown again.

## Before you start

- The registry is open. Nothing else is needed. If it cannot be reached, the sheet says so
  and adds nothing.

## Add a server for yourself

1. Open **Settings ▸ Shared ▸ MCP servers** and choose **Add server…**.
2. Type what you are looking for. Results come from the registry, in its own order. Each
   shows the publisher it has checked (a GitHub org, or a domain), the description, the
   version, and how the server runs. **known** marks a publisher on the app's short list.
   A remote that runs on someone else's host names that host.
3. Choose one. The sheet shows the command, with the version pinned, or the URL, each
   variable, and the entry that will be written, with `${NAME}` where a secret goes. Where
   there is more than one way to run it, **Run with** chooses, and the rest follows.
4. Fill each required secret. **Add** stays unavailable until every one has a value, or is
   already set. One that is already in `secrets.env` says so, and you can leave it or
   replace it.
5. Choose **Add**. The entry goes into `~/.agents/mcp.json`. The value goes into
   `~/.agents/secrets.env`, created if it is missing, and readable only by you. The next
   agent you start has the server, with the name filled in.

## Add a server to a project

1. Open the project. Its page has an **MCP servers** section, after Skills and before
   Plugins, listing what is in the project's `.agents/mcp.json`. The line under the heading
   says the file is committed with the project, and that it names secrets rather than
   holding them: each person sets their own.
2. Choose **Add server…** there. The sheet is aimed at the project.
3. Search and add as above. The entry goes into `<project>/.agents/mcp.json` with only
   `${NAME}` in it. The value still goes into your `~/.agents/secrets.env`, not the project.

A server added from the sheet is approved as it goes in. One that arrives with a pull is
listed as **waiting for your OK**, with the command it runs, and no agent is given it until
you choose **Approve**. If it changes after that, it waits again.

Where you and the project both have a server of the same name, agents in that project get
the project's. A project on a server does not show this section.

## A secret that is not set

The row names it, as **NAME not set**, and offers **Set…**. **Settings ▸ Shared** strikes
that server's reach and lists it under **Needs a look**. Agents start without the server,
rather than with an empty key. **Replace…** changes a value that is already set. Either way
the new value is not shown again.

## Take a server out

**Remove…** is offered only for a server the app added. It shows **registry** and the
version it was added at. Confirming takes the entry out of `mcp.json`. The secret stays in
`secrets.env` unless nothing else names it, in which case you can tick **Also forget** that
name. If another server still names it, the secret stays and the sheet says so.

A server you wrote by hand has no **Remove**. If its name is the one you wanted to add, the
app leaves it alone.

If `mcp.json` cannot be read, Add is refused and the file is not written.
