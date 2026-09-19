# Agents

A Mac app, rebuilt one feature at a time against a written spec.

## Build and run

```sh
xcodegen generate      # regenerate Agents.xcodeproj after editing project.yml
open Agents.xcodeproj
```

From the command line:

```sh
xcodebuild -scheme Agents -destination 'platform=macOS' build
swift test --package-path Packages/AgentsKit
```

## How work happens here

Spec Kit, one feature at a time. Each feature is a folder under `specs/`:

1. `/speckit-specify` — what the feature is, in the user's words, with acceptance criteria.
2. `/speckit-clarify` — the ambiguities get answered before any design.
3. `/speckit-plan` — how it will be built.
4. `/speckit-tasks` — the ordered list.
5. `/speckit-implement` — the work, against those tasks.

The rules the specs are held to are in `.specify/memory/constitution.md`.
