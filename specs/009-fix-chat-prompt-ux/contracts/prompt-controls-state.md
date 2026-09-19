# Contract: PromptControlsState

**Module**: `AgentsKitCore` · **File**: `Sources/AgentsKitCore/Model/PromptControlsState.swift`

The area under the prompt has one state at a time and always has one. This is the contract
between whatever the app knows about options and what the person is looking at. FR-001 says
that area is never silently empty; making it a total enum is how that becomes something the
compiler enforces rather than something a reviewer has to notice.

## Surface

```swift
public enum PromptControlsState: Equatable, Sendable {
    /// A new chat with nowhere to work yet.
    case needsFolder
    /// A folder, but no runtime to run in it.
    case needsRuntime
    /// Asking the runtime what it offers.
    case loading(runtimeName: String)
    /// The asking failed. The reason is the person's to read, and the caller offers a retry.
    case failed(reason: String)
    /// The runtime answered and has nothing to adjust. Cursor is always here, by design.
    case nothingOffered(runtimeName: String)
    /// Filtered by `isRenderable`, sorted by `categoryRank`. Never empty.
    case controls([ConfigOption])

    public static func resolve(agentOptions: [ConfigOption]?,
                               draftOptions: [ConfigOption],
                               hasFolder: Bool,
                               hasRuntime: Bool,
                               runtimeName: String?,
                               isLoading: Bool,
                               failure: String?) -> PromptControlsState
}
```

## Guarantees

| # | Guarantee | Requirement |
|---|---|---|
| C1 | `resolve` is total: every combination of inputs returns a case | FR-001 |
| C2 | `.controls` never carries an empty array, and never carries an option where `isRenderable` is false | FR-001, FR-002 |
| C3 | Options in `.controls` are sorted by `categoryRank`, stably | FR-002 |
| C4 | `agentOptions == []` is not by itself `.nothingOffered`; it falls through to the draft, the failure, or the loading state | FR-003 |
| C5 | `failure != nil` outranks `.nothingOffered` and `.controls([])` | FR-004 |
| C6 | `isLoading` outranks everything except `.needsFolder` and `.needsRuntime` | FR-001 |
| C7 | `.needsFolder` outranks `.needsRuntime` — one thing to do at a time | FR-001 |
| C8 | `resolve` never throws, never traps, and does no I/O | — |

## Precedence, in order

1. `hasFolder == false` → `.needsFolder`
2. `hasRuntime == false` → `.needsRuntime`
3. `isLoading` → `.loading`
4. `failure` → `.failed`
5. renderable options from `agentOptions ?? draftOptions`, non-empty → `.controls`
6. otherwise → `.nothingOffered`

For a started agent the caller passes `hasFolder: true, hasRuntime: true` — both are settled
facts about the agent, which is what `whereAndWhat` already draws them as.

## What the caller owes it

- `runtimeName` is the display name from `RuntimeCatalog`, or the raw id if the catalog does
  not know it. `resolve` does not look it up; the package half that holds the catalog is the
  caller's side of the wall.
- `failure` is prose already fit to show a person. `AppModel.describe(error)` produces it.
- `draftOptions` may be passed unfiltered and unsorted. `resolve` does both.

## What the view owes it

`PromptBar.options` switches over all six cases with no `default`. Adding a seventh case must
break the build — that is the point of the type. The `.failed` case draws a retry control; the
other five draw text or the row.

## Tests

`Tests/AgentsKitTests/Unit/PromptControlsStateTests.swift`

| Test | Holds |
|---|---|
| `everyCaseIsDrawn` | A switch over all six cases compiles and each is reachable from `resolve`. This is the test that carries the feature |
| `anAgentWithNoOptionsFallsThroughRatherThanShowingARow` | C4 — the `??` bug |
| `aRuntimeThatOffersNothingSaysSo` | Cursor's case, and C2 |
| `optionsThatCannotBeDrawnAreNotControls` | A list of only `.unsupported` options is `.nothingOffered` |
| `aFailedFetchIsNotAnEmptyRuntime` | C5 |
| `nothingIsChosenYet` | C7, and `.needsRuntime` after a folder |
| `controlsComeBackInCategoryOrder` | C3, against `ConfigOption.categoryOrder` |
