# Tasks: One Suggested Prompt

**Input**: [spec.md](spec.md), [plan.md](plan.md)

## Phase 1: Model and wire (US1, US4)

- [X] T001 [US4] Tests: finish_turn with `next_prompt` lands one; `next_prompts` of five keeps the first; both sent, `next_prompt` wins; old tool with nine keeps the first; schema has `next_prompt` and no `next_prompts` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AppServiceTests.swift`
- [X] T002 [US4] Test: a stored agent with three suggestions loads holding the first, in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/`
- [X] T003 [US1] `SuggestedPrompt.limit = 1`, and a helper reading the singular form, in `SuggestedPrompt.swift`
- [X] T004 [US4] Cut `suggestedPrompts` to the limit on decode in `Agent.swift`
- [X] T005 [US1] `finish_turn` schema, description and handler read `next_prompt` then `next_prompts`; old tool drops `maxItems`, in `AppService.swift`
- [X] T006 [US1] Briefing asks for one next thing, in `Briefing.swift`
- [X] T007 [US1] Daemon reply wording for one, in `DaemonCore+AppTools.swift`
- [X] T008 Update tests that expected two or more to expect the first (`FinishTurnTests`, `SuggestedPromptTests`, `AppServiceTests`, `BriefingTests` if any)

## Phase 2: Mac (US2)

- [X] T009 [US2] Remove `selectedSuggestion`/`cycleSuggestion`; arrows no longer act on the suggestion, in `App/Sources/Chat/PromptBar.swift`

## Phase 3: Phone (US3)

- [X] T010 [US3] One chip, no scroller, label truncated, in `Remote/Sources/Chat/PromptBar.swift`

## Phase 4: Verify

- [X] T011 `swift test` in `Packages/AgentsKit`, compared against main for flakes
- [X] T012 Build both schemes with xcodebuild
- [X] T013 Run the scratch app, end a turn with several suggestions over daemon.sock, screenshot the Mac field
