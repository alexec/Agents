---
diataxis: reference
devices: [mac, server]
description: The coding agents the app can start, what it runs for each, and what each can do in the app.
---

# Runtimes

A runtime is the coding agent that does the work in a conversation. This page lists the
ones the app knows how to start. Most you install and sign in to yourself, and the app
finds them on your Mac, or on a server when the folder is on a server. Codex, Gemini,
Antigravity and OpenCode are only ever the app's own copies: **Install** on their rows in **Settings ▸ Agent Runtimes** puts
them in place.

What a runtime can do in the app is decided by what it says about itself when it starts,
not by its name. The columns for pictures and signing in are what each runtime said when
it was last measured. If a newer version says something different, the app follows the
newer version.

| Runtime | Command it starts | Pictures | Sign in from the app | App tools available | Notes |
| --- | --- | --- | --- | --- | --- |
| **Claude** | `npx -y @agentclientprotocol/claude-agent-acp` | Yes | Partly. Sign in with Claude Code itself, in Terminal: run `claude` and type `/login`. The sheet then shows the account, such as **Claude Max**, and offers **Sign out** and **Who answers**. | All | `claude` has no mode the app can talk to, so the app runs this adapter through your Node instead. Its questions reach you as a card you can answer on the Mac or phone. It asks your permission before using some of the app's tools. Its subagents and background commands are shown over the prompt as they run. |
| **Grok** | `grok --permission-mode default agent stdio` | No | Yes, with **grok.com** | All | It cannot ask you a question mid-turn in a way the app can show, so it ends its turn with the question instead, and the agent shows **Waiting on your answer**. Its image and video generation is switched off for the conversations the app starts. Under the prompt, set **Default** or **Always-approve**. Agents the app starts follow this Mac-wide choice, even when Grok's own saved mode elsewhere would approve everything. |
| **Copilot** | `copilot --acp` | Yes | Hands you the exact command to run in Terminal, with **Open Terminal** and **Copy** | All | It takes no MCP server it would have to start itself, so the app runs those and hands each to Copilot over a local http address only that agent can use. It uses its own follow-up suggestions instead of the app's. It asks permission before every tool call. |
| **Gemini** | the app's own `gemini --acp --skip-trust`, installed from **Settings ▸ Agent Runtimes** | Yes | No. Paste a Gemini API key under Gemini in **Settings ▸ Agent Runtimes** (get one at aistudio.google.com/apikey). | All | A `gemini` you installed yourself is never used: the app runs the version it was built against. Google's own sign-in no longer works for individuals, so a key is the way in; the same key is used on servers. The app's tools reach Gemini only in a folder it trusts, so the app trusts the agent's folder for that conversation only, which also loads that folder's own Gemini hooks and settings. It cannot ask you a question mid-turn, so it ends its turn with the question and the agent shows **Waiting on your answer**. Its own subagents and task tracker stay. It reports tokens but no cost. On Google's free tier a spent daily quota ends the turn with Google's own sentence, and **Auto** in the model menu may pick a Pro model, which has the smallest free quota: choose a Flash model to go further. Picking a conversation back up may make Gemini record, once, that it signs in with an API key, in its own `~/.gemini/settings.json`. |
| **Cursor** | `cursor-agent acp` | Yes | Yes | All | The command is `cursor-agent`, not `agent`, which is Grok's. It offers no options to pick from and no way to sign out, so the app shows neither. Three of its own tools, which overlap with the app's, cannot be turned off. It asks your permission before using some of the app's tools. Its Agent, Plan and Ask stay under the prompt beside a separate, Mac-wide permission capsule: **Default** or **Always-approve**. |
| **Codex** | The app's own copy of `@agentclientprotocol/codex-acp`, installed from the set-up page or **Settings ▸ Agent Runtimes** | Yes | Yes: **ChatGPT** first, then a ChatGPT device code or an OpenAI API key | All | Never a `codex` or `npx` of yours: the app runs the exact version it carries, and offers **Update** when a newer app carries a newer one. Signing in with ChatGPT is shared with Codex in Terminal. Its questions reach you as a card. Its three modes are **Ask for approval**, **Approve for me** and **Full access**. It shows how much of its context is used, with no cost. Its own sub-agents and goals are on, and its sub-agents are shown over the prompt as they run. |
| **Antigravity** | The app's own copy of Google's Antigravity ACP server (`agy_acp_server`, not the `agy` command), downloaded from Google by the set-up page or **Settings ▸ Agent Runtimes** | Yes | Yes, with a personal or business Google account, in your browser | All | The one Google runtime a Google account alone can sign in to; Gemini is for an API key, and the Gemini key is never lent to Antigravity. It keeps its settings, conversations and sign-in in a folder of the app's own, never in `~/.gemini`. It runs on this Mac only; servers are not supported yet. Its questions reach you as a card. Its own tool for starting subagents stays. |
| **OpenCode** | The app's own copy of OpenCode (`opencode acp`), downloaded from its GitHub releases by the set-up page or **Settings ▸ Agent Runtimes** | Yes | Hands you the command to run in Terminal, the app's own copy by its full path, with **Open Terminal** and **Copy**. It adds one provider at a time, so the sheet keeps offering it when ready, and names `opencode auth logout` for taking one away. | All | Never an `opencode` of yours: two different programs go by that name, and the app runs the version it carries. It works signed out, on OpenCode Zen's free models. It asks your permission before editing files, running commands and fetching web pages; set **Default** or **Always-approve** in the permission capsule under the prompt. The choice applies to every OpenCode agent this Mac starts. Its questions reach you as a card. Sharing and self-update are off, and its own tool for starting subagents stays. A picked model whose provider is not signed in is dropped at the next start, with a note saying so. On a server it borrows this Mac's provider keys for each run. |

In every column:

- **Pictures**: a picture you attach goes to the runtime as the picture itself where it
  takes pictures, and as a reference to the file where it does not. An attachment a
  runtime cannot take is refused before the prompt is sent.
- **Sign in from the app**: when a runtime needs signing in, the runtime menu above the
  prompt says **Needs signing in**, and **Sign in, sign out, providers…** opens the
  runtime's sign-in. The sheet says one of **Signed in and ready**, **Installed, and
  needs signing in** or **Not asked yet**.
- **App tools available**: the tools on [Tools the app gives agents](agent-tools.md).
- **On a server**: an agent in a server folder is offered only the runtimes on that
  server. Claude, Codex, Gemini and OpenCode are the exceptions: Agents installs them on the
  server itself. Claude and Codex sign in there through this Mac's own sign-ins, Gemini with
  the key in Settings, and OpenCode borrows the provider keys it is signed in with on this Mac,
  for each run. See
  [Add a machine](../how-to/add-a-machine.md).

## What the app shows from a runtime

Each of these is offered to every runtime, and shown for those that say they can do it.

| What | Where you see it | Runtimes that do it today |
| --- | --- | --- |
| **Send now**: a prompt sent into the running turn | On a prompt waiting its turn. See [Send a prompt while an agent is working](../how-to/send-while-an-agent-works.md). | Claude, Codex |
| Background shells and subagents | A list over the prompt, and the **Background** pane. See [Watch an agent's background work](../how-to/watch-background-work.md). | Claude, Codex |
| The plan | A checklist in the conversation, and a strip at the top of the chat on iPhone and iPad. Cursor's to-do list is shown as its plan, without the items it cancelled. | Runtimes that send a plan; Cursor through its to-do list |
| Questions as a card | Above the prompt. See [Answer a question or a permission request](../how-to/answer-a-question.md). | Claude, Codex, Cursor, Antigravity, OpenCode. Grok and Gemini end their turn with the question instead. |
| Which account is signed in | Under the runtime's name in the runtime menu, and in its sign-in sheet, such as **Claude Max**. | Runtimes that report it |
| Notices | A line in the conversation with a title and a detail: an error in red, a warning or information in grey. | Runtimes that send them |
| Providers you can turn off | **Turn off** beside a provider under **Who answers** in the sign-in sheet. | Runtimes with more than one provider |

## When an allowance runs out

A chat whose runtime's allowance runs out stops there, with a note saying so, and the runtime
is marked out for every chat to see on the **Runtimes** page, under Activity. Nothing carries the chat
on: to go on, start a new chat on another runtime and ask it to continue this one (see
[Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)). A
runtime that is out can still be sent a message; if that turn works, it is back.

Where you pick a runtime, the ones that cannot take a turn are named as such rather than
listed as if they could: the chooser above the prompt on the Mac, and the **Runtime** row
of the new-session sheet on iPhone and iPad, each draw them in two runs, **Available** and
**Out**, with the reason under the name. An out runtime stays pickable in both, because
that is the only way back to it once its plan returns. A runtime that is merely rate
limited is not out — it can still take a turn — but the chooser says so, rather than
leaving you to find out from it.

The app recognises the refusal per runtime:

| Runtime | Spent allowance | Rate limit | When it is back |
| --- | --- | --- | --- |
| **Claude** | Recognised: Claude says so in a form the app reads. Paid extra usage starting counts as spent. | Recognised, and tried again on the same chat: after 30 seconds, then 2 minutes. Three in ten minutes on one chat counts as spent. | Checked every four hours; its plan window is shown when known. |
| **Codex** | Recognised, as for Claude, on this Mac and on a server that signs in through this Mac. | Recognised, as for Claude. | Checked every four hours; its plan window is shown when known. |
| **Gemini** | Recognised from Google's sentence about the daily quota, and from Google saying the key's credit is used up. | Recognised from Google's 429. | Checked every four hours; the free tier's daily reset is shown. |
| **Antigravity** | Treated as a rate limit, since Google uses the same words for both: three in ten minutes counts as spent. | Recognised from "Resource has been exhausted". | Checked every four hours. |
| **Copilot** | Recognised from "You have exceeded your monthly quota". | Not yet recognised. | Checked every four hours. |
| **Grok** | Recognised from Grok's 402 "usage balance exhausted" (Build / SuperGrok). | Not yet recognised. | Checked every four hours; what is left of its plan is shown. |
| **Cursor** | Recognised from "Upgrade your plan to continue". | Not yet recognised. | Checked every four hours. |
| **OpenCode** | Not yet recognised: the turn stops, and the runtime is marked out, as for any error. | Not yet recognised. | Checked every four hours. |

A crash or an error the app does not recognise also marks the runtime out, and stops that
turn. Each check asks for a short reply on a small model in a read-only mode where the runtime
offers one. A reply puts the runtime back, even if the provider's stated reset time has not
arrived; a failed check leaves it out and schedules another four hours later. The stated reset
time alone never brings it back. **Mark available** does, at once.

## More than one account

Claude and Codex can have more than one account (#840), for example a personal plan and a
work plan. The sign-in a runtime has already is its own, **Your Own Sign-In**. Each account you add
is a folder of its own, which the app gives the runtime in the variable that names where it
keeps its sign-in:

| Runtime | More than one account | The variable | Why or why not |
| --- | --- | --- | --- |
| **Claude** | Yes | `CLAUDE_CONFIG_DIR` | The folder holds the sign-in. On macOS, Claude keeps a Keychain item for each folder. |
| **Codex** | Yes | `CODEX_HOME` | The folder holds `auth.json`. |
| **Cursor** | Not yet | `CURSOR_CONFIG_DIR` | The folder holds the sign-in too, but a second sign-in in it is not measured yet. |
| **Copilot** | No | | It keeps its own sign-ins and changes user itself (`/user`). |
| **Gemini** | No | | Its account is an API key. A second key is an organisation key (#999). |
| **OpenCode** | No | | One `auth.json` already holds a sign-in for each provider. |
| **Grok** | No | | No variable moves its sign-in alone. |
| **Antigravity** | No | | Its home is the app's own already. |

- **Add one** with **Add Account…** on the **Runtimes** page, on all three, or in the
  runtime's sign-in sheet on the Mac (the runtime menu above the prompt, **Sign in, sign out,
  providers…**). Only a runtime on this Mac takes one: no client can sign in a server's
  account (#2257). The folder is `runtimes/accounts/<runtime>/<id>` under the app's
  root. The app links your own settings into it (Claude's `settings.json`, `CLAUDE.md`,
  skills, agents, commands and plugins; Codex's `config.toml`, `AGENTS.md`, prompts and
  skills), so only the sign-in is separate.
- **Sign it in** on the Mac: **Sign In…** on its row of the **Runtimes** page opens the
  runtime's sign-in sheet (#2255). For Claude, **Sign In** gives the command
  `CLAUDE_CONFIG_DIR=<folder> claude`: run it, then type `/login`. Codex signs in as its
  own sign-in does.
- **Choose it** when you start a session: the **Account** menu is beside the runtime menu,
  on all three, when the runtime has more than one account. Under each choice is why it
  cannot be used or that its allowance is out (#2265). A branch, **Continue in New** and
  a helper the session starts keep its account. A started session's runtime, over its
  prompt, names the account, such as **Claude · Work**, on all three (#2259). A session on
  the runtime's own sign-in shows the runtime's name only.
- **Its allowance is its own.** The **Runtimes** page shows a row for each account, under
  its runtime ("Claude · Work"). One account running out does not put the runtime, or
  another account, out. The app never changes a session to another account by itself.
- **Remove it** to stop the sessions that use it, sign it out where the runtime can, and
  delete its folder. Every client asks first, and says how many sessions it stops and that
  this cannot be undone (#2264).

### Org keys and gateways

An organisation's **org route** (#999) is one more account of each runtime it serves: an
org key, or a gateway (Amazon Bedrock, Google Vertex AI, Microsoft Azure, or a base URL such
as LiteLLM). Its id is `org:<route id>`, and it says **From your organisation**. The admin
adds it in Console ▸ Model Access; the machine gets it sealed to its own key and keeps it in
`org-routes/<id>.json` under the app's root. You cannot remove it; the organisation can. See
[org keys and gateways](../explanation/org-keys-and-gateways.md).

- **The runtime never gets the key.** The machine runs a **model relay** on loopback (TLS,
  with a CA of its own in `runtimes/model-relay-ca.pem`). The runtime gets the relay's
  address and a **stand-in**, a token that works only on that relay and only for its route.
  The relay puts in the real key, sends the request on, and streams the answer back.
- **First, everything of your own is taken out.** Your `ANTHROPIC_*`, `OPENAI_*`,
  `GEMINI_*`, `GOOGLE_*`, `AWS_*`, `CLAUDE_CODE_USE_*` and the like, from your login
  environment and your pass-through list, do not reach a session on an org account.
- **Reaches the Model By** is each runtime's default account for new sessions
  (`runtimes/setDefaultAccount`, kept on the machine in `default-accounts.json`). Without a
  choice of yours, it is the route the organisation made the default, then the runtime's
  own sign-in. A helper or workflow that names no account takes it, and says so. Set it in
  the runtime's sign-in sheet on the Mac, and under the runtime's row on the **Runtimes**
  page on iPhone, iPad and the web. The **Account** menu of a new session opens on it.
- **The organisation can require the org path** (policy `runtimes.<id>.reach`). Your own
  sign-in and added accounts are then refused: each client shows them dimmed, with **Set by
  your organisation**.
- **Continue in New.** A session whose account the organisation removed, or no longer
  allows, shows why over its chat, with **Continue in New** (`agents/continueInNew`). It
  starts a session in the same folder, on the runtime's account for new sessions, that reads
  the old session and carries on. The old session is kept.
- **Its allowance has no plan.** An org account's row on the **Runtimes** page says
  **Organisation · No plan limit** and its tokens today, as the relay counted them. After a
  rate-limit answer it says "Out until 14:05". A cost on an org account is the runtime's own
  figure, so it says "list price, as Claude reports it".
- **Tokens are the provider's count.** The relay reads the usage in each answer and keeps
  it beside what the runtime says (`relayTokens`); a limit counts it. A rate-limit answer
  puts only that account out, until its `Retry-After`, or for 5 minutes.

What each runtime is given, measured on 2026-10-22 against each CLI with a fake provider
(`<relay>` is `https://127.0.0.1:<port>/<route id>`):

| Runtime | Kind | What the machine sets |
| --- | --- | --- |
| **Claude** | Org key, base URL | `ANTHROPIC_BASE_URL=<relay>`, `ANTHROPIC_AUTH_TOKEN=<stand-in>` |
| **Claude** | Bedrock | `CLAUDE_CODE_USE_BEDROCK=1`, `ANTHROPIC_BEDROCK_BASE_URL=<relay>/~<stand-in>`, `CLAUDE_CODE_SKIP_BEDROCK_AUTH=1`, `AWS_REGION` |
| **Claude** | Vertex | `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_BASE_URL=<relay>/~<stand-in>`, `CLAUDE_CODE_SKIP_VERTEX_AUTH=1`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION` |
| **Claude** | Azure (Foundry) | `CLAUDE_CODE_USE_FOUNDRY=1`, `ANTHROPIC_FOUNDRY_BASE_URL=<relay>/~<stand-in>`, `CLAUDE_CODE_SKIP_FOUNDRY_AUTH=1` |
| **Codex** | Org key, Azure, base URL | `CODEX_HOME` of the route's own, whose `config.toml` has a model provider with `base_url = "<relay>/v1"` and `env_key = "AGENTS_ORG_STAND_IN"` |
| **Gemini** | Org key, base URL | `GEMINI_API_KEY=<stand-in>`, `GOOGLE_GEMINI_BASE_URL=<relay>`, and `GEMINI_CLI_HOME` of the route's own, which chooses the API key |
| **Gemini** | Vertex | `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_VERTEX_BASE_URL=<relay>`, `GOOGLE_API_KEY=<stand-in>`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` |
| **OpenCode** | Org key, Azure, base URL (Anthropic or OpenAI API) | `OPENCODE_CONFIG` of the route's own, with one provider whose `baseURL` is `<relay>/v1` and whose `apiKey` is `{env:AGENTS_ORG_STAND_IN}` |

Claude on Bedrock, Vertex and Foundry is told to skip its own auth, so the stand-in is in
the path. Every runtime that trusts Node's CAs gets `NODE_EXTRA_CA_CERTS`; Codex gets
`CODEX_CA_CERTIFICATE`. **Not built:** OpenCode on Bedrock and Vertex (its cloud SDKs sign
their own requests); Grok (no base URL to measure); Copilot, Cursor and Antigravity (sign-in
only).

## What each gets from `~/.agents`

Your own skills, instructions, connectors and plugins in `~/.agents` reach each runtime the
way it can take them. See [Share skills, instructions and connectors with every agent](../how-to/share-skills-across-agents.md).

| Runtime | Skills | Instructions | Connectors from `mcp.json` | Plugins |
| --- | --- | --- | --- | --- |
| **Claude** | a link in `~/.claude/skills` | `~/.claude/CLAUDE.md`, a link | sent at start | handed at start |
| **Codex** | reads `~/.agents/skills` | `~/.codex/AGENTS.md`, a link | sent at start, except sse servers; its own server of the same name wins | added to Codex by the app, and again when the plugin changes |
| **Grok** | reads `~/.agents/skills` | `~/.grok/AGENTS.md`, a link | sent at start | handed at start, with its servers sent as MCP servers |
| **Cursor** | reads `~/.agents/skills` | none: User Rules are in Cursor's settings | sent at start; its own of the same name runs too | no way in |
| **Copilot** | reads `~/.agents/skills` | `~/.copilot/copilot-instructions.md`, a link | through the app's local bridge for servers it would start; its own of the same name wins | no way in over the app |
| **Gemini** | reads `~/.agents/skills` | `~/.gemini/AGENTS.md`, a link, beside its own `GEMINI.md` | sent at start | a link in `~/.gemini/extensions`; a folder's plugins are switched on only in that folder |
| **Antigravity** | a link in the folder the app gives it | none | sent at start | no way in |
| **OpenCode** | reads `~/.agents/skills` | follows `~/.claude/CLAUDE.md`, the link above, unless you keep your own `~/.config/opencode/AGENTS.md` | sent at start | no way in: its plugins are its own npm packages |

For Codex sessions that the app starts, the brief goes in Codex ACP's
`_meta.jetbrains.air.customInstructions` session metadata. Codex ACP passes these words to
Codex as developer instructions. This keeps the person's first prompt free of the brief,
including when the app loads or resumes the session.

For the conversations the app starts, each runtime's own tools for scheduling, starting
other agents, sending notifications and saving documents elsewhere are taken away, so that
the work stays where the app can see it. Reading, searching, editing, running commands,
planning and asking you questions are not touched. The same runtime started from Terminal
has everything it always had.

## Options beyond model and mode

Every option a runtime offers in a conversation, such as Claude's effort or Codex's fast
mode, is shown under the prompt for each agent, whatever the runtime calls it. A runtime has
many more options than it offers there, in four places:

- **ACP option or `_meta`**: sent by the app when a conversation starts or picks back up.
  Works on a server exactly as on the Mac.
- **Flag**: on the command the app starts. Works on a server too.
- **Environment**: a variable the runtime reads. Works on a server too when the app sets it.
- **File**: the runtime's own settings file, such as `~/.claude/settings.json`. The app never
  edits these. The Mac's files stay on the Mac: on a server, the server's own files apply.

Measured on 2026-09-29 against Claude Code 2.1.280 (adapter 0.81.2), Codex 0.156.1 (adapter
1.13.1), Gemini CLI 0.61.0, Antigravity server 1.2.1, OpenCode 1.18.33, Grok 1.0.44, Copilot
1.0.89-5 and Cursor 2026.09.26, from each one's own code, help and documentation, and from a
handshake in an empty home. `scripts/acp-handshake.sh` names any option or `_meta` key a
newer version starts offering.

### Use Chrome (Claude)

Claude's options under the prompt also have **Use Chrome**, which the app adds. On, Claude
starts with `--chrome`: it can drive your own Chrome, signed in as you, through the
[Claude in Chrome](https://code.claude.com/docs/en/chrome) extension. That gives the agent
your sign-ins, so it is off unless you turn it on, for one chat at a time. A workflow turns it
on with `options: chrome: true`.

It takes effect from the chat's next turn: a chat between turns starts Claude again, and
carries on its conversation. Chrome needs the extension, and Claude Code's native messaging
host, which `claude` installs the first time you run `/chrome` in it. When the host is not
there, the Runtimes page says so under Claude: "Use Chrome needs Claude Code's native host in
Chrome. Run `claude`, then `/chrome`." The host looks in Chrome's `NativeMessagingHosts`
folder (`~/Library/Application Support/Google/Chrome/` on a Mac, `~/.config/google-chrome/`
on Linux).

### What the app sets for you

| Runtime | What | How | Why |
| --- | --- | --- | --- |
| **Claude** | Scheduling, workflow, notification, worktree and two document tools taken away | `_meta.claudeCode.options.disallowedTools` | The work stays where the app can see it. |
| | Your plugins from `~/.agents` | `_meta.claudeCode.options.plugins` | Shared plugins reach every agent. |
| | Every `CLAUDE_*` variable removed from its environment | Environment | A runtime the app starts must not think it is another Claude session's child. This also drops a `CLAUDE_CONFIG_DIR` of yours. |
| | On a server: this Mac's sign-in, through a relay | Environment | One sign-in, on the Mac. |
| **Codex** | Sleep, automations, memories and ChatGPT apps off; its sub-agents and goals on; its question tool outside plan mode | `CODEX_CONFIG` | The work stays where the app can see it; questions reach you as a card. |
| | On a server: this Mac's ChatGPT sign-in, through a relay | `CODEX_HOME` of the app's own | One sign-in, on the Mac. It also means the server's own `~/.codex/config.toml` is not read. |
| **Gemini** | The agent's folder trusted for this run | `--skip-trust` | The app's tools start only in a trusted folder. Nothing is written to Gemini's list of trusted folders. |
| | Nothing denied, so no `--policy` file is sent | `--policy`, when there is a rule in it | It has its own subagents and task tracker. The file is only ever for rules the app has, and there are none today. |
| | `AGENTS.md` read beside `GEMINI.md` | `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` | Shared instructions reach Gemini. Your own `context.fileName` wins. |
| | Your key from Settings | `GEMINI_API_KEY` | The only way in for individuals. |
| **Antigravity** | A home of the app's own, never `~/.gemini` | `GEMINI_HOME` | Its settings, conversations and sign-in stay apart from Gemini's. |
| | The agent's folder trusted | `AGY_ACP_DISABLE_WORKSPACE_TRUST` | As Gemini's. It also means a folder's `.agents/hooks.json` runs without Antigravity asking first. |
| | Its sign-in in a file, not the Keychain | `AGY_ACP_FORCE_FILE_STORAGE` | So it can be copied to a server without a Keychain prompt. |
| | No deny list sent | `_meta.agy.disabledTools`, while there is something in it | There is nothing to deny; the list is only ever for tools the app has a reason to take away. |
| | Keys in the environment ignored | `GEMINI_API_KEY`, `GOOGLE_API_KEY` removed | It signs in with a Google account only. |
| **OpenCode** | Asks before editing, running commands and fetching pages; sharing and self-update off | `OPENCODE_CONFIG_CONTENT`, `OPENCODE_DISABLE_SHARE`, `OPENCODE_DISABLE_AUTOUPDATE` | Left alone, it does all three without asking; no conversation is published; the app's copy is never replaced under a running agent. |
| | A temporary folder of its own | `TMPDIR` | It walks that folder at every turn: 40 seconds before the first word with the Mac's own. |
| | Its question tool off | `OPENCODE_ENABLE_QUESTION_TOOL` removed | Questions go through the app's `ask_question`. |
| **Grok** | Asks, whatever you saved in its own config | `--permission-mode default` | The app's **Default** or **Always-approve** in the prompt permission capsule decides. |
| | Its scheduler, workflow, monitor and feedback tools off; its subagents and question tool stay; the app's rules | `_meta.agentProfile.disallowedTools`, `_meta.rules` | Its `--disallowed-tools` does nothing here, so the list is in a profile of the app's. It was an allowlist until Grok 1.0.52 stopped giving the subagent tools it named (#1447). |
| | Image and video generation off | `GROK_CONFIG_PATH`, a file of the app's | Its config file is the only place for them, and yours is yours. |
| **Copilot** | Its session-store tool, your `software-factory` server and its built-in MCP servers off | `--excluded-tools`, `--disable-mcp-server`, `--disable-builtin-mcps` | The work stays where the app can see it. |
| **Cursor** | Nothing | | It has no lever: its config folder also holds its sign-in. |

### Every option, by runtime

Each table lists what a person might want to change; the long tail of each runtime (proxy,
debug, provider and terminal-only settings) is grouped into one row. In the last column,
**Show** means the app offers it, **Set** means the app chooses the value for you, and
**Leave alone** means the runtime's own default, or your own settings file, decides. Decided
on 2026-09-29; what is not built yet says **planned**. Sandbox options are decided with the
**Command sandbox** setting; see [Command sandbox](#command-sandbox) below.

#### Claude

The adapter passes anything in `_meta.claudeCode.options` to Claude Code, including
`settings`, which sits above your own settings files for that conversation only. So any
setting below can be set by the app for one agent without touching `~/.claude`.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Effort | ACP `effort`; `effortLevel` in settings | default, low, medium, high, xhigh, max | Yes, under the prompt | Yes | Already shown |
| Fast mode | ACP `fast`; `fastMode` | off | Yes, under the prompt; needs extra usage | Yes | Already shown |
| Thinking on, off or budget | `alwaysThinkingEnabled`; `MAX_THINKING_TOKENS` | on, adaptive | Yes | Yes | Leave alone: effort covers it |
| Fallback model | `fallbackModel` | none | Yes | Yes | Leave alone: overlaps the app's own fallback |
| Cost and turn limits | `_meta…options.maxBudgetUsd`, `maxTurns` | none | Yes | Yes | Set, planned: an agent's cost ceiling, stopped by Claude itself |
| Web search and fetch | tools `WebSearch`, `WebFetch` | on, asks | Yes | Yes | Show, planned: the web access switch |
| Memory | `autoMemoryEnabled` | on | Yes | Yes, when the app sets it | Show, planned: the memory switch, on by default |
| Transcript retention | `cleanupPeriodDays` | 30 days | Yes: old transcripts deleted at start | Yes, when the app sets it | Set, planned: long enough that an idle agent can still be picked back up |
| Commit and PR attribution | `attribution.commit`, `attribution.pr` | on | Yes | Server's own | Leave alone: yours to set in its settings |
| Usage data | `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | sent | Yes; a `CLAUDE_CODE_*` of your shell is removed | Yes | Show, planned: the usage data switch |
| Custom config folder | `CLAUDE_CONFIG_DIR` | `~/.claude` | Removed with every `CLAUDE_*` | — | Set, planned: let it through, so your own folder is used |
| Keep credentials out of commands | `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | off | Yes | Yes | Set on servers, planned: the relay's stand-in token stays out of shell commands |
| Checkpoints | `fileCheckpointingEnabled` | on only when the client reports file changes; the app does not | Off | Off | Leave alone |
| Compaction | `autoCompactEnabled`, `autoCompactWindow` | on, about 83% of a 200K window | Yes: `compaction_update` with its summary; `/compact` offered | Yes, through `_meta` | Leave alone: on with nothing set; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Output style, language, system prompt, hooks, MCP loading, subagents | settings, environment | its defaults | Yes | Server's own | Leave alone |
| Command sandbox | `_meta…options.sandbox.enabled` | off, unless your settings | Yes: On and Off measured | Yes; On needs bubblewrap and socat there | Show: **Command sandbox** |
| Updates, status line, notifications, theme and other terminal settings | settings | — | No: pinned version, no terminal | — | Leave alone |

#### Codex

The adapter merges `CODEX_CONFIG` into every conversation, above your `~/.codex/config.toml`,
so it reaches servers too. It sends approval, sandbox, effort, model and fast mode again on
every turn, so those in your config file only choose the first value, or nothing.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Reasoning effort | ACP `reasoning_effort`; `model_reasoning_effort` | low … max (medium) | Yes, under the prompt | Yes | Already shown |
| Fast mode | ACP `fast-mode`; `service_tier` | off | Yes, under the prompt | Yes | Already shown |
| Plan | ACP `collaboration_mode` | default, plan | Yes, under the prompt | Yes | Already shown |
| Approval policy | `approval_policy`, `approvals_reviewer` | from the mode | No: the mode decides every turn | — | Leave alone |
| Web search | `web_search` | cached; live under **Full access** | Yes | Only through `CODEX_CONFIG` | Show, planned: the web access switch |
| Usage data | `analytics.enabled`, `feedback.enabled` | on | Yes | Only through `CODEX_CONFIG` | Show, planned: the usage data switch |
| Memories | `features.memories` | off | Yes | Yes | Leave alone: Codex's own setting decides |
| Browser, computer use, image generation | `features.browser_use`, `computer_use`, `image_generation` | on | Not yet measured | — | Measure: they may be tools that duplicate the app's |
| Reasoning summaries | `model_reasoning_summary` | auto | No: the adapter chooses | — | Leave alone |
| Folder trust | `folders.<path>.trust_level` | asks | The adapter trusts every agent's folder, so a folder's own Codex config and hooks load | Yes | Leave alone |
| Compaction | `model_auto_compact_token_limit`, `compact_prompt` | on, 90% of the window, no off switch | Yes: `compaction_update`, no summary; `/compact` offered | Through `CODEX_CONFIG` | Leave alone: on with nothing set; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Verbosity, subagent limits, profiles, instructions, MCP, hooks | config file | its defaults | Yes | Not read on a relayed server | Leave alone |
| Sandbox and network | `sandbox_mode`, `sandbox_workspace_write.network_access` | from the mode: network off except **Full access** | The mode decides; measured | Yes; On needs user namespaces there | Show: **Command sandbox**, Off is **Full access** |
| Updates, notifications and terminal settings | config file | — | No | — | Leave alone |

#### Gemini

Gemini offers no options under the prompt beyond model and mode, and reads no `_meta` when a
conversation starts. Its settings come from files only: the app's own system defaults file
is the lowest of them, so yours always win over it.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Thinking level | `modelConfigs` in settings | high | Yes | Through the app's defaults file | Leave alone: no flag, and a file per agent to vary it |
| Web search and fetch | tools `google_web_search`, `web_fetch` | on | Yes | Its own settings | Show, planned: the web access switch |
| Usage statistics | `privacy.usageStatisticsEnabled` | on | Yes | Through the app's defaults file | Show, planned: the usage data switch; your own file still wins |
| Session retention | `general.sessionRetention` | 30 days, deleted at every start | Yes | Through the app's defaults file | Set, planned: long enough that an idle agent can still be picked back up |
| Subagents, task tracker | `invoke_agent`, `tracker_*` | on | Yes | Yes | Leave alone |
| Folder trust | `--skip-trust` | asks | Yes: loads the folder's own hooks and settings | Yes | Set today |
| Compression | `model.compressionThreshold` | on, at 0.5 of the window | Yes, but nothing is sent over ACP and `/compress` is not offered | Through the app's defaults file | Leave alone: on with nothing set; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Turn limit, loop detection, tool output, shell | settings | its defaults | Yes | Server's own | Leave alone |
| Checkpoints | `general.checkpointing.enabled` | off | No: only its terminal writes them | — | Leave alone |
| MCP, hooks, extensions, skills, `.env` files | settings | loaded | Yes | Server's own | Leave alone. A folder `.env` can set Gemini's variables. |
| Telemetry to your own collector | `telemetry.*`, `GEMINI_TELEMETRY_*` | off | Yes | Yes | Leave alone |
| Sandbox | `GEMINI_SANDBOX`, above `--sandbox` and `tools.sandbox` | off | Off works; with it on, Gemini never answers the app | On needs Docker or Podman there | Show: **Command sandbox**, Off only |
| Updates, output format, theme and other terminal settings | settings, flags | — | No | — | Leave alone |

#### Antigravity

Its one settings file holds only its sign-in choice and a Google Cloud project. Everything
else is an option under the prompt, the tool list the app sends, or its environment.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Thinking level | part of the model, such as `gemini-3.8-flash-high` | high | Yes, under the prompt | Mac only today | Already shown |
| Web search and fetch | tools `search_web`, `read_url_content` | on, asks | Yes | Mac only today | Show, planned: the web access switch |
| Image generation | tool `generate_image` | on | Yes | Mac only today | Leave alone |
| Subagents | tool `start_subagent` | on | Yes | Mac only today | Leave alone |
| Starting model | `AGY_ACP_DEFAULT_MODEL` | flash, high | Yes | — | Leave alone: the model is under the prompt |
| Folder hooks | `.agents/hooks.json` in the folder | asks, unless the folder is trusted | Run without asking, because the app trusts the folder | — | Set, planned: stop trusting, so it asks, once its question is measured to reach you as a card |
| MCP, skills, rules | its home, the folder | — | Yes | — | Leave alone |
| Compaction | none the ACP server reads | on, at its backend's threshold | Yes, but nothing is sent over ACP | Mac only today | Nothing to set; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Usage data, checkpoints, updates | none | — | — | — | Nothing to set |
| Sandbox | the admin's **Sandbox mode**, business accounts only | off | No lever | — | Leave alone: **No sandbox** |

#### OpenCode

The app passes its settings in `OPENCODE_CONFIG_CONTENT`, above your own `opencode.json`,
which reaches servers too. Settings your Mac's administrator manages win over both.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Effort | ACP `effort`, for models with variants | the model's variants | Yes, under the prompt, when the model has them | Yes | Already shown when offered |
| Permissions | `permission.*` | allow everything | Yes | Yes | Set today for edits, commands and fetches |
| Web search | tool `websearch`, `permission.websearch` | on, without asking, through Exa or Parallel | Yes | Yes | Set, planned: ask, as fetching does. Show, planned: the web access switch |
| Sharing, updates, question tool | `share`, `autoupdate`, `OPENCODE_ENABLE_QUESTION_TOOL` | on | Yes | Yes | Set off today |
| MCP timeout | `experimental.mcp_timeout` | 5 seconds | Yes | Yes | Measure: the app's tools that wait may be cut off |
| Language servers, formatters | `lsp`, `formatter` | off | Yes | Yes | Leave alone |
| Compaction | `compaction.*`; `OPENCODE_DISABLE_AUTOCOMPACT` | on when the window is full; pruning off | Yes: the summary arrives as agent text; `/compact` works but is not offered | Through `OPENCODE_CONFIG_CONTENT` | Leave alone: on with nothing set; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Snapshots, instructions, skills, plugins, commands, providers, output limits | `opencode.json` | its defaults | Yes | Server's own, and the app's | Leave alone |
| Leaving the folder | `permission.external_directory` | asks | Yes | Yes | Leave alone: a permission, not a sandbox; OpenCode has none |
| Theme, keys and other terminal settings | `tui.json` | — | No | — | Leave alone |

#### Grok

On a server the app starts the Grok installed there, with the same flags and `_meta`; its
settings files there are the server's own.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Reasoning effort | ACP `reasoning_effort`; `models.default_reasoning_effort` | low … xhigh (high) | Yes, under the prompt | Yes | Already shown |
| Web search and fetch | tools `web_search`, `web_fetch`, `open_page` | search on; fetch off unless xAI turns it on | Yes | Yes | Show, planned: the web access switch |
| Memory | `GROK_MEMORY`; `memory.enabled` | off, unless your config or xAI turns it on | Yes: `/memory`, `/dream`, `/flush` offered | Yes, by the variable | Show, planned: the memory switch, on by default |
| Self-update | `GROK_DISABLE_AUTOUPDATER` | updates itself in the background | Yes | Yes | Set, planned: off, so a running agent's Grok is not replaced under it |
| Shared leader process | `--no-leader`; `cli.use_leader` | from your config | Yes: a leader started with always-approve may approve for the app | Yes | Set, planned: `--no-leader`, once measured |
| Workflows and goals | `GROK_WORKFLOWS`, `GROK_GOAL` | on | Offered as commands | Yes | Set, planned: off, once measured; the `workflow` tool is already off by the app's deny list |
| Usage data | `GROK_TELEMETRY_ENABLED`, `DISABLE_TELEMETRY` | on | Yes | Yes | Show, planned: the usage data switch |
| Auto review | `_meta.autoMode` | off | Not measured with the app | Yes | Leave alone until measured |
| Folder trust | `x.ai/folder_trust/request` | asks | The app does not answer it; a server's untrusted folder may skip the folder's own settings | Yes | Measure on a server |
| Compaction | `[session] auto_compact_threshold_percent`; `GROK_AUTO_COMPACT_THRESHOLD_PERCENT` | on, at 80–85% of the window, no off switch | Yes: its own `auto_compact_*` updates in `_x.ai/session_notification`, drawn as the compaction row; `/compact` offered | Yes, by the variable | Leave alone: on with nothing set; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Subagent limits, MCP, plugins, hooks, skills, tool timeouts | config file | its defaults | Yes | Server's own | Leave alone. It also reads Claude's and Cursor's MCP servers, hooks and rules. |
| Permission rules | `permission.*`, and Claude's own settings files | — | Yes, before the app is asked | Server's own | Leave alone |
| Sandbox | `--sandbox`, before `agent stdio` | off | Yes: the whole process from its start, measured | Yes; Landlock | Show: **Command sandbox** |
| `--tools`, `--disallowed-tools`, `--max-turns` | flags | — | No: headless only | — | Leave alone |
| Theme, voice and other terminal settings | `ui.*` | — | No | — | Leave alone |

#### Copilot

Only the tool filters and effort are documented to work at launch under ACP; other flags are
read but have not been measured with the app. Its settings files on a server are the
server's own.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Reasoning effort | ACP `reasoning_effort`; `--reasoning-effort` | low … max (medium) | Yes, under the prompt | Yes | Already shown |
| Allow all | ACP `allow_all` | off | Yes, under the prompt | Yes | Already shown |
| Web addresses | `--allow-url`, `--deny-url`; `allowedUrls` | asks for each | Not measured | Yes | Show, planned: the web access switch, once measured |
| Remote control and export to GitHub | `--no-remote`, `--no-remote-export` | off unless you turned them on | Not measured | Yes | Set, planned: off, as OpenCode's sharing is |
| Context size | `--context` | default, long_context | Not measured | Yes | Leave alone |
| Credit cap | `--max-ai-credits` | none | Not measured | Yes | Leave alone: the app's cost ceiling is the place |
| Carry on in Auto when rate-limited | `continueOnAutoMode` | off | Not measured | Server's own | Leave alone. If on, the app never hears of the limit. |
| Self-update | `--no-auto-update` | on, applied at its next start | Yes | Yes | Leave alone: off would go back to an older copy |
| Memory | `memory` | on | Offered as a command | Server's own | Leave alone: no lever under ACP, so the memory switch does not reach it |
| Instructions, MCP, skills, plugins, hooks, custom agents | files and flags | loaded | Yes | Server's own | Leave alone |
| Scheduled prompts, fleet, computer use | `/every`, `/after`, `/fleet`, `/computer` | offered | Offered as commands | — | Leave alone: commands you type |
| Compaction ("infinite sessions") | none documented | on, from 80% of the window, blocking at 95% | Yes, but only the context meter shows it; `/compact` offered | Yes | Leave alone: on with nothing set, no off switch; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Usage data | none documented | — | — | — | Nothing to set |
| Folders and sandbox | `--add-dir`, `--allow-all-paths`, `--sandbox`, `--no-sandbox`, `sandbox.*` | this folder only; sandbox off | Not measured: its quota was spent | — | Leave alone: **Runtime controlled**, until measured |
| Default mode, theme and other terminal settings | settings | — | No | — | Leave alone |

#### Cursor

It reads no `_meta` when a conversation starts, and ignores most of its own flags under ACP.
Its settings file shares a folder with its sign-in, so the app can describe its settings but
not set them.

| Option | Where | Values (default) | Under ACP | On servers | Decided |
| --- | --- | --- | --- | --- | --- |
| Effort, thinking, context, fast | part of each model's value, such as `claude-opus-5[effort=high,fast=false]`; separate options when the client sends `_meta.parameterizedModelPicker` | per model | Yes, under the prompt, as one long list | Yes | Leave alone: already under the prompt, in the model |
| Always approve | `--force` | off | Yes | Yes | Leave alone: the app's **Always-approve** answers for it |
| Approval mode | `approvalMode` | allowlist | Not measured | Server's own | Leave alone. **Unrestricted** means it never asks, so the app's **Default** cannot hold it back. |
| Web search | `autoAcceptWebSearch` | asks | Yes | Server's own | Leave alone: no switch the app can reach |
| Compaction (summarization) | none: its backend decides | on | Yes, but nothing is sent over ACP and `/summarize` is not offered | Yes | Nothing to set; see [Compaction in each runtime](../explanation/compaction-by-runtime.md) |
| Attribution | `attribution.*` | on | Not measured | Server's own | Leave alone |
| Model shared with Terminal | — | — | A model picked in the app may become Cursor's default in Terminal too | — | Measure |
| Permission rules, MCP, hooks, rules, skills | files | — | Yes | Server's own | Leave alone |
| `--mode`, `--sandbox`, `--approve-mcps`, `--plugin-dir`, `--exclude-tools` | flags | — | No: not read by `acp` | — | Leave alone |
| Sandbox | `sandbox.mode` | off | Only its own setting: `acp` does not read `--sandbox` | Server's own | Leave alone: **Runtime controlled** |

## Command sandbox

Most runtimes can run their commands inside a sandbox of their own, which limits what a
command can write and, for some, what it can reach on the network. It is separate from the
permission mode, which decides when the runtime asks you, and from the app's own folder and
tool rules, which apply either way. **Settings ▸ Agent Runtimes** has a **Command sandbox**
default for each runtime, and each agent has its own choice beside its mode; see
[Settings](settings.md) and [Choose a runtime, model and mode](../how-to/choose-runtime-model-mode.md).

Each choice the app offers was measured to take effect, on 2026-09-29, by
`scripts/sandbox-probe.sh`: a real conversation, asked to write outside its folder, on the
version below. A runtime the app cannot reach offers no choice, and says why.

| Runtime | Measured on | **On** | **Off** | Without a choice | When the sandbox cannot start |
| --- | --- | --- | --- | --- | --- |
| **Claude** | Claude Code 2.1.284 | `sandbox.enabled` true, through `_meta`: writes only in the folder, asks before a new website | false | your settings decide: **Runtime controlled** | On a server without bubblewrap and socat, it will not start the conversation. On a Mac already inside a sandbox, each command fails. |
| **Codex** | Codex 0.156.1 | **Ask for approval** or **Approve for me**: writes only in the folder, no network | **Full access**, which also stops approval prompts | the mode decides | Each command fails, on a server without user namespaces or a Mac already inside a sandbox; Codex says so in its reply. |
| **Grok** | Grok 1.0.67 | not offered: `grok agent stdio --help` has no `--sandbox` option | not offered | **Runtime controlled**: the app cannot change Grok’s sandbox | Grok 1.0.44 refused to start when the flag was passed. |
| **Gemini** | Gemini CLI 0.61.0 | not offered: with its sandbox on, Gemini never answers the app | `GEMINI_SANDBOX=false`, above your own settings | your settings decide: **Runtime controlled** | On a server without Docker or Podman it will not start; on a Mac it never answers, and after 90 seconds the app says so. |
| **Cursor** | 2026.09.26 | — | — | **Runtime controlled**: its own `sandbox.mode` | — |
| **Copilot** | 1.0.89-5 | — | — | **Runtime controlled**; not measured yet | — |
| **Antigravity** | 1.2.1 | — | — | **No sandbox**, unless a business account's admin turns **Sandbox mode** on | Never fails: it asks before each command instead. |
| **OpenCode** | 1.18.33 | — | — | **No sandbox** | — |

When a runtime's sandbox cannot start, the agent stops with a card saying so, and
**Continue without sandbox** turns it off for that agent only. See
[Answer a question or a permission request](../how-to/answer-a-question.md).

## See also

- [Sign a runtime in](../how-to/sign-a-runtime-in.md)
- [Assess a runtime](../how-to/assess-a-runtime.md)
- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)
- [Why agents' own tools are taken away](../explanation/scoped-tools.md)
- [Tools the app gives agents](agent-tools.md)
