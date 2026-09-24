# Quickstart: proving it survives

Five things to check, one per story. Each is runnable without a phone in the room except
where it says otherwise.

## Prerequisites

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
swift test --package-path Packages/AgentsKit
```

`-skipPackagePluginValidation` is not optional: SwiftTerm ships a build-tool plug-in and
`xcodebuild` has nobody to ask about it, so without the flag it fails with three
unexplained build commands. Build the schemes one at a time.

To drive the app itself, use the `run-app` skill under `.claude/skills` — it launches a
copy on a root of its own so none of this touches the real daemon or its agents.

---

## 1. The phone is not told twice (US1)

**By test** — `AttentionTests`, across a restart:

```sh
swift test --package-path Packages/AgentsKit --filter Attention
```

The new case builds a core on a temporary root, lets a need be delivered and alerted to a
fake surface, drops that core, builds a second on the same root, and expects: the need is
outstanding, the delivery is the same surface, `alertCount` has not moved, and `raisedAt`
is the original time rather than the new core's clock.

**By hand**:

```sh
# Let an agent finish with an outcome that needs a person, then:
cat "$ROOT/attention.json"
```

Expect a `raised` entry and a `deliveries` entry for it. Stop the daemon, start it again,
and expect no fresh notification and the same `alertedAt`.

---

## 2. A banner for a question that died comes down (US2)

**By test** — `AttentionTests`, with a `FakeMailbox`:

Hold a permission, let it be delivered to a fake device, drop the core, build a second on
the same root, and expect a withdrawal — a `MailboxItem` with a `nil` envelope for that
need id — to have been posted. Then the test asserts the note is gone from the file.

A second case asserts the retry: with nothing connected and no mailbox, the withdrawal
stays in `withdrawing` and goes out on the next `reconsider()` once a connection exists.

**By hand, with a phone**: put a question in front of the phone, kill the daemon, and watch
the banner clear without opening the app. This is the one check that needs a device.

---

## 3. A workflow chain survives (US3)

**By test** — `WorkflowFiringTests`:

```sh
swift test --package-path Packages/AgentsKit --filter Workflow
```

Fire a workflow whose agent is still working, confirm `workflows.json` has it under
`runs`, build a second core on the same root, let the agent finish, and expect the
workflow chained on its completion to fire. A second case asserts the depth: a chain three
deep, restarted in the middle, still stops at the ceiling rather than starting again at
zero.

**By hand**:

```sh
cat "$ROOT/workflows.json" | python3 -m json.tool
```

Expect `runs` to hold the firing while its agent works, and to be empty once it is done.

---

## 4. The conversation says nobody answered (US4)

**By test** — `UnansweredQuestionTests`, three cases: the runtime exits, the person stops
the agent, the daemon restarts. Each expects a `runtimeNote` with the closing wording,
positioned after the `permissionAsked` entry and before the `stateChanged` one.

**By hand**:

```sh
grep -n "Nobody answered" "$ROOT/agents/<uuid>/transcript.jsonl"
```

Then open the conversation and scroll to it. The line must still be there after the
ending line — if it vanishes, it has been added to `RuntimeNote.isPassing` and should not
have been.

---

## 5. What you had typed is still there (US5)

**By test**:

```sh
swift test --package-path Packages/AgentsKit --filter Draft
```

`DraftStoreTests` covers the rules rather than the view: a draft round-trips; it is gone
after being cleared; it is gone once its conversation is archived; it is gone thirty days
on; a draft carrying more inline data than the cap keeps its text and its by-reference
attachments and says it dropped the rest.

**By hand**, which is the only way to check the view:

1. Launch on a scratch root with the `run-app` skill.
2. Type three paragraphs into the prompt bar without sending. Drag a file in.
3. Quit the app. Open it again on the same root.
4. The paragraphs and the file are there.
5. Send it. Quit and reopen. Nothing is restored — a draft ends when it becomes a prompt.

---

## The whole suite

```sh
swift test --package-path Packages/AgentsKit
```

This suite is broadly flaky under load. A failure that appears once is not evidence; run
it several times on this branch and on `main` before concluding the branch did it.
