# Research: Cursor makes four

Everything here was run on 2026-09-18 against `cursor-agent` 2026.09.10-fd3934a, installed at
`~/.local/bin/cursor-agent`, signed in as the user's own account. Feature 003 set the rule that a
capability claim is proved by handshake rather than read from documentation. This feature needed one
step further, because the interesting behaviour only appears during a turn, so two real turns were
run against a scratch directory.

## 1. The command is `cursor-agent acp`, and `acp` is not in its help

`cursor-agent --help` lists eighteen subcommands. `acp` is not one of them. It exists anyway:

```
$ cursor-agent acp --help
Usage: agent acp [options]
Start the Cursor Agent as an ACP (Agent Client Protocol) server
```

Note what the usage line calls itself: `agent`. Cursor's documentation says `agent acp` and its
sign-in description says `Run 'agent login' first if not logged in`.

On this Mac:

```
$ which cursor-agent agent
/Users/alexcollins/.local/bin/cursor-agent
/Users/alexcollins/.grok/bin/agent
```

`agent` is Grok. A user who follows Cursor's own advice signs into the wrong runtime.

**Decision**: the catalog entry is `cursor-agent` with arguments `["acp"]`. Any command the app shows
a user is built from the catalog entry, never from a runtime's own description of itself (FR-005a).

**Alternatives considered**: resolving `agent` and checking what it is. Rejected: the app would be
guessing at other software's identity to work around a documentation bug, and the catalog already
knows the right answer.

## 2. What the handshake says

One `initialize` and one `session/new`, nothing else.

| What | Value |
|---|---|
| `protocolVersion` | 1, which is what the app speaks |
| `loadSession` | true |
| `promptCapabilities` | `image: true`, `audio: false`, `embeddedContext: false` |
| `sessionCapabilities` | `list: {}` only. No fork, no delete |
| `authMethods` | one, `cursor_login`. No `_meta.terminal-auth` |
| logout | not advertised |
| `providers` | absent |
| `configOptions` on `session/new` | absent |
| `models` on `session/new` | present, 20+, with `currentModelId: "default[]"` |
| `modes` on `session/new` | present: agent, plan, ask |

`available_commands_update` arrives unprompted about twenty commands strong the moment a session
exists, including Cursor's own skills.

**Decision**: nothing to build. `loadSession` means resume works through 003's existing path. No
providers and no logout means those controls stay hidden by the existing capability gates.
`embeddedContext: false` is already handled: `PromptBar.swift:332-338` only embeds an image when the
runtime takes images, and a dragged file has always gone as a `resource_link`, which is baseline.

## 3. `cursor/create_plan` blocks, `-32601` answers it, and the plan arrives anyway

Two turns, same prompt, same scratch directory, differing only in how the client answered a method it
does not know.

**Turn A, answering `-32601`** (which is what the app does today):

```
TURN FINISHED: True
   1  request       cursor/create_plan
 107  notification  session/update
  51  notification  session/update:agent_message_chunk
  34  notification  session/update:agent_thought_chunk
   1  notification  session/update:available_commands_update
   1  notification  session/update:plan
   1  notification  session/update:session_info_update
   4  notification  session/update:tool_call
  15  notification  session/update:tool_call_update
{"id": 2, "result": {"stopReason": "end_turn"}}
```

**Turn B, leaving the request unanswered**:

```
TURN FINISHED: False
   1  request       cursor/create_plan
 131  notification  session/update
  ...
```

No `stopReason` inside 120 seconds, while turn A had finished. Cursor kept streaming, so the work
was not blocked, but the turn never completed.

Three things follow. The app's `-32601` fallback at `ACPSession.swift:449-450` is not a fallback here,
it is what ends the turn. Its doc comment, written in 003, already says this is deliberate: declined
loudly rather than left to time out. And `session/update:plan` arrived in both turns, so the plan
Cursor asks to render privately is also sent through the protocol's own channel, which 003 already
draws.

**Decision**: build no handler for `cursor/create_plan`. Keep declining it. Nothing is lost and the
codebase's rule against branching on runtime identity is kept.

**Alternatives considered**: implementing the method to show Cursor's richer markdown plan. Rejected
on two counts: it duplicates a plan the app already receives, and it would be the first code here to
know which runtime it is talking to. `LiveRuntimeTests.swift:18-19` records that rule as a standing
claim about this codebase.

**Caveat**: one run each. The difference is stark and the mechanism is obvious, but it is two data
points, not a study.

## 4. `cursor/ask_question` did not appear

Cursor's documentation lists it as a blocking request. It did not fire in either turn, including one
written specifically to force a question ("Ask me a multiple choice question to find out which symbol
I mean, then stop"). That turn produced only `session/update` and ended normally.

**Decision**: do not build for it. If it appears during implementation, map it onto the elicitation
stack 003 already finished (T116 to T123, all done: `Model/Elicitation.swift`,
`DaemonCore+Serving.swift`, `App/Sources/Elicitation/ElicitationView.swift`) in a way that names no
runtime. Do not build that speculatively.

**Alternatives considered**: advertising something in `clientCapabilities._meta` to opt into Cursor's
extensions. Rejected for this feature: it is an invitation to receive traffic the app has no use for,
and the plan it would unlock already arrives.

## 5. What Cursor does not send that a live test demands

`LiveRuntimeTests.swift` runs over `RuntimeCatalog.builtIn` and asserts every runtime returns a
non-empty `configOptions` containing a `model` category. Cursor returns no `configOptions` at all. It
puts its twenty-odd models in `session/new`'s `models` field instead, which `ACPTypes.swift:247`
deliberately does not decode, for every runtime, because the shapes disagree and the protocol is
retiring them.

So adding the catalog entry breaks a green test on contact.

**Decision**: the assertion is wrong, not the runtime. Change it to hold only for a runtime that
advertises options. "All three runtimes have config options" was an accident of having three.

**Alternatives considered**: skipping the assertion for Cursor by name. Rejected, obviously: that is
the branch on runtime identity this feature exists to avoid. Also considered decoding `models` so
Cursor has options like the others; that is a decision for all four runtimes and the spec puts it out
of scope.

## 6. Where the app would lose Cursor's notifications

`ACPSession.receive` handles `elicitation/complete`, then:

```swift
guard method == ACP.ClientMethod.sessionUpdate, let update = params?["update"] else { return }
```

Every other inbound notification method returns there. No log, no event, no record. By contrast an
unknown kind *inside* `session/update` becomes `.unknownUpdate(kind)` and reaches the daemon log at
`DaemonCore.swift:248-249`.

Cursor's documented notifications, `cursor/update_todos`, `cursor/task` and `cursor/generate_image`,
would land on that line. None of them appeared in these two turns, but the hole is real regardless
and belongs to every runtime.

FR-012 says nothing a runtime sends may be lost silently. Today, for notifications, it can be.

**Decision**: report an unrecognised notification method the way an unrecognised update kind is
already reported. One event, one log line, no runtime named. This is the only behaviour change in the
feature.

**Alternatives considered**: leaving it, on the grounds that nothing observed hits it. Rejected: the
spec makes a promise the code does not keep, and this is the cheapest honest way to keep it.

## 7. What adding a runtime actually touches

Verified by reading, not assumed. There is no `if` or `switch` on a runtime id anywhere in
`Packages/AgentsKit/Sources` or `App/Sources`; grepping the non-test Swift for `"claude"`, `"grok"`
or `"copilot"` returns nothing. Every enumeration goes through `RuntimeCatalog.builtIn` or
`RuntimeCatalog.runtime(id:)`.

Picks up a fourth runtime with no change: the daemon's account map and `allAccounts()`, runtime
discovery and statuses, session start, pick-up and adopt, the runtime picker, the sign-in panel, the
agent row and the session list.

Needs a change, all verified by reading:

- `RuntimeDiscoveryTests.swift:35` asserts `statuses.count == 3`.
- `LiveRuntimeTests.swift:39-42` asserts non-empty `configOptions` with a `model` category, per
  section 5. Its comment at `:18-19` also says "One code path, three runtimes", which becomes four.
- `scripts/acp-handshake.sh:14-18` hard-codes a dictionary of the three recipes for by-hand probing,
  separately from `RuntimeCatalog`. A fourth entry goes here too, or the script silently cannot probe
  the runtime this feature adds.

**Decision**: the catalog was built for this and the claim holds. The feature is an entry, a fix, and
three test files.

## Out of scope, with the evidence

- **Choosing a model or a mode.** Cursor offers twenty-plus models and three modes on `session/new`,
  the one place the app does not read for any runtime. Reading it is a four-runtime decision.
- **Cursor's MCP servers.** It advertises `mcpCapabilities: {http, sse}` and reads its own
  `.cursor/mcp.json`. The app neither reads nor writes that file.
- **Closing 003's T076.** Needs a deliberate sign-out of a real account. The user's call.
