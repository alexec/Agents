# Parity: Pins

A screen of [the parity table](../parity.md), which says what the paths and verdicts mean.

| Feature | Tier | Mac | Remote | Web | Verdict |
|---|---|---|---|---|---|
| Pinned page rows (#159) | Core | Drag; Open, Move Up / Down, Unpin: `A/Folders/PinnedPageRows.swift` | Long press: `R/Folders/PinnedPage.swift:8-60` | Drag and the menu: `W/views/Pins.tsx:17-73` | **same** (no drag on the Remote: **by design**) |
| A pinned Markdown page, live | Core | `A/Folders/PinnedPage.swift:104-106` | `R/Folders/PinnedPage.swift:100-131` | `W/views/Pins.tsx:111-133` | **same** |
| A pinned HTML page | Core | Page / Source: `A/Folders/PinnedPage.swift:54-61` | Page / Source: `R/Folders/PinnedPage.swift` | Source: `W/views/Pins.tsx:139-142` | Web: **by design** (Trusted Types) |
| Pin from the Files bar | Core | Any Markdown or HTML file: `A/Sidebar/FilesPane.swift:192-230` | Markdown in Page and HTML in Files: `R/Panes/PagePane.swift`, `R/Panes/FilesPane.swift` | Any Markdown or HTML file open under Files: `W/views/FilesPane.tsx` | **same** |
| A missing pin | Core | `A/Folders/PinnedPage.swift:85-99` | `R/Folders/PinnedPage.swift:83-92` | `W/views/Pins.tsx:125-131` | **same** |
| A pinned `ui://` view, fed afresh each time it opens (#189, #1797, #2167) | Core | `S/AppView/PinnedViewPage.swift` | The same shared page; a stray disappear on the iPhone's push neither tears it down nor drops its answer (#2167): `S/AppView/PinnedViewPage.swift` | Fed on mount, torn down on unmount: `W/views/PinnedViewPage.tsx` | **same** (#2167: walked on the Remote, a 3 s call reopened three times; the Mac and the web unchanged) |
| A server's list view, shown without a pin (#2032), after the pins; Hide in place of Unpin, Show Hidden Views in the folder's menu | Core | `A/Folders/ServerViewRows.swift`; the view page's **Hide**: `S/AppView/PinnedViewPage.swift` | `R/Sidebar/SidebarRows.swift`; the same shared page | `W/views/Pins.tsx`, `W/views/PinnedViewPage.tsx` | **same** (#2032) |
