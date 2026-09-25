# Quickstart: Checking That 039 Works

Everything here runs in the worktree `.agents/worktrees/039-blocked-status`. Nothing touches the
shared checkout or the real daemon.

## 1. Package tests

```sh
cd Packages/AgentsKit && swift test
```

These should pass, and the new tests should cover:
- **Model**: `WorkOutcome.blocked` is not `needsAPerson`. A record whose outcome is a word this
  build doesn't know decodes with `report == nil`, and the rest of the agent is intact. Counts
  with an unknown key decode, and that key is dropped (research R8).
- **Grouping**: exhaustive over state × eyes × report × outcomeAsked. A finished agent with an
  open block is `.blocked`. With a cleared block it is `.finished`. With eyes, `.needsAttention`.
  Stopped and archived ignore the block. `AgentGroup.live` has `.blocked` second.
- **Refusals** (contract §2): each row refuses and writes nothing. That includes a circle of
  three, and a named agent that is finished but itself blocked, which is accepted.
- **Two helpers, one resume** (US1): a parent blocks on two fake-runtime helpers. After the
  first finishes, nothing is queued, and one of the two waits has an ending. After the second,
  exactly one `.app` prompt goes out and names both outcomes and messages. Finishing both
  helpers in the same actor turn still produces one resume (SC-002).
- **Silent helper**: a helper that ends silently closes the wait only after the app's question
  turn ends, and not before.
- **Person clears** (US3): the person prompts a blocked agent, and a helper finishes later.
  Nothing is sent.
- **Stop and archive** (FR-017): stopping a finished blocked agent moves it to `stopped`
  through `stoppedWaiting`. Archiving drops the block. Neither is resumed later.
- **Time** (US4): `tickWorkflows(now:)` with `now` past `checkAgainAt` resumes it once, and a
  second tick sends nothing. Minutes 0 and 1441 are refused.
- **Restart** (FR-020): write a block, stop the core, mark the helper finished in the store,
  rebuild the core, and `recover()`. That gives one resume. Then do the same with the resume
  already queued before the "crash", which must give no second one.
- **Resume can't start** (FR-018): a runtime that fails to start, or a cost limit reached,
  leaves the agent `finished` with a `stuck` report giving the reason, and an empty queue.

## 2. Builds

Both schemes, one after the other, with plugin validation skipped (memory: xcodebuild needs
plugin-validation skipped):

```sh
xcodegen generate
xcodebuild -scheme Agents -configuration Debug -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation build
```

## 3. End to end on a scratch daemon (run-app skill)

Launch this worktree's build on a scratch root with a scratch project, using the `run-app` skill.

1. **UX gate (phase 2)**: before the daemon logic exists, hand-write a blocked report onto an
   agent in the scratch store and launch. Screenshot the project page. The Blocked section
   should sit between Needs attention and Working. The row should show the message, one line
   per wait, the time to check again, and Carry on. The project's Needs attention count should
   not include it. Settle this before building phase 4.
2. **US1**: start an agent with *"Start two agents: one that sleeps 20 seconds then lists the
   files here, one that sleeps 40 then counts them. Then finish your turn blocked on both."*
   The parent should go to Blocked, naming both helpers, with neither finished yet. At about
   20 s one line should show finished. At about 40 s the parent should get an app-marked
   prompt naming both outcomes, and go to Working. Screenshot each of the three moments.
3. **US2**: while the parent is blocked, have a second agent end with `needs_answer`. Only the
   second should notify (check `attentionPending` on the scratch socket), and the project's
   count should be 1.
4. **US3**: block a parent on a 60 s helper, then press Carry on (by AX press, per memory). The
   parent should run the Carry on prompt. When the helper finishes, nothing more should be
   sent.
5. **US4**: have an agent end blocked with `check_again_in_minutes: 1` and no waits. The row
   should show the time, and it should be resumed once within about 75 s.
6. **Refusals**: ask an agent to block on itself, then on an archived agent. Both should be
   refused, and the agent should read the refusal and carry on.

Stop the scratch app when done (the run-app skill covers how). Never kill `agentsd` by name.

## 4. Phone and iPad

Build Remote for the generic simulator only (memory: no throwaway simulators). How the Blocked
section and Carry on look on the phone and iPad is for Alex to walk.
