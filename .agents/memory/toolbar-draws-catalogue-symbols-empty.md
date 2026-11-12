---
name: toolbar-draws-catalogue-symbols-empty
description: On macOS 27 a SwiftUI toolbar item draws a symbol image from an asset catalogue (Image("lucide.x")) as an empty glass circle; menus and views draw it fine
metadata:
  type: project
---

A toolbar button whose label is `Image("lucide.pin")` or `Label(_, image:)` with a custom symbol from an asset catalogue draws nothing on macOS 27: the glass circle is there, the icon is not. The same image draws in views, in context menus and in the menu bar (#4976, found on the walk; `screencapture -l` showed it too, so not the walk's render).

**Why:** AppKit builds the toolbar item from an `NSImage` and loses the catalogue symbol on the way; an `NSImage(named:)` handed in with `Image(nsImage:)` draws. That image does not follow `.font`, so it is wrong for a view.

**How to apply:** in a toolbar use `Image(toolbarIcon:)`, `Label(_:toolbarIcon:)` or `Button(_:toolbarIcon:action:)` (Shared/UI/PaperIcon.swift); everywhere else `Image(icon:)`. A new toolbar item walked with an empty circle is this. See [[walk-what-you-ship]].
