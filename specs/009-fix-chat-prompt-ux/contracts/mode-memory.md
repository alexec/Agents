# Contract: ModeMemory

**Module**: `AgentsKitCore` · **File**: `Sources/AgentsKitCore/Model/ModeMemory.swift`

Remembering the mode is two questions: which advertised option *is* the mode, and may a
remembered value still be used. Both are pure, both can be wrong in ways a person would notice,
and both therefore live where `swift test` can reach them. The storage does not: that is one
`UserDefaults` key in the app, beside `sidebar.*`.

## Surface

```swift
public enum ModeMemory {
    /// The option that is the mode, if the runtime advertises one.
    ///
    /// By `category == "mode"` first, because that is what the rest of the app keys on —
    /// `categoryOrder`, `isAboutPermission`. By `id == "mode"` second, because that is what
    /// `SessionUpdate`'s `modeChanged` hard-codes.
    public static func modeOption(in options: [ConfigOption]) -> ConfigOption?

    /// What the mode control should open on.
    ///
    /// The remembered value if the runtime still offers it; otherwise what the runtime says is
    /// current; otherwise nothing, and the control shows the option's own name.
    public static func startingValue(remembered: JSONValue?,
                                     for option: ConfigOption) -> JSONValue?

    /// The defaults key for one runtime. One key per runtime, not one dictionary.
    public static func defaultsKey(runtimeID: String) -> String
}
```

## Guarantees

| # | Guarantee | Requirement |
|---|---|---|
| M1 | `startingValue` returns `remembered` only when it is among `option.options` | FR-015 |
| M2 | A remembered value the runtime no longer offers is discarded silently, and `option.currentValue` is returned | FR-017 |
| M3 | `remembered == nil` returns `option.currentValue` | FR-018 |
| M4 | `modeOption` returns `nil` for a boolean or unsupported option, however it is categorised | FR-015 |
| M5 | `modeOption` prefers category over id when both are present and disagree | — |
| M6 | `defaultsKey` is stable and namespaced: `"prompt.mode.<runtimeID>"` | FR-016 |
| M7 | Neither function throws, traps, or does I/O | — |

## Where it is called

**Read** — `AppModel.loadDraftOptions`, after the existing loop that seeds `draftChosen` from
`currentValue`:

```
for option in draftOptions where option.currentValue != nil { draftChosen[option.id] = ... }   // today
if let mode = ModeMemory.modeOption(in: draftOptions),
   let value = ModeMemory.startingValue(remembered: stored(for: runtimeID), for: mode) {
    draftChosen[mode.id] = value                                                                // new
}
```

Seeding `draftChosen` is sufficient and this was checked: `startDraft` sends
`StartOptions(values: draftChosen)` and `DaemonCore.start` calls
`session.apply(request.startOptions)` (`DaemonCore+Commands.swift:77`), which sets each value on
the session and swallows a refusal per option. No daemon method and no protocol change.

**Write** — `PromptBar.binding(for:)`, in the setter, above the draft/agent split, so one line
covers both a new chat and a live one (FR-019):

```
if ModeMemory.modeOption(in: shown)?.id == option.id { model.rememberMode(value, for: runtimeID) }
```

## Storage, in the app

`AppModel` owns the `UserDefaults` read and write, following `SidebarFrame`: sanitise on the way
in, write on change.

- A stored value that will not decode is treated as nothing remembered, and the key is left
  alone rather than cleared — a future version may understand it.
- Nothing is written for a runtime whose mode was never changed, so the defaults stay as small
  as the person's actual habits.
- Reading is not a fallible operation to the caller: it returns `JSONValue?`.

## Tests

`Tests/AgentsKitTests/Unit/ModeMemoryTests.swift`

| Test | Holds |
|---|---|
| `aRememberedModeTheRuntimeStillOffersIsUsed` | M1 |
| `aModeTheRuntimeHasDroppedIsDiscardedForItsOwnDefault` | M2 — the test that carries the feature; getting this wrong starts an agent in a mode nobody chose |
| `nothingRememberedLeavesTheRuntimesDefault` | M3 |
| `theModeIsFoundByCategoryNotByName` | M5, with an option whose id is `permission_mode` |
| `aSwitchIsNeverTheMode` | M4 |
| `aRuntimeWithNoModeOptionIsNotAFailure` | `modeOption` returns `nil`, `draftChosen` untouched |
| `eachRuntimeRemembersItsOwn` | M6, two runtimes, two keys, no bleed |
