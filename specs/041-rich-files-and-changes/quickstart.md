# Quickstart: seeing 041 work

Work in `.agents/worktrees/041-rich-files-and-changes`. Never the main checkout.

## 1. The package on its own

```sh
cd Packages/CodeText && swift test
```

Expected: every suite is green. It covers the contract's six invariants (`contracts/codetext.md`),
including the text round-trip for all 20 sample files and palette contrast.

## 2. Both apps build

Build the two schemes one after the other, with plugin validation skipped (see memory: xcodebuild):

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
```

Then confirm `agentsd` doesn't link it: `otool -L` and `nm` on the built `agentsd` show no
`ts_parser`/`tree_sitter_` symbols.

## 3. The look (Phase A gate), on a scratch root

Use the **run-app** skill: build, launch on a scratch root, and drive over `daemon.sock`.

1. Put one sample per language (`Packages/CodeText/Tests/CodeTextTests/Samples/`) in the scratch
   project.
2. Open `sample.swift` through an agent's `show_file`, or by choosing it in Files.
3. Screenshot the files pane in Light and Dark, and with the Paper setting on System.
4. Expected:
   - keywords, strings, comments, numbers and types are distinct;
   - there's no red anywhere;
   - line numbers, wrapping and the named line's highlight are unchanged;
   - an unknown file (`notes.xyz`) is plain.

**Stop and show Alex the screenshots.** Palette values are adjusted at this point, not later.

## 4. Diffs (US2, US3)

1. Start a Claude agent on the scratch root. Ask it to change one word in the middle of a
   40-line function in `sample.swift`, then to add a new function to `sample.py`.
2. In the conversation and in Changes, expected:
   - the first edit shows at most 10 lines, with one removed and one added line and the changed
     word washed on both (SC-004);
   - the second edit is all added lines;
   - long unchanged runs show "↕ N unchanged lines" and open in place.
3. In a git scratch project, change two lines 400 apart in a long file, then open Whole file.
   Expected: two changes, folds around them, and Next/Previous moving between them.

## 5. Limits (SC-005)

Open a 294 KB single-line `long.js` and a 20 MB `big.json`. Both show plain within a second,
with a line saying why, and the app stays responsive. Sample the process if it doesn't.

## 6. Timing (SC-001, SC-002)

Open `swift5k.swift` (5,000 lines; the R1 input) and log from choosing it to the first coloured
window arriving (an `os_signpost` pair in `CodeDocument`).
- Mac: expected under 0.5 s.
- Scroll top to bottom with Instruments' SwiftUI template. Hitches should be no worse than the
  same file plain on main.
- Also note the machine's load average: R1 was measured at 44–57.

## 7. Size (SC-003)

Compare the built `Agents.app` and `Remote.app` against main's build of the same config (Release):
`du -sk` for installed size, and `ditto -c -k` for a zipped size.
Expected: at most +20 MB installed and +5 MB compressed (R1 measured +17 MB and +1.9 MB).

## 8. Phone and iPad (US5)

Install on the real devices (see memory: real devices, one install at a time), open the same
sample file and edit, and ask Alex to look early. Expected: the same colours and marks as the
Mac; `sample.swift` coloured within a second.
