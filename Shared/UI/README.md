# Shared/UI

SwiftUI code compiled into both the `Agents` (Mac) and `Remote` (iOS) targets. Listed
under `sources:` for each of them in `project.yml`; XcodeGen compiles one file into both
apps.

What belongs here: the definitions both apps must agree on and that need SwiftUI to
say — a colour, a font step, a view modifier. `StateTint`, `TypeScale` and
`ChatColumn` are the three that started it; `Paper` is the fourth, and owns every
surface colour — ground, raised, well, rule — so no view picks a background of its own. `TypeScale` was `ChatTypeScale` and held
only the transcript; it holds both apps entire now, and every `.font(` outside it is a
marked decorative glyph.

What does not: arithmetic. A number that came out of a measurement goes in
`Packages/AgentsKit/Sources/AgentsKitCore`, where the one test target can hold it
(`PageMetrics` and `ChatMetrics` are the pattern). It cannot come here, because
nothing here is under test. And SwiftUI cannot go there, because `agentsd` reaches
`AgentsKitCore` through `AgentsKit`, and a daemon that moves bytes has no business
linking a UI framework.

Before this directory the two apps shared no view code at all, which is exactly how
`MarkdownText` and `BlocksView` came to disagree about font sizes.

## `Chat/` (033)

The chat itself, drawn by both apps: the transcript rows and the way the pane follows a
conversation (`ChatTranscript`), the diff, plan and block views, the command and mention
lists, the option capsules, dictation, and the pieces of the prompt area — the header
row, the cost-limit banner, the notes where there are no controls, and `PromptWords`
for every sentence the prompt area says.

What differs by app comes in through `ChatActions` (opening a touched file, a command's
output, taking a queued prompt back), or through `#if os(...)` inside the shared file
where the difference is the platform's (a picture's image type, a link's style, a
thumb-sized target). Each app's prompt field stays its own.

`ConsistencyTests` fails if either app declares its own copy of one of these types again,
or writes a chat sentence in both apps rather than once here.

## `Page/` (034)

The live page, one for both apps: `LivePage`, the one `MarkdownText` (which the chat
draws too), the passage editor with its `NSTextView` and `UITextView` halves, the caret
flags, and `FileLines`. What the page decides — following the agent, the one caret, a
draft carried across a write or a dropped connection — is `PageFollower`'s, in
AgentsKitCore, under test; the view only draws it.

What differs by app comes in through `PageActions`: where a save goes (both through the
daemon's `artifact/write`), how a picture is read (the Mac's disk; the phone asks the
Mac, and draws SVG through an offscreen WebKit view), whether typing is possible now,
and who to tell that a passage is being typed. `KeepsPlace` holds a reader's place for a
pane a phone draws afresh when it turns.

`ConsistencyTests` fails if either app declares its own page, `MarkdownText`, passage
editor or `ShellClient` again.

