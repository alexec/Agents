# turns/

- `transcripts.json`: `TranscriptEntry.display` and `TranscriptDisplayBuilder`
  (`Model/TranscriptDisplay.swift`): chunks joined, tool runs and their updates, what is never
  drawn, passing lines, subagents; `omittingThoughts`; then `turns()` and `TurnParts`
  (`Model/OutcomePage.swift`): each turn's ask, outcome, step count, steps and live line.
- `lines.json`: `ToolCall.turnLine` (`Model/OutcomePage.swift`) and `ToolCall.line`
  (`Model/PermissionRequest.swift`).
