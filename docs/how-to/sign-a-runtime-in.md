---
diataxis: how-to
devices: [mac]
description: Sign a runtime such as Claude Code, Codex, Copilot, Cursor, Gemini or Grok in or out, from the app.
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
   its name. A runtime that says which account it is signed in with shows that instead,
   such as **Claude Max** or **Anthropic API key**.
2. Choose **Sign in, sign out, providers…**.

   A sheet opens with the runtime's name and where it stands: **Signed in and ready**
   (or, where the runtime says which account, **Signed in with Claude Max, and ready**),
   **Installed, and needs signing in**, or **Not asked yet**.
3. If it needs signing in, click the way you want to sign in. The buttons are the
   runtime's own, with its own advice under each.
   - Most runtimes then sign in by themselves, often by opening a page in your browser.
     Finish there. Codex offers **ChatGPT** first: your browser opens OpenAI's sign-in, and
     once you finish, Codex in Terminal is signed in too. **ChatGPT (device code)** shows a
     code to enter on OpenAI's page instead, and **API Key** uses an OpenAI API key.
     Antigravity offers a personal or a business Google account, and opens Google's
     sign-in in your browser.
   - Claude Code signs in in Terminal: run `claude`, type `/login`, and follow what it
     asks. Then open the sheet again; it says which account, such as **Claude Max**.
   - Some hand you a command to run instead, and the sheet says, for example, **Copilot
     signs in from a terminal. Run this:** with the command under it. Click **Open
     Terminal** (it also copies the command), paste it and follow what it asks. **Copy**
     only copies it. When it is done, click **I have done it**.
4. The sheet should now say **Signed in and ready**. Click **Done**.

   The runtime is ready for the next agent you start. An agent that stopped because it
   was not signed in can be prompted again.

**When a runtime turns you away**

You do not have to go looking for the sheet. When a runtime on this Mac refuses to start
an agent or take a prompt because it needs signing in, the sheet opens by itself instead
of an error. The same happens when nobody was waiting on it: a turn that is refused, a
prompt that was queued, or an agent picked up again after the app restarts. The
conversation says, for example, **Claude needs signing in: it is not signed in**, and the
agent's turn ends with **Its sign-in was refused**. The agent keeps its conversation, so
prompt it again once you have signed in.

If you close the sheet without signing in, it does not open by itself again for that
runtime until a turn on it works. Open it from the runtime menu when you are ready.

**Gemini: paste a key**

Gemini signs in with a Gemini API key, not from the sheet: Google's own sign-in no longer
works for individuals in Gemini CLI.

1. Get a key at aistudio.google.com/apikey. It starts `AIza` or `AQ.`.
2. In **Settings ▸ Agent Runtimes**, paste it into the field under Gemini and click **Save**. The
   app checks it with Google and says **Works** or **Refused**.

It is kept in this Mac's Keychain and handed to Gemini agents on this Mac and on servers.
A `GEMINI_API_KEY` already in your shell profile is used when Settings has none. Starting a
Gemini agent with neither says **Gemini needs an API key. Add one in Settings ▸ Agent Runtimes.**

**Choose who answers**

Some runtimes can use more than one model provider. For those, the sheet has **Who
answers**, listing them with a ✓ by the current one. Click another to switch. **Turn
off**, beside a provider the runtime does not need, stops it being offered.

**Sign out**

1. Open the same sheet and click **Sign out**. It is there only when the runtime is signed
   in and supports signing out from the app.
2. Confirm with **Sign out**. The dialog says first whether anything is running on it, for
   example **This stops 2 agents mid-conversation.**

iPhone and iPad cannot sign runtimes in: sign in on the Mac. Signing Claude or Codex in on
this Mac also signs them in on your Linux servers: their requests go through this Mac. For
any other runtime on a server, sign in on the server itself; see
[Add a Linux server](add-a-linux-server.md).

## If it doesn't work

- **The sheet still says it needs signing in after I have done it.** Close it and open it
  again; the app asks the runtime afresh each time. If it still says so, run the
  runtime's own sign-in in Terminal (for Claude Code, `claude`, then `/login`), then check
  again.
- **The runtime is not in the menu at all.** It is not installed, or not where the app
  looks. With no runtime at all, the project list says **No agent runtime found** and
  what each one needs.
