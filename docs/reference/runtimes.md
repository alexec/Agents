---
diataxis: reference
devices: [mac, server]
description: The coding agents the app can start, what it runs for each, and what each can do in the app.
---

# Runtimes

A runtime is the coding agent that does the work in a conversation. This page lists the
ones the app knows how to start. Most you install and sign in to yourself, and the app
finds them on your Mac, or on a server when the project is on a server. Codex, Gemini
and Antigravity are only ever the app's own copies: **Install** on their rows in **Settings ▸ Agent Runtimes** puts
them in place.

What a runtime can do in the app is decided by what it says about itself when it starts,
not by its name. The columns for pictures and signing in are what each runtime said when
it was last measured. If a newer version says something different, the app follows the
newer version.

| Runtime | Command it starts | Pictures | Sign in from the app | App tools available | Notes |
| --- | --- | --- | --- | --- | --- |
| **Claude** | `npx -y @agentclientprotocol/claude-agent-acp` | Yes | Partly. Sign in with Claude Code itself, in Terminal: run `claude` and type `/login`. The sheet then shows the account, such as **Claude Max**, and offers **Sign out** and **Who answers**. | All | `claude` has no mode the app can talk to, so the app runs this adapter through your Node instead. Its questions reach you as a card you can answer on the Mac or phone. It asks your permission before using some of the app's tools. Its subagents and background commands are shown over the prompt as they run. |
| **Grok** | `grok --permission-mode default agent stdio` | No | Yes, with **grok.com** | All | It cannot ask you a question mid-turn in a way the app can show, so it ends its turn with the question instead, and the agent shows **Waiting on your answer**. Its image and video generation is switched off for the conversations the app starts. It offers no permission mode under the prompt; set **Default** or **Auto-review** in **Settings ▸ Agent Runtimes**. Agents the app starts always ask under **Default**, even when Grok's own saved mode elsewhere would approve everything. |
| **Copilot** | `copilot --acp` | Yes | Hands you the exact command to run in Terminal, with **Open Terminal** and **Copy** | All | It takes no MCP server it would have to start itself, so the app runs those, its own tools included, and hands each to Copilot over a local http address only that agent can use. It uses its own follow-up suggestions instead of the app's. It asks permission before every tool call. |
| **Gemini** | the app's own `gemini --acp --skip-trust`, installed from **Settings ▸ Agent Runtimes** | Yes | No. Paste a Gemini API key under Gemini in **Settings ▸ Agent Runtimes** (get one at aistudio.google.com/apikey). | All | A `gemini` you installed yourself is never used: the app runs the version it was built against. Google's own sign-in no longer works for individuals, so a key is the way in; the same key is used on servers. The app's tools reach Gemini only in a folder it trusts, so the app trusts the agent's folder for that conversation only, which also loads that project's own Gemini hooks and settings. It cannot ask you a question mid-turn, so it ends its turn with the question and the agent shows **Waiting on your answer**. Its own subagents and task tracker are switched off. It reports tokens but no cost. On Google's free tier a spent daily quota ends the turn with Google's own sentence, and **Auto** in the model menu may pick a Pro model, which has the smallest free quota: choose a Flash model to go further. Picking a conversation back up may make Gemini record, once, that it signs in with an API key, in its own `~/.gemini/settings.json`. |
| **Cursor** | `cursor-agent acp` | Yes | Yes | All | The command is `cursor-agent`, not `agent`, which is Grok's. It offers no options to pick from and no way to sign out, so the app shows neither. Three of its own tools, which overlap with the app's, cannot be turned off. It asks your permission before using some of the app's tools. Its Agent, Plan and Ask stay under the prompt; permission mode is **Default** or **Auto-review** in **Settings ▸ Agent Runtimes**, not a capsule here. |
| **Codex** | The app's own copy of `@agentclientprotocol/codex-acp`, installed from the set-up page or **Settings ▸ Agent Runtimes** | Yes | Yes: **ChatGPT** first, then a ChatGPT device code or an OpenAI API key | All | Never a `codex` or `npx` of yours: the app runs the exact version it carries, and offers **Update** when a newer app carries a newer one. Signing in with ChatGPT is shared with Codex in Terminal. Its questions reach you as a card. Its three modes are **Ask for approval**, **Approve for me** and **Full access**. It shows how much of its context is used, with no cost. Its own sub-agents are on, and shown over the prompt as they run. |
| **Antigravity** | The app's own copy of Google's Antigravity ACP server (`agy_acp_server`, not the `agy` command), downloaded from Google by the set-up page or **Settings ▸ Agent Runtimes** | Yes | Yes, with a personal or business Google account, in your browser | All | The one Google runtime a Google account alone can sign in to; Gemini is for an API key, and the Gemini key is never lent to Antigravity. It keeps its settings, conversations and sign-in in a folder of the app's own, never in `~/.gemini`. It runs on this Mac only; servers are not supported yet. Its questions reach you as a card. Its own tool for starting subagents is switched off. |

In every column:

- **Pictures**: a picture you attach goes to the runtime as the picture itself where it
  takes pictures, and as a reference to the file where it does not. An attachment a
  runtime cannot take is refused before the prompt is sent.
- **Sign in from the app**: when a runtime needs signing in, the runtime menu above the
  prompt says **Needs signing in**, and **Sign in, sign out, providers…** opens the
  runtime's sign-in. The sheet says one of **Signed in and ready**, **Installed, and
  needs signing in** or **Not asked yet**.
- **App tools available**: the tools on [Tools the app gives agents](agent-tools.md).
- **On a server**: an agent in a server project is offered only the runtimes on that
  server. Claude, Codex and Gemini are the exceptions: Agents installs them on the server
  itself. Claude and Codex sign in there through this Mac's own sign-ins, and Gemini with
  the key in Settings. See
  [Add a Linux server](../how-to/add-a-linux-server.md).

## What the app shows from a runtime

Each of these is offered to every runtime, and shown for those that say they can do it.

| What | Where you see it | Runtimes that do it today |
| --- | --- | --- |
| **Send now**: a prompt sent into the running turn | On a prompt waiting its turn. See [Send a prompt while an agent is working](../how-to/send-while-an-agent-works.md). | Claude, Codex |
| Background shells and subagents | A list over the prompt, and the **Background** pane. See [Watch an agent's background work](../how-to/watch-background-work.md). | Claude, Codex |
| The plan | A checklist in the conversation, and a strip at the top of the chat on iPhone and iPad. Cursor's to-do list is shown as its plan, without the items it cancelled. | Runtimes that send a plan; Cursor through its to-do list |
| Questions as a card | Above the prompt. See [Answer a question or a permission request](../how-to/answer-a-question.md). | Claude, Codex, Cursor, Antigravity. Grok and Gemini end their turn with the question instead. |
| Which account is signed in | Under the runtime's name in the runtime menu, and in its sign-in sheet, such as **Claude Max**. | Runtimes that report it |
| Notices | A line in the conversation with a title and a detail: an error in red, a warning or information in grey. | Runtimes that send them |
| Providers you can turn off | **Turn off** beside a provider under **Who answers** in the sign-in sheet. | Runtimes with more than one provider |

## When an allowance runs out

With a pool set up, a chat whose runtime's allowance runs out carries on with the next runtime
in it (see [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)).
That needs the app to recognise the refusal, which it does per runtime:

| Runtime | Spent allowance | Rate limit | When it is back |
| --- | --- | --- | --- |
| **Claude** | Recognised: Claude says so in a form the app reads. Paid extra usage starting counts as spent. | Recognised, and tried again on the same runtime: after 30 seconds, then 2 minutes. Three in ten minutes counts as spent. | The time Claude's plan window gives. |
| **Codex** | Recognised, as for Claude, on this Mac and on a server that signs in through this Mac. | Recognised, as for Claude. | When Codex says; otherwise it is tried again after an hour. |
| **Gemini** | Recognised from Google's sentence about the daily quota. On free or prepaid credit, also when the app's count of what it cost reaches the amount, or the credit's date passes. | Recognised from Google's 429. | The free tier: midnight Pacific. Credit: when you mark it available or raise the amount. |
| **Antigravity** | Treated as a rate limit, since Google uses the same words for both: three in ten minutes counts as spent. | Recognised from "Resource has been exhausted". | Tried again after an hour. |
| **Copilot** | Recognised from "You have exceeded your monthly quota". | Not yet recognised. | Tried again after an hour when spent without a window. |
| **Grok** | Recognised from Grok's 402 "usage balance exhausted" (Build / SuperGrok). | Not yet recognised. | Tried again after an hour when spent without a window. |
| **Cursor** | **Not yet recognised.** A chat on it stops when its allowance runs out, as it always has. It can still be carried on to. | Not yet recognised. | — |

An error the app does not recognise never moves a chat: it stops, as before.

## What each gets from `~/.agents`

Your own skills, instructions, MCP servers and plugins in `~/.agents` reach each runtime the
way it can take them. See [Share skills, instructions and servers with every agent](../how-to/share-skills-across-agents.md).

| Runtime | Skills | Instructions | MCP servers from `mcp.json` | Plugins |
| --- | --- | --- | --- | --- |
| **Claude** | a link in `~/.claude/skills` | `~/.claude/CLAUDE.md`, a link | sent at start | handed at start |
| **Codex** | reads `~/.agents/skills` | `~/.codex/AGENTS.md`, a link | sent at start, except sse servers; its own server of the same name wins | added to Codex by the app, and again when the plugin changes |
| **Grok** | reads `~/.agents/skills` | `~/.grok/AGENTS.md`, a link | sent at start | handed at start, with its servers sent as MCP servers |
| **Cursor** | reads `~/.agents/skills` | none: User Rules are in Cursor's settings | sent at start; its own of the same name runs too | no way in |
| **Copilot** | reads `~/.agents/skills` | `~/.copilot/copilot-instructions.md`, a link | through the app's local bridge for servers it would start; its own of the same name wins | no way in over the app |
| **Gemini** | reads `~/.agents/skills` | `~/.gemini/AGENTS.md`, a link, beside its own `GEMINI.md` | sent at start | a link in `~/.gemini/extensions`; a project's plugins are switched on only in that project |
| **Antigravity** | a link in the folder the app gives it | none | sent at start | no way in |

For the conversations the app starts, each runtime's own tools for scheduling, starting
other agents, sending notifications and saving documents elsewhere are taken away, so that
the work stays where the app can see it. Reading, searching, editing, running commands,
planning and asking you questions are not touched. The same runtime started from Terminal
has everything it always had.

## See also

- [Sign a runtime in](../how-to/sign-a-runtime-in.md)
- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)
- [Why agents' own tools are taken away](../explanation/scoped-tools.md)
- [Tools the app gives agents](agent-tools.md)
- [Why chats carry on when a plan runs out](../explanation/runtime-pool.md)
