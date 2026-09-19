# Quickstart: Cursor makes four

How to prove this feature works, by hand, in the order that finds problems soonest. Every step says
what you should see. If a step does not match, stop there: the later steps assume the earlier ones.

## Prerequisites

```sh
cursor-agent --version     # 2026.09.10-fd3934a or later
cursor-agent status        # ✓ Logged in as ...
which cursor-agent         # ~/.local/bin/cursor-agent
```

If `cursor-agent status` says you are signed out, sign in with `cursor-agent login` before starting.
Signing out deliberately is a separate exercise and belongs to 003's T076, not here.

Be aware that `which agent` on this Mac returns Grok, not Cursor. That is the trap this feature is
built around; see research section 1.

## 1. It is on the list

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' build
open build/DD/Build/Products/Debug/Agents.app
```

Start a new agent. **Expect**: four runtimes offered, Cursor among them, named "Cursor". No warning
badge, because it is installed.

## 2. It runs a turn

Pick Cursor, pick a scratch folder, and send a prompt that reads and edits a file.

**Expect**: the reply streams. A tool call appears and asks permission before it writes. The edit
arrives as a diff. The agent appears under its project. What the turn cost goes on the record, in
whatever currency Cursor reported, or nothing at all if it reported nothing.

**Expect not**: any model name shown for this agent. Cursor reports its models where the app does not
read, for every runtime. This is correct; see the spec's Out of Scope.

## 3. A plan arrives, and the private one is declined

Send something worth planning: "Add a docstring, then a second function, then a test for it. Plan the
work first."

**Expect**: a plan appears where the app draws plans. In the daemon log, one line recording that
`cursor/create_plan` was declined:

```sh
tail -f ~/Library/Application\ Support/Agents/daemon.log
```

**Expect**: the turn finishes. This is the whole point of the `-32601` rule. If the turn hangs, the
decline is not reaching Cursor and everything else in this feature is moot.

## 4. Nothing is dropped silently

The fix is to unknown notifications, which no runtime on this Mac reliably sends, so drive it from
the fake agent:

```sh
swift test --package-path Packages/AgentsKit --filter ACPSessionTests
```

**Expect**: the case that sends a notification with a method nobody knows asserts an
`unknownNotification` event rather than silence. Before this feature that case does not exist and
the notification vanishes at `ACPSession.swift:398`.

## 5. Attachments respect what Cursor takes

With a Cursor agent selected, drag in a picture, then drag in a text file.

**Expect**: the picture is accepted and goes by value, because Cursor takes images. The text file is
accepted and goes as a reference, because Cursor does not take embedded context. Neither is refused,
and nothing is sent in a shape Cursor rejects.

## 6. Sign-in is honest, and points at the right command

This is the step that catches the trap. With Cursor signed in there is nothing to see, so read the
sign-in panel rather than triggering it:

**Expect**: no sign-out control for Cursor, because it advertises no logout. No provider picker,
because it advertises no providers.

**Expect**: if any command is ever shown for signing into Cursor, it names `cursor-agent`. It must
never say `agent login`, which is what Cursor's own description says and which would send the user to
Grok.

## 7. It survives a restart

Quit the window. Reopen it.

**Expect**: the Cursor agent is still there with its conversation intact. Then:

```sh
pkill -f agentsd
```

Reopen and select the agent. **Expect**: the conversation resumes rather than starting over, because
Cursor advertises `loadSession`.

## 8. The other three are unchanged

```sh
swift test --package-path Packages/AgentsKit
AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter LiveRuntimeTests
```

**Expect**: everything green, including the live suite over all four runtimes. The live
`configOptions` assertion has been changed to hold only where a runtime advertises options, so Cursor
passes it by not claiming any. If that test still asserts every runtime has options, it fails here,
and the fix is the assertion rather than the runtime; see research section 5.

## By hand, without the app

```sh
scripts/acp-handshake.sh cursor
```

**Expect**: the handshake table in research section 2. `loadSession: true`, one auth method, no
providers, `image: true`, `embeddedContext: false`.
