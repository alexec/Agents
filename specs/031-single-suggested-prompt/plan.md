# Implementation Plan: One Suggested Prompt

**Branch**: `031-single-suggested-prompt` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

## Summary

A conversation holds at most one suggested prompt. The ceiling that was four becomes one, and every
place that took the first four now takes the first one. The agent is told to send one, in a new
singular `next_prompt` field; the old list forms are still read, first usable entry kept.

## Technical Context

Swift 6, SwiftUI (macOS app, iOS Remote), AgentsKit package. Tests: `swift test` in
`Packages/AgentsKit`. No new dependencies.

## Decisions

- **The wire stays a list.** `Agent.suggestedPrompts`, `FinishTurnRequest.prompts` and
  `SuggestPromptsRequest.prompts` stay arrays, capped at one. Changing their type would break a phone
  and a daemon on different builds (FR-012); a list of at most one is read by both.
- **`SuggestedPrompt.limit` becomes 1.** `list(in:)` and both daemon doors already cut to it, so
  the old forms keep the first usable entry with no new code (FR-004).
- **Stored records are cut on load.** `Agent.init(from:)` keeps only the first (FR-006).
- **`finish_turn` gains `next_prompt`**, a single object, and loses `next_prompts` from its schema.
  The handler reads `next_prompt` first and falls back to `next_prompts` (FR-005). Its description
  and the briefing ask for one (FR-002, FR-003).
- **`suggest_next_prompts` keeps its `prompts` list** with no `maxItems`, so a resumed conversation
  sending four is not refused by a runtime validating against the schema.
- **Mac**: `selectedSuggestion` and `cycleSuggestion` go; the arrow handlers stop consulting the
  suggestion (FR-008). **Phone**: `SuggestionRow` becomes one chip, no scroller, label truncated
  to the width (FR-009).

## Files

- `Packages/AgentsKit/Sources/AgentsKitCore/Model/SuggestedPrompt.swift` — limit, `first(in:)`.
- `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift` — cut on decode.
- `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift` — schema, description, handler.
- `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` — the finish line.
- `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift` — reply wording.
- `App/Sources/Chat/PromptBar.swift`, `Remote/Sources/Chat/PromptBar.swift` — UI.
- Tests under `Packages/AgentsKit/Tests/AgentsKitTests`.
