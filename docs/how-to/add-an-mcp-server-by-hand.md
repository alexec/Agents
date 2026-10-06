---
diataxis: how-to
devices: [mac]
description: Add an MCP server that is not in the registry, a local command or a remote URL, and see it answer before anything is written.
---

# Add an MCP server by hand

Not every server is on the [MCP Registry](https://registry.modelcontextprotocol.io). One
your team runs, or one you are building, can still be added from the app, for yourself or
to a project. The app connects to it first. Only a server that answered is written, and
the sheet shows the tools it listed.

## Before you start

- For a local server, the command it runs, such as `npx`, `uvx`, `docker` or a path, and
  its arguments.
- For a remote server, its URL, which starts with `https://`, and any headers it needs.

## Add it

1. Open **Settings ▸ Shared ▸ MCP servers**, or a project's **MCP servers** section, and
   choose **Add server…**.
2. Choose **Add by hand…**.
3. Give it a **Name**: letters, digits, dots, dashes and underscores. Agents see its tools
   under this name.
4. Choose how it runs:
   - **Local command**: the **Command**, and the **Arguments** on one line, quoted as in
     a shell (`--dir "/a b"`). **Add variable** adds an environment variable.
   - **Remote URL**: the **URL**. **Add header** adds a header, such as `Authorization`.
5. Tick **Secret** on a variable or header that holds a key or token. Its value goes into
   your own `~/.agents/secrets.env`, and the entry in `mcp.json` holds `${NAME}`, the same
   way a registry add does. The line under it shows the name. A variable's secret has the
   variable's own name. A header's has the server's and the header's, such as
   `MY_API_AUTHORIZATION`. Leave the value empty to use one that is already set under that
   name. A plain value can name a secret that is already set, as `${NAME}`.
6. Choose **Verify**. The app starts the command, or opens a session with the URL, and asks
   the server who it is and what tools it has. Nothing is written yet.
   - **It answered**: the sheet names the server and lists its tools. It also shows the
     entry that would be written.
   - **It did not answer**: the sheet says why, for example that the command was not found,
     or what the URL answered with. Change something and choose **Verify** again.
   - **It asks you to sign in**: the server wants a sign-in, an OAuth one, before it answers.
     The sign-in sheet opens, and once you have signed in in your browser, Verify runs
     again with it: see [Sign in to an MCP server](sign-in-to-an-mcp-server.md).
7. Choose **Add to ~/.agents**, or **Add to project**. It is offered only once the server
   has answered, and only while the form still says what was verified. Change anything and
   you verify again.

Agents you start after that have the server. A project's entry is approved as it goes in,
as a registry one is.

## Take it out

The row shows **added by hand**, and has **Remove…**, as a registry server's does: see
[Take a server out](add-an-mcp-server-from-the-registry.md#take-a-server-out).

## Where Verify runs

A local server runs on this Mac, in the project's folder (or your home folder for your own
servers), with the same environment the app gives the runtimes, and is stopped as soon as
it has answered. The app logs the server's name and whether it answered, never its command,
arguments, variables, headers or URL.

If the name is already in that `mcp.json`, whether the app wrote it or you did, the sheet
says so and adds nothing.
