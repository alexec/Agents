# Parity walk: the page beside the window (#110)

**Date:** 2026-10-01

**What it covers:** every change to the window's or the Remote's UI merged since 071 was planned (2026-09-29), with the issue's table first and the rest after it. Each row says whether the page had it *before* this branch, and what it has *now*.

**How it was run:**
- A run-app scratch root, `/tmp/run-p110`, with the window, its host and its control plane.
- One git project, `work`, seeded with:
  - three approved workflows: *After the build* (triggering, on `custom.build_green`, `branch.moved` on `main`, and `greeting` finishing), *Nightly tidy* (weekdays at 10pm, turned off), and *Write a greeting* (Sundays at 3am);
  - three real Claude sessions: *Repo notes* (wrote `notes.md`, unread), *Ready check* (in a new worktree, labelled `audit` and `ui`) and *Park conversation* (parked).
- The page was driven in headless Chrome by `Web/test/walk/parity.mjs`, at 1440 × 900.
- *before* shots are `main`'s `Web/dist`; *after* shots are this branch's.
- Scenes that need the host away pause the root's own `agentsd` with `SIGSTOP`, and always resume it.
- The control plane reads `Web/dist` once at start, so only the scratch control plane was restarted after each rebuild.
- Screenshots are in `walks/parity/`. What each run read off the page is appended to `before-notes.txt` and `after-notes.txt` (the earliest *before* runs predate appending; their readings are quoted in the Notes column).

**Window screenshots:** taken on 2026-10-02 once the Mac was unlocked, of the same scratch window, by window id and over AX (no clicks or keys). They are in `walks/parity/window/`. Rows the window shots don't cover point to the window's own walk for that change.

## Key

- **has**: the page does what the window does.
- **partly**: the page does some of it; the rest is said.
- **lacks**: the page does not do it.
- **by design**: the page leaves it out on purpose (071 spec), and still does.
- **n/a**: nothing for the page to do.

## The issue's table

| Change | Issue | Before | Now | Page shots | Window | Notes |
|---|---|---|---|---|---|---|
| Unread is a mark: dot, bold row, counts, Mark as Unread | #70 | has | has | `before-sessions.png` | `window/sessions.png` | Dot and heavier title, "Done 2 · 2 unread", "work · 2 unread" on the project row, Mark as Unread/Read in ···. |
| Answer cards hold while sending ("telling your Mac") | #86 | has | has | `after-acting.png` (card) | `window/sessions.png` (card) | The button sent stays bright with "telling your Mac"; the others are held. |
| In-flight marks on start, send, Send now, stop, park, archive; one action at a time | #87 | lacks | **has** | `before-acting.png`, `after-acting.png`, `after-starting.png` | #87's walk | Row says "Parking — telling your Mac" in its report's place, and ··· holds. Send spins in its button, with "Sending — telling your Mac" past 400 ms. A reply leaves the field at once and comes back if it did not go. A new session keeps its words, held, under "Starting — telling your Mac". Send now says it in its row. Walked with the host paused. |
| Workflow page: Triggers section, next run, last fired | #98 | lacks | **has** | `before-workflow.png`, `after-workflow-triggering.png`, `after-workflow-schedule.png`, `after-workflow-off.png` | `window/workflow-triggering.png` | A row opens the page in the chat's place. One line a trigger, with filters, scope ("In work, on this Mac"), which agent a triggering run resumes, a schedule's next time, Unknown for one this version can't watch; then "Last ran …, on …", the prompt and recent runs. Settings and approval stay the window's: the page says "approve it on the Mac". **Difference:** the window says an event trigger by its catalogue meaning ("When an agent here publishes custom.build_green"); the page says its name ("When custom.build_green"), as it did before. |
| Workflow Enabled switch apart from archive; off marked in place | #100 | partly (off marked in place only) | **has** | `after-workflow-menu.png`, `after-workflow-off.png` | `window/workflow-off.png`, `window/sessions.png` (Off on the row) | Enabled beside Run Now on the page; Turn Off / Turn On in the row's ···. Walked off and on again: the row read "Write a greeting · Off", then back. **Protocol:** `workflows/enable` added to `WebSignatures` (a device may already call it). |
| A down host is plain, said at once; actions fail fast | #83 | partly | **has**, page-side | `before-hostdown-chat.png`, `before-hostdown-new.png`, `after-hostdown-chat.png`, `after-hostdown-new.png` | `window/hostdown-10s.png`, `window/hostdown-65s.png` | Now: "This Mac's host isn't answering" whole in the projects column; the strip over a chat and a new session reads as the window's, with since when; the sessions column greys; sending and ··· are off. The window also greys a card's answers while the host is down; the page now does too (found from the window's shot). **Timing:** with the host paused, the page heard it ~54–60 s later. So did the window: at 10 s it showed nothing (`hostdown-10s.png`), and by 65 s it showed the strip (`hostdown-65s.png`). Both learn about the host from the control plane, so on timing the page is level with the window. A host that exits closes its uplink and is heard sooner. Making either quicker is #106's lane. **Left out:** the window's Try Again redials its own connection to the host; the page has nothing of its own to redial, and says the control plane is trying. |
| Disk-full / refused writes in words | #88 | partly (a refused call already said the host's sentence) | **has** | — | — | Now hears `storage/writeFailed` and says its sentence. Unit-tested; not provoked on the scratch host (it needs a full disk). **Protocol:** `storage/writeFailed` added to `WebSignatures`. |
| Project Settings reachable with a session open | #97 | by design | by design | — | — | The page has no settings. |
| Alerts held until their own button closes them | #101 | lacks (a second problem replaced the first) | **has** | — | — | The problem strip stays until its OK; a second waits its turn. Unit-tested. |
| Sidebar project row height | #104 | has | has | `before-sessions.png` | `window/sessions.png` | Two lines, 43 px, nothing clipped. |
| Turn detail Outcome/Steps/Details; concise turns; trailing reply | 069, concise turns | has | has | `before-chat-outcome.png`, `before-chat-steps.png` | `window/sessions.png` | Prompt, "▸ 7 steps", the reply, then the report. |
| Labels tag input on start | labels tag input | has | has | `bar.mjs` | `window/sessions.png` | Comma adds, Delete on an empty field removes; above the input on the left (#108). |
| Sessions column as one list; Archived folds named | sessions column | partly (workflows could not be chosen) | **has** | `before-sessions.png`, `after-workflow-triggering.png` | `window/sessions.png` | "Archived sessions" and "Archived workflows" were already named, and search covered both. A workflow row is now chosen like a session row and opens its page. |
| Queued prompts look | #95 | n/a | n/a | — | — | #95 has not landed. Queued rows read "Waiting its turn" with Send now and ×. |
| Prompt bar layout | #108 | has | has | `walks/108/` | `walks/108/window-*.png` | `bar.mjs` re-run on this branch: every control where #108 put it, no problems at 1440 or 390. |

## Also merged since 2026-09-29

| Change | Issue | Before | Now | Page shots | Window | Notes |
|---|---|---|---|---|---|---|
| Changes as a tree, status-coloured squares | #63 | lacks (a flat list, state in words) | **has** | `before-changes.png`, `after-changes.png` | `window/changes.png` | ChangeTree ported: folders first, one-folder chains on one line, totals, folders close. A square in its status colour, with the status in words for a reader. Headed "4 files · +33 −0", as the window's is. The window's note that git's changes may include other agents' work is not on the page. |
| Files: the same rows as Changes | #63 | lacks | **has** | `before-files.png`, `after-files.png` | `window/changes.png` | A changed file has its square and +N −M; a folder the total under it. The page lists a folder at a time, as the Remote does, not as a tree. |
| Files: Back finds where it was, the file marked | #66 | partly (back to the folder) | **has** | `before-files-back.png`, `after-files-back.png` | — | The file last open is marked. |
| A folder always ends on its contents or a sentence | #62 | has | has | — | — | A listing that fails says why; an empty one says "Nothing here." |
| Files pane drops stale reads | #89 | has | has | — | — | Already in 071. |
| Session rows: title owns its line; worktree badge beside labels | #68 | has | has | `before-sessions.png` | — | "⑂ reply-one-word-ready audit ui" on the line under the report. |
| Reconnect at once on wake and on a network change | #82 | partly (on coming into view) | **has** | — | — | Also on the browser's `online` event. |
| Connect…: a deadline and words a person reads | #84 | has | has | — | — | Each pairing step has a 15 s deadline, and the page's own sentences. |
| A chat opens with its last 12 turns | #90 | lacks (50) | **has** | — | — | Earlier turns come as the top is reached, as before. |
| HTML opens as a live page | #67 | by design | by design | — | — | 071 FR-031: the page shows HTML as source and runs nothing. |
| Helper limits per project | #64 | by design | by design | — | — | A setting. |
| Swipe to archive waits for the swipe | #74 | n/a | n/a | — | — | The page has no swipe. |
| Dictation keeps every word through a pause | #69 | by design | by design | — | — | Dictation is the window's. |
| Archive stays on the chat when it did not archive (073) | 073 | has | has | — | — | Archive never leaves the chat on the page; a failure says why. |
| Pairing a phone, the window shows the code | 058 | n/a | n/a | — | — | The window's own pairing. |
| One grant: no "It may" choice on the pairing sheets (2026-10-02) | #111 | lacks (footer said "· Device") | **has** | `after111-identity.png` | #111's walk | The footer reads "Chrome on this Mac", no grant. A browser may do what the window may; Settings, pairing and hosts still have no screens on the page (by design, below). Scene `identity` in `parity.mjs`. |
| Pairing a browser: the sheets give the address, say this Mac only, and say when the page isn't served (2026-10-02) | #105 | n/a | **has** | `walks/105/web-pairing-after.png` | `walks/105/` | The page makes no codes; its pairing screen now names **Pair a Window or Phone… ▸ A browser on this Mac** and shows no grant in its placeholder. See `walks/105.md`. |
| Open in Browser in View, atop Settings ▸ Control plane and in Agents Host (2026-10-02) | #109 | n/a | **has** (the page's side) | `109/first-open-pairs.png`, `109/paired-opens-directly.png` | `109/settings-control-plane.png` | These are the window's ways into the page; the page has nothing to open. Its side: it pairs from `#code=` in its address and takes the code out at once (`pairLink.ts`). See [109.md](109.md). |
| Finer event matching: lists, labels, codes, filters in words (spec 073) | #99 | partly (a list was dropped, so a trigger read wider than written) | **has** | `after-filters-t1.png`, `after-filters-codes.png`, `after-filters-typo.png` | `window/filters-t1.png`, `window/filters-codes.png` | Walked 2026-10-02 at 496972b1 on `/tmp/run-r073`, in headless Chrome (the `filters` scene of `parity.mjs`) and the window by window id. The page says each filter in the window's words: *labelled bug, and parked*; *its allowance ran out or rate limited, and still limited after retrying, on Claude*; *by you, labelled bug or regression*. A list is a capsule joined by ` \| ` (`outcome: stuck \| partly_done`), and a run's cause joins it with `\|`. A wrong value is the workflow's problem, naming the right values. The page still names the event where the window says its meaning (below). |
| New project: Add Folder…, Clone Git URL…, the empty list's two buttons, a clone's row | #115 | lacks (nothing could add a project) | **has** | `walks/115/addproject-*.png` | `walks/115/window-projects.png` | + at the head of the projects column, and the same items under the projects menu at medium width. Add Folder… browses the host over `files/browse` for every host (the window does this for servers only). Not on the page: a folder dragged in from Finder, the clipboard's URL filled in (web: by design, no clipboard read), Add Server…. See `walks/115.md`. |
| Settings ▸ Control plane: "Couldn't join the control plane: … Trying again…" for this Mac's host (2026-10-02) | #113 | by design | by design | — | — | A Settings row; the page has no Settings. `control/status` carries `thisMacHost` and the page's types have it, unused. |
| No chevron on a turn's margin lines (2026-10-02) | #112 | has the chevron (▸/▾ on every call line that opens, in a turn and out) | **has** | `before112-margin.png`, `after112-margin.png` | `window/112-before-steps.png`, `window/112-after-steps.png`, `window/112-after-details.png` | Walked at ec46210e on `/tmp/run-i112b` (one real Claude turn), in headless Chrome (the `margin` scene of `parity.mjs`: 6 chevrons before, 0 after; "Read file" still opens) and the window by window id over AX. A step is a plain line in the margin on both; an open call's detail sits under its line. "Hide steps" keeps its chevron. |
| An agent whose folder has gone: Folder is missing on the row, a strip over the chat, a refused send with the ways on (2026-10-02) | #119 | lacks (a send failed with the host's words and nothing else) | **has** | `119/119-web-strip-1440.png`, `119/119-web-refused-1440.png`, `119/119-web-successor-1440.png` | `119/window-strip.png`, `119/window-recreated.png`, `119/window-successor.png` | Walked on `/tmp/run-f119` (a real Claude agent in a worktree, parked, the worktree removed with `git worktree remove`), in headless Chrome (`Web/test/walk/foldergone.mjs`) and the window by window id. Both say *Folder is missing* on the row and over the chat with the path, refuse a send with *This agent's folder isn't there any more (…). It was a worktree, and may have been removed after merging.*, keep the words in the prompt, and offer Continue in the project folder, Recreate the worktree (while its branch is kept) and Archive. Continue carries what was typed. The window's refused-send alert was proved over the socket (-32004 with these words, nothing queued, still parked) but not drawn: an AX-set prompt never reaches SwiftUI's binding, and typing needed the front window while Alex was at the keyboard. |

## Since this walk

| Change | Issue | Page | Notes |
|---|---|---|---|
| Declared resources with descriptions, counted holders ("2 of 3 held") | #116 | **has**, read-only | A **Resources** fold under each host lists the declared resources with their descriptions and "2 of 3 held", each holder, and anything else held or awaited; kept by `leases/changed` (added to `WebSignatures`). **web: by design** for declaring, editing and ending leases: they are the Mac's (Settings ▸ Resources, the Resources page), as on the Remote. |

## Left out by design

- Settings, Project Settings and helper limits.
- The terminal.
- Dictation.
- Approving a workflow, and changing a workflow's settings: the page says "approve it on the Mac", and shows the settings only in the workflow's one-line summary.
- HTML as a live page.
- Declaring, editing and removing resources, and ending leases (#116): the Mac's.

## Counts

Of the rows above, the page lacked or partly had 12 before this branch. All 12 are closed:
#87, #98, #100, #83 (page side), #88, #101, the sessions column, #63 (Changes), #63 (Files), #66, #82, #90.

The window's shots found two more, both closed: answer cards held while their host is down (#83), and the Changes total line (#63).

What is still different, and why:
- **#83, "said at once":** neither the window nor the page hears a paused host for about a minute. Both learn of it from the control plane, which is #106's lane.
- **Event trigger words:** the page says an event's name, not the window's catalogue meaning. Its filters read as the window's since 073.
- **The window's Try Again for its host:** nothing on the page to redial.
