# Quickstart: proving the right sidebar works

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

How to check this feature does what it says. Each section names the success criterion it proves. The
unit-testable half runs with no app; the rest is done in front of the running app, because a terminal
that looks right is the only proof that a terminal is right.

## Prerequisites

- macOS 27, the repo checked out, Xcode 27 command line tools
- `xcodegen` on the path, for `project.yml`
- At least one runtime installed and working from 001
- A folder with a git repo and a few thousand files in it, for the responsiveness checks
- A network connection for the first build only, to resolve SwiftTerm

## Build and run the tests

```bash
cd Packages/AgentsKit
swift test
```

Everything in the kit runs here with no app and no simulator. What this covers:

| Area | What is asserted |
|---|---|
| Replay | Recorded byte streams from real `vim`, `htop` and `less` sessions give the same screen fed one byte at a time as fed in one chunk. This is the property `shell.attach` rests on. Emulation itself is SwiftTerm's and is not retested here |
| `Scrollback` | The cap drops from the front, the tail is what comes back, and a buffer that has dropped says so |
| `FileProbe` | UTF-16 with a BOM, a PNG, an empty file, and a file valid for its whole prefix and rubbish after, are each classified correctly |
| `DirectoryReader` | Sorting, the entry cap, and a directory that disappears between listing and reading |
| Artifact filter | A transcript with `resource_link`, embedded `resource`, tool calls with `locations` and `diff`, and plain messages yields exactly the two resource blocks, newest first. Annotations with an audience that is not `user` are excluded |
| Idle rule | A shell with a running child is never idle; one with no child and no input past the threshold is |
| `PTY` | A shell spawns, reports a tty, receives a resize, and its exit status is reported |

Build the app:

```bash
xcodegen generate
xcodebuild -scheme Agents -configuration Debug build
```

## Scenario 1: read what the agent changed (SC-001, SC-002)

1. Start an agent on a folder and ask it to change one file.
2. When it says it did, open the sidebar and the files pane.
3. The file it named carries the mark for "touched by the agent". Choose it.

**Expect**: its new contents, within a second. From the agent's claim to reading the file, under 10
seconds and without leaving the window (SC-001).

4. With the file still open, ask the agent to change it again.

**Expect**: the pane shows the new contents within 2 seconds, without being asked (SC-002, FR-012).

5. Delete the file from a shell outside the app.

**Expect**: the pane says it has gone. It does not keep showing the old contents (FR-016).

## Scenario 2: check the agent's claim (SC-003, SC-004)

1. On a running agent, open the terminal pane.

**Expect**: a shell prompt in the agent's folder within 2 seconds (SC-003). `pwd` is the agent's
folder, with nothing typed to get there.

2. Run the project's tests from that shell.

**Expect**: output as it is produced. `^C` interrupts. The agent's claim is checked without opening
another application (SC-004).

3. Run `vim`, move around, `:q`. Run `htop`, quit it. Run `less` on a long file, page through it.

**Expect**: each draws correctly, takes single keypresses, and leaves the screen as it found it
(FR-021). SwiftTerm does the drawing, so this checks our wiring of it, and it is still the only
honest way to check a terminal.

4. Resize the sidebar while `htop` is running.

**Expect**: it reflows to the new width.

## Scenario 3: the shell outlives the window (SC-006, SC-010)

1. Start a long build in the terminal pane.
2. Switch to the files pane, then to another agent, then back.

**Expect**: the same session, still running, with everything it printed while hidden (SC-006, FR-022).

3. Quit the app entirely. Wait 60 seconds. Open it again and go to that agent's terminal.

**Expect**: the build is still running, and the output produced while the app was shut is there
(SC-010, FR-026).

4. Open a second window on the same agent and open its terminal.

**Expect**: the same shell, the same scrollback, output arriving in both (FR-023).

5. In one window, type. It appears in both.

## Scenario 4: the browser (SC-007)

1. Start a local server in the terminal pane of the agent's folder.
2. Open the browser pane and go to its address.

**Expect**: the page loads, with back, forward and reload (FR-030).

3. Change a file the page uses, reload.

**Expect**: the change, within one reload, without switching applications (SC-007).

4. Switch agents and come back.

**Expect**: the same page, still there (FR-031).

5. Stop the server. Reload.

**Expect**: a plain statement that the connection was refused, and an offer to try again. Not a
blank panel (FR-032).

6. Go to a site you are signed into in Safari.

**Expect**: signed out. Nothing is said about Safari (FR-033).

7. Open a page that calls `window.open`.

**Expect**: nothing opens (FR-034).

## Scenario 5: artifacts (SC-008)

1. Open the artifacts pane on an agent that has been working.

**Expect**: with today's runtimes, the empty state. Read it as a new user would: it should say what
will appear there and read like a fact, not a failure (FR-043). **This is the expected result** and
the consequence of FR-046 being answered as "only what the runtime marks".

2. To prove the pane itself, run the fake agent from the test suite with a `resource_link` block and
   an embedded `resource` block in a reply.

**Expect**: both listed, newest first, each with what it is and when it arrived (FR-040). One arrives
while the pane is open and appears without asking (FR-041). Choosing one opens it in the files pane
or the browser, and there is a way back to the message it came from (FR-042). A tool call that
touched six files in the same run adds nothing to the list (FR-046).

3. Delete the file one points at. Choose it again.

**Expect**: it stays in the list and says it has gone (FR-045).

4. Stop and archive the agent, reopen the app, open the pane.

**Expect**: the artifacts are still listed and still readable (FR-044).

## Scenario 6: the sidebar frame (SC-005, SC-009)

1. Open the sidebar, resize it, pick the browser pane. Quit and reopen.

**Expect**: open, the same width, on the browser pane (FR-004).

2. Close the sidebar. Quit and reopen.

**Expect**: closed, and opening it returns to the pane last showing (FR-004, acceptance 1.5).

3. With the sidebar open, switch between ten agents.

**Expect**: the window stays responsive, and each agent returns to the pane and position it was left
at (SC-005, FR-005).

4. Close the sidebar and use the app as in 001: start an agent, follow up, stop it.

**Expect**: no step added anywhere, and nothing of the sidebar running (SC-009, FR-006).

5. Narrow the window until the conversation and sidebar cannot both be usable.

**Expect**: the sidebar cannot be opened, and the control says why. It does not silently do nothing.

6. Select nothing, so the start form is showing. Open the sidebar.

**Expect**: it says there is no agent to show, rather than four blank panes (FR-007).

## Scenario 7: the awkward cases

| Do this | Expect |
|---|---|
| Open a 200MB log in the files pane | The start of it, quickly, and a statement that there is more. The app does not stall (FR-015) |
| Open a PNG in the files pane | What it is and how big, never its bytes (FR-014) |
| Open a folder with 50,000 entries | The list draws and stays scrollable. The tree is never walked (FR-015) |
| `rm -rf` the folder the shell is sitting in, from that shell | The shell stays; the files pane says the folder has gone (FR-016) |
| Leave a shell idle past the reap threshold | It is let go, and the pane says so rather than showing a dead screen (FR-028) |
| Kill `agentsd`, then open the terminal pane | The previous shell is reported gone, with the reason. A new one starts on the next attach (FR-029) |
| Point `SHELL` at something that does not exist and open the pane | It says the shell would not start, and offers to try again (FR-024) |
| Run a runtime (`claude`, say) inside the terminal pane | It runs, as any program does. Nothing claims it is one of this app's agents |
