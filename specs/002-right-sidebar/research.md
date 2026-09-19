# Research: The right sidebar

**Date**: 2026-09-18 | **Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Everything below was checked on this Mac on 2026-09-18, against this repository at
`8ddc965` and against the ACP v1 schema. Where something is proved, the proof is the
command that proved it. Where something is a judgement, it is written as a judgement.

---

## 1. What counts as an artifact (FR-046, the one open question)

**Decision**: only what the runtime marks. An artifact is a `resource_link` content block
or an embedded `resource` content block that an agent sends. Nothing else is listed.

**Decided by**: the user, on 2026-09-18, choosing this over three alternatives that were
put to them with the consequence spelled out.

**Rationale**: the pane is a claim about intent. A `resource_link` is the protocol's own
way for an agent to say "here is a thing I made, it has a name and a type". A file the
agent happened to touch is not that. Listing touched files would make the pane fuller and
make it a liar: it would call every read-modify-write of a lockfile an artifact. The
narrow definition means everything in the pane got there because an agent deliberately
put it there.

**The cost, stated plainly**: no runtime on this Mac sends these blocks today. The spec's
own research says so and today's check agrees. So the pane ships empty against claude,
copilot and grok, and stays empty until a runtime starts handing things over. FR-043, the
empty state, is not a nicety in this feature. It is the pane's main screen, and it has to
say what will appear there in a way that does not read like a bug.

**What this buys**: the pane is tiny. There is no crawler, no baseline, no heuristic about
which of the agent's writes mattered. It is a filter over the transcript, and the
transcript already holds the blocks.

**Alternatives considered**:

| Alternative | Why not |
|---|---|
| Every file a tool call touched, from `locations` and `diff` | Full on day one, but it answers "what changed" and calls the answer "artifacts". That question already has a better home: the files pane, FR-013. Putting it in both makes the sidebar say the same thing twice |
| Touched files plus handed-over resources | The same objection, diluted. Two feeds under one heading, with different meanings, sorted together by time |
| Things the user pins by hand | Honest, and empty for a different reason. Costs a new gesture in the transcript, and answers "find it again" rather than "what came out of this". Not ruled out later; it is the natural second source when the pane has earned its place |

**Consequence for FR-013**: the `locations` and `diff` feed is real, it is already decoded
(`ToolCallLocation`, `ToolCallContent.Diff`), and it is the right answer to a different
requirement. The files pane uses it to mark what changed since the agent started. That
keeps one feed, one meaning, one place.

**One gap found**: `ContentBlock` decodes `resource_link` and `resource` but not the
`annotations` field the schema allows on them, which is where `audience` and `priority`
live. The spec quotes those as the way an agent says a thing is for the user. Decoding
them is a small addition to an existing type. When present, `audience` containing `user`
is the mark; when absent, the block is listed anyway. An agent that bothered to send a
resource link meant it.

---

## 2. A shell in the sidebar needs a pty, and a pty works here with no dependency

**Decision**: `openpty` plus `posix_spawn` with `POSIX_SPAWN_SETSID`, and the slave
device opened by the child as its first tty so it becomes the controlling terminal.

**Proved today**, compiled and run with `swiftc` on this Mac:

```
openpty rc: 0 master: 3 slave: 4
ptsname: /dev/ttys007
POSIX_SPAWN_SETSID flag value: 1024
TIOCSWINSZ rc: 0
/dev/ttys007
cols=120 rows=40
speed 9600 baud; 40 rows; 120 columns;
```

The child ran `tty`, `tput cols` and `stty -a`. It reported a real terminal device, the
window size the parent set, and a live line discipline. That is FR-020 and the mechanical
half of FR-021: a program that asks "am I on a terminal" gets yes, `^C` reaches the
foreground process group because the kernel's line discipline is doing it, and a
full-screen program can ask how big the screen is.

**Why not `Process`**: `Process` gives pipes and has no way to ask for a session of its
own. A pipe is not a terminal: `isatty` is false, so programs switch to their batch
behaviour, and there is no process group for `^C` to reach. `POSIX_SPAWN_SETSID` is the
piece `Process` does not expose, which is why this goes to `posix_spawn` directly. The
existing `RuntimeProcess` stays as it is; runtimes want pipes.

**Resizing**: `ioctl(master, TIOCSWINSZ)` returned 0 and the size reached the child. The
pane sends its size when the sidebar is resized, and the kernel sends `SIGWINCH`.

**Alternatives considered**: `forkpty` does this in one call, but it forks a process that
has threads, and everything between the fork and the exec has to be async-signal-safe.
`posix_spawn` is the same result without that window. Rejected.

---

## 3. Terminal emulation is written here, not taken

**Decision**: write a VT parser and screen model in `AgentsKit`. No dependency.

**Rationale**: the rule in force since 001 is no third-party dependencies, and
`Package.swift` still has none. The rationale 001 recorded was cost against benefit, not
purity: JSON-RPC was "a small amount of code and not worth a dependency". A terminal
emulator is not a small amount of code, so the rule and its reasoning point different
ways, and this is the one place in the feature where that happens. It is written here
anyway, for two reasons that are specific rather than dogmatic.

First, it is exactly the shape this project puts in the kit: bytes in, a grid of cells
out, no I/O, no UI, no timing. `swift test` can feed it a recorded stream from a real
`vim` session and assert the screen. Almost nothing else in this feature tests that
cleanly.

Second, the subset that matters is bounded, and the boundary can be drawn honestly:

- CSI cursor moves, erase in line and display, insert and delete lines and characters
- SGR: bold, dim, italic, underline, inverse, and colour in 16, 256 and truecolour forms
- Scroll regions, and the alternate screen buffer, which is what `vim` and `less` use
- OSC 0 and 2 for the title, which the pane shows, and OSC 8 hyperlinks ignored safely
- UTF-8 decoding across chunk boundaries, and wide characters taking two cells

What is out: sixel and other graphics, mouse reporting, bracketed paste in this feature,
and every private mode not listed. An escape sequence that is not understood is consumed
and dropped rather than printed, so an unknown sequence costs its own effect and nothing
else.

**Alternatives considered**: SwiftTerm is MIT, complete, and would save most of this
work. It was rejected because the no-dependency rule is explicit, twice affirmed, and the
user has not been asked to reverse it. That reversal is available: 003 reversed a 001
decision the same way, with evidence and the user's approval on the record. If the parser
turns out to be the thing holding this feature up, that is the moment to ask, and the
grid model behind the view is the same either way. This is risk 1 in the plan.

---

## 4. The shell belongs to the daemon, and it is the user's

**Decision**: the daemon owns pty sessions, keyed by agent. The app attaches to one and
detaches from it. Closing a window detaches; it does not kill.

**Rationale**: FR-026 asks for a build that survives quitting the app, and FR-023 asks two
windows on one agent to see one shell. Both fall out of the daemon owning it, which is
already the reason the daemon owns agents. The daemon already tracks child processes,
already holds pending permission questions across having no window at all, and already
has a per-agent notification channel. This is that pattern again, not a new one.

**Scrollback while nobody is watching**: the daemon keeps a ring buffer per shell with a
byte cap, and the emulator screen is rebuilt from it on attach. A build that printed for
an hour with no window open gives back the tail, which is what SC-006 and SC-010 ask for.
The cap is a cap: a shell that printed 500MB gives back the end of it and says so.

**Names collide, so they are kept apart**: 003 gives agents terminals of their own, served
by the daemon, notified as `agent/terminalOutput`. Those are the agent's. These are the
user's. Nothing the user types here goes to the agent (FR-025), and nothing the agent runs
appears here. They are different methods (`shell/*`, not `terminal/*`), a different
notification, and a different owner in the daemon. Sharing the pty plumbing is fine;
sharing an identifier space is not.

**Letting go (FR-028)**: a shell with a foreground process is work, and the daemon's
existing lifetime rule already counts work it is holding. A shell that is idle, meaning no
child of the shell is running and nothing has been typed, is released after a timeout, and
the pane says it was let go rather than drawing a dead screen. The idle rule is a time
rule, so it is a pure function of clock, last input and child state, and it is tested as
one.

---

## 5. The files pane watches with FSEvents and reads lazily

**Decision**: `FSEventStreamCreate` on the agent's folder for FR-012, `DirectoryEnumerator`
one level at a time for FR-015, and a byte cap on the read for FR-011.

**Rationale**: FSEvents is the platform's own, coalesces bursts, and reports a directory
rather than a file, which is enough: the pane re-reads the directory it is showing and the
file it has open. A build that writes 4000 files produces a manageable number of
directory-level events rather than 4000 file-level ones.

One level at a time is what keeps FR-015 true. The pane never walks the tree. A folder
with thousands of entries is a list of thousands of names, which draws lazily like any
list. `node_modules` is not a problem unless the user opens it.

**Reading a file**: the pane reads a prefix, not the file. The cap is a byte count, and a
file over the cap shows the prefix and says there is more. FR-015 says not to read a whole
large file to show the start of it, which is a `FileHandle` read of the first chunk.

**Is it text (FR-014)**: the first chunk decides. A NUL byte in the first 8KB means
binary, and invalid UTF-8 means binary. Everything else is text. The pane then says what
the file is from its extension and size rather than showing bytes. This is a pure function
over a chunk, so it is tested with the awkward cases: UTF-16 with a BOM, a PNG, an empty
file, a file that is valid UTF-8 for 8KB and rubbish after.

**Changed since the agent started (FR-013)**: from the transcript, not from the disk. Every
tool call carries `locations`, and an edit carries a `diff` with a path. Reading the
agent's own transcript gives the set of paths it touched, in order, with no crawling and
no baseline snapshot. It is also the truthful answer: it is what the agent did, rather
than what happened in the folder. A file changed by the user's own editor is not marked,
which is correct.

**When it disappears (FR-016)**: FSEvents reports the parent, the re-read finds the entry
gone, and the pane says so. The open file's contents are cleared rather than left on
screen. The rule is that the pane never shows contents it cannot currently vouch for.

---

## 6. The browser is `WKWebView`, and it is already separate from Safari

**Decision**: one `WKWebView` per agent, held by the window, with a non-default
`WKWebsiteDataStore`.

**FR-033 is satisfied by the platform, not by us**: a `WKWebView` in this app has no access
to Safari's cookies, history or passwords. They are different applications with different
containers. There is nothing to opt out of, and the requirement is met by doing nothing
special. The pane gets its own persistent data store anyway, so that a login to a local
dev server survives a restart without touching anything else.

**FR-034, what a page may not do**: `WKUIDelegate`'s
`createWebViewWithConfiguration` returns nil, so a page cannot open a window.
`decidePolicyFor navigationAction` refuses schemes that are not http, https, about or
file. Downloads are refused in this feature, which the spec's assumptions already say.
Camera and microphone go through `requestMediaCapturePermissionFor`, which is asked rather
than granted. The app is not sandboxed, so this is the only gate, which is why it is
written as refuse-by-default and has its own tests.

**FR-031, keeping the page**: the web view is kept alive per agent for the life of the
window and not recreated when the pane is hidden, because recreating it reloads the page
and loses scroll position and any form state. SwiftUI's `NSViewRepresentable` makes a new
coordinator freely, so the views are held outside the view tree, in the window's sidebar
state, keyed by agent.

**FR-032, saying what failed**: `didFailProvisionalNavigation` carries an `NSError` with a
usable domain and code. Connection refused, host not found and timeout are named in plain
words; anything else shows the system's description. Every one offers reload. A local
server that has stopped is the common case and is worth its own sentence.

---

## 7. Sidebar state: some belongs to the window, some to the agent

**Decision**: two pieces of state with different homes and different lifetimes.

Open, width and which pane is showing belong to the window and persist in `UserDefaults`.
They are one user's preference about a window, they are not worth a daemon round trip, and
they are the same for every agent. FR-004.

Where each pane had got to, meaning the folder path and open file, the browser's current
URL, and which shell is attached, belongs to the pairing of window and agent. It is held
in memory for the window's life so that switching agents and coming back returns to the
same place. FR-005.

**Why not the daemon**: the daemon is the owner of things that outlive windows. A scroll
position does not. The exception is the shell, which does outlive the window, and which is
therefore the daemon's, addressed by the agent's id. The window remembers which shell it
was looking at; the daemon remembers the shell.

**Two windows (the spec's edge case)**: each window has its own sidebar state and they do
not synchronise. Both address the one shell the agent has. Output goes to both. This is
the same rule as the transcript, which both windows also show.

---

## 8. What is not settled, and is deliberately not settled here

- **The narrow window.** FR-003 says the conversation keeps the rest of the window, and the
  spec's edge case says the app has to choose when both cannot be usable. The choice is a
  minimum width for the conversation, below which the sidebar cannot be opened and the
  control says why. The number is a design decision made in front of the running app, not
  in this document.
- **How much scrollback.** A byte cap exists. The number is tuned against a real build,
  because the honest input is what `xcodebuild` prints, not a guess made now.
- **The idle timeout for a shell.** Same reason. The rule is written and tested; the
  constant is picked from use.

---

## Summary of decisions

| # | Decision | Status |
|---|---|---|
| 1 | An artifact is a `resource_link` or embedded `resource`, and nothing else | Settled by the user. Pane ships empty against today's runtimes, knowingly |
| 2 | `openpty` + `posix_spawn(POSIX_SPAWN_SETSID)` for the shell | Proved on this Mac today |
| 3 | The VT parser is written here, in the kit, under test | Settled, and the largest risk in the feature |
| 4 | The daemon owns shells, keyed by agent, separate from 003's agent terminals | Settled |
| 5 | FSEvents, one directory level at a time, prefix reads | Settled |
| 6 | `WKWebView` with its own data store, refuse-by-default delegates | Settled. FR-033 is free |
| 7 | Window keeps the frame state, window-and-agent keeps the pane state, daemon keeps the shell | Settled |
| 8 | Three constants are left to be picked in front of the app | Deliberate |
