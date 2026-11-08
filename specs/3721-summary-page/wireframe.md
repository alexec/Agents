# Summary: its own row and page (#3721)

Part of #3719. The daily summary is the person's page, not a session in the home folder.
Tier: Core (the Mac window, the Remote and the web page).

## The row

At the top of the sidebar, above Needs You and For Review. It shows only when the daily
summary is on (Settings ▸ Agent Configuration ▸ Workflows: Summary, or Summary and checks).

```
┌──────────────────────────────────┐
│ ● Summary                        │  ← dot: the newest page is unread
│   Daily summary, Fri 6 Nov       │  ← the newest page's title
├──────────────────────────────────┤
│ ⚠ Needs You                   2  │
│ ☐ For Review                  1  │
│ …                                │
│ ▾ ~                              │  ← no daily summary sessions here any more
│   …                              │
└──────────────────────────────────┘
```

- No page yet: the row says "No summary yet" under "Summary".
- Selected (Mac, web) or tapped (Remote): the page opens in the detail pane (Mac, web) or is
  pushed (Remote).

## The page

```
┌──────────────────────────────────────────────────────────────┐
│ Summary                         [Fri 6 Nov, 18:10 ▾]         │  ← picker: the newest 3 pages
├──────────────────────────────────────────────────────────────┤
│ # Daily summary, Fri 6 Nov                                   │
│                                                              │
│ For you: 2 PRs wait on your approval …                       │  ← the saved page, as Markdown;
│ ## Landed                                                    │    agents:// and forge links open
│ - …                                                          │    their session, PR or issue (#3353)
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ How this was written ›                                       │  ← opens the writer's session
├──────────────────────────────────────────────────────────────┤
│ Daily summary   (Off | Summary | Summary and checks)         │  ← the same control as Settings ▸
│ At              [08:00 ▾]                                    │    Workflows (#3351, #3395)
│ Checks every    [4 hours ▾]                                  │
│ Once a day, an agent writes one short page …                 │
└──────────────────────────────────────────────────────────────┘
```

- No page yet: "No summary yet. The first one is written at 08:00." above the control.
- Opening the newest page marks it read: the row's dot goes.
- The Remote draws the same page as a pushed screen: the picker in the toolbar, the control
  in a section at the bottom.

## The writer's session

The sessions the Daily summary workflow started leave the home folder's list and For Review on
every client. Needs You still lists one that asks the person something. "How this was written"
opens it.

## The wire

- `summaries/list` → the saved pages, newest first: `name`, `title`, `savedAt`, `unread`, and
  `writer` (the session that wrote it).
- `summaries/read` `{name}` → the page and its Markdown. Reading the newest marks it read.
- `summaries/changed` → the pages, after a save or a read.

The host keeps `unread` and `writer` in `~/.agents/summaries/pages.json`, beside the pages.

Decided: a wire method, not a shown file, because the Remote and the web are not on the
machine that saved the file. The client asks the host it asks for the control
(`dailySummary/settings`). Reading another machine's pages through the control plane is a
follow-up; today the summary is written on one machine, the one that holds the control.
