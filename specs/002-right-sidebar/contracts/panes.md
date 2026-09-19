# Contract: what each pane is given, and what it may do

The sidebar is a UI surface, so its contract is not a wire format. It is what each pane may reach,
what it must refuse, and what it owes the user when something is not there. These are the things a
test can check and a reviewer can hold the code to.

## The sidebar

| | |
|---|---|
| **Given** | The selected agent, or nothing |
| **May** | Open, close, resize itself between a minimum and a maximum, and show one pane |
| **Must not** | Take so much width that the conversation stops being usable. Below a minimum conversation width the sidebar cannot be opened, and the control says why rather than doing nothing |
| **Owes** | An empty state naming why there is nothing to show when no agent is selected (FR-007) |
| **Costs when closed** | Nothing. No FSEvents stream, no web view, no attach (FR-006, SC-009) |

Panes take turns and are not torn down when hidden. Switching panes keeps the browser's page, the
files pane's folder and the terminal's attachment. Switching agents rebuilds what is per-agent from
that agent's kept state (FR-005).

## Files

| | |
|---|---|
| **Given** | The agent's folder, and the set of paths the agent has touched |
| **May** | List one directory at a time, move into and out of directories within the agent's folder, read the first chunk of a file, watch for changes |
| **Must not** | Write anything. No create, rename, delete or edit. Reading is the whole of it (FR-017) |
| **Must not** | Walk the tree, or read a whole large file to show its start (FR-015) |
| **Must not** | Show the bytes of a file it cannot read as text (FR-014) |
| **Must not** | Leave contents on screen that it cannot currently vouch for (FR-016) |
| **Owes** | New contents within 2 seconds of a change landing (FR-012, SC-002) |
| **Owes** | A plain statement when a file or the folder has gone (FR-016) |
| **Owes** | A mark on every file the agent touched since it started (FR-013) |

The touched set comes from the transcript: every `ToolCallLocation.path` and every
`ToolCallContent.Diff.path`. Not from mtimes, so a file the user edited is not marked.

## Terminal

| | |
|---|---|
| **Given** | The agent's id, and the pane's size in rows and columns |
| **May** | Attach, detach, send bytes, send a size, send a signal, restart a shell that is not live |
| **Must not** | Start a shell the user did not ask for. No pane open, no shell |
| **Must not** | Kill anything on detach, on closing a window, or on quitting the app (FR-026) |
| **Must not** | Send anything the user types to the agent, or show anything the agent runs (FR-025) |
| **Must not** | Print an escape sequence it did not understand. Unknown sequences are consumed and dropped |
| **Owes** | A shell ready to type into within 2 seconds of the pane opening (FR-020, SC-003) |
| **Owes** | Output as it is produced, single keypresses, interrupt, and the screen handling full-screen programs expect (FR-021) |
| **Owes** | The same session, with its scrollback, after moving between panes and agents (FR-022) |
| **Owes** | A statement of what happened, and an offer to start a new shell, when the shell has exited, failed or been let go (FR-024, FR-028, FR-029) |

An agent runtime run inside this pane is an ordinary program. Nothing pretends it is one of the
app's agents (the spec's edge case).

## Browser

| | |
|---|---|
| **Given** | Nothing but what the user types, or an artifact's `http(s)` uri |
| **May** | Load http, https, about and file. Go back, forward and reload |
| **Must not** | Open a window of its own. `createWebViewWithConfiguration` returns nil (FR-034) |
| **Must not** | Navigate to any other scheme. Anything else is refused, visibly |
| **Must not** | Download. Refused in this feature, by the spec's assumption |
| **Must not** | Reach the camera or microphone without the user being asked (FR-034) |
| **Must not** | Read or write Safari's cookies, history or passwords, or say anything about them (FR-033) |
| **Must not** | Be driven by the agent. The user drives it (FR-035) |
| **Owes** | The same page after switching panes and agents (FR-031) |
| **Owes** | What failed, in plain words, with an offer to try again (FR-032) |

Every capability is written as an explicit allow over a refusing default, so that a delegate method
nobody considered still refuses. FR-033 needs no work: a `WKWebView` here has no access to Safari's
container. The pane gets its own persistent data store so a login to a local server survives a
restart.

## Artifacts

| | |
|---|---|
| **Given** | The agent's transcript |
| **May** | List `resource_link` and embedded `resource` blocks, newest first, and open one |
| **Must not** | List a file a tool call merely touched. That is the files pane's marks (FR-046) |
| **Must not** | List a block whose `annotations.audience` is present and does not include `user` |
| **Must not** | Store anything. The list is derived on read, every time (FR-044) |
| **Must not** | Show what is no longer there as though it were (FR-045) |
| **Owes** | What each one is and when it arrived (FR-040) |
| **Owes** | An update when one arrives while the pane is open, over `agent.entry` (FR-041) |
| **Owes** | A way to reach the message it came from (FR-042) |
| **Owes** | A statement of what will appear there when there is nothing yet (FR-043) |

The empty state is this pane's ordinary screen. No runtime on this Mac sends these blocks today, so
it is written as a plain statement about what will appear there, in the app's own voice, not as an
apology and not as an error.

Opening an artifact: a `file:` uri opens in the files pane, an `http(s)` uri in the browser, and an
embedded `resource` is read in place. A uri that no longer resolves stays in the list and says so
when opened (FR-045).
