---
diataxis: explanation
description: Whether token-compression tools such as rtk and Headroom would cut what the app's agents cost, how either would plug in, and what to do about it.
devices: [mac, server]
---

# Token-compression tools

Token-compression tools promise to cut what a coding agent costs. They shrink what the
agent reads before it reaches the model. Two of them are widely used: **rtk** (Rust
Token Killer) and **Headroom**. Both claim savings of 60–95%.

This page records what each tool does and what independent measurements found. It also
covers where either would plug into the app and what the app should do. It was researched
on 2026-10-08 from each project's own pages, two independent benchmarks of rtk and three
write-ups of Headroom in use. No tool was installed or run, and no code was changed.

## In short

**Neither tool should be built into the app, or turned on by default.**

- **rtk made agents more expensive** in both independent benchmarks: up to 7.6% more at
  the median, with no change in quality.
- **Headroom saves something, but far less than claimed:** about 5–10% on the wire. In
  one real Claude Code session it compressed nothing.
- **Most of what an agent reads is already cheap.** Cached input is 94–98% of input
  tokens, billed at a tenth of the price or less. Compressing it saves little.

If Headroom is worth trying, it should be an opt-in switch per runtime. The app's own
token counts, not the tool's, should judge it (see [What the app could do](#what-the-app-could-do)).

## rtk

[rtk](https://github.com/rtk-ai/rtk) is a single Rust binary, Apache-2.0, with no
dependencies. It filters the output of over 100 shell commands, among them git, cargo,
npm, pytest, docker and kubectl, before the agent reads it. It groups, deduplicates
and truncates, and adds under 10 ms to each command.

**How it hooks in.** `rtk init -g` installs a hook that runs before each tool call. The
hook rewrites a shell command such as `git status` to `rtk git status`. It supports:

| Agent | What `rtk init` installs |
|---|---|
| Claude Code | A `PreToolUse` hook in `settings.json` |
| Codex | A `PreToolUse` hook and a note in `AGENTS.md` |
| Copilot | A `PreToolUse` hook |
| Cursor | An entry in `hooks.json` |
| Gemini CLI | A `BeforeTool` hook |
| OpenCode | A TypeScript plugin on `tool.execute.before` |

Its configuration lives in `~/.config/rtk/config.toml`. Telemetry is off unless turned on.
When a command fails or is cut short, the full output is kept and `rtk recall <id>`
gives it back.

**What it cannot see.** Only shell commands go through the hook. Claude Code's own Read,
Grep and Glob tools do not, so rtk reaches about a fifth of what the agent reads.

**What it reports.** `rtk gain` shows the tokens saved, but it counts bytes removed,
divided by four. That is not what is billed.

### What independent benchmarks found

| Benchmark | Set-up | Cost with rtk | Quality |
|---|---|---|---|
| [JetBrains](https://blog.jetbrains.com/ai/2026/07/rtk-claude-code-token-savings/) | Claude Code, SkillsBench, 425 paired trials | **+7.6%** median at low effort; +0.1% at high | No difference |
| [Quesma](https://quesma.com/blog/does-rtk-make-ai-coding-cheaper/) | Claude Code (Fable 5.0) and OpenCode (DeepSeek V4 Pro), Terminal-Bench 2.1, 1,740 attempts | **+1%** (Fable), **+17%** (DeepSeek) | 1–2% fewer tasks passed |

In the JetBrains runs, `rtk gain` claimed 96.2 million tokens saved while the bills
went up. Both benchmarks give the same reasons:

- **Command output is a small share of what the agent reads:** 7% for Fable and 26% for
  DeepSeek.
- **Most of it is already cheap.** Input already in the cache is billed at a tenth to a
  thirtieth of the full price.
- **Shorter output led to more turns.** The agent ran extra commands to find what had been
  filtered away. With DeepSeek, 58 tasks took more turns and 44 cost more. One attempt
  cost nine times the normal amount, after rtk mishandled a command flag it did not support.
- **Claude Code already truncates very long output** of the kind rtk targets.

rtk does not break prompt caching. It filters output once, before the output enters the
conversation, and never rewrites it afterwards.

## Headroom

[Headroom](https://github.com/headroomlabs-ai/headroom) is Python with Rust for the
fast paths, Apache-2.0. It is installed with `uv tool install "headroom-ai[all]"` and
needs Python 3.10 or later. It compresses on the wire. It sits between the agent and the
provider and shrinks tool output, logs, JSON, file reads and older history in each request.

**How it runs:**

- **as a proxy:** `headroom proxy --port 8787`, with the agent's `ANTHROPIC_BASE_URL` (or
  its OpenAI equivalent) pointed at it;
- **wrapping an agent:** `headroom wrap claude` starts the proxy and the agent together. It
  covers Claude Code, Codex, Cursor, Copilot, Cline, Continue, OpenCode, Aider and Grok;
- **as an MCP server,** with `headroom_compress`, `headroom_retrieve` and `headroom_stats` tools;
- **as a library,** calling `compress(messages)`.

**Compression can be undone.** The original is kept locally for a while, and the model
can ask for it back with `headroom_retrieve`.

**It claims to keep prompt caching working.** It marks content that changes rather than
rewriting the start of the prompt.

**Subscription logins work.** A Claude subscription works through the proxy, not only an
API key ([my-claude #228](https://github.com/sehoon787/my-claude/pull/228)).

**Telemetry is on by default.** It sends anonymous compression figures, never prompts or
code. `HEADROOM_BEACON=off` or `DO_NOT_TRACK=1` turns it off.

### What it saves in practice

Headroom itself says coding agents get about 20% fewer tokens, and JSON 60–95% fewer.
Measurements by others were lower:

- **Headroom's own fleet median is 4.8%**, according to an independent write-up that
  measured about 10% on the wire. In one real Claude Code session, that write-up found 0%
  of the conversation compressed
  ([Claude Code Costs, Act III](https://dev.to/sumedhbala/claude-code-costs-act-iii-the-ecosystem-of-options-for-spending-less-33pc)).
- **[One developer's trial](https://www.russ.cloud/2026/06/13/playing-with-headroom-compressing-the-context-going-to-my-ai-coding-agents/)
  reported 20.7% saved** on about 1.9 million tokens. Only about 5% of that came from
  compressing content; the rest came from trimming the history of long conversations. The
  cache discount it showed was Anthropic's own and would have happened anyway.
- **Each request took about 300 ms longer** in the same trial, with occasional waits of
  tens of seconds while its model warmed up.

**It adds a way for a session to fail.** If the proxy is down, the agent cannot reach
the model at all. That is why at least one set-up keeps it opt-in.

## Where either would plug into the app

The app has no integration of either tool today. In the code, "headroom" only names the
cost-limit idea, not this tool.

Every runtime, on the Mac and on a Linux server, starts through one path. The app also
has ways to pass each runtime its own environment and plugins.

| Hook | Where | Fits |
|---|---|---|
| Environment per runtime | `RuntimeLaunch.environment` in `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/RuntimeLaunch.swift`. Claude, Codex and Grok have no entries yet. | Headroom: point `ANTHROPIC_BASE_URL` (Claude) or Codex's base URL at the proxy |
| The launch | `ProcessSessionLauncher.launch` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` merges the environment and starts the runtime. | Both |
| `PATH` | `LoginShellPath.environment()` in `Packages/AgentsKit/Sources/AgentsKit/Runtimes/LoginShellPath.swift`. The app's terminals use it too. | rtk: a folder of wrapper commands placed first |
| Personal plugins | `~/.agents/plugins`. They reach Claude, Grok, Codex and Gemini, but not Cursor or Copilot over ACP. | rtk: a plugin that carries its hook, with no change to the app |

**On servers, `ANTHROPIC_BASE_URL` is already in use.** The sign-in relay sets it to point
Claude at the Mac (`ToolPolicyCatalog.swift`), and Codex gets a base URL the same way. A
Headroom proxy there would have to sit in front of the relay, not replace it.

**The app can already measure the result.** After each turn it records input, output and
cached-read tokens (`TurnUsage`), and it keeps a running cost per agent (`costToDate`). Only
the last turn is kept, though. A fair comparison needs every turn's usage kept, for example
in `turns.jsonl`.

## What the app could do

1. **Not ship rtk, or turn it on by default.** Both independent benchmarks found it made
   agents more expensive. Anyone who wants it can install it for themselves, with
   `rtk init -g` or as a personal plugin.
2. **If Headroom is worth trying, make it an opt-in switch per runtime,** off by default.
   - The app would not install it. It would only point the runtime at a proxy on the Mac.
   - If the proxy is not running, the runtime would connect directly rather than fail.
   - Server runs would be left alone, because of the relay.
   - Keep each turn's token counts, and compare agents with the switch on and off. Judge it
     on those figures, not on what Headroom reports about itself.
3. **Cut what is sent instead of compressing it.** These savings are in the app's own hands:
   - give each agent fewer tools and MCP servers, since their schemas are sent every turn;
   - keep the start of each prompt the same from turn to turn, so the cache keeps working;
   - choose when each runtime compacts. All eight compact on their own already
     (see [Compaction in each runtime](compaction-by-runtime.md)).

## Sources

- [rtk-ai/rtk](https://github.com/rtk-ai/rtk), and its site at [rtk-ai.app](https://www.rtk-ai.app/)
- [JetBrains: rtk Claude Code token savings, a skill trial benchmark](https://blog.jetbrains.com/ai/2026/07/rtk-claude-code-token-savings/)
- [Quesma: RTK reports huge token savings, but our cost benchmarks disagree](https://quesma.com/blog/does-rtk-make-ai-coding-cheaper/)
- [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom)
- [Playing with Headroom (russ.cloud)](https://www.russ.cloud/2026/06/13/playing-with-headroom-compressing-the-context-going-to-my-ai-coding-agents/)
- [Claude Code Costs, Act III (DEV Community)](https://dev.to/sumedhbala/claude-code-costs-act-iii-the-ecosystem-of-options-for-spending-less-33pc)
- [sehoon787/my-claude #228: the Headroom proxy rationale](https://github.com/sehoon787/my-claude/pull/228)
