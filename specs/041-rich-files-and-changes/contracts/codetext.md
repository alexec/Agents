# Contract: CodeText package and the views that draw code (041)

`Packages/CodeText` is linked by the `Agents` and `Remote` targets. It is **not** linked by
`agentsd` or `AgentsKit`. A check in the tasks greps the agentsd target's
dependencies.

## Public API (Swift)

```swift
public enum CodeLanguage: String, CaseIterable, Sendable {
    case swift, c, cpp, python, javascript, typescript, tsx, json, go, rust, java,
         ruby, bash, yaml, toml, html, css, markdown, dockerfile, make
    public static func detect(path: String, firstLine: Substring?) -> CodeLanguage?
    public static func fence(tag: String?) -> CodeLanguage?
}

public enum CodeRole: Sendable { case keyword, string, comment, number, type,
                                      function, property, punctuation, plain
    public static func role(forCapture name: String) -> CodeRole
}

public struct CodeSpan: Hashable, Sendable { public var range: Range<Int>; public var role: CodeRole }

public enum PlainReason: Sendable { case tooLarge, lineTooLong }

@MainActor @Observable
public final class CodeDocument {
    public init(text: String, language: CodeLanguage?)
    public private(set) var lines: [Substring]
    public private(set) var plainBecause: PlainReason?
    public func update(text: String)              // incremental reparse (R7)
    public func appear(line: Int)                 // ask for this line's window
    public func spans(line: Int) -> [CodeSpan]    // [] until the window arrives
}

public struct DiffRow: Hashable, Sendable {
    public enum Kind: Sendable { case context, removed, added }
    public var kind: Kind; public var text: Substring
    public var newLine: Int?; public var changed: [Range<Int>]
}

public enum LineDiff {
    public static func rows(old: String?, new: String) -> [DiffRow]
    public static func rows(whole: [(kind: DiffRow.Kind, text: String, newLine: Int?)]) -> [DiffRow]
}

public struct Fold: Hashable, Sendable { public var range: Range<Int> }
public enum Folds { public static func of(_ rows: [DiffRow], context: Int = 3, minimum: Int = 8) -> [Fold] }
public enum Limits { /* the R6 values, public constants */ }
```

`AgentsKitCore.DiffLine` is converted at the call site in the app, so `CodeText` does not depend
on AgentsKit.

## Invariants (tested)

1. **Text is untouched.** For every sample in every language, joining each line's
   `AttributedString` characters gives the input (FR-006, SC-006).
2. **Detection is total and conservative.** Unknown extensions, names and tags give nil. No
   language is guessed from content other than `#!`.
3. **Diff round-trip.** The context and removed rows of `rows(old:new:)` rebuild `old`, and its
   context and added rows rebuild `new`.
4. **Folds hide only context**, and never hide a row within 3 of a change.
5. **Limits hold.** Text over 512 KB, or with a line over 4,000 characters, gives
   `plainBecause != nil` and no spans. A pair over 1,000 characters gives no `changed`.
6. **Contrast.** Every `CodeInk` role is at 4.5:1 or better against `Paper.ground` and
   `Paper.well`, light and dark.

## View contracts

| View | Before | After |
|---|---|---|
| `FileLines(text:line:place:)` | plain numbered rows | gains `path:`. Rows are coloured when a language is detected; everything else (wrap, gutter, scroll-to-line, keepsPlace, selection) is unchanged. Past a limit, one line above the rows says why. |
| `DiffView(diff:maxHeight:showsPath:)` | all old struck, then all new | `LineDiff` rows with folds and word marks, coloured by the path's language. Signature unchanged; the conversation's 280 pt cap stays. |
| `ChangeFileView` Whole file | every line | `LineDiff.rows(whole:)` with folds, word marks, colour, and Next/Previous change buttons in the header. |
| `MarkdownText` `.code(language, text)` | plain | coloured by `CodeLanguage.fence(tag:)`, which is also used for the label. |
| Remote `FilesPane`, `ChangesView`, `PermissionSheet` | as above | the same shared views, so the same results. |

Copying from any of these views gives plain text only. Marks and numbers are separate `Text`
views outside the selectable line, as they are today.
