# 034 walk

What has been proved, and what is left to see.

## Proved without a screen (2026-09-24)

- **Suite**: 1448 tests.
  - On this branch, 5 of 6 full runs pass. The one failure was `PTYTests`
    `nothingIsStillBeingGatheredWhenTheProgramIsSaidToBeOver`.
  - The pre-034 baseline passes 4 of 6. Its failures were `PTYTests`
    `outputArrivesAsItIsProduced`.
  - These are timing tests of the pty that 034 does not touch, and the suite is flaky
    under load. There are no new failures.
- **Both schemes build**: `Agents` for macOS, and `Remote` for the generic iOS simulator,
  now linking SwiftTerm.
- **The daemon, by test**:
  - `files/list`, `files/read`, `files/watch` and `files/unwatch` are held to the agent's
    folders, with `show_file`'s refusal. A symlink that points out of the folders is
    refused.
  - `files/changed` reaches only the connection that is watching, and the watch ends with
    the connection.
  - A shell takes the size of whoever typed last.
  - A phone hears a shell only while it has that shell open.
  - A phone's `artifact/write` tells the agent exactly as the Mac's does.
- **The page, by test**: `PageFollower` (14 tests) covers one caret, the page's own echo,
  a draft carried across the agent's write, a collision, a failed save keeping the draft,
  and a reconnect that saves the draft over what the agent wrote meanwhile.

## Alex's: the Mac (deferred, 2026-09-24)

The page moved to `Shared/UI/Page`, so it needs seeing once on the Mac. These walks need a
chat selected, which takes a press, so they wait for a time nobody is at the keyboard.

1. **The page**: in a scratch copy, an agent shows a new `.md` and writes it in four
   steps. The caret with the agent's name types each block, and the view follows.
2. **Typing**: click a passage, type, and pause. `cat` shows the edit, with no caret or
   mark on the page for it.
3. **A picture**: an SVG beside the document draws. Redraw it and the passage is marked.
4. **The terminal**: attach, `ls`, resize the pane, `exit`, then New shell.

## Alex's: iPhone and iPad

Build `Remote` onto the devices from this branch. The Mac runs this branch's app and
daemon, and the bridge is started by hand as usual.

**Placement (US5)**
- On an iPad in landscape, the Panes button (right of Stop/Archive) opens a column beside
  the chat. Drag the rule between them to size it. Rotate to portrait: the pane is pushed
  over the chat, and Back returns to the chat where it was.
- On an iPhone, the pane is pushed.
- Open agent A's Files two folders down, go to agent B, and come back. A is where it was.

**The page (US1, US2)**
- From the phone, ask an agent to write a short plan and show it first. The Page opens
  empty with the file's name, then fills, one block at a time, with the agent's caret.
- Type in the prompt field while the agent calls `show_file`. A "Wants you to see" strip
  appears instead of the pane opening.
- Tap a passage. The keyboard comes up in place. Type, pause, and the Mac's page shows
  it. Say "carry on", and the agent keeps your words.
- Type a passage while the agent rewrites the same one. The card appears with both
  versions.
- **Drops (SC-008)**: turn off WiFi mid-sentence. The passage goes read-only and the
  draft stays. Turn WiFi on: it saves, or says "Not saved: …".
- **An SVG diagram**: it draws. This is the first time SVG has been drawn by WebKit on the
  phone, and I could not see it. If it comes out blank, say so: the offscreen snapshot is
  the likely cause.

**Files (US3)**
- Open a file the agent never touched: its current contents, numbered. A changed file has
  the dot, including one changed an hour into a long chat.
- Tap a file name in a tool call. It opens at that line. "What the agent did" shows the
  diffs.
- A picture opens and pinches to zoom. A `.sqlite` file says what it is.
- An Exchanged entry for a file in the folder opens the live file.

**Terminal (US4)**
- Run `ls` on the Mac's pane, then open Terminal on the phone. The same scrollback is
  there.
- `sleep 100` on the phone, then **^C** once: it is interrupted.
- `top` in portrait draws at the phone's size. Type on the Mac and it redraws at the
  Mac's size.
- Lock the phone during `sleep 30; echo finished`, then come back. `finished` is there.

**Older Mac (FR-029)**: against a daemon from before 034, Panes shows only Exchanged, with
"Update Agents on your Mac…".

## Not seen by anyone yet

- Anything on an iPhone or iPad. There is no Simulator GUI on this Mac.
- The SVG raster, the key row's layout, and the column's drag handle.
