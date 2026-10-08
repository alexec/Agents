---
diataxis: explanation
description: What the app's own tools and briefing add to every request an agent makes, what is cached, and what the app changed and left alone to cut it (#465).
devices: [mac, server]
---

# What agents are sent each turn

Every request a runtime makes to its model carries the whole conversation so far: the
system prompt, every tool's schema and the history. Most of it is cached by the provider,
and a cached token is billed at a tenth of the price or less. The token-compression
research (#464) found that compression tools save little. This page measures what the
app itself adds to each request, and records what was changed because of it.

Measured on 2026-10-08, from the agents on Alex's Mac and from the app's own code.

## Where the tokens go

`scripts/turn-usage.sh` adds up every turn's usage, as each runtime reported it, for every
agent on this Mac. On 2026-10-08 it read:

| Runtime | Turns | Uncached input | Cache reads | Cache writes | Output |
| --- | --- | --- | --- | --- | --- |
| Claude | 1,278 | 51,876 | 4,033 M (98.5%) | 61 M (1.4%) | 12.5 M |
| Codex | 153 | 427,027 | 14.8 M (97.1%) | none reported | 13,704 |
| OpenCode | 29 | 9,095 | 1.66 M (99.4%) | none reported | 3,300 |

The percentages are shares of all input. For Claude, at its list prices (a cache read is
0.1× input, a cache write 1.25×, output 5×), **cache reads are about three quarters of
the cost**, cache writes about a seventh and output about a ninth. Uncached input is
almost nothing.

So the size of what is re-read on every request matters more than anything sent once.
Each tool schema is re-read on every model call, and a turn makes many calls: Claude's
turns read 3.2 M cached tokens each on average, against a median context of 128 K at
the agent's last turn.

## The app's own tools

`ToolCostTests` measures what the app's MCP server lists, a tool at a time, as compact
JSON. A token is taken as about four bytes.

| Session | Bytes | About |
| --- | --- | --- |
| An agent the person started (21 tools) | 35,764 | 8,900 tokens |
| An agent another agent started (16 tools) | 29,448 | 7,400 tokens |
| Grok's rules, which repeat the tools in its system prompt | 8,851 | 2,200 tokens |
| The briefing, sent once with the first prompt (Claude) | 2,589 | 650 tokens |

Two tools are over half of it: `manage_workflows` (8,600 bytes) and `finish_turn` (8,188).
`start_agent` is next at 3,385; every other tool is under 1,800.

What a runtime does with the list differs:

- **Claude** defers MCP tools behind its own tool search. A session sees each tool's name
  only, and pays for a schema once the agent loads it. The app's tools cost a Claude agent
  almost nothing until it uses them, and `finish_turn` is the one every turn uses.
- **Grok** hides MCP tools behind `search_tool` too, so the app writes the tools into its
  rules instead (see [Why agents' own tools are taken away](scoped-tools.md)). That is about
  2,200 tokens, fixed for the session.
- **Codex, OpenCode, Gemini, Copilot, Cursor and Antigravity** send every listed schema
  with every request: about 8,900 tokens, against the 97 K a Codex turn reads on average.

A project's own MCP servers are added on top, in the same way for each runtime. They are
the person's choice, and they are not measured here. To measure one, list its tools
(`tools/list`) and count the bytes of the answer.

`ToolCostTests` holds the lead's list under 40,000 bytes, about a tenth over what it
measured. A new tool or a longer description that goes over says so in the tests, and the
ceiling is raised on purpose.

## What changed

**Keys in one order.** The app wrote its tool list, and every message it sends a runtime,
with each object's keys in the order the process happened to hash them. That order is
different every time the host starts. After a restart, an agent picked back up was sent
the same tools with their fields reordered. Where a runtime passes a schema on as sent,
that is a different prompt prefix, and the provider's cache misses on all of it. The app
now writes keys sorted, so the same tools are the same bytes in every process.

**Every turn's usage, kept per turn.** Each turn's usage was already recorded in the
transcript. `turns.jsonl` now carries it beside each turn too, added up when a turn
reports more than once, so turns can be compared without reading whole transcripts.
`scripts/turn-usage.sh --since DATE` compares runtimes from a date on, and `--turns` prints
one line per turn.

## What was left alone, and why

**No tool was taken off an agent.** Claude makes 88% of the turns measured and already
defers the app's tools. On the other runtimes, the largest cut that would not take away
something agents use, leaving `manage_workflows` off agents started by other agents,
saves about 2,150 tokens a request, about 2% of what a Codex turn reads, and it costs
an agent a tool it may be asked to use.

**The start of each prompt was already stable.** The briefing goes with the first prompt
only, and stays in the history from then on. What the app adds to a later prompt (a moved
folder, an edit to a live page, why a workflow started) comes in that prompt, after
everything already cached. Tools are listed in a fixed order, and plugin folders and MCP
servers are read in a fixed order. Nothing per turn goes into a system prompt. The one
thing that moved was the key order above.

**No compaction threshold was set.** An earlier threshold makes later requests smaller.
But each compaction is a model call over the whole history, and its result has to be
cached again. It also loses detail the agent may still need. Whether that is a net saving
depends on how long agents run after compacting, and no measurement shows it yet. With
usage now kept per turn, `scripts/turn-usage.sh --turns` can compare an agent's turns
before and after a compaction. The levers each runtime offers are in
[Compaction in each runtime](compaction-by-runtime.md).

## Related

- [Why agents' own tools are taken away](scoped-tools.md), for what each runtime keeps.
- [Tools the app gives agents](../reference/agent-tools.md), for the full list.
- [Compaction in each runtime](compaction-by-runtime.md).
