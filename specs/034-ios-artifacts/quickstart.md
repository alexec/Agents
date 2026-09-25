# Quickstart: validating 034

How each slice is shown to work. The details are in [contracts/daemon-api.md](./contracts/daemon-api.md)
and [contracts/panes-ui.md](./contracts/panes-ui.md). Who does what:

- **Me** (an agent on this Mac): the suite, both builds, the daemon over its socket, and the
  Mac page on a scratch root with the run-app skill.
- **Alex**: the phone and iPad walks. This Mac cannot tap a simulator, and no throwaway
  simulators are made.

## Every slice

```sh
cd Packages/AgentsKit && swift test          # compare with main if anything flakes (six runs each)
cd ../..
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
```

Build the two schemes one after the other, never in parallel. `-skipPackagePluginValidation`
is required: SwiftTerm fails silently without it, and the Remote now links SwiftTerm too.

## Slice A: panes on screen, read-only (the gate)

**The daemon, over its socket** (scratch root; never poll it tightly):
1. Start an agent on a scratch project. Call `files/list` on its `cwd`. The result has folders
   first, and `omitted` is 0.
2. `files/read` a `.md`, a `.png`, an `.svg`, a 300 KB log and a `.sqlite`. The results are:
   `text`, `image`, `image`, `text` with `isTruncated: true`, and `other`.
3. `files/read` again with the stamp. The answer is `unchanged`.
4. `files/read` of `/etc/hosts` gives the scope refusal, word for word as `show_file`'s. A
   symlink in the folder that points out of it gives the same.
5. Open two connections, `files/watch` on one, and touch a file. Only the watching connection
   gets `files/changed`. Close it. The daemon log says the watch stopped.

**The Mac page, unchanged after the move** (run-app, scratch root):
- Ask an agent to write a Markdown document in four steps and to show it first.
- Screenshot each step.
- The caret with the agent's name types each block in turn, and the view follows.
- Clicking a passage opens it for typing. Pausing puts the edit on disk (`cat`).
- The pictures redraw when their SVG is rewritten.
- Compare with 022's walk screenshots in `specs/022-live-artifacts/walk/`.

**The phone and iPad** (Alex):
- iPad landscape: Panes opens a column beside the chat, and the page follows the agent while
  the chat streams.
- iPad portrait and iPhone: the pane is pushed, and Back returns to the chat where it was.
- Files: go two folders down and open a file the agent never touched. It shows its current
  contents. A changed file has the dot.
- Go to another agent and back. The pane is as it was.

## Slice B: attention

- With the chat in front, the agent calls `show_file` on a new `.md`. The Page opens empty
  with the name, then fills (US1 scenario 1).
- With the prompt field focused, the same call shows the "Wants you to see" strip instead.
- With another screen in front, nothing opens. Opening that chat later shows the strip.
- Tap a file name in a tool call. The current file opens at the line, and "What the agent
  did" opens the diffs.
- An Exchanged entry for a file opens the live file. A message entry opens as before.

## Slice C: typing on the page

1. On the phone, edit a paragraph and pause. Within 2 s, `cat` on the Mac shows it, and the
   Mac's page shows it without a caret or a mark.
2. Prompt "carry on". The agent's next turn begins with the "you changed…" note (compare
   `ArtifactWriteTests`), and its next write keeps the edit.
3. While typing on the phone, have the agent rewrite a *different* section. The phone's view
   does not move, and the draft is untouched.
4. Have the agent rewrite *the same* passage. The collision card appears, and both versions
   are visible.
5. **Drops (SC-008)**: turn WiFi off mid-sentence and keep typing. The editor goes read-only
   with the draft visible. Turn WiFi on. The draft is saved, or it says "Not saved". Repeat
   20 times across both orders (drop before the pause, and after it). No text is lost
   without a message.
6. Two phones and the Mac on one page, each editing a different passage. The agent's note
   lists each passage once.

Unit tests that stand in for most of this: `PageFollowerTests` covers echo, one caret, carry
across a write, collision, reconnect with a draft, and a failed save keeping the draft.

## Slice D: the shell

**Daemon** (`ShellSizeTests`):
- `shell/input` with a size resizes first.
- A device connection hears `shell/output` only after attaching.

**Mac and phone together** (Alex):
1. On the Mac, open an agent's terminal and run `ls`.
2. Open the same agent's terminal on the phone. The same scrollback is there.
3. Run `sleep 100; echo done` from the phone, then tap **^C** once. It is interrupted, and
   the Mac's pane shows the same.
4. Run `top` on the phone in portrait. It draws at the phone's size. Type on the Mac, and it
   redraws at the Mac's.
5. Start `sleep 30; echo finished`, lock the phone, and wait. Reopen it from the phone and from
   the Mac. `finished` is on both.
6. `exit`. The pane says the shell exited and offers Start again, which starts a new one.

## Slice E: edges and the older Mac

- Delete the open file. The page says it is gone and keeps its text. Delete a folder being
  listed. It says gone.
- Remove the agent's worktree (030). Files says the folder is gone.
- For an archived agent, pages can be read and typed on, and the terminal follows the Mac's
  rule.
- **Older Mac**: run the phone against a daemon built from `main` before 034 (a scratch root
  and bridge). Panes shows the Exchanged list and the rebuilt file, with the update line.
  There is no Terminal segment.

## Done when

Every checkbox of `tasks.md` is done, the suite is green on six runs against main's rate,
both schemes build, the Mac page walk matches 022's, and Alex has walked slices A–E on an
iPhone and an iPad.
