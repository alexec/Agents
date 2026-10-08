---
diataxis: explanation
description: Whether each runtime compacts a long conversation on its own when the app starts it, and what the app would pass to change that (#395).
devices: [mac, server]
---

# Compaction in each runtime

A long conversation eventually fills the model's context. Compaction is how a runtime keeps
going: it replaces the older part of the conversation with a shorter record. Gemini calls
it compression and Cursor calls it summarization. This page records, for each runtime the
app can start, three things:

- whether compaction happens on its own when nothing is set;
- what the app sees when it happens;
- what the app could pass to change it without touching your own settings files.

Read on 2026-10-08 for #395, from the source or binary of the exact copy the app runs.
No conversation was run long enough to compact, so no allowance was spent. That means
**nothing here has been watched happening**: where a line says *inferred*, it comes from the
code, not from a run.

## In short

**Every runtime compacts on its own, with nothing set.** None of them needs anything from
the app to turn it on, so the app does not have to change to keep a long agent going.

They differ in what the app sees:

- **Claude and Codex** tell the app, with ACP's `compaction_update`. The app asks for this by
  advertising `session.compaction`.
- **Grok** tells it in a message of its own that the app does not read.
- **OpenCode** shows its summary as ordinary agent text (inferred).
- **Gemini, Copilot, Cursor and Antigravity** say nothing. At most, the context meter drops.

| Runtime | Version read | On with nothing set | When it fires | What the app sees | `/compact` over ACP | Lever the app could use |
| --- | --- | --- | --- | --- | --- | --- |
| **Claude** | adapter 0.85.1, Claude Code 2.1.286 | Yes (`autoCompactEnabled`, default on) | About 83% of a 200K window (window − min(max output, 20K) − 13K) | `compaction_update` with a streamed summary, then a `usage_update` that resets the meter | Yes, advertised | `_meta.claudeCode.options.settings.autoCompactEnabled` / `autoCompactWindow` |
| **Codex** | codex-acp 1.13.1, Codex 0.156.1 | Yes, with no off switch | 90% of the window: 244,800 of 272,000 tokens for every bundled model | `compaction_update` with status only, no summary | Yes, advertised | `model_auto_compact_token_limit` (lower only) and `compact_prompt` in `CODEX_CONFIG` |
| **Gemini** | 0.61.0 | Yes (`model.compressionThreshold`, 0.5) | Half the window: about 524K of 1M tokens | Nothing over ACP | No: `/compress` is in its terminal only | `model.compressionThreshold` in the app's system defaults file. 1.0 is in effect off; 0 is not off. |
| **Antigravity** | agy-acp-server 1.2.1 | Yes, in its Go harness | Its backend's default, not readable. A forum measurement puts it at about 220–260K. | Nothing over ACP | No | None: the ACP server reads no compaction setting |
| **Grok** | 1.0.46 | Yes ("auto-compact") | 85% by its docs; its bundled grok-4.5 and 4.6 say 80% | Its own `auto_compact_*` updates in `x.ai/session_notification`, which the app drops as unknown | Yes, advertised | `GROK_AUTO_COMPACT_THRESHOLD_PERCENT`, `GROK_COMPACTION_MODE`. There is no off switch. |
| **OpenCode** | 1.18.33 | Yes (`compaction.auto`, default on) | When the usable window is full: the input limit minus up to 20K reserved | The summary as agent text, then a "continue" turn (inferred). No `compaction_update`. | Works, but not advertised | `compaction.*` in `OPENCODE_CONFIG_CONTENT`; `OPENCODE_DISABLE_AUTOCOMPACT` to turn it off |
| **Copilot** | 1.0.93-1 | Yes ("infinite sessions") | Background from 80%, blocking at 95% | Nothing over ACP but a falling `usage_update` (inferred) | Yes, since 1.0.39 | Undocumented `COPILOT_BACKGROUND_COMPACTION_THRESHOLD`, `COPILOT_BUFFER_EXHAUSTION_THRESHOLD`; no off switch ([copilot-cli#2333](https://github.com/github/copilot-cli/issues/2333)) |
| **Cursor** | 2026.10.01-e373342 | Yes (summarization) | Its backend decides; not in the client | Nothing: its ACP layer drops `summary_*` updates, and it sends no `usage_update` | No: `/summarize` is in its terminal only | None |

**What the app sets today:** nothing about compaction, for any runtime. It does not strip
anything that would turn compaction off.

One small exception: the app removes every `CLAUDE_*` variable of your shell, so
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from your shell do
not reach Claude. `DISABLE_AUTO_COMPACT` does reach it, and so do your own settings files.

## What the app shows

The app advertises `session.compaction` (`ClientCapabilities.app`, `ACPTypes.swift`).
Both updates it asks for are ACP **unstable**: the ACP SDK marks them "not part of the spec
yet".

A runtime sends one compaction as several updates under one `compactionId`: one when it
starts, the chunks of its summary, and one when it ends. The record keeps each of them. The
page draws them as **one row** (#443), which says how the compaction stands:

- **Summarising the conversation so far…** while it runs;
- **Made room by summarising the conversation so far** when it is done;
- **Could not summarise the conversation to make room**, with the runtime's reason, when it
  failed;
- **Stopped summarising the conversation** when it was cancelled.

The summary sits under the row. A summary sent with the ending replaces the chunks, as ACP
says it should. A record written before #443 has no ids, and its updates are joined while
the row is still in progress.

Codex's rows have no summary under them, because Codex sends none. That is right as it is.

## Runtime by runtime

### Claude

- **Default.** `autoCompactEnabled` is on unless `DISABLE_COMPACT` or `DISABLE_AUTO_COMPACT`
  is set. On 1M models, a 200K boundary may apply unless the model is natively 1M.
- **Lever.** The adapter passes `_meta.claudeCode.options.settings` as Claude Code's
  flag-settings tier. It sits above your user, project and local settings, and only managed
  policy beats it. So `{autoCompactEnabled: false}` or `{autoCompactWindow: N}` (100K–1M)
  would set it for one agent. The same `_meta` can also carry `env`, but your settings
  file's own `env` block is applied after it.
- **Over ACP.** `compaction_update` `in_progress`, then `compaction_summary_chunk`s, then
  `completed`, `failed` or `cancelled` with a `summary`. It also sends a `usage_update` with
  the token count after compaction. A loaded session replays an old compaction as a
  completed update.
- **What is kept.** Earlier turns, tool results included, become a summary written by the
  model. Claude Code then attaches references to the plan file, the skills already used and
  the files touched again, and it can keep a recent tail word for word.

### Codex

- **Default.** On for every model, and it cannot be turned off. It fires at 90% of the
  context window, or a lower `model_auto_compact_token_limit`, before a turn and in the
  middle of one. A compaction at the end of a turn is off by default
  (`model_post_turn_compact_threshold_percent` 0).
- **Lever.** Keys added to the `CODEX_CONFIG` the app already sends, which today holds only
  `features.*`. That reaches servers too.
- **Over ACP.** `compaction_update` `in_progress`, then `completed`, `failed` or
  `cancelled`, with no summary.
- **What is kept.** Local compaction keeps the opening context and about 20K tokens of
  recent *user* messages, then a summary. Assistant turns, tool calls and tool output are
  dropped. With a ChatGPT sign-in, compaction happens on OpenAI's side and comes back as an
  encrypted item, so what it keeps cannot be read.

### Gemini

- **Default.** Before every turn, it compresses once the last prompt reached
  `compressionThreshold` × the model's limit: 0.5 × 1,048,576. Apart from that, every turn
  masks old tool output beyond 50K protected tokens, whatever the threshold.
- **Lever.** The app already writes `gemini-system-defaults.json` and passes it in
  `GEMINI_CLI_SYSTEM_DEFAULTS_PATH`; today it holds only the context file names. Adding
  `"model": {"compressionThreshold": X}` there changes the default, and your own setting
  still wins. A value of 0 counts as unset; 1.0 is in effect off.
- **Over ACP.** Nothing. `ChatCompressed` falls through the ACP loop's `default`. A
  `PreCompress` hook does fire. An overflow ends the turn as `max_tokens`.
- **What is kept.** About the newest 30% of the history word for word. The rest becomes a
  `<state_snapshot>` written by the model. Large tool output is cut down to a stub that
  points to a file in its temp folder.

### Antigravity

- **Default.** Compaction runs in its Go harness at the backend's default threshold.
- **Lever.** None. Its SDK has `CompactionConfig(token_threshold)`, but the ACP server never
  sets it, reads only `auth` and `gcp` from its settings file, and uses `_meta` only for
  sign-in. People have asked for one
  ([antigravity-cli#1072](https://github.com/google-antigravity/antigravity-cli/issues/1072)).
- **Over ACP.** Nothing. The adapter registers no compaction hook, and `/plan` and `/logout`
  are its only commands.
- **What is kept.** Its summary prompt asks for six sections: outstanding requests, the
  user's own words, work done, model knowledge, files and code, and next steps. It may skip
  large code blocks, and the summary can be truncated.

### Grok

- **Default.** It compacts at 85% of the window by default (`[session]
  auto_compact_threshold_percent`), or at a model's own figure: 80 for grok-4.5 and 4.6.
  Its default mode is `segments`.
- **Lever.** `GROK_AUTO_COMPACT_THRESHOLD_PERCENT` in the launch environment. A `[session]`
  key in the app's `GROK_CONFIG_PATH` overlay may also work, but only `[features]` has been
  measured there. There is no off switch; whether 100 turns it off in effect is unverified.
- **Over ACP.** `auto_compact_started`, `completed` (tokens before and after, a summary
  preview), `failed` and `cancelled`, inside the extension notification
  `x.ai/session_notification`. The app reads only `_x.ai/billing`, so these are dropped.
  This comes from its embedded docs; it has not been seen on the wire.
- **What is kept.** Tool-result pruning is on: the last 3 turns are kept, results over 4,000
  characters are trimmed to their first and last 1,500 characters, and results older than
  10 turns become a placeholder. Before compacting, it writes a summary to its memory.
  Segment checkpoints are saved under the session's `compaction_checkpoints/`.

### OpenCode

- **Default.** `compaction.auto` is on. It also compacts on the provider's context-overflow
  error. `compaction.prune` is off.
- **Lever.** `"compaction": {"auto": …, "prune": …, "reserved": …}` in the
  `OPENCODE_CONFIG_CONTENT` the app already sends, above your `opencode.json`. To turn it
  off, `OPENCODE_DISABLE_AUTOCOMPACT=1`, which wins over every file. With it off, an
  overflow ends the turn as an error.
- **Over ACP.** No compaction update: the ACP layer does not forward `session.compacted`.
  The summary is an assistant message, so it should stream as ordinary agent text, followed
  by more text after OpenCode adds a hidden "continue" prompt (inferred). A typed `/compact`
  works over ACP but is not in its advertised commands.
- **What is kept.** The summary prompt cuts each tool result to 2,000 characters and keeps a
  recent tail word for word. With pruning on, older tool output reads "[Old tool result
  content cleared]".

### Copilot

- **Default.** "Infinite sessions" is on. It compacts in the background from 80% of the
  window and blocks at 95%. Each compaction saves a checkpoint. `--context long_context`
  moves the window from about 200K to 1M.
- **Lever.** None documented. Its SDK's `infiniteSessions.enabled` is for SDK sessions only.
  The binary names `COPILOT_BACKGROUND_COMPACTION_THRESHOLD` and
  `COPILOT_BUFFER_EXHAUSTION_THRESHOLD`, which are untested.
- **Over ACP.** Its `session.compaction_start` and `compaction_complete` events map to no ACP
  update (inferred), so only the meter falls. `/compact [focus]` is offered over ACP.
- **What is kept.** Goals, actions, key details, files and next steps. Your latest prompt,
  skills and extended thinking are kept too. Exact wording and full command output are
  lost. A `preCompact` hook runs first and cannot stop it.

### Cursor

- **Default.** Cursor's backend summarizes when the window fills; the client holds no
  threshold. A `preCompact` hook runs first.
- **Lever.** None: no setting, environment variable or ACP option.
- **Over ACP.** Nothing. `presentInteractionUpdate` has no case for `summary_started`,
  `summary` or `summary_completed`, and the ACP layer sends no `usage_update` at all.
  `/summarize` is in its terminal only.
- **What is kept.** It is lossy. The agent keeps a reference to a chat-history file it can
  search, and your latest message is kept word for word (since 2026.07.06).

## On servers

The levers above travel with the launch, so they reach a server too: `_meta` for Claude,
`CODEX_CONFIG`, the Gemini defaults file, `OPENCODE_CONFIG_CONTENT`, and environment
variables for Grok and Copilot. On a server, the runtime's own settings files are the
server's.

Antigravity runs on this Mac only.

## What this leaves open

- **Watching it happen.** The table comes from reading code. A compaction has not been seen
  in the app for any runtime. Claude and Codex can be watched cheaply by typing `/compact`
  in an agent. That also shows the one row (#443) on screen.
- **Whether to change any defaults.** Nothing needs turning on. Whether the app should *show*
  a switch or a threshold is a product decision. These have a lever the app can reach:
  Claude, Codex (threshold only), Gemini, Grok (threshold only), OpenCode and Copilot
  (untested). Antigravity and Cursor have none.
- **Showing the silent ones.** The app could draw Grok's own updates. For the others, it
  could only infer a compaction from a sudden drop in the context meter, and Cursor does
  not even send the meter.
