# Contract: Editing one front-matter key

**Module**: `AgentsKitCore` · **File**: `Sources/AgentsKitCore/Model/FrontMatter.swift`

Beside `FrontMatter.strip`, and in the same file for the reason that file gives for existing: the
positional rule about `---` is stated once. A second implementation of it is how the top of
somebody's document gets eaten.

This is the only thing in the app that writes into a file a person wrote. It does one key at a time,
in the front matter, and refuses anything it cannot do safely rather than doing its best.

## Surface

```swift
public enum FrontMatterEdit {
    public struct Refusal: Error, Sendable {
        public var message: String
    }

    /// Set, change or remove one top-level scalar key. `nil` removes it.
    /// Returns the whole document.
    public static func set(_ key: String, to value: String?, in source: String) throws -> String
}
```

Pure: a function of text, returning text. No file handle, no URL, no clock. The writing — the atomic
replace and the rescan that follows — is `DaemonCore+Workflows`'s, with every other workflow write.

## What it does

Given `permission-mode` → `"plan"`:

```diff
 ---
 name: Morning build check
 on:
   - schedule:
       at: [":00"]
 agent: new           # a fresh one every time
+permission-mode: plan
 ---

 Check whether the build is still green.
```

Given `permission-mode` → `"acceptEdits"` on the file above, the existing line's value is replaced
and nothing else moves. Given `permission-mode` → `nil`, the line goes.

## Guarantees

| # | Guarantee | Requirement |
|---|---|---|
| E1 | Only the lines between the opening `---` (which must be line one) and its closing `---` are considered | FR-022 |
| E2 | Everything outside that block is returned byte-identical, including the prompt body | FR-015, FR-022 |
| E3 | Only column-zero keys match. A `model:` indented under a trigger is never touched | FR-022 |
| E4 | Replacing a value preserves the line's trailing comment: `agent: new   # a fresh one` keeps its comment | FR-022 |
| E5 | Other lines keep their order, spacing, quoting and comments exactly | FR-022 |
| E6 | A key being added goes on its own line immediately before the closing fence | FR-020 |
| E7 | Removing a key removes its whole line and nothing adjacent | FR-020 |
| E8 | A value needing quoting is quoted; a plain scalar is written plain | FR-020 |
| E9 | A document with no front matter, or an unclosed block, is a `Refusal` — never a guess and never a fence invented for it | FR-005, FR-025 |
| E10 | A key appearing more than once at column zero is a `Refusal`: two answers is not something to pick between silently | FR-025 |
| E11 | A key whose existing value is not a scalar — a list or a block under it — is a `Refusal` | FR-025 |
| E12 | The line ending style of the document is preserved | FR-022 |
| E13 | `set` never writes, reads or touches the file system | — |

E9 through E11 are the reason this returns a `Refusal` rather than a best effort. Every one of them
is a file whose shape the app did not expect, and the correct move in a person's repository is to
stop and say so — which FR-025 then requires be said plainly, rather than the change being held in
the app as though it had worked.

## Tests

`Tests/AgentsKitTests/Unit/FrontMatterEditTests.swift`

| Test | Holds |
|---|---|
| `addingAKeyPutsItJustInsideTheFence` | E6 |
| `changingAValueLeavesTheCommentAfterIt` | E4 — the one somebody notices in a diff |
| `theBodyIsReturnedByteForByte` | E2, with a body containing its own `---` rule |
| `anIndentedKeyOfTheSameNameIsNotTouched` | E3 — `model:` nested under a trigger |
| `removingAKeyTakesOnlyItsLine` | E7 |
| `aDocumentWithNoFrontMatterIsRefused` | E9 |
| `aKeyTwiceIsRefusedRatherThanPicked` | E10 |
| `aKeyWithAListUnderItIsRefused` | E11 |
| `windowsLineEndingsSurvive` | E12 |
| `everyWorkflowInThisRepositoryRoundTrips` | E2 and E5 together: set a key and remove it again, and the file is what it was |
