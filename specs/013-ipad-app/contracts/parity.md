# Contract: what the Mac shows, and where it is on the iPad

FR-021 promises the iPad shows everything the Mac's window shows **about the work**, and makes
silence a defect: anything the Mac shows and the iPad does not must be named. This is that
list. SC-005 is a walk down it, item by item, with the Mac and the iPad side by side.

**How to use it**: when the Mac gains a surface, add a row. A row with no disposition is a
failing spec, not an oversight. Inventory taken 2026-09-19 against `App/Sources/`.

**The rule the dispositions follow**: reading what the agent did comes across; driving the Mac
does not. A fact about the work is in scope. A fact about the Mac's own machine — its shell,
its browser, its file system at large, its signed-in accounts — is not.

---

## The project list

| The Mac shows | On iPad | Why |
|---|---|---|
| Live projects, newest activity first, named by `ProjectNaming` | **Yes** | FR-014. Built. |
| A mark on a project whose agent needs the person | **Yes** | FR-014. Built. |
| A missing folder, marked and dimmed, still selectable | **Yes** | FR-014, edge case. Built. |
| Swipe to archive a project (`SwipeToArchive`) | **No** | Out of scope: archiving a project is tidying, and tidying is a desk activity (005, carried forward). |
| Adding a project | **No** | Out of scope: it means choosing a folder on the Mac. |

## The project page

| The Mac shows | On iPad | Why |
|---|---|---|
| The project's name | **Yes** | Built. |
| A prompt bar with this project's folder fixed | **Yes** | FR-026. **Not built** — corrected 2026-09-19. `ProjectPageView` says so in its own comment and the 2026-09-19 inventory read it as built. T072 builds it. |
| Agents grouped "Needs input", "Working", "Completed" via `AgentGroup` | **Yes** | FR-015. Built, same shared file. |
| Agent cards, with how a completed one ended | **Yes** | FR-019. Built. |
| Archived agents behind a disclosure, ten at a time | **Yes** | FR-020. Built. |
| Workflows section — a project's standing arrangements (008) | **Yes, listed and their state** | FR-021. New. Listing is a fact about the work. |
| Starting, confirming, cancelling a workflow (008) | **No** | Out of scope, named in spec: driving, not reading. |
| Project cost total (012) | **Yes** | FR-021. It is a fact about the work. |
| Grand total across projects, on its own page (012) | **Yes** | FR-021. Same reason. |
| Setting or changing a cost limit (010) | **No** | Out of scope, named in spec: the iPad shows what is spent; the Mac is where a limit changes. |
| A cost limit having been hit, and that it stopped an agent (010) | **Yes** | FR-021. The person must know why it stopped. Showing is not setting. |

## The conversation

| The Mac shows | On iPad | Why |
|---|---|---|
| Transcript: prompts, replies, tool calls (`Transcript`, `BlocksView`) | **Yes** | FR-016. Built. |
| Markdown in replies (`MarkdownText`) | **Yes** | FR-016. Built. |
| Diffs (`DiffView`) | **Yes** | FR-016. Built. |
| Command output | **Yes** | FR-016. Built. |
| Files a tool call touched (`ToolCall.locations`) | **Yes** | FR-016. Built as a list; FR-020a adds opening one. |
| **The content of a touched file, read only** | **Yes — built 2026-09-19** | FR-020a. `FileView`. The content is the agent's own diffs out of the transcript, not a read of the Mac's disk: nothing in the protocol hands a client a file's bytes. A file the agent only read says so. |
| **A document the agent produced (007)** | **Yes — built 2026-09-19, read only** | FR-020b. `DocumentView` and `ArtifactsList`, off the conversation's menu. An embedded resource reads in place; one that is a file on the Mac says where it is. |
| Editing a file, or opening one the agent never touched | **No** | Out of scope, named in spec. |
| The plan (`PlanView`, `Agent.plans`) | **Yes — built 2026-09-19** | FR-017. `CurrentPlanStrip` at the head of the conversation, collapsed to the step being worked. See research §5. |
| Cost and context as reported (`ContextMeter`) | **Yes** | FR-018. Built. |
| How an agent ended — finished, stopped, the error | **Yes** | FR-019. Built. |
| Resuming / coming-back state (011) | **Yes** | FR-021. `AgentsModel.isComingBack` is shared. |
| The prompt bar, sending text | **Yes** | FR-025. **Not built** — corrected 2026-09-19. There is no `TextField` anywhere in `Remote/Sources/`. T072 builds it, and T067 and T069 hang off it. |
| Attachments on the prompt (`AttachmentStrip`) | **Yes** | FR-025. Built on the model side; the iPad's picker is T074's, and it needs T072's prompt bar to hang on. |
| Slash commands offered while typing (`CommandList`) | **Yes** | FR-021. It is what this runtime takes; withholding it makes the iPad's prompt bar quietly weaker. |
| Mode / model / effort / permission controls (`SelectCapsule`, `OptionMenu`, 009) | **Yes** | FR-021 and FR-026. An agent started from the iPad must be startable with the runtimes and options the Mac has. |
| Jump to the live end (`JumpToEnd`) | **Yes** | FR-021. |
| Dictation (`Dictation`) | **Not judged** | Out of scope by omission on the Mac's terms: it is a Mac input method. The iPad has the system's own. No requirement either way — **the one row here that is a shrug, and it is recorded as one.** |
| Permission request in full, with the Mac's choices (`PermissionView`) | **Yes** | FR-011. Built. |
| A form request (`ElicitationView`) | **Yes** | FR-011. Built. |
| Suggested next prompts (`agents/suggestPrompts`) | **Yes** | FR-021. |

## The right-hand inspector (002)

| The Mac shows | On iPad | Why |
|---|---|---|
| A file the agent touched, read only (`FilesPane`, `FileLines`) | **Yes** | FR-020a. The reading half, built 2026-09-19 as a sheet off the conversation — an iPad has no inspector to put it in. |
| A document the agent produced (`ArtifactsPane`, `DocumentView`, 007) | **Yes** | FR-020b. The reading half, built 2026-09-19 as a sheet off the conversation, same reason. |
| A live terminal (`TerminalPane`, `TerminalHostView`, `ShellClient`) | **No** | Out of scope, named in spec: the Mac's window onto the Mac's own machine. |
| A browser (`BrowserPane`) | **No** | Same. |

## Everything else in the window

| The Mac shows | On iPad | Why |
|---|---|---|
| Runtime accounts, signing in (`RuntimeAccountView`) | **No** | Out of scope: needs the Mac's browser. |
| The session list, adopting a session (`SessionListView`) | **No** | Out of scope by omission — **this row needs a decision.** It is neither clearly a fact about the work nor clearly driving the Mac. Flagged for `/speckit-clarify`. |
| Where an agent may work and what it can reach (`AgentReachView`, extra folders, MCP servers) | **Shown, not edited** | FR-021 to show it; choosing folders needs the Mac's file system. |
| Forking an agent (`agents/fork`) | **No** | Out of scope by omission. Not in FR-025 to FR-027. |
| Paired devices, approve and revoke | **Mac only** | FR of US4: the Mac is where a device is trusted. By design. |

---

## Two rows that are not settled

Named here rather than hidden, because FR-021 says silence is a defect:

1. **Dictation** — no requirement either way. Probably nothing to do, since the iPad's keyboard
   has its own; but nobody has decided.
2. **Sessions (adopt / delete)** — genuinely ambiguous under the rule. Adopting a session is
   closer to starting work than to reading it, which argues for the iPad; it is also a piece of
   Mac housekeeping, which argues against.

Both are candidates for `/speckit-clarify` and neither blocks the build.

---

## The read-only audit (T062, SC-014)

Walked 2026-09-19 over `Remote/Sources/`. There is no `TextEditor`, no `ShareLink`, no
`fileExporter`, no `UIActivityViewController` and no write to disk anywhere in the target.
Nothing had to be removed. Read-only holds because the iPad has no screen that offers to
change anything, which is what SC-014 asks for — not because a flag is set somewhere.

Re-walk this when a screen that takes input lands. The first will be T072's prompt bar, which
writes to the *conversation* and not to a file, and the distinction is the thing to check.
