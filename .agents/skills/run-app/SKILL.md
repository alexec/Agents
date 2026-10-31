---
name: run-app
description: Build, launch and drive this Mac app (Agents) on a scratch set-up of its own (a control plane, this Mac's host and the window), so a change can be seen working without touching the real ones or asking the user to click anything. Use whenever asked to run, start, screenshot, walk or manually verify the app, or whenever a change to App/, Host/, Go/, Remote/ or Packages/AgentsKit needs proving beyond `swift test`. Close everything it started and delete the scratch app and its files when done ("When you are done"), also when the walk failed.
---

# Run and test this app

The window is one thing and the agents are another. Since 058 there are three
pieces, as on the real Mac:
- **this Mac's host**, `agentsd`, owns the agents. The root it is pointed at *is* its
  identity: its lock, its socket, its agents;
- **the control plane**, `agents-control`, which the host dials out to;
- **the window**, the sandboxed App Store build (`AgentsStore`), a client of the control
  plane like the phone. It starts nothing.

That is the whole basis of this skill: you get all three of your own, so nothing you
do reaches the user's agents, and nothing of theirs reaches yours. The helpers come
out of a scratch build of Agents Host; Agents Host itself is not run (its launch
agents are the real Mac's).

**Test your own change. Do not hand the user a list of steps to walk.** Almost
everything the window can do, the socket can do too, with no screen involved.
Ask for the user only after you have run what you can and are stuck on something
genuinely visual — and say what you already saw.

## The loop

```sh
S=.claude/skills/run-app/scripts

# 1. build and launch on a fresh root (prints ROOT, APP_PID, WINDOW_ID, WINDOW_ON, DAEMON_PID, CONTROL_PID, CONTROL_URL)
eval "$($S/launch.sh --slug mychange)"        # /tmp/run-mychange

# 2. give it something to work in — you may create scratch folders freely
mkdir -p $ROOT/work && git -C $ROOT/work init -q
$S/rpc.py $ROOT call folders/add "{\"folder\":\"file://$ROOT/work\"}"

# 3. drive it and read what came back
$S/rpc.py $ROOT call agents/list '{"includeArchived":false}'
$S/rpc.py $ROOT start claude $ROOT/work "Write hello.txt with one line in it." 120
#   ^ starts a real agent, says yes to its permissions, and follows it to the end

# 4. look at it, if the change is visual
$S/walk.py $ROOT shot /tmp/run-mychange-1.png    # then Read the png; works on a locked screen

# 5. always, at the end: see "When you are done" below
$S/stop.sh $ROOT                                  # must print clean
```

`launch.sh` builds with `xcodegen generate`, then `xcodebuild -scheme AgentsHost`
and `-scheme AgentsStore`, one after the other, into the one `build/DD`, with `-skipPackagePluginValidation`. Skip the build with `--no-build` when
nothing has changed since the last one. The build log is at
`/tmp/run-<slug>-build.log`.

Every build goes through `scripts/build-cache.sh` (#234): one package cache, one set of
checked-out packages and one Xcode compilation cache in `~/Library/Caches/Agents-build/`,
shared by every worktree. A fresh worktree replays what any other build already compiled,
so its first build is no longer a cold one. Build the same way by hand:
`scripts/build-cache.sh xcodebuild …` and `scripts/build-cache.sh swift test …`. Deleting a
worktree's own `build/` and `.build` is still the clean-up, and leaves the cache alone;
`scripts/build-cache.sh du` shows its size and `prune` bounds it.

Verify only what you touched: the schemes and tests for the paths your branch changes, as
`.agents/skills/merge-wave/scripts/merge-wave.sh plan <your branch>`, run in your
worktree, lists them with their commands (#2685): an `App/` or `Host/` change needs
`AgentsHost` and `AgentsStore`, not the Remote or the web page, so no iOS simulator
build; a `Remote/` change needs only the Remote; a `Shared/`, `Packages/` or `project.yml`
change needs both; a `Packages/AgentsKit` change needs its tests filtered by
`scripts/select-test-suites.sh`. The full suite and every scheme run once, in the wave.

Then it:
1. starts `agents-control serve --home $ROOT/control` on a free loopback port, with
   no Bonjour (its log is `$ROOT/control/control.log`), serving the web remote (071) from
   this checkout's `Web/dist` (built by Agents Host's build, not checked in) on another free
   loopback port, printed as `WEB_URL` (never the live 8792);
2. starts `agentsd --control-code <host code>` on `$ROOT`, as Agents Host's launch agent
   would, with this session's `CLAUDE_*` and `AGENTS_*` taken out of its environment;
3. opens the window with `AGENTS_CONTROL=<client code>` and `--walk run-<slug>`: it
   pairs by itself, into `walks/run-<slug>/` in its container, so it never touches the
   user's own window's pairing, which lives in the same container.

`--no-window` leaves the window out, for work the socket proves on its own.
It runs the `agents-control` and `agentsd` the build carries (Go, the only ones since #1314),
as Agents Host does, and says which on stderr.
`CONTROL_BIN=<path>` and `AGENTSD_BIN=<path>` run others in their place, such as a Go one
built from the tree: `GOOS=darwin Go/scripts/go.sh build -o out/darwin/agents-control
./cmd/agents-control`, then `CONTROL_BIN=$PWD/Go/out/darwin/agents-control launch.sh …`.
`--host-first` starts the host while the control plane is down, with the host code left in
its root as Agents Host leaves it, waits until it has failed to join (`HOST_FIRST_WAIT`
seconds more, 5 by default), then starts the control plane and waits for the host to join
with the same code (#113). The control plane is always given `--host-root $ROOT`, so
`control/status` carries the host's join as `thisMacHost`.
`--outside-checkout` opens a copy of the window from `$ROOT/app`, so its title does not start
with the worktree's name, for pictures and videos (#1078).
`--first-run` opens the window unpaired, on frame K, and prints `PAIR_CODE` to paste
into **Connect…**. To walk Agents Host itself, open a scratch build of it with
`AGENTS_ROOT=$ROOT` (its plists and jobs are the root's, and `stop.sh` boots them out). Make
more codes with `"$HOSTAPP/Contents/Helpers/agents-control" code --client
--home $ROOT/control` (add `--browser` for a code the web remote pairs with: a browser's code
works only through the loopback listener, and any other only over TLS), where `HOSTAPP` is `build/DD/Build/Products/Debug/Agents
Host.app`.

## Rules that are not optional

1. **Never `pkill -f agentsd` or `agents-control`, never `killall Agents`.** This
   session is hosted by the user's own Agents Host and its daemon. The only helpers
   you may kill are the pids in *your* root's `daemon.lock` and
   `control/control.pid`, which is what `stop.sh` does.
2. **Always stop what you started**, including when the test failed or you are
   about to hand back. A left-behind window and daemon are the user's problem to
   find. `stop.sh $ROOT` removes the root and its side files too; `stop.sh $ROOT --keep`
   leaves them for reading and still stops the processes. Run `stop.sh $ROOT` again once
   you have read a kept root: nothing else deletes it (#2400).
3. **Keep this session out of what you start** — `launch.sh` does. `open` hands
   this session's environment to the app, and the `CLAUDE_*` variables in it reach
   every runtime the daemon starts; an agent started that way stops authenticating
   the moment this session ends. The window is opened with `env -i`; the host keeps
   the rest of the environment, because a runtime started with none cannot sign in.
4. **Keep the root short.** A Unix socket may be named with 104 bytes and no
   more, and the socket is `<root>/daemon.sock`. `/tmp/run-<slug>` is the shape, and `/tmp/ag-*` is not: the live tests in
   `AgentsKitTests` keep their own temporary roots there.
5. **The window launches behind** (`open -n -g`), so it does not take the screen
   off the user mid-keystroke. Use `--front` only if you must, and prefer it
   when nobody is at the keyboard:
   `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1e9)}'`.
6. **Never seed a root from the real one** (`~/Library/Application Support/Agents`), not
   its `agents/`, not one record, not `folders.json` or `workflows.json` (#228). A copied
   record carries a real runtime session, worktree and folder: a scratch host that resumed
   copies of live agents once had them merge, archive and start agents in the real repo.
   Seed synthetic agents under the scratch root instead:
   `.agents/reviews/robustness-performance/tools/rp-seed.py /tmp/run-<slug> …`, or
   `scripts/seed-archived.swift --root /tmp/run-<slug> …`, then `launch.sh --seeded`.
   `launch.sh` refuses a root holding records copied from the real one, and the host
   itself shows any record stamped with another root as *imported*, stopped, and never
   runs it.
7. **A scratch host runs agents only inside its root.** Started on a root that is not the
   real one, `agentsd` refuses a folder outside it (`--allow-outside-root` lifts that), so
   keep folders under `$ROOT`, as `$ROOT/work` below. It also claims each runtime session
   it runs in `~/Library/Application Support/Agents Session Locks/`, which every daemon on
   this Mac shares, and will not resume a conversation another daemon holds.
8. **Never install.** Do not copy the app into `~/Applications`, `/Applications` or
   `~/AgentsApps`, and do not `launchctl kickstart` the login-item jobs
   (`com.alexecollins.agentshost.daemon` and `.control`). A walk runs from `build/DD`
   on `/tmp/run-<slug>`. `stop.sh` may boot out only the scratch jobs whose plists sit
   in that root.

## Driving it without the screen

`rpc.py` speaks the host's JSON-RPC — one object per line over its socket, the
same protocol the window speaks through the control plane. Every method is in
`Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`; read
`Method` and `Notification` there rather than guessing.

```sh
$S/rpc.py $ROOT call daemon/ping
$S/rpc.py $ROOT call folders/list
$S/rpc.py $ROOT call agents/transcript '{"agentID":"…"}'
$S/rpc.py $ROOT watch 60 agent/changed agent/entry --showing <agentID>
#   notifications as they arrive; an agent's entries and terminal output go only to a
#   connection whose presence shows it (#203), which --showing reports
```

### The turn that stops for a person

A turn that wants permission parks at `state=waitingOnUser`, and in a headless
run there is nobody looking at the card. `rpc.py … start` answers `allow_once`
for you (pass `--ask` to leave them alone and answer them yourself). By hand it
is two calls:

```sh
$S/rpc.py $ROOT call permissions/pending      # id, the tool call, the options
$S/rpc.py $ROOT call permissions/answer '{"permissionID":"…","optionID":"allow-once"}'
```

`elicitations/pending` and `elicitations/answer` are the same shape for a
question a runtime raised, and `agents/setOption '{"agentID":"…","optionID":"mode","value":"acceptEdits"}'`
takes the permission question away for the rest of the conversation.

For anything longer than one call, import it:

```python
import sys; sys.path.insert(0, ".claude/skills/run-app/scripts")
from rpc import Client
c = Client("/tmp/run-mychange")
c.call("folders/add", {"folder": "file:///tmp/run-mychange/work"})
agent = c.call("agents/start", {"runtimeID": "claude",
                                "cwd": "file:///tmp/run-mychange/work",
                                "prompt": "…"})
note = c.wait_for(lambda m: m.get("method") == "agent/permission")
c.call("permissions/answer", {"permissionID": note["params"]["id"],
                              "optionID": "allow-once"})
```

This is how a daemon-side change is proved: state on the record, an entry in the
transcript, a notification that arrived, a file on disk. `$ROOT/logs/daemon.log` has
what it was doing (an `uplink:` line says it joined the control plane);
`$ROOT/agents/<uuid>/agent.json` and `transcript.jsonl` are the record itself and
are plain to `cat`. `$ROOT/control/control.log` is the control plane's side.

A runtime the daemon starts inherits your scratch root, so an agent you start
this way is real: it costs money and it edits files. Point it at `$ROOT/work`,
keep the prompt small, and prefer the socket calls that need no runtime at all
when what you are testing is not the conversation.

## Looking at it

**Walk with the walk socket first (#1172).** A Debug window launched with `--walk` (every
`launch.sh` window) draws and presses itself, in its own process, through `walk.py`. Nothing
goes through the window server, the AX server, focus or HID, so it works on a **locked** or
sleeping screen, it cannot click or type into the person's own window, and it needs no
Accessibility permission and no `screen` lease. Two lanes walk at once, each on its own root.

```sh
$S/walk.py $ROOT shot /tmp/run-mychange-1.png   # the window, its sheet over it; then Read the png
$S/walk.py $ROOT tree 20                        # the accessibility tree, frames as in the shot
$S/walk.py $ROOT find "Not now"                 # every element whose label holds the text
$S/walk.py $ROOT press "=Not now"               # AXPress the innermost match (=: whole label)
$S/walk.py $ROOT unfold proj00                  # a sidebar folder, as its chevron does
$S/walk.py $ROOT select "Fix the build"         # a sidebar row, as a click selects it
$S/walk.py $ROOT set "What do you want to do" "Write hello.txt"   # a field, by label or placeholder
$S/walk.py $ROOT click proj00                   # a click on a label's middle, for a tap gesture
$S/walk.py $ROOT key return                     # a key to the window's first responder
$S/walk.py $ROOT wait "P00 seeded live 0" 10    # until it is there (gone: until it has left)
$S/walk.py $ROOT size 1500 900                  # the window's frame, for wide-window walks
$S/walk.py $ROOT menu Session                   # a menu's items; menu Session Stop chooses one
$S/walk.py $ROOT dock /tmp/run-mychange-dock.png # the icon the app gives the Dock tile, and its badge (#1317)
```

`walk.py` with no arguments lists every command, `--window N` for another window, `--first`
for the first match, and `info`, `views` and `layers` for when a shot or a press goes
wrong. The socket is at `walk.sock` in the walk's folder in the window's container;
`walk.py` links `$ROOT/walk.sock` to it. Only a Debug build has it, and only a window with
`--walk`: the person's window has neither.

What the walk socket does not do, and stays with `ui.swift`, `shot.sh` and the `screen`
lease while the person is away and the screen unlocked: real trackpad gestures (a row
swipe, swiping a pane in) and scroll phases (`.cghidEventTap`), animation and feel, and
menu items that need the key window (most are off in a window launched behind; use the
button or the row instead).

`walk.py shot` takes the window server's picture (`shot.sh`) while the screen is unlocked,
and the window's own render while it is locked: on screen, a window's layers are on the GPU,
and its own render draws the sidebar and the terminal black. The locked render draws the
glass and materials as plain fills, the selected row in the grey of a window that is not
key, and no traffic lights. `--render` takes the window's own render either way.

```sh
$S/shot.sh $ROOT out.png            # window server capture, behind the user's window; unlocked only
swift $S/ui.swift windows <APP_PID> # window ids, sizes, names, on|off this Space
swift $S/ui.swift selftest          # `windows` still finds a window not on screen
swift $S/ui.swift dump <APP_PID> 14 # the accessibility tree through the AX server
swift $S/ui.swift find <APP_PID> "Start"
swift $S/ui.swift press <APP_PID> "Start"   # AXPress, no pointer, no focus stolen
swift $S/ui.swift select <APP_PID> "Agents"  # AXSelected on a list row: picks it
swift $S/ui.swift unfold <APP_PID> "Agents"  # AXDisclosing on a sidebar folder (or fold)
```

`ui.swift` needs Accessibility permission for whatever process runs it, and the AX server
shows no window while the screen is locked. A card in this app is usually the `Button`
itself, so `press` (here and in `walk.py`) walks up from a matching label to the nearest
pressable ancestor. Typing is its weak spot: keystrokes go
wherever focus is, so use `walk.py set` or `walk.py key`, never `cliclick`-style synthetic
keys.

### A question card takes a click (#2374)

A view drawn over the transcript took every click once, and no question card could be
answered; AXPress went round it, so only a click shows it. After a change to the chat pane
(`ChatTranscript`, `SwipeToShowPane`, a card), walk a card:

```sh
$S/rpc.py $ROOT start claude $ROOT/work "Call ask_question once with two questions: id 'pick', \
  prompt 'Which colour?', options Red and Blue; and id 'words', prompt 'Any other words?', \
  with no options." 300 &
$S/walk.py $ROOT select "Call ask_question"
$S/walk.py $ROOT click "=Blue"   # must say "clicked …HostingScrollView…", never "…SwipeAnchorView…"
```

The click must land in the transcript's scroll view. A SwiftUI Button fires only in a
key window, and a walk never makes its window key: the walk socket's click reaches the
Button but does not press it while another app is in front, as on a locked screen. While
the scratch window is key, the same clicks answer the card: Blue turns the page, a click
in the box and `key` letters type into it, and Submit's answer is in the transcript as
`elicitationAnswered`.

A swipe on a session row is the row's, not the chat's (#2459). The detail column, and the
transcript in it, is laid out under the floating sidebar, so `SwipeAnchor.holds` takes a
swipe only when what the window hits is in the anchor's own split view column. With the
screen lease and the scratch window in front, two fingers right to left on another
session's row must show its Archive action and leave the Exchanged pane shut; the same
swipe over the transcript must still open it. `walk.py views 60` shows the two columns:
the `SwipeAnchorView` under one `_NSSplitViewItemViewWrapper`, the sidebar's
`ListCoreScrollView` under the other.

### When a full-screen app is in front

A window opened behind (`launch.sh` without `--front`) while the user's front app is
full screen goes to the desktop's Space, not theirs (#1131). `launch.sh` waits for the
window on any Space, prints `WINDOW_ID` and `WINDOW_ON` (`on` or `off`), and says so on
stderr when it is `off`, or when the window process has no window at all after 30s.
An `off` window is drawn and works: `shot.sh` captures it, and the socket drives it.
AX does not reach it: `ui.swift dump` shows only the menu bar, and `find`, `press` and
`set` match nothing. Do not move it onto the user's Space or bring it forward. Prove
what the socket can, take the screenshots, and leave the presses for when nobody is at
the keyboard (`--front`, rule 5).

### When the screen is locked

A lock no longer stops a walk: `walk.py` draws, reads and presses on a locked screen with
the display asleep, so do not wait for `person.back` to look. Check before you plan a
walk that needs the screen anyway (`1` is locked):

```sh
ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked
```

Only the out-of-scope walks above (gestures, scroll phases, feel) wait for an unlock, with
`wait_for_event` on `person.back` and an `until_minutes`. Nothing unlocks the Mac: macOS
keeps synthetic keys off the lock screen, and no agent is given the password. Do not
change the Mac's sleep or lock settings, and do not hold the display awake. Gestures on
iOS (the Remote walks in the walk simulator, below) and anything about animation or feel
are the user's, worth asking for by name once the rest is done.

## Two windows on one root

Don't. One root is one host, one control plane and one window's pairing. If you need
a second surface, launch a second root with another slug and stop both. The windows
share one container (the bundle id is the real window's), but a walk's window keeps
its pairing in `walks/<walk>` and its defaults in a domain of its own,
`com.alexecollins.agents.store.walk.<walk>` (`WindowDefaults`, #1029); `stop.sh`
removes both.

## The Remote

The Remote is built for the generic simulator:

```sh
scripts/build-cache.sh xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD-sim -skipPackagePluginValidation build
```

To see it, walk it in the **walk simulator** (#1182): one named simulator, "Agents Walk"
(iPhone 17 Pro, the newest iOS), made by `remote.sh` the first time and kept. It boots with
no Simulator GUI. Lease it as `Agents Walk simulator`. Never make another simulator, and
never walk on the user's iPhone or iPad. The Debug Remote launched with `-walk` opens a
walk socket in its container's `tmp/` and draws and presses itself in process, as the Mac
window does (a locked screen does not stop it):

```sh
S=.agents/skills/run-app/scripts
$S/remote.sh up build/DD-sim/Build/Products/Debug-iphonesimulator/Agents.app --fake  # canned daemon
$S/walk.py remote wait "New Session"
$S/walk.py remote press "Lay the remote out"     # a sidebar row, a button
$S/walk.py remote set "What to say" "Push it"    # the prompt
$S/walk.py remote key escape                     # put the keyboard away
$S/walk.py remote scroll --by -600               # as a drag: a following transcript lets go
$S/walk.py remote press "#BackButton"
$S/walk.py remote shot /tmp/remote.png
$S/remote.sh down                                # quits and uninstalls it, shuts the simulator down
```

`AGENTS_WALK_SIM="iPad Pro 13-inch (M5) (16GB)"` gives a kept iPad simulator of its own.
Without `--fake` the Remote is not paired: pair it with a scratch control plane's code
(`code --client`) at launch, `remote.sh up APP -- -pair "$CODE"` (#1287; the sheet's Paste takes
no press but a finger's). With `-pair` it takes the app out first, so no pairing with an earlier root
is kept. APP is the `build/DD-sim` build above, made from this tree: an older Remote may not pair
with this control plane. When the phone says the code was not taken, `remote.sh log` shows the
Remote's own log, whose `pairing: failed:` line says why (#2272). To open a banner's or widget row's link as a tap would, launch with `-- -open
'agents://need?token=…'` (#1367): `simctl openurl` raises "Open in Agents?", which no walk can press. What the walk socket cannot do: the keyboard
runs in another process, so it is drawn white (`key escape` first, for a full picture);
`click` at a point, `menu`, `size` and `fold` are the Mac's only; swipes, long presses,
context menus and feel stay with the user on a device. A fake device
(`FakeDeviceLiveTests`) still stands in for a phone in tests.

## The web remote in a browser (071)

`WEB_URL` is the scratch control plane's web remote. Walk it in headless Chrome with a
throwaway profile, never Alex's own browser (it draws on a locked screen too, #1172): `node Web/test/walk/cdp.mjs` is a dependency-free
DevTools client (launch, open, set the viewport, press by accessible name, type, screenshot,
read the console and network). Pair it with a code made as above (`code --client --browser`).
Safari is walked only with Alex's go-ahead, asked with the question tool; on a locked screen its WebDriver session timed out (#1172, with Alex's Safari open), so a locked walk is headless Chrome.
**Open in Browser** (#109) in a walk's window opens no browser: it writes the address, with
`#code=…` when it pairs, to `walks/run-<slug>/opened-url` in the window's container, and takes
Chrome as the default browser. `node Web/test/walk/openinbrowser.mjs <that file> <profile> <out.png>`
opens it in headless Chrome. Run it once per press, on the same profile.

**Before handing back a change to the window's or the Remote's UI**, check the page against it:
1. Run the scene of `node Web/test/walk/parity.mjs <WEB_URL> <browser code> <ROOT> <out dir> <prefix> [scene…]`
   that covers the change, or add a scene. Make a fresh browser code for each run; a code is spent once
   used. The control plane reads `Web/dist` once at start, so after rebuilding the page restart only
   your root's control plane (its `control/control.pid`) with the arguments `launch.sh` used.
2. Add or update the change's row in its screen's file, `specs/071-web-remote/walks/parity/<screen>.md`: the page's shot, the
   window's shot, and has, partly, lacks or by design.
3. A gap you don't close in the same branch gets a parity issue, named in the commit, when the row's
   tier names that client (#2796). A Mac + web row gets no Remote issue: its line is `remote: tier mac+web`.

## Screenshots for Alex (#2811)

A UI enhancement merges only after Alex approves its screenshots on the PR (AGENTS.md,
"A UI enhancement waits for Alex"). Alex reviews the pictures, not the walk, so take a set
that shows the change as a person meets it:

- **One shot per state and per client.** The states are the ones the change draws: for
  example empty, filled, while it works, an error, and a sheet or a card open. Take each
  state on every client that draws it: the Mac window (`$S/walk.py $ROOT shot`, or
  `$S/shot.sh $ROOT`), the Remote in the walk simulator (`$S/walk.py remote shot`, with
  `key escape` first) and the web page in headless Chrome (`cdp.mjs`'s screenshot). The
  iPad (`AGENTS_WALK_SIM`) only when the change draws differently there. A client that
  does not have the change gets no shot; the PR says why, as its parity line does.
- **Name each file `<client>-<state>.png`**, with `mac`, `remote`, `ipad` or `web` and a
  short state: `mac-empty.png`, `web-error.png`, `remote-question.png`.
- **Only scratch data.** The repo is public: a scratch root and the fake runtime, never a
  real name, path, token, session or Alex's own windows. Read each PNG before you push it.
- **Not a video.** Screenshots are easier to review. Voice mode is the exception: Alex
  tests it on the installed Mac app, because a scratch app has no microphone or speech.

Put them on the PR with `pr-shots.sh`. It commits them to the orphan branch `screenshots`
as `pr-<n>/<file>` (so `main` gets no images and you need no worktree), takes away that
PR's earlier set, and prints a Markdown image line per file:

```sh
$S/pr-shots.sh 2850 /tmp/run-mychange-shots/*.png > /tmp/run-mychange-shots/body.md
```

Put the lines under `## Screenshots` in the PR body (`gh pr edit <n> --body-file`). When Alex
asks for changes, take the whole set again and run it again: Alex sees only the new set.
The shots go with the root in "When you are done"; keep them under `/tmp/run-<slug>-*`.

## When you are done

Before you commit, hand back or end your turn, close everything you started and delete
the scratch app and its files. Do this also when the walk failed, and as soon as you have
finished with the app: not when the lane ends. A scratch app left running is a bug in the
lane: a headless Chrome from one web walk ran for 20 hours after its PR merged (#1624). A
scratch app left on disk is one too: 264 `/tmp/run-*` items and four worktrees' builds of
0.7–7 GB each were found waiting on CI and review (#2400).

1. For every headless Chrome from `Web/test/walk/cdp.mjs`: `await chrome.close()`. Its
   profile, `/tmp/run-<slug>-chrome*`, goes in step 3.
2. If you started the walk simulator: `$S/remote.sh down`. It uninstalls the Remote too.
3. For every root you launched: `$S/stop.sh $ROOT`. It must print `clean`. It removes the
   root and its side files (`/tmp/run-<slug>-*`, `/tmp/run-<slug>.*`: the build log, the
   shots, the Chrome profiles). A root you kept with `--keep`: run `$S/stop.sh $ROOT` again
   the moment you have read it.
4. Check that nothing is left, running or on disk. Both must print nothing:

   ```sh
   pgrep -fl -- "--walk run-<slug>|/tmp/run-<slug>"
   ls -d /tmp/run-<slug>* 2>/dev/null
   ```

5. After the last walk or screenshot you need, unless you will launch again in this turn,
   delete the worktree's own build output: the scratch `Agents.app` and Agents Host in
   `build/DD`, about 2 GB a worktree, and 17 lanes' of it filled the disk (#2346). Do not
   wait for the lane to end: a rebuild from the shared cache is fast (#234), and a lane
   that must walk again after review rebuilds. Never in the main checkout, whose
   `build/DD` the live app may run from. The shared cache in
   `~/Library/Caches/Agents-build/` stays.

   ```sh
   [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ] &&  # a linked worktree
     rm -rf build .build Packages/*/.build
   ```
