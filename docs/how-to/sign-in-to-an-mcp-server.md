---
diataxis: how-to
devices: [mac]
description: Sign in to a remote MCP server that asks for OAuth, such as GitHub's, so agents start with it connected.
---

# Sign in to an MCP server

Some remote MCP servers want you to sign in before they answer: GitHub's
(`https://api.githubcopilot.com/mcp/`) is one. The app signs in as an OAuth client, the way
the [MCP authorization spec](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
describes, in your own browser. The next agent you start has the server, with your sign-in.

## See which servers want it

Open **Settings ▸ Shared ▸ MCP servers**, or a project's **MCP servers** section. A remote
server that asked for a sign-in says **needs sign-in** on its row, the way a missing secret
says **NAME not set**. Agents start without it until you sign in.

The app asks each remote server once, the first time the list is shown, with nothing sent
but the MCP greeting. A server you have not approved yet in a project is not asked. A
server whose entry sends its own `Authorization` header is not signed in to: the header is
its sign-in.

## Sign in

1. Choose **Sign in…** on the row.
2. Your browser opens on the server's sign-in page. Sign in there and allow the access it
   asks for.
3. The browser comes back to the app, says **Signed in**, and you can close the tab. The
   row now says **signed in**.

The sheet waits for up to ten minutes. **Cancel** stops it; nothing is kept.

### A server that doesn't let apps register

Most servers let the app register itself for the sign-in. GitHub's does not: the sheet asks
for a **Client ID** instead, and a **Client secret** if the client has one.

1. Register an OAuth app with the server's sign-in. On GitHub: **Settings ▸ Developer
   settings ▸ OAuth Apps ▸ New OAuth App**.
2. Give it the callback URL the sheet shows, `http://127.0.0.1/callback`. The app listens
   on a different port each time; GitHub takes any port on `127.0.0.1`.
3. Paste its client ID, and its secret, into the sheet, and choose **Sign in**.

The client is kept for that server's sign-in, so the next sign-in doesn't ask again.

## Add a server that asks, by hand

On [Add by hand](add-an-mcp-server-by-hand.md), **Verify** finds out the server wants a
sign-in and opens the same sheet. Once you have signed in, it verifies again, with your
sign-in, and **Add** is offered as usual. The entry that is written has no token in it.

## Sign out

Choose **Sign out** on the row. The app tells the server to forget the grant where the
server offers that, and forgets it itself. The row says **needs sign-in** again.

## Where the sign-in is kept

In `~/.agents/mcp-sign-ins.json`, beside `secrets.env`, and like it readable only by you.
Never in `mcp.json`, so a project's committed entry carries no one's sign-in. The app logs
the server's name and what happened, never an address, a code or a token, and it never
sends a sign-in to your iPhone, iPad or the web page. If your `~/.agents` is a git
repository, keep `mcp-sign-ins.json` out of it as you keep `secrets.env`.

A sign-in is for the server's address, so a server in both your own `mcp.json` and a
project's is signed in to once.

## When an agent starts

The app gives the agent the server with your sign-in as its `Authorization` header. A
sign-in that is about to end is renewed first. If the server no longer takes it, the row
says **needs sign-in** again, and agents start without the server until you sign in.

Signing in runs on this Mac's own host. A project on a server host can't sign in to an MCP
server yet.
