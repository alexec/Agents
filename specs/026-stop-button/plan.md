# Implementation Plan: Stop Is a Button, Like Archive

**Branch**: `026-stop-button` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

## Summary

The daemon's `agents/stop` is already complete: it cancels the turn, answers pending
permissions and forms as cancelled, withdraws a pending pick-up (and says `agent/resuming
false`), keeps queued prompts, and releases the runtime. Nothing in the daemon changes.

The work is three views and one predicate:

- `AgentsModel.canStop(_:)` in AgentsKitCore — `state.holdsRuntime || isComingBack` — the one
  place that decides which chats offer Stop (FR-003), read by both apps.
- Mac `ChatView` toolbar: a Stop item before Archive, `stop.circle`, ⌘. — stays on the page.
- Mac `AgentRow` context menu and phone `ChatMenu`: gate Stop on `canStop` rather than
  `holdsRuntime`, which picks up the coming-back case (FR-007).

## Technical Context

Swift 6 / SwiftUI, macOS app + iOS Remote app, shared AgentsKitCore. Tests with swift-testing in
`Packages/AgentsKit`. No new API, no model changes, no persisted data.

## Decisions

- **No confirmation** (FR-005): Archive has none either, and a stopped agent resumes on a prompt.
- **⌘.** is bound on the toolbar button itself, so it exists exactly when the button does (FR-009).
- **A coming-back chat keeps its `daemonGone` ending** when stopped; the daemon's note in the
  transcript is what records the person's stop. Spec amended to match.
- **Tooltip / accessibility**: "Stop this agent and stay on the chat".

## Verification

- Unit: `canStop` for every state, with and without coming-back.
- Build both schemes (Agents, Remote) with plugin validation skipped.
- Run the app on a scratch root (run-app skill), start a long turn, press Stop in the toolbar,
  screenshot: still on the chat, ended as stopped by you, no Stop button left.
