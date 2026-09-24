# Tasks: Stop Is a Button, Like Archive

**Input**: [spec.md](spec.md), [plan.md](plan.md)

## Phase 1: Foundational

- [X] T001 Add a failing test for `canStop` across every state and the coming-back case in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentsModelTests.swift`
- [X] T002 Add `AgentsModel.canStop(_:)` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`; expose it on `AppModel` and `RemoteModel`

## Phase 2: User Story 1 — Stop the chat you are reading (P1)

- [X] T003 [US1] Add the Stop toolbar item before Archive in `App/Sources/Chat/ChatView.swift`, gated on `canStop`, staying on the page

## Phase 3: User Story 2 — Stop a chat that is coming back (P2)

- [X] T004 [P] [US2] Gate the card menu's Stop on `canStop` in `App/Sources/AgentList/AgentRow.swift`
- [X] T005 [P] [US2] Gate the phone chat menu's Stop on `canStop` in `Remote/Sources/Chat/RemoteChatView.swift`

## Phase 4: User Story 3 — Stop from the keyboard (P3)

- [X] T006 [US3] Bind ⌘. to the toolbar Stop in `App/Sources/Chat/ChatView.swift`

## Phase 5: Polish

- [X] T007 Run `swift test --filter AgentsModelTests`
- [X] T008 Build the Agents and Remote schemes
- [X] T009 Run the app on a scratch root and confirm Stop in the toolbar stops a working chat without leaving it
