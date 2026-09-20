# Quickstart: What Every Agent Is Told

Three ways to check this, in order of how much they prove. The fakes settle whether the words are
sent correctly; only the live runs settle whether they work, and working is the entire point of the
feature.

## Prerequisites

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

For the live section you also need at least one runtime signed in and on the path — `claude`,
`copilot`, `grok` or `cursor-agent` — and the built helper:

```sh
HELPER=./build/DD/Build/Products/Debug/Agents.app/Contents/Helpers/agentsd
```

---

## 1. The block itself (seconds)

```sh
swift test --package-path Packages/AgentsKit --filter Briefing
```

Expect: every line present in the block, the two app tools named exactly as an agent will find them,
the escalation line naming no tool at all, and the block inside its ceiling.

The ceiling test is the one worth understanding rather than just passing. It is there because an
agent told six things at once follows the first two, and that failure is silent — so when 014 raises
it, the raise should come with a reason.

---

## 2. When it is sent (seconds)

```sh
swift test --package-path Packages/AgentsKit --filter Suggest
```

Four claims, all against fakes, all fast:

| Test | What it settles |
|---|---|
| `theRuntimeIsAskedForThemWhenTheConversationStarts` | The first prompt carries the block, after the person's words |
| `andNotAgainOnEveryPromptAfterThat` | The second prompt carries nothing of ours |
| `aRuntimeThatLostTheConversationIsAskedAgain` | Both prompts carry it when the runtime has forgotten the first conversation |
| `whatWeAddIsNotWhatTheRecordSays` | The transcript holds the person's words alone |

The last one is the one to run before believing any of the others. A briefing that leaks into the
record turns the transcript into an account of something that did not happen.

Then the whole suite, because the rename touches the daemon's turn path:

```sh
swift test --package-path Packages/AgentsKit
```

---

## 3. Whether it actually works (tens of minutes, real money)

```sh
AGENTS_LIVE=1 AGENTS_MCP_HELPER=$HELPER swift test --package-path Packages/AgentsKit --filter Live
```

This is where SC-001 and SC-002 live, and it is the only part of this feature that can fail in an
interesting way. Everything above checks that we said the words; this checks whether saying them
changed anything. A failure here is news about somebody else's software, not a bug in ours —
`SuggestedPromptLiveTests` already carries its findings in its own doc comment, and this suite should
carry its findings the same way.

**The escalation run.** Give an agent a task with two defensible answers and no stated preference —
the standing example is a schema change where the index can be dropped first or last, and one order
is slow to undo. Then watch for which of three things happens:

1. A question reaches the daemon and is held for the person. **This is the feature working.**
2. The agent picks one and says which. This is the failure the feature exists to prevent, and if it
   survives the briefing on a given runtime, that is the finding to write down.
3. The agent ends its turn with the question written into its reply. Half-working: it knew to ask
   and not where to ask.

**The workflow run.** Ask for something recurring — "check the build every morning and tell me if it
is red". Watch for `manage_workflows` being called and the person being asked to approve. A shell
script, a cron line in a comment, or a launch agent is the failure, and it is worth capturing
verbatim, because the agent will usually also report that the job is set up.

**The restraint run.** Ask for something ordinary that nobody asked to be repeated, and confirm no
workflow appears. This is the half of the reversal in [research.md](./research.md) that has to hold
for the other half to be safe.

---

## 4. By hand, in the app

```sh
open Agents.xcodeproj    # run, or:
open ./build/DD/Build/Products/Debug/Agents.app
```

1. Start an agent in any project and send one prompt.
2. Read the transcript. You should see **your words and nothing else** — no instructions, no
   housekeeping, nothing attributed to you that you did not type.
3. Ask it for something recurring. The workflow confirmation should come up in plain words, the same
   as it does today.
4. Ask it something with two real answers. The question should arrive as a question you can answer —
   and it should still be waiting if you close the window and come back, or pick up the phone.

The third and fourth steps are the ones a person has to do, because what is being judged is whether
the agent's behaviour changed, and no fake can tell you that.
