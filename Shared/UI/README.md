# Shared/UI

SwiftUI code compiled into both the `Agents` (Mac) and `Remote` (iOS) targets. Listed
under `sources:` for each of them in `project.yml`; XcodeGen compiles one file into both
apps.

What belongs here: the definitions both apps must agree on and that need SwiftUI to
say — a colour, a font step, a view modifier. `StateTint`, `ChatTypeScale` and
`ChatColumn` are the three that started it.

What does not: arithmetic. A number that came out of a measurement goes in
`Packages/AgentsKit/Sources/AgentsKitCore`, where the one test target can hold it
(`PageMetrics` and `ChatMetrics` are the pattern). It cannot come here, because
nothing here is under test. And SwiftUI cannot go there, because `agentsd` reaches
`AgentsKitCore` through `AgentsKit`, and a daemon that moves bytes has no business
linking a UI framework.

Before this directory the two apps shared no view code at all, which is exactly how
`MarkdownText` and `BlocksView` came to disagree about font sizes.
