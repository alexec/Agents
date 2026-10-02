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

**Window screenshots:** pending. The Mac was locked for the whole walk, and `screencapture -l` cannot take a locked window. What each row says about the window comes from its source and its own walks until the shots are taken, and they are added as a *Window* column.

## Key

- **has**: the page does what the window does.
- **partly**: the page does some of it; the rest is said.
- **lacks**: the page does not do it.
- **by design**: the page leaves it out on purpose (071 spec), and still does.
- **n/a**: nothing for the page to do.

## The issue's table

| Change | Issue | Before | Now | Page shots | Notes |
|---|---|---|---|---|---|
| Unread is a mark: dot, bold row, counts, Mark as Unread | #70 | has | has | `before-sessions.png` | Dot and heavier title, "Done 2 · 2 unread", "work · 2 unread" on the project row, Mark as Unread/Read in ···. |
| Answer cards hold while sending ("telling your Mac") | #86 | has | has | `after-acting.png` (card) | The button sent stays bright with "telling your Mac"; the others are held. |
| In-flight marks on start, send, Send now, stop, park, archive; one action at a time | #87 | lacks | **has** | `before-acting.png`, `after-acting.png`, `after-starting.png` | Row says "Parking — telling your Mac" in its report's place, and ··· holds. Send spins in its button, with "Sending — telling your Mac" past 400 ms. A reply leaves the field at once and comes back if it did not go. A new session keeps its words, held, under "Starting — telling your Mac". Send now says it in its row. Walked with the host paused. |
| Workflow page: Triggers section, next run, last fired | #98 | lacks | **has** | `before-workflow.png`, `after-workflow-triggering.png`, `after-workflow-schedule.png`, `after-workflow-off.png` | A row opens the page in the chat's place. One line a trigger, with filters, scope ("In work, on this Mac"), which agent a triggering run resumes, a schedule's next time, Unknown for one this version can't watch; then "Last ran …, on …", the prompt and recent runs. Settings and approval stay the window's: the page says "approve it on the Mac". |
| Workflow Enabled switch apart from archive; off marked in place | #100 | partly (off marked in place only) | **has** | `after-workflow-menu.png`, `after-workflow-off.png` | Enabled beside Run Now on the page; Turn Off / Turn On in the row's ···. Walked off and on again: the row read "Write a greeting · Off", then back. **Protocol:** `workflows/enable` added to `WebSignatures` (a device may already call it). |
| A down host is plain, said at once; actions fail fast | #83 | partly | **has**, page-side | `before-hostdown-chat.png`, `before-hostdown-new.png`, `after-hostdown-chat.png`, `after-hostdown-new.png` | Now: "This Mac's host isn't answering" whole in the projects column; the strip over a chat and a new session reads as the window's, with since when; the sessions column greys; sending and ··· are off. **Not at once:** with the host paused, the page heard it ~55–60 s later, because it is told by the control plane's host state. A host that exits closes its uplink and is heard sooner. How the control plane reports hosts is #106's lane, so this was left alone. |
| Disk-full / refused writes in words | #88 | partly (a refused call already said the host's sentence) | **has** | — | Now hears `storage/writeFailed` and says its sentence. Unit-tested; not provoked on the scratch host (it needs a full disk). **Protocol:** `storage/writeFailed` added to `WebSignatures`. |
| Project Settings reachable with a session open | #97 | by design | by design | — | The page has no settings. |
| Alerts held until their own button closes them | #101 | lacks (a second problem replaced the first) | **has** | — | The problem strip stays until its OK; a second waits its turn. Unit-tested. |
| Sidebar project row height | #104 | has | has | `before-sessions.png` | Two lines, 43 px, nothing clipped. |
| Turn detail Outcome/Steps/Details; concise turns; trailing reply | 069, concise turns | has | has | `before-chat-outcome.png`, `before-chat-steps.png` | Prompt, "▸ 7 steps", the reply, then the report. |
| Labels tag input on start | labels tag input | has | has | `bar.mjs` | Comma adds, Delete on an empty field removes; above the input on the left (#108). |
| Sessions column as one list; Archived folds named | sessions column | partly (workflows could not be chosen) | **has** | `before-sessions.png`, `after-workflow-triggering.png` | "Archived sessions" and "Archived workflows" were already named, and search covered both. A workflow row is now chosen like a session row and opens its page. |
| Queued prompts look | #95 | n/a | n/a | — | #95 has not landed. Queued rows read "Waiting its turn" with Send now and ×. |
| Prompt bar layout | #108 | has | has | `walks/108/` | `bar.mjs` re-run on this branch: every control where #108 put it, no problems at 1440 or 390. |

## Also merged since 2026-09-29

| Change | Issue | Before | Now | Page shots | Notes |
|---|---|---|---|---|---|
| Changes as a tree, status-coloured squares | #63 | lacks (a flat list, state in words) | **has** | `before-changes.png`, `after-changes.png` | ChangeTree ported: folders first, one-folder chains on one line, totals, folders close. A square in its status colour, with the status in words for a reader. |
| Files: the same rows as Changes | #63 | lacks | **has** | `before-files.png`, `after-files.png` | A changed file has its square and +N −M; a folder the total under it. The page lists a folder at a time, as the Remote does, not as a tree. |
| Files: Back finds where it was, the file marked | #66 | partly (back to the folder) | **has** | `before-files-back.png`, `after-files-back.png` | The file last open is marked. |
| A folder always ends on its contents or a sentence | #62 | has | has | — | A listing that fails says why; an empty one says "Nothing here." |
| Files pane drops stale reads | #89 | has | has | — | Already in 071. |
| Session rows: title owns its line; worktree badge beside labels | #68 | has | has | `before-sessions.png` | "⑂ reply-one-word-ready audit ui" on the line under the report. |
| Reconnect at once on wake and on a network change | #82 | partly (on coming into view) | **has** | — | Also on the browser's `online` event. |
| Connect…: a deadline and words a person reads | #84 | has | has | — | Each pairing step has a 15 s deadline, and the page's own sentences. |
| A chat opens with its last 12 turns | #90 | lacks (50) | **has** | — | Earlier turns come as the top is reached, as before. |
| HTML opens as a live page | #67 | by design | by design | — | 071 FR-031: the page shows HTML as source and runs nothing. |
| Helper limits per project | #64 | by design | by design | — | A setting. |
| Swipe to archive waits for the swipe | #74 | n/a | n/a | — | The page has no swipe. |
| Dictation keeps every word through a pause | #69 | by design | by design | — | Dictation is the window's. |
| Archive stays on the chat when it did not archive (073) | 073 | has | has | — | Archive never leaves the chat on the page; a failure says why. |
| Pairing a phone, the window shows the code | 058 | n/a | n/a | — | The window's own pairing. |

## Left out by design

- Settings, Project Settings and helper limits.
- The terminal.
- Dictation.
- Approving a workflow, and changing a workflow's settings: the page says "approve it on the Mac", and shows the settings only in the workflow's one-line summary.
- HTML as a live page.

## Counts

Of the rows above, the page lacked or partly had 12 before this branch. All 12 are closed:
#87, #98, #100, #83 (page side), #88, #101, the sessions column, #63 (Changes), #63 (Files), #66, #82, #90.

What is still open:
- **#83, "said at once":** this needs the control plane to notice a host going away sooner. It is #106's lane, so it is not done here.
- **Window screenshots:** waiting for the Mac to be unlocked.
