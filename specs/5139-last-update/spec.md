# "Last update <time ago>" on every page with cached data (#5139)

Status: the rule is decided. The children of epic #5139 do the work.

## Why

Alex, 2026-11-12: "Any page that displays cached data must show a 'last update <time ago>'
so the user knows how fresh the data is."

A page that shows old data and does not say so looks current. Then a person can act on a
cost, a runtime or a machine state that has changed. Now, only five places say how fresh
their data is, and three of them show a clock time ("since 14:02"). The person must then
calculate the age.

## The rule

The rule is in `docs/reference/design-system.md`, "How fresh the data is". In short:

1. **Which pages.** A page or pane shows cached data when it shows data from an earlier
   read. That includes:
   - data from the local copy (`LocalCopy` on Mac and Remote, IndexedDB on the web);
   - a read that is shown while its source does not answer;
   - data that is read once when the page opens;
   - a poll of 30 s or more.
2. **Pages that show no line.** A page that reads again every 5 s or less, and whose last
   read worked, shows no line. When one of its reads fails, it shows the line. (Decided in
   #5139: a line that always says "just now" is noise.)
3. **The time.** The time is when the client got the data (the read). It is not the time
   of the content, such as a PR's `updatedAt`, which rows can still show. It is also not
   the time that the link went down.
4. **The words.** All three clients use the same words:

   | Age | Words |
   |---|---|
   | under 1 minute | Last update just now |
   | 1–59 minutes | Last update 5 min ago |
   | 1–23 hours | Last update 2 h ago |
   | the day before | Last update yesterday |
   | older | Last update 3 Nov |

   The time is in the person's own time zone. The screen reader reads "Last update 5
   minutes ago".
5. **The tick.** The words change as time goes by: every 10 s for the first minute, then
   once a minute. The Mac and the Remote use `TimelineView`. The web uses one shared timer.
6. **Where.** When the pane has a banner (offline, stale), the line goes in the banner,
   after its words. When it has no banner, the line goes at the top of the pane, in
   `ink.secondary` at the caption step, at the trailing end of the pane's header when it
   has one. It is not a new control and it moves no section. It is a status line.
7. **One time for a page.** When the page has parts that were read at different times,
   it shows the oldest time.

## What we have now (2026-11-12)

| Client | Place | Shows now | Time of read |
|---|---|---|---|
| All | Banner for a link that is down: web `Banner.tsx`, Mac `ControlAwayStrip`, Remote `StaleBanner` | Web and Mac: no time. Remote: "Last heard … 5 minutes ago", but it does not tick | Web: link `since`. Mac: none. Remote: `lastHeardFrom` |
| All | Launch from the local copy | Only the link banner | Web: `MachineCopy.at`. Mac and Remote: `LocalCopy.Record` has no time (file mtime only) |
| All | Work list, item, plan, features, timeline | "From this device. Reading it again." | Web: `WorkCopy.at`. Mac and Remote: none |
| All | Archived Sessions, Archived Workflows | "Showing what was last read." | none |
| Mac, web | Cost, Tokens, Time, Velocity, Multiplier | nothing | none |
| All | Runtimes, Settings ▸ Agent runtimes | Allowance "Out since …" only | `RuntimeStatus.checkedAt`, `RuntimeAccount.checkedAt` |
| Mac, web | MCP servers | Web: "checked 14:02". Mac: nothing | `MCPServerHealth.checkedAt` |
| All | Workflow MCP triggers | "Checked 20 s ago", ticks | `MCPTriggerStatus.lastPolledAt` |
| All | Machine page, processes, backups | "Offline … can't say how it is doing now" | none |
| All | Events, bus log | Mac: a tooltip "Last at 14:02" | `lastEventAt` (the time of the content) |
| All | People, Accounts, Secrets | nothing | none |
| Remote, web | Needs You heading | "Updated 14:02" | Remote: `needsYouUpdatedAt`. Web: link `since` |
| Remote | Widget | "Updated 14:02", then "Updated 40 min ago" | `AttentionSnapshot.countedAt` |
| Web | Console Machines | "Last listed: 5 min ago" | `heardAt` |
| Mac, Remote | Server offline strip | "offline since 14:02" | Remote: `hostDownSince`. Mac: always now (bug #5148) |

These Remote pages show data from the last read but have no stale banner: the folder
page, Events, Machine, Multiplier, Velocity, Work, Summary, the Settings pages and the
iPad sidebar.

## Helpers we have now

There are many "ago" helpers, and #5141 replaces them with one per client for this line:

- **Swift:** `ActivityTime` and `ArchivedTime` (`Shared/UI/ActivityTime.swift`), and
  `MCPTriggerStatus.ago`. There are also the `ago` helpers in `ActivityWords`,
  `WorkLook`, `StatusSecretsWords`, `ConnectorSetupWords` and `WorkTimeline`. Some code
  calls `.formatted(.relative(presentation: .named))` directly.
- **Web:** `ago()` in `model/connectorSetup.ts`, `mcpAgo` in `model/workflows.ts`,
  `model/updated.ts` ("Updated HH:MM"), and helpers in `activity.ts`, `docs.ts`,
  `workTimeline.ts`, `archivedPage.ts`, `secretInfo.ts`, `statusSecrets.ts` and
  `auditSinks.ts`. There is also `Intl.RelativeTimeFormat` in `workflows.ts` and
  `SessionRow.tsx`.

The words are our own because the table above is shorter than what Foundation and
`Intl.RelativeTimeFormat` give ("5 minutes ago", "in 0 seconds"). The libraries still
give the date of an older day.

## Plan

Epic #5139. The order is in its sub-issues and their "blocked by" links:

1. #5140: this spec and the rule (docs only).
2. #5141: the shared line on each client, and the banners that cover every page. It
   includes a time of the read on `LocalCopy.Record`.
3. After #5141, these can run at the same time: #5142 Work, #5143 Archived, #5144 usage
   pages, #5145 runtimes and MCP health, #5146 the machine page, backups, events, people,
   accounts and secrets, and #5147 the Remote pages that have no stale banner.
4. #5148 (bug, no blocker): the Mac shows a server's offline "since" as now.

## Approval

Each child is a UI enhancement. The line is a status line, not a screen, a control or a
layout. So a child that only adds the line does not wait for Alex
("Approval: not needed"). #5147 adds an existing banner to pages that do not have one.
That is a layout change, so it waits for Alex.

## Tier

Core: it is on every client that draws each page. A page that is Mac + web gets the line
on the Mac and the web.
