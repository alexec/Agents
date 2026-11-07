---
name: type-into-a-scratch-window-by-pid
description: "ui.swift `set` on a SwiftUI .searchable field changes the AX value but never the binding; focus it by AX and post CGEvent keys to the pid instead"
metadata:
  type: reference
  modified: 2026-10-04T05:08:58.522Z
---

Found 2026-10-03 measuring #176. `ui.swift set <pid> "Search" "words"` prints "set: AXTextField" but the sidebar's `.searchable` binding never moves (no text-did-change), so nothing filters.

What works, with no keys reaching the front app: set `AXFocused` true on the first AXTextField of the pid, then for each character a `CGEvent(keyboardEventSource:virtualKey:0,keyDown:)` with `keyboardSetUnicodeString`, sent by `postToPid(pid)`. ⌘A is virtualKey 0 with `.maskCommand`, and Delete is 51. A ~40-line swift helper; the #176 version was deleted with its scratch folder.

Also: a root stopped with `stop.sh --keep` can't be relaunched with `--seeded`. Its host never rejoins the new control plane, so the sidebar shows no projects. Reseed a fresh root per run instead.

Related: [[drive-a-scratch-window-by-pid-with-ax]], [[keystrokes-go-to-the-front-app-not-the-scratch-one]].

2026-10-08 (⌘P typed-look fix, PR #489): Return also works by pid. Use virtualKey 36 with unicode "\r", right after AXFocused on the field. Leftover text stays in the Open File field across shows, so ⌘A + Delete first. Mouse clicks posted to a background pid do nothing. Read a text view's caret with AXSelectedTextRange on its AXTextArea.
