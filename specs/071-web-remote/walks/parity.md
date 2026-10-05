# Parity: the Mac window, the Remote and the web page (#233)

**Date:** 2026-10-04, at main 28884102.

**What it is:** where each of the three clients stands, a row per screen and feature. The three are the Mac window (`App/`), the Remote on iPhone and iPad (`Remote/`), and the web page (`Web/`). Every parity line in a commit (AGENTS.md, "Keeping the three clients in step") updates the row it changes.

**How it was made:** by reading the code, not by a walk. The session that wrote it ran no builds and no tests while #234 had the machine. Rows that earlier walks covered keep their facts; their record is under [History](#history-the-page-beside-the-window-110) below. A row read from code alone may be wrong in a detail; a walk that finds one corrects the row.

**Paths:** `A/` = `App/Sources`, `R/` = `Remote/Sources`, `S/` = `Shared/UI` (drawn by both the window and the Remote), `W/` = `Web/src`, `K/` = `Packages/AgentsKit/Sources/AgentsKitCore`.

**Verdicts:**
- **same**: the three do the same thing (look may differ by platform).
- **by design**: one leaves it out or does it differently on purpose, and why.
- **delta**: they differ and shouldn't; the issue, and the side to change.

## Counts

Of 205 rows: **87 same**, **38 by design**, **80 delta** (after #238–#244, #255–#258, #264–#266, #291). A row with any open delta counts as delta, even where another side's difference is by design.

| Screen | Same | By design | Delta |
|---|---|---|---|
| Sidebar and project list | 3 | 2 | 12 |
| Session rows and states | 10 | 2 | 11 |
| Chat turns and turn detail | 4 | 3 | 16 |
| Prompt bar and queued prompts | 7 | 2 | 11 |
| Question and permission cards | 10 | 4 | 1 |
| Start sheet and new project | 17 | 5 | 0 |
| Worktrees and Files | 11 | 6 | 4 |
| Dashboard and pins | 8 | 0 | 6 |
| Workflows page | 6 | 1 | 7 |
| Settings and Project Settings | 1 | 6 | 0 |
| Pool, runtimes and spending | 2 | 1 | 7 |
| Events and resources | 1 | 1 | 3 |
| Notifications and badges | 2 | 1 | 1 |
| Disk strip | 1 | 1 | 1 |
| Hosts, connection and pairing | 3 | 3 | 0 |
| MCP Apps views | 1 | 0 | 0 |

The deltas are tracked by 31 issues:
- **Already open:** #226 (the Remote's one sidebar) and #235 (the page's one sidebar at phone width).
- **Filed by this audit, the Remote to change:** #238 (with the page), #239, #240, #241, #242, #243, #244, #245, #246 (with one web row), #247, #248, #249.
- **The page to change:** #250, #251, #252, #253, #254, #255, #256, #257, #259, #260, #261, #262.
- **The window to change, or more than one side:** #263, #264, #265, #266.
- **Alex to decide** (one client only, nothing says whether that is meant): #267.

## Sidebar and project list

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| One sidebar: Activity, projects folding open on their sessions and workflows, `host:Project` names | `A/Projects/ProjectListView.swift:48-96` | Its own project list, then a project page of cards, under host headings: `R/Projects/ProjectListView.swift:18-27`, `R/Projects/ProjectPageView.swift` | From 760 px, as the window: `W/views/Sidebar.tsx:38-104` (#151). Below, one column at a time | **delta**: Remote #226; web at phone width #235 |
| Project order | Last activity, newest first; this Mac's, then each server's: `K/Client/AgentsModel.swift:635`, `A/Projects/ProjectListView.swift:41-45` | Last activity, within host sections | **By name** within each host: `W/views/Sidebar.tsx:42-48` | **delta**: web #250 |
| Project row subtitle | Needs you (· N unread), else working / unread, else *N complete* / stopped: `A/Projects/ProjectRow.swift:75-96` | No complete / stopped fallback: `R/Projects/ProjectListView.swift:143-151` | As the window: `W/model/groups.ts:176-188` | **delta**: Remote #226 |
| Project row menu | Dashboard, New Session, Project Settings…, Archive, Show in Finder: `A/Projects/ProjectListView.swift:511-542` | None: the row is a button | Dashboard, New Session: `W/views/Sidebar.tsx:197-201` | Web: **by design** (Settings, Archive and Finder are the Mac's, #151). Remote: **delta** #226 |
| Archived projects fold, Bring Back | `A/Projects/ProjectListView.swift:87-95, 596-623` | None | None (`W/model/store.ts:779` asks without archived) | **delta**: decide, #267 |
| Activity rows | Events, Resources, Runtimes, Spending at the top, no icons (#155): `A/Projects/ProjectListView.swift:54-59` | Events, Spending, Resources after the projects, with icons; no Runtimes row: `R/Projects/ProjectListView.swift:32-41` | As the window: `W/views/Activity.tsx:95-131` | **delta**: Remote #226 |
| Session groups and their folds, counts and tint when folded (#181) | `A/Projects/ProjectListView.swift:356-397` | The same rules on the project page: `R/Projects/ProjectPageView.swift:94-124` | `W/views/Sidebar.tsx:230-263` | **same** (where the Remote draws them: #226) |
| Group order: by start, newest first (#182) | `ProjectShelf` | `ProjectShelf` | `W/model/groups.ts` (`byStart`), held to `Fixtures/web/groups/panels.json` | **same** |
| Pinned sessions (#180) | Pinned group; order by drag: `A/Projects/ProjectListView.swift:383-390` | Move Up / Down in the long press: `R/Projects/AgentCard.swift:209-218` | Move Up / Down in the row menu: `W/views/Sidebar.tsx:339-348` | **by design** (drag on the window; menus where there's no drag) |
| "No sessions yet" | Only with no live session at all, pinned included: `A/Projects/ProjectListView.swift:319, 452` | n/a | Also under a Pinned group when every live session is pinned: `W/views/Sidebar.tsx:177-179, 264` | **delta**: web #250 |
| Archived sessions fold | *Archived sessions*, 50, *Show all N* while searching: `A/Projects/ProjectListView.swift:401-441` | *Archived*, 10 at a time: `R/Projects/ProjectPageView.swift:207-234` | As the window: `W/views/Sidebar.tsx:265-283` | **delta**: Remote #226 |
| Workflows and Archived workflows folds | Siblings: `A/Projects/ProjectWorkRows.swift:33-55` | `R/Projects/WorkflowsSection.swift` | Archived nested inside Workflows: `W/views/Sidebar.tsx:284-314` | **delta**: web #250 |
| Search (#176) | After a 150 ms pause, every project, capped pages per host, *More matches…*: `A/Projects/ProjectListView.swift:106-120` | One project's page: `R/Projects/ProjectPageView.swift:34, 53-57` | As the window (#193): `W/views/Sidebar.tsx:52-68` | **delta**: Remote #226 |
| Sidebar foot: host notices | *Connecting…*, or the host-down notice with Try Again; *X is offline*: `A/Projects/ProjectListView.swift:551-577` | *offline* on the host heading | *This Mac's host isn't answering* even while only connecting: `W/views/Sidebar.tsx:74, 108-117` | **delta**: web #250 (connecting). Try Again on the page: **by design** (#83, nothing of its own to redial) |
| Files the host couldn't read (`store/notes`, #205) | Sidebar foot: `A/Projects/ProjectListView.swift:580-587` | A section at the foot of the projects list, asked on each catch-up: `R/Projects/ProjectListView.swift:42-55` | Sidebar foot, a server's named: `W/views/Sidebar.tsx:117-125` | **same** (#223) |
| Keeping this Mac awake | Wake row: `A/Projects/ProjectListView.swift:745-809` | None | None | **by design** (the Mac's setting; the page isn't told the wake state, #151) |
| Forget this client | None (the window is paired by its Mac) | Only when the control plane refuses it: `R/Link/ControlPlaneLink.swift:70-75` | *Forget This Browser…*: `W/views/Sidebar.tsx:118-128` | **delta**: decide, #267 |

## Session rows and states

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Status shape and tint | `A/AgentList/AgentRow.swift:294-348` | The same shape: `R/Projects/AgentCard.swift:274-284` | Ported: `W/model/status.ts:44-92` | **same** |
| Spoken status words | `StatusShape.words` (*Unread ·*, *Waiting for an allowance*) | `StatusShape.words(row:)`: `R/Projects/AgentCard.swift` | `W/model/status.ts` | **same** |
| Coming back after a restart | Spinner and words: `A/AgentList/AgentRow.swift:60, 277` | `R/Projects/AgentCard.swift:68, 270` | Never: `isComingBack` not passed, `W/views/SessionRow.tsx:16` | **delta**: web #251 |
| Unread mark (#70) | Dot, semibold: `A/AgentList/AgentRow.swift:76-83` | `R/Projects/AgentCard.swift:80-89` | `W/views/SessionRow.tsx:74-75` | **same** |
| Report line, title owning its line (#68) | `A/AgentList/AgentRow.swift` | `R/Projects/AgentCard.swift` | `W/views/SessionRow.tsx:69-92` | **same** |
| Started-by mark (workflow, agent) | `A/AgentList/AgentRow.swift:84-208` | Workflow and agent: `R/Projects/AgentCard.swift` | None | **delta**: web #251 |
| Background line | `A/AgentList/AgentRow.swift` | `BackgroundWords.mark`: `R/Projects/AgentCard.swift` | `W/views/SessionRow.tsx:69-92` | **same** |
| Lease mark | `A/AgentList/AgentRow.swift:153` | `R/Projects/AgentCard.swift:145` | None | **delta**: web #251 |
| Event-wait line, retirement note | `A/AgentList/AgentRow.swift` | `R/Projects/AgentCard.swift` | None | **delta**: web #251 |
| Block lines (#152, #157) | Under the report: `A/AgentList/AgentRow.swift` | The same | Same words: `W/model/block.ts`, held to `Fixtures/web/block/lines.json` | **same** |
| Carry on | Row button and row menu: `A/AgentList/AgentRow.swift:189-216` | Long press: `R/Projects/AgentCard.swift:180-187` | Chat strip only, not the row menu: `W/views/SessionMenu.tsx:16-44` | **delta**: web #250 (menu). The row button: **by design** (the page's row is itself a button, #157) |
| Park line | `S/ParkWords.swift` on the row | The same | `W/views/SessionRow.tsx:40-66` | **same** |
| Worktree badge | ⑂ name, struck when gone, help *branch — path*: `A/AgentList/AgentRow.swift:361-386` | Struck when gone, help *branch — path*: `R/Projects/AgentCard.swift` | Struck; help the branch only: `W/views/SessionRow.tsx:84`, `W/app.css:561` | **same**; web #251 |
| Folder is missing (#119) | On the row | On the row | On the row | **same** |
| Labels | Every chip: `A/AgentList/AgentRow.swift:138-148` | Two, then *+N*: `R/Projects/AgentCard.swift:22-45` | Every chip: `W/views/SessionRow.tsx:85` | **by design** (phone width) |
| Last-activity time in the corner | None | None | *5m*, *3h*, *2d*: `W/views/SessionRow.tsx:93` | **delta**: decide, #267 |
| In flight, "telling …" (#87) | The host's name: `A/Permission/AnswerRecipient.swift:6-9` | The host's name: `R/RemoteModel.swift` `answerRecipient`, at `R/Projects/AgentCard.swift:122` and four more | `store.recipient(host)`: `W/model/store.ts:1111-1113` | **same** (#239) |
| One action at a time, held while telling (#87) | `A/AgentList/AgentRow.swift` | `R/Projects/AgentCard.swift` | `W/views/SessionRow.tsx` | **same** |
| Row actions | Carry on, Stop, Bring Back, Retire Now…, Mark Read / Unread, Pin, Branch, Park, Archive, Show in Finder: `A/AgentList/AgentRow.swift:213-268` | Stop, Bring Back, and the other card actions: `R/Projects/AgentCard.swift` | Stop, Park / Unpark, Mark, Pin, Bring Back / Archive, Move: `W/views/SessionMenu.tsx:16-44` | **same** for Stop and Bring Back; Branch #267. Retire Now and Show in Finder: **by design** (retention and Finder are the Mac's) |
| Swipe | Pin; Archive, or Bring Back when archived: `A/Projects/ProjectListView.swift:487-506` | Pin; Archive, or Bring Back when archived: `R/Projects/AgentCard.swift` | None | **same**; web: **by design** (no swipe) |
| Swipe waits for the swipe to close (#74) | Yes | Yes | n/a | **by design** (the page has no swipe) |
| Mark Read / Unread reaches the agent's host | Per host | Per host: `R/RemoteModel.swift:2493-2507` | Per host: `W/views/SessionMenu.tsx:78` | **same** (#238) |
| Rename | None | None | None | **same** |

## Chat turns and turn detail

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Outcome / Steps / Details, and the chooser (069) | View ▸ Turns: `A/Commands/AgentsCommands.swift:113` | ··· ▸ Turns show: `R/Chat/RemoteChatView.swift:265` | A select in the chat's head, kept: `W/views/Chat.tsx:29-37, 193` | **same** |
| Reconnect catch-up keeps one row per turn and entry id (#221) | `K/Client/AgentsModel.swift`; rows deduplicated in `S/Chat/ChatTranscript.swift` | Shared | `W/model/store.ts` | **same** |
| Concise turn: prompt, *7 steps*, reply, report; no chevron (#148) | `S/Chat/TranscriptRows.swift:38-158` | Shared | `W/views/chat/Rows.tsx:345-399` (walked, #148) | **same** |
| An open call: diff, Argument, Return (#153) | `S/Chat/TranscriptRows.swift:572-675` | Shared | `W/views/chat/Rows.tsx:128-187`; drops non-text content (`:165-167`) | **delta** (minor): web #252 |
| Show in Changes under an edit (#153) | `A/Chat/ChatView.swift:82-88` | Opens what the agent did to that file, in a sheet (#242): `R/Chat/RemoteChatView.swift`; a Changes of its own is #245 | `W/views/Chat.tsx:76-79` | **same** |
| A location in a call | Opens in the Mac's editor: `A/Chat/ChatView.swift:74` | Opens in Files at the line: `R/Chat/RemoteChatView.swift:222-228` | Opens in Files: `W/views/Chat.tsx:72-75` | **by design** (only the Mac has an editor) |
| Terminal output in a call | `S/Chat/ChatBlocks.swift:151` | Shared | *shown in the Mac window*: `W/views/chat/Rows.tsx:166` | **by design** (no terminal on the page) |
| Markdown: code colour, task lists | `S/Page/MarkdownText.swift:24, 204`, `S/Code/CodeBlockText.swift` | Shared | No colour, no checkboxes: `W/render/markdown.ts:89-93` | **delta**: web #252 |
| Pictures in messages | `S/Chat/ChatBlocks.swift:40-51` | Shared | *[image]*: `W/views/chat/Rows.tsx:40` | **delta**: web #252 |
| Plan; a withdrawn plan | `S/Chat/ChatBlocks.swift:177-223` | Shared, plus a current-plan strip: `R/Chat/PlanView.swift:13-69` | Withdrawn ignored: `W/views/chat/Rows.tsx:87-96` | **delta**: web #252; the plan strip #267 |
| Switch note and handoff | `S/Chat/SwitchNote.swift:7-24` | Shared | Headline only: `W/views/chat/Rows.tsx:198-212` | **delta**: web #252 |
| Jump to end | Whenever scrolled away, *Something new*: `S/Chat/JumpToEnd.swift:9-43` | Shared | Only on news, *New messages ↓*: `W/views/Chat.tsx:221` | **delta**: web #252 |
| First open: the last 12 turns, earlier ones at the top (#90, #91) | 12: `K/Daemon/DaemonAPI.swift` (`TurnsRequest.opening`, #242) | 12, the same request: `R/RemoteModel.swift` | 12: `W/model/store.ts` (`openingTurns`) | **same** |
| A finished turn longer than a page | One call for up to the host's ceiling (1,000), kept for every turn opened: `A/AppModel.swift` turnEntries, `S/Chat/ChatTranscript.swift` fetchedTurns | The same: `R/RemoteModel.swift` turnEntries | The last 200, then Earlier steps; eight open turns kept: `W/model/store.ts` turnEntries, `W/views/Chat.tsx`, `W/views/chat/Rows.tsx` | **delta**: mac #285, remote #215 |
| Coming back after a restart, in the chat | `S/Chat/ChatTranscript.swift:135-136` | Shared | Only *Working*: `W/views/Chat.tsx:216-218` | **delta**: web #251 |
| A retired agent | `S/Retired/RetiredAgentPage.swift` with Started by: `A/ContentView.swift:106-108` | With Started by, worded by `K/Client/AgentsModel.swift` (`retiredStarterLabel`, #242) | *New session*, prompt off: `W/views/Chat.tsx:191, 225` | **delta**: web #253 |
| Background work over the prompt, its ending line | Stop, Steps, Output: `S/Chat/BackgroundRows.swift:13-45, 228-262`, `A/Sidebar/BackgroundPane.swift` | Stop and Steps: `R/Chat/PromptBar.swift:54-63` | Names only; no Stop, no Steps: `W/views/Chat.tsx:309-328` | **delta**: web #253 |
| Sandbox failure card (064) | `S/Chat/SandboxFailureCard.swift:19-68` | Shared: `R/Chat/RemoteChatView.swift:238-252` | Title and details only, no answers: `W/views/chat/Rows.tsx:294-302` | **delta**: web #253 |
| Park line in the chat | `A/Chat/ChatView.swift:141-145` | At the chat's head: `R/Chat/RemoteChatView.swift:89-95` | Row only | **delta**: web #253 |
| Block strip (#157) | Park line and Carry on: `A/Chat/ChatView.swift:134-161` | Carry on in the toolbar: `R/Chat/RemoteChatView.swift:144-154` | Wait lines and Carry on: `W/views/BlockStrip.tsx:7-17` | **delta**: decide, #267 (wait lines in the chat on the page only) |
| Folder is missing strip, refused send (#119) | `A/Chat/MissingFolderStrip.swift` | `R/Chat/RemoteMissingFolderStrip.swift`, alert `R/RemoteApp.swift:135-151` | `W/views/MissingFolder.tsx:30-55` (inline notice) | **same** |
| Who is asking, on a card (#121) | `askerLine` | `askerLine` | `W/model/asker.ts`, held to `Fixtures/web/asker/line.json` | **same** |
| Crowd mark on an empty chat | `A/Chat/CrowdMark.swift` | None | None | **by design** (decoration of the window's empty chat) |
| Context meter | `A/Chat/ContextMeter.swift:15` | Its own copy: `R/Chat/RemoteChatView.swift:289-343` | None | **delta**: web #254 |

## Prompt bar and queued prompts

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Layout (#108) | `A/Chat/PromptBar.swift` | `R/Chat/PromptBar.swift` | `W/views/Prompt.tsx` (walked, `walks/108/`) | **same** (each to its width) |
| The bar's head: place, labels, runtime | `A/Chat/PromptBar.swift:246-269, 353-363` | Over the field: the place (said, not offered), labels, runtime: `R/Chat/PromptBar.swift` (`PromptHead`, #242) | `W/views/Chat.tsx:230-271` | **same** (moving a session stays the window's, 053) |
| Moving a session to another place (053) | Worktree capsule: `A/Chat/PromptBar.swift:1185-1261` | None | Names the place, can't move: `W/views/Chat.tsx:249-264` | **by design** (moving is the window's) |
| Model and effort | One `ModelPill`: `S/Chat/ModelPill.swift` | One `ModelPill` | A pill each: `W/views/PromptMenus.tsx:44-63` | **delta**: web #254 (or record by design) |
| No-controls note | `OptionsNote`: `S/Chat/PromptPieces.swift` | The same | Nothing: `W/views/PromptMenus.tsx:48` | **delta**: web #254 |
| Sandbox capsule | `S/Chat/SandboxCapsule.swift`, `A/Chat/PromptBar.swift:854-878` | `R/Chat/PromptBar.swift:498-505` | None | **delta**: web #254 |
| Lease and event-wait capsules | `S/Chat/LeaseRow.swift`, `S/Chat/WaitCapsule.swift` | The same, the wait without ✕ (`WaitCapsule.swift:9-10`) | None | **delta**: web #254 |
| Cost / day-limit banner | `S/Chat/PromptPieces.swift:104` | The same | None | **delta**: web #254 |
| Placeholder | `PromptWords.placeholder`: `S/Chat/PromptPieces.swift:14-24` | The same | *Reply…*: `W/views/Chat.tsx:225` | **delta**: web #254 |
| Send / Queue / Stop button | `A/Chat/PromptBar.swift:478-524` | `R/Chat/PromptBar.swift:228-272` | Always *↑ Send*; Stop in ···: `W/views/Prompt.tsx:173-176` | **delta**: web #254 |
| Sending in flight (#87) | Spinner, *telling* after 400 ms: `A/Chat/PromptBar.swift:120-138` | The host's name: `R/Chat/PromptBar.swift:94` | `W/views/Prompt.tsx:119-121` | **same** (#239) |
| Queued prompts as bubbles, Send now, × (#95) | `S/Chat/TranscriptRows.swift:377-463` | Shared | `W/views/Chat.tsx:277-306` | **same** |
| Attachments | Picker, drag, paste: `A/Chat/PromptBar.swift:455-463` | `R/Chat/PromptBar.swift:214` | Picker, drop, paste: `W/views/Prompt.tsx:122-171` | **same** |
| Dictation (#69) | `S/Chat/Dictation.swift` | Shared | None | **by design** (071) |
| Slash commands | `S/Chat/CommandList.swift` | Shared | Over the field: `W/views/Prompt.tsx:223`, `W/model/completions.ts` | **same** (#255) |
| @ file mentions | `A/Chat/PromptBar.swift:644-690` | `R/Chat/PromptBar.swift:418-454` | Asks the host (`files/mention`): `W/views/Prompt.tsx:236`; none on a new session, as the Remote (no agent to ask yet) | **same** (#255) |
| Suggested next prompt (031) | Placeholder and Tab: `A/Chat/PromptBar.swift:67-88` | A chip: `R/Chat/PromptBar.swift:537-561` | None | **delta**: web #254. Placeholder against chip: **by design** (touch) |
| Drafts kept | Across relaunch: `A/Chat/DraftKeeper.swift` | Flushed on going to the background | Memory only, lost on reload: `W/model/store.ts:1009` | **delta**: web #254 |
| Warm on intent (#183) | `A/Chat/PromptBar.swift:175-177` | To the agent's host: `R/RemoteModel.swift:2480-2490` | `W/views/Chat.tsx:50, 229` | **same** (#238) |
| The bar on an archived chat | Shown: *Say what next, and this comes back* | Shown (#242) | Shown | **same** |

## Question and permission cards

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Where they show | Together, over the prompt: `A/Chat/ChatView.swift:172-196` | Together: `R/Chat/RemoteChatView.swift` (#243) | Together: `W/views/Cards.tsx:122-133` | **same** |
| Asker line and title (#121) | `A/Elicitation/ElicitationView.swift:28-34` | `R/Elicitation/ElicitationSheet.swift:28-42` | `W/views/Cards.tsx:117-120` | **same** |
| One-tap single choice | One property only: `A/Elicitation/ElicitationView.swift:37, 303-333` | Also with the optional Other box: `R/Elicitation/ElicitationSheet.swift:79-141` | The window's rule | **by design** (one tap on a phone; `ElicitationSheet.swift:79-89`) |
| Multi-page forms | *1/3*: `A/Elicitation/ElicitationView.swift:89-150` | *Question 1 of 3*: `R/Elicitation/FormPages.swift:50-55` | *1/3*: `W/views/Cards.tsx:209-218` | **same** |
| Date, date-time, email, URL fields | DatePicker: `A/Elicitation/ElicitationView.swift:436-444` | DatePicker, keyboards: `R/Elicitation/FormPages.swift:125-133, 329-357` | The browser's date, datetime-local, email and url inputs: `W/views/Cards.tsx:430`, `W/model/formInputs.ts` | **same** (#265) |
| A field's problem in place | Under every field | Under every part | Under every field: `W/views/Cards.tsx:441` | **same** (#256) |
| Held while sending (#86) | The answer bright, *telling* the host | *telling* the host: `R/Elicitation/ElicitationSheet.swift:188-203` | The host's name: `W/views/Cards.tsx:96-116` | **by design**: buttons replaced on the Remote (layout); the host's name the same since #239 |
| Greyed while the host is down (#83) | `A/Chat/ChatView.swift:179-193` | The agent's host: `R/Elicitation/ElicitationSheet.swift:159-162`, `R/Permission/PermissionSheet.swift:126` | `W/views/Chat.tsx:45-46` | **same** (#239) |
| Decline; a link question | *No thanks*; *Gave up*: `A/Elicitation/ElicitationView.swift:46-62` | As the window: `R/Elicitation/ElicitationSheet.swift` (#243) | As the window: `W/views/Cards.tsx:277-285` | **same** |
| Answered elsewhere | Disappears | Disappears | 4 s, *Answered on another device.*: `W/views/Cards.tsx:145-146` | **by design** (#266): the page may be one of several browsers on one person's devices, and says why the card it was looking at went (spec 071 US2 scenario 5) |
| Keyboard answers | ⌘1…9, Return: `A/Elicitation/ElicitationView.swift:528-540` | n/a | ⌥1…9, Return: `W/views/Cards.tsx:177` | **same** (#256); ⌥ for ⌘ **by design** (a browser keeps ⌘1…9 for its tabs) |
| Permission options | `A/Permission/PermissionView.swift:41-48` | `R/Permission/PermissionSheet.swift:110-127` | `W/views/Cards.tsx:176-184` | **same** |
| What the call will do | Title and kind, plus the diffs and content: `A/Permission/PermissionView.swift:110-125` | Plus the diffs and content: `R/Permission/PermissionSheet.swift:66-106` | Title, kind, diffs and content; a plan instead of *switch_mode*: `W/views/Cards.tsx:224-236` | **same** (#256, #266) |
| Plan approval | Show plan: the file or the text: `A/Permission/PermissionView.swift:96-111` | The file or the text: `R/Permission/PermissionSheet.swift` (#243) | Show plan: the file or the text: `W/views/Cards.tsx:226-231` | **same** (#243, #256) |
| A server key ask | `A/Chat/TokenAskCard.swift`, `A/Hosts/Lending.swift:79-87` | None | None | **by design** (the key is lent from the Mac's Keychain); what the others see: #267 |

## Start sheet and new project

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Its shape | A bar on the project: `A/Chat/PromptBar.swift:242-347` | A sheet: `R/StartAgent/StartAgentView.swift:25-46` | A bar: `W/views/NewAgent.tsx:154-210` | **by design** |
| Runtimes listed by name (#154) | `RuntimeCatalog.sortedByName` | The same | `W/model/runtimes.ts` | **same** |
| Available and Out groups | For this Mac's projects: `A/Chat/PromptBar.swift:310-346, 1065-1087` | The project's host's runtimes, split only for this Mac's projects: `R/StartAgent/ChoiceRows.swift:57-140`, `R/RemoteModel.swift` `startRuntimes` (#240) | Available, Out and Can't start, from the host's `isOut`, in runs only when one is out: `W/views/NewAgent.tsx:289-292`, `W/model/runtimes.ts` | **same** (#240, #257) |
| Default runtime | `RuntimeCatalog.newSessionRuntime`: the kept form's, else Claude, else the first: `A/Chat/PromptBar.swift:1119`, `K/Runtimes/RuntimeCatalog.swift:127-136` | The same rule, on this project's host, its kept choice in its defaults: `R/RemoteModel.swift:472-479, 527` | Its twin, held to the same fixture: `W/model/runtimes.ts`, `W/views/NewAgent.tsx` | **same** (#264) |
| A model out of the pool (#140) | In the chooser | In the menu row | A line under the menus | **by design** (#140) |
| Model, effort, permission | `A/Chat/PromptBar.swift:788-887` | `R/StartAgent/ChoiceRows.swift:22-50, 186-290` | Pills: `W/views/NewAgent.tsx:203-206` | **same** |
| Sandbox choice, and *Start without sandbox* | `A/Chat/PromptBar.swift:854-878, 952-974` | Choice menu, including *Start without sandbox*: `R/StartAgent/ChoiceRows.swift` | Both: `W/views/NewAgent.tsx:363` | **same** (web #257) |
| Options that fail to load | Retry: `A/Chat/PromptBar.swift:745-751` | *Try again*: `R/StartAgent/ChoiceRows.swift:28-33` | *Try again*: `W/views/NewAgent.tsx:219` | **same** (#257) |
| Labels (tag input) | `S/LabelTagField.swift` | Shared | `W/views/Labels.tsx` | **same** |
| Where it runs | Folder; new worktree (or why not); worktrees, missing ones off, *· N agents*; on a branch: `A/Chat/PromptBar.swift:1129-1178` | The same, with git status: `R/StartAgent/ChoiceRows.swift:133-182` | The window's: `W/views/NewAgent.tsx:250-266` | **same** (#257) |
| Reach: extra folders | `A/StartAgent/AgentReachView.swift` | Folder paths in the start sheet: `R/StartAgent/StartAgentView.swift` | Typed paths: `W/views/Reach.tsx` | **same** |
| Reach: MCP servers | `A/StartAgent/AgentReachView.swift` | None | *chosen in the window* | **by design** (the window's) |
| The project's host offline | Send off: `A/Chat/PromptBar.swift:365-372` | Send off, with the strip: `R/StartAgent/StartAgentView.swift:45, 135-139` | Off: `W/views/NewAgent.tsx:144-146` | **same** (#239) |
| Starting, in flight (#87) | Words held, *Starting — telling …* | Spinner, *telling* the project's host | Held: `W/views/Prompt.tsx:92-120` | **same** |
| Attachments, refused before sending | `A/Chat/AttachmentStrip.swift` | `R/StartAgent/PhoneAttachments.swift` | `W/model/attachments.ts` | **same** |
| The form kept between starts | Text, attachments, folder, runtime, reach, options: `A/Chat/DraftKeeper.swift:125-170` | Text, attachments, runtime, reach folders and options: `R/StartAgent/StartDraftKeeper.swift`, `R/RemoteModel.swift` | Text, runtime, reach, options: `W/model/startForm.ts` | **same** (web #257; the folder is not kept, as the window keeps none for the page's places) |
| Prewarm on typing (#183) | Yes | Yes, to the agent's host | Yes | **same** (#238) |
| Add Folder…, Clone Git URL… (#115) | `A/Projects/ProjectListView.swift:150-180`, `A/Projects/CloneSheet.swift` | Actions on the empty-project screen: `R/Sidebar/ProjectRow.swift`, `R/RemoteModel.swift` | `W/views/NewProject.tsx:34-260` | **same** |
| Add Server… | `A/Control/ControlAddServerSheet.swift` | None | None | **by design** (installs over ssh from the Mac) |
| Add Folder on this Mac: Finder drag, the clipboard's URL | Yes | n/a | Browses the host instead | **by design** (#115: no drag from Finder, no clipboard read) |
| No projects yet | Words and buttons, or *No agent runtime found*: `A/Projects/ProjectListView.swift:81-84, 636-655` | Empty-state words and Add Folder / Clone Git URL actions: `R/Sidebar/ProjectRow.swift` | *No projects yet* only: `W/views/NewProject.tsx:85-103` | **same** (web #257; *No agent runtime found* remains window-only) |
| Continue in the project folder (#119, 065) | `A/AppModel.swift:2944-2958` | `R/RemoteModel.swift:2387-2407` | `W/model/store.ts:1088-1091` | **same** |

## Worktrees and Files

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Worktree list, Remove…, Clean up | Project Settings ▸ Worktrees: `A/Projects/WorktreeRow.swift` | None | None | **by design** (Project Settings are the Mac's) |
| Recreate a removed worktree (#119) | `A/Chat/MissingFolderStrip.swift:29-35` | `R/Chat/RemoteMissingFolderStrip.swift:24-26` | `W/views/MissingFolder.tsx:22-23` | **same** |
| Files: a tree, or a folder at a time (#133) | A tree: `A/Sidebar/FilesPane.swift:292-375` | A folder at a time: `R/Panes/FilesPane.swift:103-260` | A tree from 760 px: `W/views/files/Tree.tsx:25` | **by design** (phone width). The iPad: #267 |
| Change marks in Files (#63) | Square, +N −M, folder totals: `A/Sidebar/FilesPane.swift:420-474` | A touched dot only: `R/Panes/FilesPane.swift:248-252` | `W/views/FilesPane.tsx:50-115` | **delta**: Remote #245 |
| Changes: tree, squares, total (#63) | `A/Sidebar/ChangesPane.swift:93-199` | No Changes pane: `R/Panes/PaneState.swift:10-11` | `W/views/Changes.tsx:69-143` | **delta**: Remote #245 |
| Changes: *may include other agents' work* | `A/Sidebar/ChangesPane.swift:142, 185-192` | n/a | None | **delta**: web #259 |
| Diff view | Edits / Whole file, Previous / Next, Open in Files, changed words marked: `A/Sidebar/ChangeFileView.swift` | The agent's edits only: `R/Chat/ChangesView.swift` | Chosen by itself, no controls: `W/views/Changes.tsx:47-67` | **delta**: web #259, Remote #245 |
| An open file follows the disk | `A/Sidebar/FilesPane.swift:94-99` | `R/Panes/FilesPane.swift:75-77` | Read again when anything under the agent changes: `W/views/files/FileView.tsx` | **same** |
| Code with line numbers | `S/Page/FileLines.swift` | Shared | `W/views/files/FileLines.tsx` | **same** |
| Markdown in Files | The live page in place: `A/Sidebar/FilesPane.swift:480-514` | To the Page pane: `R/Panes/PaneState.swift:67-70` | The live page in place: `W/views/FilesPane.tsx` | **same** |
| Pictures, zoom | `A/Sidebar/ImageFile.swift:68-84` | Pinch: `R/Panes/FilesPane.swift:378-474` | Zoom, actual size, fit and a pinch: `W/views/files/ZoomPicture.tsx` | **same** |
| Pictures inside a Markdown page | `S/Page/MarkdownText.swift:144, 214` | Shared | From beside the document: `W/render/markdown.ts` | **same** |
| HTML file (#67) | Page / Source, scripts off: `A/Sidebar/FilesPane.swift:232-261` | The same: `R/Panes/FilesPane.swift:140-165` | Source: `W/views/files/FileView.tsx:83-90` | **by design** (071 FR-031, Trusted Types) |
| Back finds where it was (#66) | `A/Sidebar/FilesPane.swift:76-86` | `R/Panes/FilesPane.swift:47-57` | `W/views/FilesPane.tsx:36, 60-65` | **same** |
| A folder ends on its contents or a sentence (#62); stale reads dropped (#89) | Yes | Yes | Yes | **same** |
| Writing a file: the live Markdown page only | `A/Sidebar/FilesPane.swift:501-506` | `R/Panes/PagePane.swift` | `W/views/LiveDocument.tsx` | **same** |
| Search in files | None | None | None | **same** |
| Exchanged documents | `A/Sidebar/ArtifactsPane.swift` | `R/Chat/DocumentView.swift` | `W/views/Exchanged.tsx` (a web address is a link) | **same** |
| Terminal | Tabs (055): `A/Sidebar/TerminalPane.swift` | One shell: `R/Panes/TerminalPane.swift` | None | Web: **by design** (071). The Remote's one shell: #267 |
| Browser pane | `A/Sidebar/BrowserPane.swift` | None (FR-030) | None | **by design** (local servers only listen on the Mac) |
| Open in another app, Show in Finder | `A/Sidebar/OpenElsewhere.swift` | *It can't be shown here.* | *It can't be shown here.* | **by design** |

## Dashboard and pins

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Dashboard row and page (#122) | `A/Dashboard/DashboardPage.swift` | `R/Dashboard/DashboardPage.swift` | `W/views/Dashboard.tsx` | **same** |
| Tile kinds, sparklines, greying when stale | `S/Dashboard/TileCard.swift` | Shared | `W/views/Dashboard.tsx:259-305` | **same** |
| Tile detail, its History row (#127) | `A/Dashboard/DashboardPage.swift:343-383` | None | All but *Greyed after*: `W/views/Dashboard.tsx:356-381` | **delta**: Remote #246; web #246 |
| Hide, Show, Remove, Show Hidden Tiles | `A/Dashboard/DashboardPage.swift:86-93, 283-289` | Hide and Remove; nothing brings one back: `R/Dashboard/DashboardPage.swift:70-74, 187-193` | `W/views/Dashboard.tsx:75-79, 241-244` | **delta**: Remote #246 |
| Order: drag, Move items (#147) | Drag and every Move item: `A/Dashboard/DashboardPage.swift:174-187, 292-316` | Tile Move items; no section moves: `R/Dashboard/DashboardPage.swift:198-223` | Drag and every Move item: `W/views/Dashboard.tsx:99-204` | **delta**: Remote #246 (section moves). No drag on the Remote: **by design** |
| Update now (#146) | `A/Dashboard/DashboardPage.swift:98-136` | In the toolbar: `R/Dashboard/DashboardPage.swift:103-158` | `W/views/Dashboard.tsx:137-169` | **same** |
| *‹project› · updated …* | `A/Dashboard/DashboardPage.swift:81, 138-146` | None | `W/views/Dashboard.tsx:87-88` | **delta**: Remote #246 |
| A store file set aside, said (#171); the footer sentence (#127) | `A/Dashboard/DashboardPage.swift:24-29, 47-50` | `R/Dashboard/DashboardPage.swift:65-69, 88-92` | `W/views/Dashboard.tsx:90, 129` | **same** |
| Pinned page rows (#159) | Drag; Open, Move Up / Down, Unpin: `A/Projects/PinnedPageRows.swift` | Long press: `R/Dashboard/PinnedPage.swift:8-60` | Drag and the menu: `W/views/Pins.tsx:17-73` | **same** (no drag on the Remote: **by design**) |
| A pinned Markdown page, live | `A/Dashboard/PinnedPage.swift:104-106` | `R/Dashboard/PinnedPage.swift:100-131` | `W/views/Pins.tsx:111-133` | **same** |
| A pinned HTML page | Page / Source: `A/Dashboard/PinnedPage.swift:54-61` | Page only: `R/Dashboard/PinnedPage.swift:94-99` | Source: `W/views/Pins.tsx:139-142` | **delta**: Remote #245. Web: **by design** (Trusted Types) |
| Pin from the Files bar | Any Markdown or HTML file: `A/Sidebar/FilesPane.swift:192-230` | None | Any Markdown or HTML file open under Files: `W/views/FilesPane.tsx` | **delta**: Remote #245 |
| A missing pin | `A/Dashboard/PinnedPage.swift:85-99` | `R/Dashboard/PinnedPage.swift:83-92` | `W/views/Pins.tsx:125-131` | **same** |
| A page tile | `A/Dashboard/PinnedPage.swift:222-273` | `R/Dashboard/PinnedPage.swift:158-215` | `W/views/Dashboard.tsx:330-354` | **same** (HTML as source on the page: **by design**) |

## Workflows page

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Status card (#142) | `A/Projects/WorkflowPage.swift:225-273`, `S/WorkflowStatus.swift` | `R/Projects/WorkflowPage.swift:120-165` | `W/views/WorkflowPage.tsx:83-95` | **same** |
| An unreadable workflow file | Its text under *The file is below*: `A/Projects/WorkflowPage.swift:211-218` | *The file is below*, and nothing: `R/Projects/WorkflowPage.swift:79-90` | *Fix its file*: `W/model/workflows.ts:541` | **delta**: Remote #247 |
| Triggers, next runs, last ran (#98, #99) | `A/Projects/WorkflowPage.swift:285-452` | The soonest run only | `W/views/WorkflowPage.tsx:109-150` | **delta**: Remote #247 |
| An event trigger's words | Its catalogue meaning | n/a | The event's name: `W/model/workflows.ts:70-75` | **delta**: web #260 |
| Recent runs | Asked of the host, archived included, Show more: `A/Projects/WorkflowPage.swift:848-879` | The same: `R/Projects/WorkflowPage.swift:547-567` | Loaded ones, up to 6: `W/views/WorkflowPage.tsx:47-49, 153` | **delta**: web #260 |
| Enabled switch, in the file (#100, #125) | `A/Projects/WorkflowPage.swift:177-186` | `R/Projects/WorkflowPage.swift:194-196` | `W/views/WorkflowPage.tsx:71-75` | **same** |
| Approve | Page and row menu: `A/Projects/ProjectWorkRows.swift:166-168` | Page; the row says *on the Mac*: `R/Projects/WorkflowsSection.swift:76-78, 149-150` | Page: `W/views/WorkflowPage.tsx:64-68` | **delta**: Remote #247, web #260 |
| Archive and Bring Back | Page, row menu, swipe | Toolbar, long press | Page: `W/views/WorkflowPage.tsx:58-78`; not the row | **delta**: web #260 |
| Run Now | Page and row menu | Page and long press | Page and the row | **same** |
| The row's second line | Summary | Next run and last outcome: `R/Projects/WorkflowsSection.swift:142-162` | Summary | **by design** (the card has room) |
| Settings: runtime, permission, model, effort, labels (#162) | `A/Projects/WorkflowPage.swift:479-592` | A row each: `R/Projects/WorkflowPage.swift:291-512` | Pills: `W/views/WorkflowSettings.tsx:44-139` | **same** |
| Cooldown | A menu: `A/Projects/WorkflowPage.swift:310-339` | A sentence when set: `R/Projects/WorkflowPage.swift:132-134` | A menu: `W/views/WorkflowSettings.tsx:142-157` | **delta**: Remote #247 |
| An unreadable file locks the settings (#179) | `S/WorkflowStatus.swift:144` | `R/Projects/WorkflowPage.swift:296, 333, 510` | `W/views/WorkflowPage.tsx:44` | **same** |
| Writing a workflow | None (the author's) | None | None | **same** |

## Settings and Project Settings

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Settings (General, Appearance, Agent Runtimes, Shared, Limits, Resources, Control plane) | `A/Settings/SettingsWindow.swift` | None | None | **by design** (the Mac's) |
| Project Settings (helper limits, disk lines, MCP, plugins, skills, worktrees; #64, #97, #126, #195) | `A/Projects/ProjectSettingsSheet.swift` | None | None | **by design** |
| Add an MCP server, a skill, plugins (059) | `A/Catalog/` | None | None | **by design** |
| Light and dark | System / Light / Dark: `A/Settings/AppearanceSettingsView.swift` | The system's | `prefers-color-scheme`: `W/theme/paper.css:48` | **by design** (a setting) |
| The accent (#156) | AccentColor | AccentColor | `--accent`, the same values | **same** |
| What agents call you (#121) | Settings ▸ General | None | None | **by design** |
| Warm pool size (#183) | Settings ▸ General | None | None | **by design** |

## Pool, runtimes and spending

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Runtimes page: availability, pool note (#140) | `A/Runtimes/RuntimesView.swift:73-122` | `R/Projects/RuntimesView.swift:61-77` | `W/views/Activity.tsx:166-180` | **same** |
| Allowance readings | Yes | Yes | None: never asked | **delta**: web #261 |
| Mark available | Button: `A/Runtimes/RuntimesView.swift:88-93` | Swipe: `R/Projects/RuntimesView.swift:23-28` | None | **delta**: web #261 |
| *N out* in Activity | Allowances out: `A/Runtimes/RuntimesView.swift:131-133` | `anyOut`: `R/Projects/RuntimesView.swift:89` | Pool notes: `W/views/Activity.tsx:58-60` | **delta**: web #261 |
| Assess a runtime (#47) | Settings ▸ Agent Runtimes | *Assess in…* | None | **by design** (#47) |
| Spending: all time, project shares | `A/Spending/SpendingView.swift:31-39` | `R/Projects/TotalsView.swift:31-42` | Today per host only: `W/views/Activity.tsx:226-246` | **delta**: web #261 |
| Today, in Activity | This Mac and every server: `A/Projects/ProjectListView.swift:719-722` | This Mac only: `R/Projects/ProjectListView.swift:189-191` | Every host: `W/views/Activity.tsx:26-32` | **delta**: Remote #248 |
| Close to full | 0.85: `K/Model/Usage.swift:35` | The same | 0.8: `W/views/Activity.tsx:48-52` | **delta**: web #261 |
| Daily limit read-outs | Settings ▸ Limits: `A/Settings/CostSettingsView.swift` | *Today X of limit*, *limit reached*; no per-agent line: `R/Projects/TotalsView.swift:96-121` | Daily and per-agent; no *limit reached*: `W/views/Activity.tsx:236-239` | **delta**: Remote #248, web #261. The setting: **by design** |
| A store file set aside, said (#171) | `A/Spending/SpendingView.swift:26-30` | `R/Projects/TotalsView.swift:26-30` | `W/views/Activity.tsx:240` | **same** |

## Events and resources

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Events ▸ Waiting now | Openable, with ✕: `A/Events/EventsView.swift:58-61, 281-325` | None: `R/Events/EventsListView.swift:31-58` | Titles only: `W/views/Activity.tsx:195-202` | **delta**: Remote #248, web #262 |
| Event rows: consequences, name, scope, days, Show older | `S/Events/EventRow.swift`, `A/Events/EventsView.swift:89, 161-173` | Shared (no kind filter) | A flat list: `W/views/Activity.tsx:203-221` | **delta**: web #262 |
| A workflow in a consequence | A link: `A/Events/EventsView.swift:151` | Plain text: `R/Events/EventsListView.swift:8-10, 45-46` | n/a | **delta**: Remote #248 |
| Resources, counted holders (#116) | `A/Resources/ResourcesView.swift` | Read-only: `R/Resources/ResourcesListView.swift` | Read-only: `W/views/Resources.tsx` | **same** (reading) |
| Declaring resources, ending leases (#116) | Settings ▸ Resources, the Resources page | None | None | **by design** (the Mac's) |

## Notifications and badges

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| Notifications | `A/Notifications/MacNotifier.swift:37-79` | Local and push: `R/Notifications/DeviceNotifier.swift:34-98` | None: `W/presence.ts:5` | **by design** (071: the page takes no notices) |
| The needs-you count | Dock badge: `A/ContentView.swift:267-268` | No icon badge, though it asks for one: `R/Notifications/DeviceNotifier.swift:116, 130` | The tab's title: `W/presence.ts:16-30` | **delta**: Remote #249 |
| Presence: watching and active | Every host; *watching* to the owner: `A/AppModel.swift:2531-2549` | The same: `R/RemoteModel.swift:1604-1618` | The same: `W/presence.ts:36-47` | **same** (#203, checked in #238) |
| Unread counts on project rows and folds (#70) | Yes | Yes | Yes | **same** |

## Disk strip

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| The strip while a volume is low or critical (#195, #196) | `A/Sidebar/DiskStrip.swift` | Under the connection banner: `R/StaleBanner.swift:83-104` | `W/views/DiskStrip.tsx`, words held to `Fixtures/web/disk/lines.json` | **same** (words) |
| A server's disk | A server's `disk/changed` replaces the Mac's, unnamed: `A/AppModel.swift:2040-2076`, `K/Client/AgentsModel.swift:481-482` | This Mac's only | Per host, a server's named: `W/views/DiskStrip.tsx:6-23` | **delta**: Mac and Remote #263 |
| Low and Critical settings | Project Settings | None | None | **by design** |

## Hosts, connection and pairing

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| A down host over a chat (#83) | `A/Chat/OfflineStrip.swift:9-50`, with Try Again | `R/Chat/HostOfflineStrip.swift`, in the window's words (`S/OfflineWords.swift`), no button; the Mac link is `R/StaleBanner.swift` | `W/views/OfflineStrip.tsx`, no button | **by design**: no button on the Remote or the page, which dial the host again by themselves |
| The control plane away | `A/Sidebar/ControlAwayStrip.swift` | `R/StaleBanner.swift` | `W/views/Banner.tsx` | **same** |
| Reconnect on wake and network change (#82) | `A/WakeAndNetwork.swift` | Yes (its hangs are #208, not parity) | Yes, and the `online` event | **same** |
| A refused write said in words (#88) | `storage/writeFailed` | `storage/writeFailed`: `R/RemoteModel.swift` | `storage/writeFailed` (unit-tested) | **same** |
| Hosts and servers | Settings ▸ Control plane: `A/Control/ControlSettingsView.swift:247-269` | Host headings | Names in the sidebar, the foot | **by design** (managing hosts is the Mac's) |
| Pairing | Shows the codes: `A/Control/ControlClientsPane.swift` | Scans: `R/Link/PairingView.swift` | Pastes, or `#code=`: `W/views/Pairing.tsx`, `W/pairLink.ts` | **by design** (#105, #109, #111) |

## MCP Apps views

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| `ui://` views (#187–#191) | Not built | Not built | Not built | **same** (planned for all three in #187) |

## Live sync

#233 asks whether "not in sync" also means one client showing stale state after another acts. From the code:
- **#238 (fixed):** the Remote sent Mark Read / Unread and prewarm for a server's agent to the Mac; they go to the agent's own host now, and presence already did since #203.
- **#263:** a server's disk state overwrites the window's.
- Catch-up and lean changes are #203, #175 and #208; this audit found nothing more there.

## History: the page beside the window (#110)

The record of the walks that brought the page level with the window, from 2026-10-01 to #233. It is kept for its facts and shots; the table above is where each client stands now. Two of its rows have moved on since: the window locks a workflow's settings when its file can't be read, so #179 is done on all three; and the page now has Archive and Bring Back on the workflow page (`W/views/WorkflowPage.tsx:58-78`), though not in the row's menu (#260).

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

### Key

- **has**: the page does what the window does.
- **partly**: the page does some of it; the rest is said.
- **lacks**: the page does not do it.
- **by design**: the page leaves it out on purpose (071 spec), and still does.
- **n/a**: nothing for the page to do.

### The issue's table

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
| Turn detail Outcome/Steps/Details; concise turns; trailing reply | 069, concise turns | has | has | `before-chat-outcome.png`, `before-chat-steps.png` | `window/sessions.png` | Prompt, "▸ 7 steps", the reply, then the report. Since #148, "7 steps" with no chevron, and the turn in the window's serif (below). |
| Labels tag input on start | labels tag input | has | has | `bar.mjs` | `window/sessions.png` | Comma adds, Delete on an empty field removes; above the input on the left (#108). |
| Sessions column as one list; Archived folds named | sessions column | partly (workflows could not be chosen) | **has** | `before-sessions.png`, `after-workflow-triggering.png` | `window/sessions.png` | "Archived sessions" and "Archived workflows" were already named, and search covered both. A workflow row is now chosen like a session row and opens its page. |
| Queued prompts look | #95 | n/a | n/a | — | — | #95 has not landed. Queued rows read "Waiting its turn" with Send now and ×. |
| Prompt bar layout | #108 | has | has | `walks/108/` | `walks/108/window-*.png` | `bar.mjs` re-run on this branch: every control where #108 put it, no problems at 1440 or 390. |

### Also merged since 2026-09-29

| Change | Issue | Before | Now | Page shots | Window | Notes |
|---|---|---|---|---|---|---|
| Changes as a tree, status-coloured squares | #63 | lacks (a flat list, state in words) | **has** | `before-changes.png`, `after-changes.png` | `window/changes.png` | ChangeTree ported: folders first, one-folder chains on one line, totals, folders close. A square in its status colour, with the status in words for a reader. Headed "4 files · +33 −0", as the window's is. The window's note that git's changes may include other agents' work is not on the page. |
| Files: the same rows as Changes | #63 | lacks | **has** | `before-files.png`, `after-files.png` | `window/changes.png` | A changed file has its square and +N −M; a folder the total under it. Since #133 the page draws Files as a tree from 760 wide (see the next row); below that it lists a folder at a time, as the Remote does. |
| Files: Back finds where it was, the file marked | #66 | partly (back to the folder) | **has** | `before-files-back.png`, `after-files-back.png` | — | The file last open is marked. |
| Files as a tree: folders open in place and stay open, the open file marked with its folders open, the keys | #133 | lacks (a folder at a time) | **has** | `walks/133/tree-*.png`, `walks/133/phone-folder-list.png` | `walks/133/window-tree.png` | From 760 wide. Folders are read when opened, and only the rows in view are drawn (a folder of 3000 drew 40). Up and down move, left shuts or steps out, right opens or steps in, Return opens; Home and End too. Each folder's reads are numbered, so a slow one is dropped (#89). Below 760 the page keeps the Remote's one folder at a time (web: by design, a phone's width has no room for the indents). Walked by `Web/test/walk/filestree.mjs`, notes in `walks/133/notes.txt`. The window writes +1 −0 where the page writes +1, as the page's Changes already does. |
| A folder always ends on its contents or a sentence | #62 | has | has | — | — | A listing that fails says why; an empty one says "Nothing here." |
| Files pane drops stale reads | #89 | has | has | — | — | Already in 071. |
| Session rows: title owns its line; worktree badge beside labels | #68 | has | has | `before-sessions.png` | — | "⑂ reply-one-word-ready audit ui" on the line under the report. |
| Reconnect at once on wake and on a network change | #82 | partly (on coming into view) | **has** | — | — | Also on the browser's `online` event. |
| Connect…: a deadline and words a person reads | #84 | has | has | — | — | Each pairing step has a 15 s deadline, and the page's own sentences. |
| A chat opens with its last 12 turns | #90 | lacks (50) | **has** | — | — | Earlier turns come as the top is reached, as before. |
| HTML opens as a live page | #67 | by design | by design | — | — | 071 FR-031: the page shows HTML as source and runs nothing. |
| Helper limits per project | #64 | by design | by design | — | — | A setting. |
| Helper limits kept in the project's `.agents/project.json`, and Project Settings says so | #126 | by design | by design | — | — | Still a setting, the Mac's alone (Project Settings ▸ General), as on the Remote. Nothing the page shows changed: it never showed the limits. |
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
| No chevron on a turn's margin lines (2026-10-02) | #112 | has the chevron (▸/▾ on every call line that opens, in a turn and out) | **has** | `before112-margin.png`, `after112-margin.png` | `window/112-before-steps.png`, `window/112-after-steps.png`, `window/112-after-details.png` | Walked at ec46210e on `/tmp/run-i112b` (one real Claude turn), in headless Chrome (the `margin` scene of `parity.mjs`: 6 chevrons before, 0 after; "Read file" still opens) and the window by window id over AX. A step is a plain line in the margin on both; an open call's detail sits under its line. "Hide steps" kept its chevron until #148 (below). |
| An agent whose folder has gone: Folder is missing on the row, a strip over the chat, a refused send with the ways on (2026-10-02) | #119 | lacks (a send failed with the host's words and nothing else) | **has** | `119/119-web-strip-1440.png`, `119/119-web-refused-1440.png`, `119/119-web-successor-1440.png` | `119/window-strip.png`, `119/window-recreated.png`, `119/window-successor.png` | Walked on `/tmp/run-f119` (a real Claude agent in a worktree, parked, the worktree removed with `git worktree remove`), in headless Chrome (`Web/test/walk/foldergone.mjs`) and the window by window id. Both say *Folder is missing* on the row and over the chat with the path, refuse a send with *This agent's folder isn't there any more (…). It was a worktree, and may have been removed after merging.*, keep the words in the prompt, and offer Continue in the project folder, Recreate the worktree (while its branch is kept) and Archive. Continue carries what was typed. The window's refused-send alert was proved over the socket (-32004 with these words, nothing queued, still parked) but not drawn: an AX-set prompt never reaches SwiftUI's binding, and typing needed the front window while Alex was at the keyboard. |
| Who is asking, at the head of every question and permission card: title and runtime, and a helper's starter (2026-10-02) | #121 | lacks (a subagent's name only) | **has** | `121/121-web-asker.png` | `121/window-asker.png` | Walked on `/tmp/run-i121` with a real Claude agent asking through `ask_form` after the briefing named it and the person ("Alex, should the new file Claude (this agent)…"), in headless Chrome (the `asker` scene of `parity.mjs`) and the window by window id. Both head the card with *Asked by “…” (Claude)*; the words are pinned for the page by `Fixtures/web/asker/line.json` (titled, a helper with its starter, a starter gone, untitled, a subagent). The Remote's sheets use the same `AgentsModel.askerLine` (built, not looked at). **web: by design** for Settings ▸ General ▸ What agents call you: it is the Mac's, as on the Remote. |

### Since this walk

| Change | Issue | Page | Notes |
|---|---|---|---|
| Declared resources with descriptions, counted holders ("2 of 3 held") | #116 | **has**, read-only | A **Resources** fold under each host lists the declared resources with their descriptions and "2 of 3 held", each holder, and anything else held or awaited; kept by `leases/changed` (added to `WebSignatures`). **web: by design** for declaring, editing and ending leases: they are the Mac's (Settings ▸ Resources, the Resources page), as on the Remote. |
| The project Dashboard: row at the top of the sessions column, page of tiles, greying, detail, Hide/Show/Remove, live | #122 (074) | **has** | Same row, sections, grid (tables and notes across), SVG sparklines, greyed stale tiles, a keeper foot that opens the session or workflow; Hide/Show/Remove and Details… in a tile's ···. Show Hidden Tiles is a check box in the page's head, where the window has it in a menu. Shots: `specs/074-project-dashboard/walks/074-web-*.png`; window: `specs/074-project-dashboard/look/mac-dashboard.png`. |
| Workflow Enabled and Archive are lines in the workflow's file (`enabled: false`, `archived: true`), and each page says so under the switch | #125 | **has** | The page's Enabled switch writes the file as the window's does, and the page says the window's sentence under it: *Enabled and Archive are saved in .agents/workflows/<id>.md, a file in this project you may commit*. A workflow turned off on another clone reads *Off: its file says enabled: false*, on every client. The page has no Archive (by design, as before: Archive and Bring Back are the window's and the Remote's). |
| Number-tile history kept in the project (`.agents/dashboard/history/<id>.jsonl`); the Dashboard says its tiles and trends are project files | #127 | **has** | The window, the Remote and the page end the Dashboard with *Tiles and their trends are files in .agents/dashboard/ in this project, which you may commit.* A number tile's detail adds a **History** row naming its file, on the window and the page (the Remote has no detail). The trend itself comes from the host as before, so nothing else on the page changed. |
| Update now on the Dashboard: runs the `dashboard` workflow or a one-off agent, Updating… while it runs, the last update and its cooldown, why it can't start | #146 | **has** | A button at the right of the page's head, after Show Hidden Tiles (the window has it beside its ··· menu; the Remote in the toolbar), and a line under *updated …*: running with Open Session, the waiting-for-approval refusal with Open Workflow, *Last update 12:11; again from 12:16*. Shots: `specs/074-project-dashboard/walks/146-web-update-*.png`; window: `specs/074-project-dashboard/look/146-mac-update-*.png`. Also fixed here: a status tile's line wore the session list's `.status` ring. |
| Dashboard order: drag tiles within and between sections, drag a section by its heading, Move Up / Move Down / Move to Section in a tile's ···, Move Section Up / Down; kept in `.agents/dashboard/_order.json` | #147 | **has** | HTML drag and drop on tiles and section headings, and the same Move items in a tile's ··· and a section heading's ···, sending `dashboard/arrange` once per drop, as the window does. The Remote has the Move items in its long-press menu, and no drag. Ordering is unit-tested (`Web/test/dashboard-order.test.mjs`); the page's drag isn't walked in a browser yet. Window shots: `specs/074-project-dashboard/walks/147/`. |
| Pinned pages: a project's Markdown and HTML pages under it in the sidebar, before its sessions, open live in the chat's place; drag or Move Up / Down to re-order, Unpin; the pin in the files pane's bar; a `page` Dashboard tile; `pin_page`, `unpin_page`, `move_pin`; at most 10 a project, in `.agents/pins.json` | #159 | **partly** | The same rows (drag, Move Up / Move Down / Unpin in the menu, Missing), the same route into the chat's place (`pg`), Markdown live and typed on through `pins/write`, the files pane's pin, the `page` tile with Open. **web: by design:** an HTML pin, and an HTML page tile, show as source, as the page's files pane shows HTML: the page's policy allows no frames and no HTML of its own making (Trusted Types), which is what keeps an agent's page from running in it. Walked in headless Chrome (`Web/test/walk/pins.mjs`); shots and the window's in `specs/159-pinned-pages/look/`. |
| Assess a runtime: **Assess…** in Settings ▸ Agent Runtimes on the Mac, **Assess in…** in a runtime's menu on the Remote's Runtimes page | #47 | lacks, **web: by design** | The page has neither Settings nor a Runtimes page (both left out by design below), so it has nowhere to start one. What an assessment does is all in its conversation, which the page shows like any other: the steps, the form it asks, and the app's scored table as a note at the end. |
| A model out of the pool, said where the runtime is chosen: the Runtimes page's line and the chooser on the Mac and the Remote, the line under the new session's menus on the page | #140 | lacks (nothing about the pool at all) | **has** | not shot | not shot | The daemon words it once: `RuntimeStatus.poolNote` carries the Pool page's line whenever the runtime or one of its models is out, and the page shows it under the menus for the runtime chosen. Not walked in a browser; pinned by `ModelFailureTests`. |
| One sidebar: Activity at the top, projects folding open on their sessions and workflows, `host:Project` names, the Mac's state at the foot, two columns (2026-10-03) | #145 | **has**, #151 | From 760 px the page has the window's one sidebar and two columns: Activity (Events, Resources, Runtimes, Spending, each opening a read-only page), every project a folding row with Needs you / Working / unread marks and counts when folded, Archived folded, folds kept in localStorage, `build-box:api-server` names, a project's row opening its Dashboard (✎ New Session in its head), help text with nothing chosen, and the host notices at the foot. ↑/↓ move through the list and open what they land on, ←/→ fold, the menu key or a right click opens a row's menu (a session's ··· actions; a project's Dashboard and New Session). 760–1200 px uses the sidebar too, in place of the projects menu. Shots: `walks/151/`; window: `specs/145-one-sidebar/walks/`. **web: to do, #235:** phone widths still drill one column at a time, the iPhone Remote's old shape; since #226 the iPhone's root is the one sidebar. **web: by design:** *Keeping this Mac awake* (the page isn't told the wake state); Project Settings, Archive and Show in Finder in the project menu; ⌘F, ⌫ and several rows at once. See `walks/151/README.md`. |
| Activity rows (Events, Resources, Runtimes, Today) in the projects' type, no icons (2026-10-03) | #155 | **has** | The page's Activity rows lost their glyphs and take the project names' weight and left edge, as the window's do. Trailing status text unchanged. Window shots: `specs/145-one-sidebar/walks/155/`. |
| A turn's steps with no chevron and no rule or indent (Mac, Remote and page), and the page's turn drawn as the window's | #148 | **has** (an open call's detail: **partly**, #153) | Walked 2026-10-03 on two run-app roots, `/tmp/run-i148b` at main 14b8570a (*before*) and `/tmp/run-i148a` at this branch (*after*). Each had one real Claude turn: read a file, list a folder, write `notes.md`. The page was walked in headless Chrome (the `turn` scene of `parity.mjs`) and the window by window id over AX, at Outcome, Steps and Details: `walks/148/{before,after}-side-by-side-{outcome,steps,details}.png`, with the readings in `walks/148/*-notes.txt`. Before: "▸ 7 steps" / "▾ Hide steps", and the steps 21 px in under a 2 px rule, on both surfaces. After: "7 steps" / "Hide steps", and the steps on the turn's own margin (stepsLeft = turnLeft, no rule). Also fixed on the page: the turn's text is set in the system serif at 15 px, as the window's reading step is (it was 13 px sans); the steps control is 11 px sans, as the window's fine step is (it was 12 px); Argument and Return are tertiary (`faint`), as the window has them; and code in an open call is 13 px. Left for #153: an edit's diff with +/− lines, **Show in Changes**, and locations as links that open the file. |
| An open call's detail: an edit's diff with + and − lines, **Show in Changes** under it, and each location a link that opens the file (2026-10-03) | #153 | **has** | Walked 2026-10-03 on one run-app root, `/tmp/run-i153`, with one real Claude turn that read README.md and edited notes.txt. The page was walked in headless Chrome (the `call` scene of `parity.mjs`), first with main's `Web/dist` (*before*) and then this branch's, and the window by window id over AX at the same open calls: `walks/153/before-call-details.png`, `walks/153/after-call-{details,show-in-changes,location}.png`, `walks/153/window-call-details.png`, with the readings in `walks/153/*-notes.txt`. Before: the edit was the file name, then the old and new text as two plain blocks (one struck through); no Show in Changes; the locations one mono line of plain text. After, as the window has it: the edit's full path at the fine step, then its lines marked − and + in a well capped at 280 px; **Show in Changes** under it at the right, which opens the Files pane on Changes at that file, its diff open; each location (`README.md:1`, `notes.txt:1`) a link in the reading text that opens the file under Files at that line. Claude sent the edit twice (the change, then the whole file), and both draw it twice. The window marks the changed words inside a line, and the page does not, as its Changes already did not. The window opens a location in the Mac's editor; the page opens it in its Files pane, as the Remote does (web: by design, the page has no editor). |
| A blocked agent's wait lines: "Carries on when any of these finishes" or "…all of these have finished" when there are several, each agent waited on with its state, and "Checks again at …" (2026-10-03) | #152, #157 | **has** | Since #157 the page says the window's lines, from the same rules (`Web/src/model/block.ts`, held to `Fixtures/web/block/lines.json`, which `AgentsModel.blockLines` writes): under the report on the session row, and in a strip under the chat's head with **Carry on** (its help as the window's). On the session row in the one sidebar (#151), the narrow sessions list and a workflow's recent runs. Walked on `/tmp/run-b157`, rebased onto main at b9de40ac, with two real blocked Claude haiku leads, one waiting on all of two haiku helpers (one finished, one still asking), one on any of two (both still asking), each with a time to check again, in headless Chrome at 1440 wide (`Web/test/walk/blocked.mjs`) and the window by window id: the same lines, word for word. Shots: `157/web-rows-1440.png`, `157/web-chat-all-1440.png`, `157/web-chat-any-1440.png`; window: `157/window-rows.png`. **Difference:** the window has Carry on on the row too; the page's row is itself a button, so its Carry on is in the chat's strip, where the window's chat has it as well. |
| Runtimes listed alphabetically by name everywhere, and Claude still the new session's default (2026-10-03) | #154 | lacks (the menu in the daemon's catalog order) | **has** | `154/web-new-session.png` | `154/window-runtimes.png`, `154/window-new-session.png` | The daemon's `runtimes/list` is sorted at the source (`RuntimeCatalog.builtIn`); the page sorts a host's list again on arrival (`Web/src/model/runtimes.ts`, the same rule as `RuntimeCatalog.sortedByName`) for a host on an older build, and picks Claude first when it can start rather than the list's first. Walked on `/tmp/run-i154` in headless Chrome (the `runtimes` scene of `parity.mjs`): the menu read Claude, Copilot, Cursor, Grok with Claude chosen; the window's Runtimes page read Antigravity … OpenCode, and its new session opened on Claude. Pinned by `Web/test/runtimes.test.mjs` and `RuntimeOrderTests`. |
| The app icon's violet as the accent: links, focus, the prominent button and Send, switches and checkboxes, light and dark (2026-10-03) | #156 | **has** | Walked 2026-10-03 on one run-app root, `/tmp/run-accent`, with one real Claude turn whose prompt holds a link, and one workflow. The page was walked in headless Chrome (`Web/test/walk/accent.mjs`) and the window by window id over AX: `specs/156-accent/web-{pairing,session,workflow}-{light,dark}.png` and `specs/156-accent/mac-{session,workflow}-{light,dark}.png`. Before, the page had no accent: links and focus rings were the browser's blue (or a stray #2f6fd1 fallback) and the prominent button was ink. Now `--accent` is #5B3BE0 light and #AB8EFF dark, the window's AccentColor, with `accent-color` on `:root`; the prominent button, Send and Run Now are accent-filled with the ground as their text, on both surfaces. |
| Workflow page: every attribute, in the window's order — a Status card (why it is or isn't running), agent mode in words and the exact standing agent, settings, labels, cooldown, keys from a later version; Approve and Archive / Bring Back beside Run Now and Enabled (2026-10-03) | #142 | lacks (one "happening" line, triggers, prompt and runs; approval "on the Mac") | **has** (#162) | `specs/142-workflow-page/web-{on,off-by-file,awaiting-approval,approved}.png` | `specs/142-workflow-page/shot-{on,off-by-file,awaiting-approval}.png` | Walked 2026-10-03 on one run-app root, `/tmp/run-wf142`, with the three workflows of the look (Nightly review: standing, labels, cooldown, `notify:`; Close landed issues: `enabled: false`; Write release notes: triggering, changed since approved) and one real Claude run of Nightly review. The page in headless Chrome (`Web/test/walk/workflowpage.mjs`), the window by window id over AX. Both: the same status lines in the same order (`WorkflowStatus.swift` and `workflowStatusLines`), "Sends each run to its standing agent" with a link to the agent the daemon keeps, the settings, the labels, "From a later version" with `notify: {…}`. Approve pressed on the page let Write release notes run. Since #162 the page edits them too: the runtime top right, the permission mode left and model, effort and the runtime's other options right under the prompt (choices from `options/remembered`), the labels in the sessions' tag input, and the cooldown menu under the triggers, each writing its one key through `workflows/settings` (added to `WebSignatures`). Walked 2026-10-03 on `/tmp/run-wf162` in headless Chrome (`Web/test/walk/workflowsettings.mjs`): each change read back from the file, a refusal (the file made unreadable) said inline with the menu left on the file's value, and the window's page showing the same values by window id. Shots: `walks/162/web-{before,after,refused}.png`; window: `walks/162/window-after.png`. **Difference:** the window keeps the model, effort and other options behind one pill; the page draws them as separate pills, as its prompt does. A file that cannot be read locks the page's settings (the window does not yet: #179). |
| A store file set aside as unreadable is said where the store shows: a line on the Dashboard (`_order.json`, its history, the host's `state.json`) and on Spending / Settings ▸ Limits (`spend.json`, `limits.json`) (2026-10-03) | #171 | **has** | The page draws `DashboardSnapshot.note` under the Dashboard's *updated …* line and `CostState.note` in each host's section of Spending, as quiet small text with ⚠︎; the window has it on its Dashboard, Spending page and Settings ▸ Limits, the Remote on its Dashboard and Totals. Window walked on a scratch root (`/tmp/run-i171`) with `spend.json` corrupted: the Spending page showed the line. The page's line is checked by `tsc` only, not walked in a browser. |
| Files the host could not read in this run (set aside, held or kept in part: `devices.json`, `projects.json`, a project's `pins.json`, …) said at the window's sidebar foot from `store/notes` / `store/notesChanged`, and a note in Settings ▸ Agent Runtimes when `credentials.json` won't read (2026-10-04) | #205 | n/a | **has**, #223: the page and the Remote ask `store/notes` on connecting and hear `store/notesChanged`; each note at the foot of the sidebar or the projects list. Limits that don't read already reach them through `CostState.note` (#171), and a refused start comes back as its error. | | | The window's sidebar line was not screenshotted: the Mac was locked. The daemon's side was proved over the socket on a scratch root. |
| Warm on intent: opening a session or typing in its box starts its runtime ahead of the prompt (`agents/prewarm`) | #183 | lacks | **has** | — (no visible change) | — (no visible change) | The page sends it on opening a chat and on its first keys, once per session and reason every 15 s, as the window and the Remote do; `test/store.test.mjs` holds the debounce. **web: by design:** the pool size is a Mac setting beside Sleep (Settings ▸ General), which the page does not show, as it does not show the wake setting. |
| A session group's rows in the order they started, newest first, so clicking a working session or its new lines never move it; Archived stays newest activity first (2026-10-03) | #182 | lacks (newest activity first) | **has** | The same rule in `Web/src/model/groups.ts` (`byStart`), held to `Fixtures/web/groups/panels.json`, which `AgentsModel` writes. The Remote reads the same `ProjectShelf` as the window. |
| Each session group and Workflows fold at their heading, like the Archived folds, kept across visits; folded, a group still says its count and unread, and a folded Needs you keeps its count in the attention tint; a search unfolds them (2026-10-03) | #181 | lacks (plain headings) | **has** | `<details>` per group in `Web/src/views/Sidebar.tsx`; the folds are kept in localStorage as a *closed* set (`agents.sidebar.folded`), so groups start open. ←/→ on a heading fold it on the page; the window's headings aren't rows of its list, so there they fold by click. The Remote folds the same groups and Workflows, kept on the device. |
| The Remote draws the Mac's one sidebar from the same model (`SidebarProjectFold`, `SidebarOrder`, `SidebarFolds` in AgentsKitCore): the iPad's sidebar beside the detail, the iPhone's root list pushing to it, swipe actions for the Mac's menus (2026-10-04) | #226 | **partly**, #235 | The page's sidebar (#151) already follows the same rules from 760 px; below that it drills one column at a time (#235). Built and not walked on a device: the look on the iPhone and iPad is Alex's. |
| Pinned sessions: a Pinned group under the pinned pages, kept on top whatever their state, still showing state, unread and Needs you and still counted; Pin / Unpin in the row's menu and the Session menu (Mac), the card's long press and swipe (Remote), the row menu and ··· (page); `pin_session` for an agent's own session; in `.agents/pins.json` with the pages; archiving unpins (2026-10-03) | #180 | lacks | **partly** | The page has the Pinned group (folding, kept in localStorage), Pin / Unpin in the row's menu and the chat's ···, and its order from `pins/changed`. **Difference:** the window re-orders pinned sessions by drag; the page and the Remote by Move Up / Move Down in a pinned row's menu, as the Remote does pinned pages. |
| Low disk space: a strip across the top of the window while a volume is low or critical, with how much is free and the largest worktrees; Project Settings ▸ Low / Critical disk space (2026-10-03) | #195, #196 | lacks | **has** (the setting: by design) | `walks/196/web-disk-{critical,low}.png` | not shot (#195's own walk) | Since #196 the page and the Remote draw the window's strip from the same `disk/state`, asked on connect, and `disk/changed`, replaced whole: one row a volume, the dot `--tint-failure` when critical and `--tint-attention` when low, at the top of the page above the columns, and on the Remote under the connection banner on every screen (not while it is stale or unpaired). The words are `DiskAlarm.line`'s, ported in `Web/src/model/disk.ts` and held to `Fixtures/web/disk/lines.json`, which Swift writes (including printf's round-half-to-even on an exact quarter, 12.25 GB → *12.2 GB*). A server's rows are prefixed with its name. Walked 2026-10-04 on `/tmp/run-d196` in headless Chrome (the `disk` scene of `parity.mjs`, which writes #195's `disk-free-override`): *Macintosh HD is almost full: 1.5 GB free. Agents’ commands will start failing.*, then *Macintosh HD is running low: 12.0 GB free (2%).*, gone once the override was removed, and back on a fresh load from `disk/state`. The Remote is built for the generic simulator; its look on the iPhone and iPad is Alex's. **web: by design:** the Low / Critical disk space setting, as Project Settings and helper limits are (below); the Remote doesn't have it either. |
| A tool's `ui://` view drawn in the chat (MCP Apps): inline and full screen, themed, sized by the view, its app-only tool, ui/message after the person's Send, model context told with the next message, torn down when the chat changes; an undeclared domain blocked (2026-10-04) | #187 | **has** | The page draws the view through the spec's sandbox proxy at `127.0.0.1` (the page is at `localhost`), framed by the page alone and under the view's own policy; the window and the Remote in a WebKit view of their own. Same bridge rules on both (`AppViewBridge.swift`, `appViewBridge.ts`), described in `docs/explanation/views.md`. Walked 2026-10-04 in headless Chrome (`Web/test/walk/views.mjs`) on a run-app root with a real Claude session that called `show_test_view`: drawn through the proxy at `127.0.0.1` (`sandbox="allow-scripts allow-same-origin"`), Paper light and dark, Taller 229 → 275, full screen and back, Count twice (`count 1`, `count 2` in the daemon log), Ask the agent → Send went as the person's prompt and the agent answered, Give context was told to the agent with the next message and not in the bubble, opening another chat sent `ui/resource-teardown` and the view answered; `example.com` blocked (fetch and image) by the strict policy. Shots: `specs/187-mcp-apps/walks/web-*.png`. The window walked 2026-10-04 on a scratch root by window id over AX: light (following the system) and dark, Count, Taller, full screen and back, teardown on leaving the chat, `example.com` blocked ("on desktop" in the daemon log); `specs/187-mcp-apps/walks/mac-*.png`. Safari not walked (Alex's own Safari was open). |
| Sidebar search waits for a pause in the typing, shows 10 archived matches a fold then "Show all N", and asks each host for a capped page with "More matches…"; a Dashboard drop is sent one at a time, newest last, and a stale fetch can't undo it (2026-10-03) | #176 | **has**, #193 | The page filters once the typing pauses 150 ms, shows a fold's first 10 archived matches and *Show all N*, and asks each online host for a capped page (`agents/list` with `query`, `limit` 200, `lean`), with *More matches…* asking with the list cursor where a page came back full; a reply for words no longer asked is dropped, and what a search brought in is let go when it ends or changes. The search no longer lists a page of every project's archived sessions. The Dashboard keeps its order with `Web/src/model/dashboardOrderSync.ts`, the window's `DashboardOrderSync` ported, with its tests and the 200 seeded interleavings (`Web/test/dashboard-order-sync.test.mjs`). Walked in headless Chrome (`Web/test/walk/search193.mjs`) on a scratch root with 480 archived agents in two projects: no filtering between keys at 100 ms a key; 170 + 30 matches, 10 a fold; More matches… brought 200 more; two drops 30 ms apart left the page and the host on the second. Shots and readings: `walks/193/`. |

### Left out by design

- Settings, Project Settings, helper limits and the disk space lines (#195).
- The terminal.
- Dictation.
- HTML as a live page.
- Declaring, editing and removing resources, and ending leases (#116): the Mac's.
- Starting a runtime assessment (#47): it lives in Settings ▸ Agent Runtimes and on the Remote's Runtimes page, neither of which the page has.

### Counts

Of the rows above, the page lacked or partly had 12 before this branch. All 12 are closed:
#87, #98, #100, #83 (page side), #88, #101, the sessions column, #63 (Changes), #63 (Files), #66, #82, #90.

The window's shots found two more, both closed: answer cards held while their host is down (#83), and the Changes total line (#63).

What is still different, and why:
- **#83, "said at once":** neither the window nor the page hears a paused host for about a minute. Both learn of it from the control plane, which is #106's lane.
- **Event trigger words (#260):** the page says an event's name, not the window's catalogue meaning. Its filters read as the window's since 073.
- **The window's Try Again for its host:** nothing on the page to redial.
