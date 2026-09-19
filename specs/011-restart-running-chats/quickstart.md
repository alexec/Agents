# Quickstart: validating a restarted daemon picking up running chats

How to prove each user story works, in the order they ship. Every scenario is runnable without a
real runtime, a credential or a network: `DaemonCore`'s `SessionLauncher` is injectable, and
`Integration/DaemonTests.swift` already drives recovery end to end through `FakeLauncher` against a
temporary root.

## Prerequisites

```sh
xcodegen generate      # after editing project.yml
swift test --package-path Packages/AgentsKit
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

Tests are Swift Testing (`import Testing`) under `Packages/AgentsKit/Tests/AgentsKitTests`, split
`Unit` / `Integration` / `Live` / `Fake`. The pick-up eligibility rule is pure and belongs in
`Unit`; everything that drives `DaemonCore` belongs in `Integration`, beside the four recovery
tests that are already there.

Run a second app against a throwaway root so nothing touches your real chats:

```sh
open Agents.app --args --root /tmp/agents-restart-test
```

To interrupt the daemon the way a crash does — no shutdown, no cleanup:

```sh
kill -9 "$(cat /tmp/agents-restart-test/daemon.lock)"
```

The throwaway root's own `daemon.lock` holds that daemon's pid and nobody else's, which is what
makes this safe to run. **Do not** reach for a pattern kill such as `pkill -9 -f 'Agents.*daemon'`:
the ordinary daemon is the same `agentsd` binary under a different root, so a pattern wide enough
to find this one is wide enough to find that one, and you will take down the chats you were
actually working in along with the ones you meant to interrupt.

Anything gentler lets the daemon shut down cleanly, which is a different code path and will not
reproduce any of this.

---

## Story 1 — The work you left running is still running

### By hand, in the app

1. Start a chat on a job long enough to still be running in a minute — "list every file under this
   folder and summarise each one" against a large repository will do.
2. While it is working, `kill -9` the daemon.
3. Reopen the app.
4. The chat is working again, in the same conversation, without you typing anything. Its transcript
   has the interruption in it and then carries on.

Repeat with a chat that has stopped to ask a permission question: it comes back too.

### In tests

Extends `anAgentFoundDeadOnStartUpIsPickedBackUpAndToldWhy` and
`anAgentWaitingOnAnAnswerIsToldItsQuestionWentWithTheDaemon`, both of which pass today.

- `severalInterruptedAgentsAreAllPickedBackUp` — save three `.running` agents, `recover()`, expect
  three launches and three that reach `.finished`.
- `theyComeBackMostRecentlyActiveFirst` — save three with staggered `lastActivityAt`, assert
  `FakeLauncher` saw them in that order.
- `agentsComingBackHoldTheDaemonOpen` — with a pick-up pending and no connections, `shouldExit` is
  false. Passes today via `resuming`.

---

## Story 2 — Nobody is told anything untrue

### By hand

1. Interrupt a chat as above and reopen the app.
2. Before it starts working, its row reads **"Coming back after a restart"** — not "Stopped", and
   not a blank that flickers into "Working".
3. Open it. The transcript says, at the break, that it stopped because the app did; below that, in
   brackets and visibly the app's voice, the words telling the agent the turn was cut off.
4. Check the same chat on the phone. It says the same thing.

### In tests

- `anAgentOnItsWayBackUpIsBroadcastAsResuming` — a broadcaster stub collects `agent/resuming`;
  expect `true` for every id before the first launch and `false` after each.
- `aWindowConnectingLateIsToldWhatIsStillComingBack` — call `agents/resuming` mid-batch, expect the
  ids not yet picked up.
- The row saying the same thing on both platforms needs no test: no test target reaches `App/` or
  `Remote/`, and `AgentsModel.comingBackDescription` and `.comingBackSymbol` are the one copy that
  `AgentRow`, `AgentCard`, `Transcript` and `RemoteChatView` all read. There is no second switch
  to drift from.
- `anOlderClientIgnoresTheResumingNotification` — `AgentsModel.apply` returns `false` for an unknown
  method, which is the existing documented behaviour; assert `agent/resuming` is claimed.

---

## Story 3 — A chat that cannot come back says so

### By hand

1. Interrupt a chat, then move or rename the runtime binary it was using.
2. Reopen the app. The chat stays stopped and its transcript says it could not be picked back up
   and why.
3. Put the runtime back and send the chat a message. It starts, and **nothing about a restart is
   sent along with your words**.

### In tests

`anAgentWhoseRuntimeHasGoneIsLeftAloneWithAnExplanation` covers this today, including that the
queue is left empty. Add:

- `oneFailureDoesNotStopTheRest` — three agents, the middle one on a missing runtime; the other two
  still reach `.finished`.

---

## Story 4 — No stampede, no loop

### By hand, the stampede

1. Leave five chats working. `kill -9` the daemon. Reopen.
2. The rows light up one after another, not together. The app stays responsive and you can open any
   chat while the rest are still coming back.

### By hand, the loop

Hard to stage by hand — it needs a chat whose work reliably kills the daemon. Do it in tests. What
you *can* check by hand is the shape of it: interrupt a chat, reopen, and while it is coming back
`kill -9` the daemon again. On the third start the chat stays stopped and says it was picked back
up last time and did not get to the end of a turn.

### In tests

- `theyAreStartedOneAtATime` — every fake runtime takes a known time to shake hands and
  `FakeLauncher` timestamps each launch; expect every gap to be at least that long, which two
  starting at once could not be.
- `anAgentCutOffTwiceInARowIsNotPickedUpAThirdTime` — save an agent with `restartPickUps == 1`,
  `.stopped`, `daemonGone`; `recover()` then `pickUpAfterRestart`; expect zero launches and the
  limit line in the transcript. **New behaviour.**
- `aTurnThatEndsClearsTheCount` — pick one up, let it finish, assert `restartPickUps == 0` and that
  it is eligible again.
- `anEndingThatIsNotAFinishAlsoClearsTheCount` — the same with a `maxTokens` ending: it still got
  to the end of a turn.
- `theCountIsWrittenBeforeTheWordsAreSent` — a runtime that takes seconds to shake hands, so the
  pick-up is demonstrably still in flight; assert the saved record already
  shows `1`. This is the one that makes the guard survive a crash mid-pick-up.
- `Unit/AgentPickUpTests.swift` — exhaust `mayBePickedUpAfterRestart` over every `AgentState` ×
  `EndedReason` × `restartPickUps ∈ {0, 1, 2}`.

---

## Story 5 — Only what was cut off comes back

### By hand

Leave four chats: one working, one you stop yourself, one that finished, one archived. `kill -9`,
reopen. Exactly one of them is working afterwards.

### In tests

- `onlyInterruptedAgentsArePickedBackUp` — save one of each of `.running`, `.waitingOnUser`,
  `.finished`, `.stopped`/`cancelled`, `.archived`; expect exactly two launches.
- `anAgentWhoseProcessDiedIsNotPickedBackUp` — `.stopped` with `processDied`; expect none. That
  ending was already reported to the person at the time.

---

## The two cases that are easy to get wrong

### Words queued before the crash

1. Start a chat working, and while it works type another message so it queues behind the turn.
2. `kill -9` the daemon. Reopen.
3. The chat comes back, is told about the restart **first**, and only then receives what you typed.

In tests: `anAgentWithWordsAlreadyQueuedIsStillPickedBackUp` (the `queuedPrompts.isEmpty` guard
used to abandon it) and `theRestartWordsGoAheadOfWhatWasQueued`, asserting
the order the `FakeLauncher` saw them.

### Stopping a chat before it comes back

1. Interrupt several chats so there is a queue, and reopen the app.
2. Press Stop on one that has not started yet.
3. It stays stopped, says you stopped it before it was picked back up, and does not start.

In tests: `stoppingAnAgentBeforeItIsPickedUpWithdrawsIt` — assert no launch for it, that it is gone
from `resuming`, and that `shouldExit` is not held open by it once the rest are done.

---

## Whole-feature check

With everything in:

```sh
swift test --package-path Packages/AgentsKit --filter DaemonTests
swift test --package-path Packages/AgentsKit --filter AgentPickUpTests
```

Then, in the app against a throwaway root: five chats working, `kill -9`, reopen, and inside a
minute every one of them is either working again or carrying a line saying why not — which is
SC-001, and the only measurement this feature really turns on.

## Not covered here

Spending limits (FR-019). `010-cost-limits` is specified and not yet built. When it lands, add one
test asserting that a pick-up refused for cost reads in the chat as a refusal rather than a crash —
the path is already there, because a pick-up is an ordinary prompt and `pickUp` already catches and
reports what `prompt` throws.
