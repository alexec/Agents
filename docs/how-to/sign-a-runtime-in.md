---
diataxis: how-to
devices: [mac]
description: Sign a runtime such as Claude Code, Copilot, Cursor or Grok in or out, from the app.
---

# Sign a runtime in

A runtime is the coding agent the app runs for you, such as Claude Code. Each one signs in
to its own account. When one is installed but not signed in, the app says **Needs
signing in** beside it, and you can sign it in from there.

## Before you start

- The runtime installed on this Mac. See [Reference](../reference/index.md) for what each
  runtime needs.

## Steps

1. On a project's page, click the runtime above the prompt (it names the current one,
   such as **Claude**). A runtime that is not signed in says **Needs signing in** under
   its name.
2. Choose **Sign in, sign out, providers…**.

   A sheet opens with the runtime's name and where it stands: **Signed in and ready**,
   **Installed, and needs signing in**, or **Not asked yet**.
3. If it needs signing in, click the way you want to sign in. The buttons are the
   runtime's own, with its own advice under each.
   - Most runtimes then sign in by themselves, often by opening a page in your browser.
     Finish there.
   - Some hand you a command to run instead, and the sheet says, for example, **Copilot
     signs in from a terminal. Run this:** with the command under it. Click **Open
     Terminal** (it also copies the command), paste it and follow what it asks. **Copy**
     only copies it. When it is done, click **I have done it**.
4. The sheet should now say **Signed in and ready**. Click **Done**.

   The runtime is ready for the next agent you start. An agent that stopped because it
   was not signed in can be prompted again.

**Choose who answers**

Some runtimes can use more than one model provider. For those, the sheet has **Who
answers**, listing them with a ✓ by the current one. Click another to switch.

**Sign out**

1. Open the same sheet and click **Sign out**. It is there only when the runtime is signed
   in and supports signing out from the app.
2. Confirm with **Sign out**. The dialog says first whether anything is running on it, for
   example **This stops 2 agents mid-conversation.**

iPhone and iPad cannot sign runtimes in: sign in on the Mac. For a runtime on a Linux
server, sign in on the server itself; see [Add a Linux server](add-a-linux-server.md).

## If it doesn't work

- **The sheet still says it needs signing in after I have done it.** Close it and open it
  again; the app asks the runtime afresh each time. If it still says so, run the
  runtime's own sign-in in Terminal (for Claude Code, `claude`, then `/login`), then check
  again.
- **The runtime is not in the menu at all.** It is not installed, or not where the app
  looks. With no runtime at all, the project list says **No agent runtime found** and
  what each one needs.
