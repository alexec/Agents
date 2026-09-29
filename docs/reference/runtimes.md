---
diataxis: reference
devices: [mac, server]
description: The coding agents the app can start, what it runs for each, and what each can do in the app.
---

# Runtimes

A runtime is the coding agent that does the work in a conversation. This page lists the
ones the app knows how to start. Most you install and sign in to yourself, and the app
finds them on your Mac, or on a server when the project is on a server. Codex, Gemini,
Antigravity and OpenCode are only ever the app's own copies: **Install** on their rows in **Settings ▸ Agent Runtimes** puts
them in place.

What a runtime can do in the app is decided by what it says about itself when it starts,
not by its name. The columns for pictures and signing in are what each runtime said when
it was last measured. If a newer version says something different, the app follows the
newer version.

| Runtime | Command it starts | Pictures | Sign in from the app | App tools available | Notes |
| --- | --- | --- | --- | --- | --- |
| **Claude** | `npx -y @agentclientprotocol/claude-agent-acp` | Yes | Partly. Sign in with Claude Code itself, in Terminal: run `claude` and type `/login`. The sheet then shows the account, such as **Claude Max**, and offers **Sign out** and **Who answers**. | All | `claude` has no mode the app can talk to, so the app runs this adapter through your Node instead. Its questions reach you as a card you can answer on the Mac or phone. It asks your permission before using some of the app's tools. Its subagents and background commands are shown over the prompt as they run. |
| **Grok** | `grok --permission-mode default agent stdio` | No | Yes, with **grok.com** | All | It cannot ask you a question mid-turn in a way the app can show, so it ends its turn with the question instead, and the agent shows **Waiting on your answer**. Its image and video generation is switched off for the conversations the app starts. It offers no permission mode under the prompt; set **Default** or **Always-approve** in **Settings ▸ Agent Runtimes**. Agents the app starts always ask under **Default**, even when Grok's own saved mode elsewhere would approve everything. |
| **Copilot** | `copilot --acp` | Yes | Hands you the exact command to run in Terminal, with **Open Terminal** and **Copy** | All | It takes no MCP server it would have to start itself, so the app runs those, its own tools included, and hands each to Copilot over a local http address only that agent can use. It uses its own follow-up suggestions instead of the app's. It asks permission before every tool call. |
| **Gemini** | the app's own `gemini --acp --skip-trust`, installed from **Settings ▸ Agent Runtimes** | Yes | No. Paste a Gemini API key under Gemini in **Settings ▸ Agent Runtimes** (get one at aistudio.google.com/apikey). | All | A `gemini` you installed yourself is never used: the app runs the version it was built against. Google's own sign-in no longer works for individuals, so a key is the way in; the same key is used on servers. The app's tools reach Gemini only in a folder it trusts, so the app trusts the agent's folder for that conversation only, which also loads that project's own Gemini hooks and settings. It cannot ask you a question mid-turn, so it ends its turn with the question and the agent shows **Waiting on your answer**. Its own subagents and task tracker are switched off. It reports tokens but no cost. On Google's free tier a spent daily quota ends the turn with Google's own sentence, and **Auto** in the model menu may pick a Pro model, which has the smallest free quota: choose a Flash model to go further. Picking a conversation back up may make Gemini record, once, that it signs in with an API key, in its own `~/.gemini/settings.json`. |
| **Cursor** | `cursor-agent acp` | Yes | Yes | All | The command is `cursor-agent`, not `agent`, which is Grok's. It offers no options to pick from and no way to sign out, so the app shows neither. Three of its own tools, which overlap with the app's, cannot be turned off. It asks your permission before using some of the app's tools. Its Agent, Plan and Ask stay under the prompt; permission mode is **Default** or **Always-approve** in **Settings ▸ Agent Runtimes**, not a capsule here. |
| **Codex** | The app's own copy of `@agentclientprotocol/codex-acp`, installed from the set-up page or **Settings ▸ Agent Runtimes** | Yes | Yes: **ChatGPT** first, then a ChatGPT device code or an OpenAI API key | All | Never a `codex` or `npx` of yours: the app runs the exact version it carries, and offers **Update** when a newer app carries a newer one. Signing in with ChatGPT is shared with Codex in Terminal. Its questions reach you as a card. Its three modes are **Ask for approval**, **Approve for me** and **Full access**. It shows how much of its context is used, with no cost. Its own sub-agents are on, and shown over the prompt as they run. |
| **Antigravity** | The app's own copy of Google's Antigravity ACP server (`agy_acp_server`, not the `agy` command), downloaded from Google by the set-up page or **Settings ▸ Agent Runtimes** | Yes | Yes, with a personal or business Google account, in your browser | All | The one Google runtime a Google account alone can sign in to; Gemini is for an API key, and the Gemini key is never lent to Antigravity. It keeps its settings, conversations and sign-in in a folder of the app's own, never in `~/.gemini`. It runs on this Mac only; servers are not supported yet. Its questions reach you as a card. Its own tool for starting subagents is switched off. |
| **OpenCode** | The app's own copy of OpenCode (`opencode acp`), downloaded from its GitHub releases by the set-up page or **Settings ▸ Agent Runtimes** | Yes | Hands you the command to run in Terminal, the app's own copy by its full path, with **Open Terminal** and **Copy**. It adds one provider at a time, so the sheet keeps offering it when ready, and names `opencode auth logout` for taking one away. | All | Never an `opencode` of yours: two different programs go by that name, and the app runs the version it carries. It works signed out, on OpenCode Zen's free models. It asks your permission before editing files, running commands and fetching web pages; set **Default** or **Always-approve** in **Settings ▸ Agent Runtimes**. Its questions reach you as a card. Sharing and self-update are off, and its own tool for starting subagents is switched off. A picked model whose provider is not signed in is dropped at the next start, with a note saying so. On a server it borrows this Mac's provider keys for each run. |

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
  server. Claude, Codex, Gemini and OpenCode are the exceptions: Agents installs them on the
  server itself. Claude and Codex sign in there through this Mac's own sign-ins, Gemini with
  the key in Settings, and OpenCode borrows the provider keys it is signed in with on this Mac,
  for each run. See
  [Add a Linux server](../how-to/add-a-linux-server.md).

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
is marked out for every chat to see in **Settings ▸ Agent Runtimes**. Nothing carries the chat
on: to go on, start a new chat on another runtime and ask it to continue this one (see
[Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)). A
runtime that is out can still be sent a message; if that turn works, it is back.

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
| **OpenCode** | reads `~/.agents/skills` | follows `~/.claude/CLAUDE.md`, the link above, unless you keep your own `~/.config/opencode/AGENTS.md` | sent at start | no way in: its plugins are its own npm packages |

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

### What the app sets for you

| Runtime | What | How | Why |
| --- | --- | --- | --- |
| **Claude** | Scheduling, workflow, notification, peer-agent, worktree and two document tools taken away | `_meta.claudeCode.options.disallowedTools` | The work stays where the app can see it. |
| | Your plugins from `~/.agents` | `_meta.claudeCode.options.plugins` | Shared plugins reach every agent. |
| | Every `CLAUDE_*` variable removed from its environment | Environment | A runtime the app starts must not think it is another Claude session's child. This also drops a `CLAUDE_CONFIG_DIR` of yours. |
| | On a server: this Mac's sign-in, through a relay | Environment | One sign-in, on the Mac. |
| **Codex** | Sleep, goals, automations, memories and ChatGPT apps off; its sub-agents on; its question tool outside plan mode | `CODEX_CONFIG` | The work stays where the app can see it; questions reach you as a card. |
| | On a server: this Mac's ChatGPT sign-in, through a relay | `CODEX_HOME` of the app's own | One sign-in, on the Mac. It also means the server's own `~/.codex/config.toml` is not read. |
| **Gemini** | The agent's folder trusted for this run | `--skip-trust` | The app's tools start only in a trusted folder. Nothing is written to Gemini's list of trusted folders. |
| | Its subagents and task tracker off | `--policy`, a file of the app's | The work stays where the app can see it. While the app passes this, a `policyPaths` of yours is not read. |
| | `AGENTS.md` read beside `GEMINI.md` | `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` | Shared instructions reach Gemini. Your own `context.fileName` wins. |
| | Your key from Settings | `GEMINI_API_KEY` | The only way in for individuals. |
| **Antigravity** | A home of the app's own, never `~/.gemini` | `GEMINI_HOME` | Its settings, conversations and sign-in stay apart from Gemini's. |
| | The agent's folder trusted | `AGY_ACP_DISABLE_WORKSPACE_TRUST` | As Gemini's. It also means a project's `.agents/hooks.json` runs without Antigravity asking first. |
| | Its sign-in in a file, not the Keychain | `AGY_ACP_FORCE_FILE_STORAGE` | So it can be copied to a server without a Keychain prompt. |
| | Its subagent tool off | `_meta.agy.disabledTools` | The work stays where the app can see it. |
| | Keys in the environment ignored | `GEMINI_API_KEY`, `GOOGLE_API_KEY` removed | It signs in with a Google account only. |
| **OpenCode** | Asks before editing, running commands and fetching pages; subagents off; sharing and self-update off | `OPENCODE_CONFIG_CONTENT`, `OPENCODE_DISABLE_SHARE`, `OPENCODE_DISABLE_AUTOUPDATE` | Left alone, it does all three without asking; no conversation is published; the app's copy is never replaced under a running agent. |
| | A temporary folder of its own | `TMPDIR` | It walks that folder at every turn: 40 seconds before the first word with the Mac's own. |
| | Its question tool off | `OPENCODE_ENABLE_QUESTION_TOOL` removed | Questions go through the app's `ask_form`. |
| **Grok** | Asks, whatever you saved in its own config | `--permission-mode default` | The app's **Default** or **Always-approve** decides (Settings ▸ Agent Runtimes). |
| | Only its work tools, and the app's rules | `_meta.agentProfile`, `_meta.rules` | Its `--disallowed-tools` does nothing here, so it is an allowlist. |
| | Image and video generation off | `GROK_CONFIG_PATH`, a file of the app's | Its config file is the only place for them, and yours is yours. |
| **Copilot** | Its subagent and session-store tools, your `software-factory` server and its built-in MCP servers off | `--excluded-tools`, `--disable-mcp-server`, `--disable-builtin-mcps` | The work stays where the app can see it. |
| **Cursor** | Nothing | | It has no lever: its config folder also holds its sign-in. |

### Every option, by runtime

Each table lists what a person might want to change; the long tail of each runtime (proxy,
debug, provider and terminal-only settings) is grouped into one row. In the last column,
**Show** means the app offers it, **Set** means the app chooses the value for you, and
**Leave alone** means the runtime's own default, or your own settings file, decides. These
are proposals until they are decided. Sandbox options are listed and decided with the
sandbox setting ([#40](https://github.com/alexec/Agents/issues/40)).

#### Claude

The adapter passes anything in `_meta.claudeCode.options` to Claude Code, including
`settings`, which sits above your own settings files for that conversation only. So any
setting below can be set by the app for one agent without touching `~/.claude`.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Effort | ACP `effort`; `effortLevel` in settings | default, low, medium, high, xhigh, max | Yes, under the prompt | Yes | Show a default for new agents in Settings, beside the one under the prompt |
| Fast mode | ACP `fast`; `fastMode` | off | Yes, under the prompt; needs extra usage | Yes | Already shown |
| Thinking on, off or budget | `alwaysThinkingEnabled`; `MAX_THINKING_TOKENS` | on, adaptive | Yes | Yes | Leave alone: effort covers it |
| Fallback model | `fallbackModel` | none | Yes | Yes | Leave alone: overlaps the app's own fallback |
| Cost and turn limits | `_meta…options.maxBudgetUsd`, `maxTurns` | none | Yes | Yes | Set: an agent's cost ceiling, stopped by Claude itself |
| Web search and fetch | tools `WebSearch`, `WebFetch` | on, asks | Yes | Yes | Show: one web access switch per runtime |
| Memory | `autoMemoryEnabled` | on | Yes | Server's own | Decide with Codex's, which the app turns off |
| Transcript retention | `cleanupPeriodDays` | 30 days | Yes: old transcripts deleted at start | Server's own | Set: long enough that an idle agent can still be picked back up |
| Commit and PR attribution | `attribution.commit`, `attribution.pr` | on | Yes | Server's own | Leave alone: yours to set in its settings |
| Usage data | `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | sent | Yes; a `CLAUDE_CODE_*` of your shell is removed | Yes | Show: one usage data switch per runtime |
| Custom config folder | `CLAUDE_CONFIG_DIR` | `~/.claude` | Removed with every `CLAUDE_*` | — | Set: let it through, so your own folder is used |
| Keep credentials out of commands | `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | off | Yes | Yes | Set on servers: the relay's stand-in token stays out of shell commands |
| Checkpoints | `fileCheckpointingEnabled` | on only when the client reports file changes; the app does not | Off | Off | Leave alone |
| Compaction, output style, language, system prompt, hooks, MCP loading, subagents | settings, environment | its defaults | Yes | Server's own | Leave alone |
| Sandbox and network | `sandbox.*` | off | Yes | Server's own | Sandbox (#40) |
| Updates, status line, notifications, theme and other terminal settings | settings | — | No: pinned version, no terminal | — | Leave alone |

#### Codex

The adapter merges `CODEX_CONFIG` into every conversation, above your `~/.codex/config.toml`,
so it reaches servers too. It sends approval, sandbox, effort, model and fast mode again on
every turn, so those in your config file only choose the first value, or nothing.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Reasoning effort | ACP `reasoning_effort`; `model_reasoning_effort` | low … max (medium) | Yes, under the prompt | Yes | Show a default for new agents in Settings |
| Fast mode | ACP `fast-mode`; `service_tier` | off | Yes, under the prompt | Yes | Already shown |
| Plan | ACP `collaboration_mode` | default, plan | Yes, under the prompt | Yes | Already shown |
| Approval policy | `approval_policy`, `approvals_reviewer` | from the mode | No: the mode decides every turn | — | Leave alone |
| Web search | `web_search` | cached; live under **Full access** | Yes | Only through `CODEX_CONFIG` | Show: one web access switch per runtime |
| Usage data | `analytics.enabled`, `feedback.enabled` | on | Yes | Only through `CODEX_CONFIG` | Show: one usage data switch per runtime |
| Memories | `features.memories` | off | Yes | Yes | Set off today |
| Browser, computer use, image generation | `features.browser_use`, `computer_use`, `image_generation` | on | Not yet measured | — | Measure: they may be tools that duplicate the app's |
| Reasoning summaries | `model_reasoning_summary` | auto | No: the adapter chooses | — | Leave alone |
| Folder trust | `projects.<path>.trust_level` | asks | The adapter trusts every agent's folder, so a project's own Codex config and hooks load | Yes | Leave alone |
| Verbosity, compaction, subagent limits, profiles, instructions, MCP, hooks | config file | its defaults | Yes | Not read on a relayed server | Leave alone |
| Sandbox and network | `sandbox_mode`, `sandbox_workspace_write.network_access` | from the mode: network off except **Full access** | The mode decides | — | Sandbox (#40) |
| Updates, notifications and terminal settings | config file | — | No | — | Leave alone |

#### Gemini

Gemini offers no options under the prompt beyond model and mode, and reads no `_meta` when a
conversation starts. Its settings come from files only: the app's own system defaults file
is the lowest of them, so yours always win over it.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Thinking level | `modelConfigs` in settings | high | Yes | Through the app's defaults file | Leave alone: no flag, and a file per agent to vary it |
| Web search and fetch | tools `google_web_search`, `web_fetch` | on | Yes | Through the app's policy file | Show: one web access switch per runtime |
| Usage statistics | `privacy.usageStatisticsEnabled` | on | Yes | Through the app's defaults file | Show: one usage data switch per runtime; your own file still wins |
| Session retention | `general.sessionRetention` | 30 days, deleted at every start | Yes | Through the app's defaults file | Set: long enough that an idle agent can still be picked back up |
| Subagents, task tracker | `invoke_agent`, `tracker_*` | on, off | Yes | Yes | Set off today |
| Folder trust | `--skip-trust` | asks | Yes: loads the project's own hooks and settings | Yes | Set today |
| Compression, turn limit, loop detection, tool output, shell | settings | its defaults | Yes | Server's own | Leave alone |
| Checkpoints | `general.checkpointing.enabled` | off | No: only its terminal writes them | — | Leave alone |
| MCP, hooks, extensions, skills, `.env` files | settings | loaded | Yes | Server's own | Leave alone. A project `.env` can set Gemini's variables. |
| Telemetry to your own collector | `telemetry.*`, `GEMINI_TELEMETRY_*` | off | Yes | Yes | Leave alone |
| Sandbox | `--sandbox`, `tools.sandbox` | off | Not measured | — | Sandbox (#40) |
| Updates, output format, theme and other terminal settings | settings, flags | — | No | — | Leave alone |

#### Antigravity

Its one settings file holds only its sign-in choice and a Google Cloud project. Everything
else is an option under the prompt, the tool list the app sends, or its environment.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Thinking level | part of the model, such as `gemini-3.8-flash-high` | high | Yes, under the prompt | Mac only today | Already shown |
| Web search and fetch | tools `search_web`, `read_url_content` | on, asks | Yes | Mac only today | Show: one web access switch per runtime |
| Image generation | tool `generate_image` | on | Yes | Mac only today | Leave alone |
| Subagents | tool `start_subagent` | on | Yes | Mac only today | Set off today |
| Starting model | `AGY_ACP_DEFAULT_MODEL` | flash, high | Yes | — | Leave alone: the model is under the prompt |
| Project hooks | `.agents/hooks.json` in the project | asks, unless the folder is trusted | Run without asking, because the app trusts the folder | — | Decide: keep trusting, or let it ask |
| MCP, skills, rules | its home, the project | — | Yes | — | Leave alone |
| Usage data, compaction, checkpoints, updates | none | — | — | — | Nothing to set |
| Sandbox | business accounts only | off | — | — | Sandbox (#40) |

#### OpenCode

The app passes its settings in `OPENCODE_CONFIG_CONTENT`, above your own `opencode.json`,
which reaches servers too. Settings your Mac's administrator manages win over both.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Effort | ACP `effort`, for models with variants | the model's variants | Yes, under the prompt, when the model has them | Yes | Already shown when offered |
| Permissions | `permission.*` | allow everything | Yes | Yes | Set today for edits, commands and fetches |
| Web search | tool `websearch`, `permission.websearch` | on, without asking, through Exa or Parallel | Yes | Yes | Set: ask, as fetching does; and Show with the web access switch |
| Subagents, sharing, updates, question tool | `tools.task`, `share`, `autoupdate` | on | Yes | Yes | Set off today |
| MCP timeout | `experimental.mcp_timeout` | 5 seconds | Yes | Yes | Measure: the app's tools that wait may be cut off |
| Language servers, formatters | `lsp`, `formatter` | off | Yes | Yes | Leave alone |
| Compaction, snapshots, instructions, skills, plugins, commands, providers, output limits | `opencode.json` | its defaults | Yes | Server's own, and the app's | Leave alone |
| Leaving the project folder | `permission.external_directory` | asks | Yes | Yes | Sandbox (#40) |
| Theme, keys and other terminal settings | `tui.json` | — | No | — | Leave alone |

#### Grok

On a server the app starts the Grok installed there, with the same flags and `_meta`; its
settings files there are the server's own.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Reasoning effort | ACP `reasoning_effort`; `models.default_reasoning_effort` | low … xhigh (high) | Yes, under the prompt | Yes | Show a default for new agents in Settings |
| Web search and fetch | tools `web_search`, `web_fetch`, `open_page` in the app's allowlist | search on; fetch off unless xAI turns it on | Yes | Yes | Show: one web access switch per runtime |
| Memory | `GROK_MEMORY`; `memory.enabled` | off, unless your config or xAI turns it on | Yes: `/memory`, `/dream`, `/flush` offered | Yes, by the variable | Decide with Claude's and Codex's |
| Self-update | `GROK_DISABLE_AUTOUPDATER` | updates itself in the background | Yes | Yes | Set: off, so a running agent's Grok is not replaced under it |
| Shared leader process | `--no-leader`; `cli.use_leader` | from your config | Yes: a leader started with always-approve may approve for the app | Yes | Set `--no-leader`, once measured |
| Workflows and goals | `GROK_WORKFLOWS`, `GROK_GOAL` | on | Offered as commands | Yes | Set off, once measured: it may close the `workflow` tool the allowlist cannot |
| Usage data | `GROK_TELEMETRY_ENABLED`, `DISABLE_TELEMETRY` | on | Yes | Yes | Show: one usage data switch per runtime |
| Auto review | `_meta.autoMode` | off | Not measured with the app | Yes | Leave alone until measured |
| Folder trust | `x.ai/folder_trust/request` | asks | The app does not answer it; a server's untrusted folder may skip the project's own settings | Yes | Measure on a server |
| Compaction, subagent limits, MCP, plugins, hooks, skills, tool timeouts | config file | its defaults | Yes | Server's own | Leave alone. It also reads Claude's and Cursor's MCP servers, hooks and rules. |
| Permission rules | `permission.*`, and Claude's own settings files | — | Yes, before the app is asked | Server's own | Leave alone |
| Sandbox | `--sandbox` | off | Not with a leader | — | Sandbox (#40) |
| `--tools`, `--disallowed-tools`, `--max-turns` | flags | — | No: headless only | — | Leave alone |
| Theme, voice and other terminal settings | `ui.*` | — | No | — | Leave alone |

#### Copilot

Only the tool filters and effort are documented to work at launch under ACP; other flags are
read but have not been measured with the app. Its settings files on a server are the
server's own.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Reasoning effort | ACP `reasoning_effort`; `--reasoning-effort` | low … max (medium) | Yes, under the prompt | Yes | Show a default for new agents in Settings |
| Allow all | ACP `allow_all` | off | Yes, under the prompt | Yes | Already shown |
| Web addresses | `--allow-url`, `--deny-url`; `allowedUrls` | asks for each | Not measured | Yes | Show: part of the web access switch, once measured |
| Remote control and export to GitHub | `--no-remote`, `--no-remote-export` | off unless you turned them on | Not measured | Yes | Set off, as OpenCode's sharing is |
| Context size | `--context` | default, long_context | Not measured | Yes | Leave alone |
| Credit cap | `--max-ai-credits` | none | Not measured | Yes | Leave alone: the app's cost ceiling is the place |
| Carry on in Auto when rate-limited | `continueOnAutoMode` | off | Not measured | Server's own | Leave alone. If on, the app never hears of the limit. |
| Self-update | `--no-auto-update` | on, applied at its next start | Yes | Yes | Leave alone: off would go back to an older copy |
| Memory | `memory` | on | Offered as a command | Server's own | Decide with Claude's and Codex's |
| Instructions, MCP, skills, plugins, hooks, custom agents | files and flags | loaded | Yes | Server's own | Leave alone |
| Scheduled prompts, fleet, computer use | `/every`, `/after`, `/fleet`, `/computer` | offered | Offered as commands | — | Leave alone: commands you type |
| Usage data | none documented | — | — | — | Nothing to set |
| Folders and sandbox | `--add-dir`, `--allow-all-paths`, `sandbox.*` | this folder only | Not measured | — | Sandbox (#40) |
| Default mode, theme and other terminal settings | settings | — | No | — | Leave alone |

#### Cursor

It reads no `_meta` when a conversation starts, and ignores most of its own flags under ACP.
Its settings file shares a folder with its sign-in, so the app can describe its settings but
not set them.

| Option | Where | Values (default) | Under ACP | On servers | Proposed |
| --- | --- | --- | --- | --- | --- |
| Effort, thinking, context, fast | part of each model's value, such as `claude-opus-5[effort=high,fast=false]`; separate options when the client sends `_meta.parameterizedModelPicker` | per model | Yes, under the prompt, as one long list | Yes | Show: ask for them as separate options, as Claude's and Codex's are |
| Always approve | `--force` | off | Yes | Yes | Leave alone: the app's **Always-approve** answers for it |
| Approval mode | `approvalMode` | allowlist | Not measured | Server's own | Leave alone. **Unrestricted** means it never asks, so the app's **Default** cannot hold it back. |
| Web search | `autoAcceptWebSearch` | asks | Yes | Server's own | Leave alone: no switch the app can reach |
| Attribution | `attribution.*` | on | Not measured | Server's own | Leave alone |
| Model shared with Terminal | — | — | A model picked in the app may become Cursor's default in Terminal too | — | Measure |
| Permission rules, MCP, hooks, rules, skills | files | — | Yes | Server's own | Leave alone |
| `--mode`, `--sandbox`, `--approve-mcps`, `--plugin-dir`, `--exclude-tools` | flags | — | No: not read by `acp` | — | Leave alone |
| Sandbox | `sandbox.*` | off | Not by flag | — | Sandbox (#40) |

## See also

- [Sign a runtime in](../how-to/sign-a-runtime-in.md)
- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md)
- [Why agents' own tools are taken away](../explanation/scoped-tools.md)
- [Tools the app gives agents](agent-tools.md)
