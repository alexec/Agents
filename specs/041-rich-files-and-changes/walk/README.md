# 041 look gate (T024): the files pane in colour

Taken 2026-09-25 on a scratch root (`/tmp/run-041`) from branch `041-rich-files-and-changes`.
Each file was shown by a real Claude agent calling `show_file`, as it is in real use. The
pane was captured from behind the other windows. Light is the Paper theme on System (light
here); dark is the same window relaunched with `--appearance dark`.

## Light

The whole window, for scale: `sample.swift` shown at line 20, which keeps its highlight.

![window](window-light.png)

![Swift, light](pane-light-sample.swift.png)

![Python, light](pane-light-sample.py.png)

![TypeScript, light](pane-light-sample.ts.png)

![TSX, light](pane-light-sample.tsx.png)

![JSON, light](pane-light-sample.json.png)

A kind of file the app doesn't know stays plain, with no message:

![notes.xyz, light](pane-light-notes.xyz.png)

## Dark

![Swift, dark](pane-dark-sample.swift.png)

![Python, dark](pane-dark-sample.py.png)

![TypeScript, dark](pane-dark-sample.ts.png)

![JSON, dark](pane-dark-sample.json.png)

## What to look at

| Role | Light | Dark | Seen as |
|---|---|---|---|
| keyword | `#2B4C8C` semibold | `#8FB0E8` semibold | clear in both |
| string | `#4E6420` | `#A9C27A` | clear |
| comment | `#6E675B` italic | `#9C9486` italic | clear; doc and block comments both |
| number | `#7A3E7A` | `#D5A3D5` | clear |
| type | `#1F6A6A` | `#7CC4C0` | clear |
| function | `#3D5A80` | `#9DB5D9` | **too close to the ink in light**: `sell`, `append` barely differ from plain (checked: they are coloured) |
| property | `#6B5A2E` | `#C9B27E` | TypeScript enum members and object keys |
| punctuation | `#5F5A52` | `#A8A196` | reads as plain, on purpose |

Also:
- The name being declared in Swift (`struct Till`) is not coloured. That's the Swift grammar's
  query, not ours, so it's the same in any tree-sitter app. TypeScript and Python colour it.
- Line numbers, wrapping, the named line's highlight and selection are unchanged.
- The family emoji on the last Swift line is drawn by the system's monospaced fallback font,
  the same as before this change.
