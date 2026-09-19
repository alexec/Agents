# Quickstart: proving Complete ACP coverage

Nine scenarios, one per user story, in priority order. Each one is a thing to do with your hands and
what should happen. Where a story cannot be driven by a runtime on this Mac, the scenario says which
test drives it instead, because that is the honest answer rather than a step nobody can perform.

## Before you start

```bash
swift test --package-path Packages/AgentsKit          # the whole suite, no Xcode, no simulator
xcodebuild -project Agents.xcodeproj -scheme Agents \
  -configuration Debug -derivedDataPath build/DD build
pkill -f agentsd; pkill -f "Contents/MacOS/Agents"    # the daemon is long-lived: kill it after a kit change
open build/DD/Build/Products/Debug/Agents.app
```

The live suite, off by default because it costs money and needs your credentials:

```bash
AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter Live
```

## 1. An agent starts whatever its runtime advertises (P1)

**By hand**: start an agent with each runtime. Every setting the runtime offers appears; the Claude
adapter's `fast` is a switch rather than a two-item menu.

**By test**: `swift test --filter ConfigOption`. The cases that matter are grouped choices, a
boolean, a choice with no value, an unknown type, and a malformed list. Each one costs at most its
own option, and `session/new` still succeeds. This is the bug that can lose an agent, so the test
comes first.

**Version check**: the fake agent answers `initialize` with version 2. The app says it cannot speak
that version and does not show the session as healthy.

## 2. Say it with a picture or a file (P2)

**By hand, Claude or Copilot**: drag a screenshot onto the prompt, type "what is this", send. The
reply describes the picture. The transcript shows the picture under what you said.

**By hand, Grok**: try the same. The composer says Grok does not take pictures, before you send, and
the prompt is still there.

**By hand, any runtime**: type `@`, choose a file, send "summarise this". The file is referenced by
name and the agent reads it.

## 3. See the work, not the summary (P3)

**By hand, Copilot or Grok**: ask it to change one word in a file. The tool call shows the old line
against the new one with the path. Click the path: the file opens at that line.

**By hand, Claude adapter**: the same request arrives as console text rather than a diff, because
the adapter shells out. It reads as text, not as raw JSON.

**By hand, Grok**: ask it to run a command. Output appears while it runs.

## 4. Know what it cost (P4)

**By hand, Claude adapter or Copilot**: start a turn and watch the meter move while it works. When
the turn ends, the transcript records what that turn used, and the cost if the runtime sent one.

**By hand, Grok**: no meter and no cost, because Grok sends neither. Nothing is invented.

**By test**: a fake agent sends `size: 0`, then a usage with no cost, then one with a cost in an
unusual currency. The meter hides, the cost hides, the currency is shown as sent.

## 5. Sign in, sign out, choose who answers (P5)

**By hand**: sign a runtime out deliberately, in its own CLI. The app shows it as needing sign-in,
not as broken. Sign back in from the app. Copilot's method needs a terminal, so the app shows the
exact command Copilot named and opens a terminal at it.

This is also where the error a signed-out runtime returns gets written down for the first time, which
is the task carried over from 001.

**By hand, Claude adapter**: change the provider, start an agent, confirm it uses it, restart the app
and confirm the choice survived.

## 6. Follow the plan (P6)

**By hand**: give an agent something big enough to plan ("read this package and write down the five
things you would change"). The plan appears as steps with their states, and the states tick over.

**By test**: a fake agent sends a plan, then an update to it, then removes it. One plan on screen
throughout, ending marked as withdrawn.

## 7. Pick up sessions the app did not start (P7)

**By hand**: run a Claude session from a terminal in a folder the app knows. In the app, ask what
else is in this folder. It is listed with the title the runtime wrote. Adopt it, read the history,
carry on. Ask again: it is no longer offered, because it is now yours.

**By hand**: fork an agent mid-conversation. Two agents, same history, the first untouched.

**By hand**: delete an archived agent's session. The app asks first and says it is permanent.

## 8. Let the agent reach further (P8)

**By hand, Grok**: this is the one runtime that takes us up on it. Ask it to edit a file. The
transcript shows the reads it made through the app and asks permission for the write. Refuse the
write: the file is unchanged and Grok is told.

**By hand**: ask an agent to write outside its folder. It is refused, and the refusal says why.

**By hand**: stop an agent while a command it started is still running. The command dies with it.
Check with `ps`.

**By test**: path confinement, with `..`, a symlink pointing out of the folder, and a file that does
not exist yet. Refusal is the default.

## 9. Answer the agent's question in a form (P9)

**By test only**. No runtime on this Mac sends an elicitation request. The fake agent sends one of
each shape: a string with a format, a number with a range, a boolean, a multi-select, and a URL
request. Each is drawn, validated and answered. Cancelling reports declined. A form asked while no
window is open is waiting when one opens.

## What "done" looks like

- `swift test` passes, including the new fake-agent cases.
- Each of the nine scenarios above behaves as described, on this Mac, with these runtimes.
- A handshake against all three runtimes shows no advertised capability without a matching action in
  the app, which is SC-002, and is worth re-running whenever a runtime updates.
- An agent record written by 001 still opens.
