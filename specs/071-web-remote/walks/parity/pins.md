# Parity: Pins

A screen of [the parity table](../parity.md), which says what the paths and verdicts mean.

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Pinned page rows (#159) | Drag; Open, Move Up / Down, Unpin: `A/Projects/PinnedPageRows.swift` | Long press: `R/Projects/PinnedPage.swift:8-60` | Drag and the menu: `W/views/Pins.tsx:17-73` | **same** (no drag on the Remote: **by design**) |
| A pinned Markdown page, live | `A/Projects/PinnedPage.swift:104-106` | `R/Projects/PinnedPage.swift:100-131` | `W/views/Pins.tsx:111-133` | **same** |
| A pinned HTML page | Page / Source: `A/Projects/PinnedPage.swift:54-61` | Page / Source: `R/Projects/PinnedPage.swift` | Source: `W/views/Pins.tsx:139-142` | Web: **by design** (Trusted Types) |
| Pin from the Files bar | Any Markdown or HTML file: `A/Sidebar/FilesPane.swift:192-230` | Markdown in Page and HTML in Files: `R/Panes/PagePane.swift`, `R/Panes/FilesPane.swift` | Any Markdown or HTML file open under Files: `W/views/FilesPane.tsx` | **same** |
| A missing pin | `A/Projects/PinnedPage.swift:85-99` | `R/Projects/PinnedPage.swift:83-92` | `W/views/Pins.tsx:125-131` | **same** |
| A pinned `ui://` view, fed afresh each time it opens (#189, #1797, #2167) | `S/AppView/PinnedViewPage.swift` | The same shared page; a stray disappear on the iPhone's push neither tears it down nor drops its answer (#2167): `S/AppView/PinnedViewPage.swift` | Fed on mount, torn down on unmount: `W/views/PinnedViewPage.tsx` | **same** (#2167: walked on the Remote, a 3 s call reopened three times; the Mac and the web unchanged) |
