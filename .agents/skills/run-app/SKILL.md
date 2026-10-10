---
name: run-app
description: Build, launch and drive this Mac app (Agents) on a scratch set-up of its own (a control plane, this Mac's host and the window), so a change can be seen working without touching the real ones or asking the user to click anything. Use whenever asked to run, start, screenshot, walk or manually verify the app, or whenever a change to App/, Host/, Daemon/, Remote/, Packages/AgentsKit or Packages/ControlPlane needs proving beyond `swift test`.
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

# 1. build and launch on a fresh root (prints ROOT, APP_PID, DAEMON_PID, CONTROL_PID, CONTROL_URL)
eval "$($S/launch.sh --slug mychange)"        # /tmp/run-mychange

# 2. give it something to work in — you may create scratch projects freely
mkdir -p $ROOT/work && git -C $ROOT/work init -q
$S/rpc.py $ROOT call projects/add "{\"folder\":\"file://$ROOT/work\"}"

# 3. drive it and read what came back
$S/rpc.py $ROOT call agents/list '{"includeArchived":false}'
$S/rpc.py $ROOT start claude $ROOT/work "Write hello.txt with one line in it." 120
#   ^ starts a real agent, says yes to its permissions, and follows it to the end

# 4. look at it, if the change is visual
$S/shot.sh $ROOT /tmp/run-mychange-1.png        # then Read the png

# 5. always, at the end
$S/stop.sh $ROOT
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
`merge-wave.sh plan` lists them (an `App/` change needs `AgentsHost` and `AgentsStore`,
not the Remote or the web page; a `Packages/AgentsKit` change needs its tests filtered
by `scripts/select-test-suites.sh`). The full suite and every scheme run once, in the wave.

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
`--host-first` starts the host while the control plane is down, with the host code left in
its root as Agents Host leaves it, waits until it has failed to join (`HOST_FIRST_WAIT`
seconds more, 5 by default), then starts the control plane and waits for the host to join
with the same code (#113). The control plane is always given `--host-root $ROOT`, so
`control/status` carries the host's join as `thisMacHost`.
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
   find. `stop.sh $ROOT` removes the root too; `stop.sh $ROOT --keep` leaves it
   for reading and still stops the processes.
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
   its `agents/`, not one record, not `projects.json` or `workflows.json` (#228). A copied
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
   keep projects under `$ROOT`, as `$ROOT/work` below. It also claims each runtime session
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
$S/rpc.py $ROOT call projects/list
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
c.call("projects/add", {"folder": "file:///tmp/run-mychange/work"})
agent = c.call("agents/start", {"runtimeID": "claude",
                                "cwd": "file:///tmp/run-mychange/work",
                                "prompt": "…"})
note = c.wait_for(lambda m: m.get("method") == "agent/permission")
c.call("permissions/answer", {"permissionID": note["params"]["id"],
                              "optionID": "allow-once"})
```

This is how a daemon-side change is proved: state on the record, an entry in the
transcript, a notification that arrived, a file on disk. `$ROOT/daemon.log` has
what it was doing (an `uplink:` line says it joined the control plane);
`$ROOT/agents/<uuid>/agent.json` and `transcript.jsonl` are the record itself and
are plain to `cat`. `$ROOT/control/control.log` is the control plane's side.

A runtime the daemon starts inherits your scratch root, so an agent you start
this way is real: it costs money and it edits files. Point it at `$ROOT/work`,
keep the prompt small, and prefer the socket calls that need no runtime at all
when what you are testing is not the conversation.

## Looking at it

```sh
$S/shot.sh $ROOT out.png            # captures the window even behind the user's
swift $S/ui.swift windows <APP_PID> # window ids and sizes
swift $S/ui.swift dump <APP_PID> 14 # the accessibility tree: roles and labels
swift $S/ui.swift find <APP_PID> "Start"
swift $S/ui.swift press <APP_PID> "Start"   # AXPress, no pointer, no focus stolen
swift $S/ui.swift select <APP_PID> "Agents"  # AXSelected on a list row: picks it
swift $S/ui.swift unfold <APP_PID> "Agents"  # AXDisclosing on a sidebar project (or fold)
```

`ui.swift` needs Accessibility permission for whatever process runs it; if it
says it has none, screenshots and the socket still work and are usually enough.
`screencapture -l <window id>` and AX actions both work on a window that is not
in front, which is what makes this safe while somebody is working. A card in
this app is usually the `Button` itself, so `press` walks up from a matching
label to the nearest pressable ancestor. Typing is the weak spot: keystrokes go
wherever focus is, so use `ui.swift set` on a field, or the socket, rather than
`cliclick`-style synthetic keys.

### When the screen is locked

A locked Mac stops the looking, not the testing. With the lock screen up,
`shot.sh` says "could not create image from window" (or captures only after the
display is woken), `ui.swift dump` shows the menu bar and no window, and `press`
matches nothing. Nothing unlocks it: macOS keeps synthetic keys off the lock
screen, and no agent is given the password. Do not change the Mac's sleep or
lock settings, and do not hold the display awake to stop it locking.

Check before you plan a look — `1` is locked:

```sh
ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked
```

If it is locked, do everything the socket can prove first, then wait for the
user to unlock with `wait_for_event` on `person.back` with an `until_minutes`
(its `why` is `locked` for an unlock; every wait needs a time limit, #572) and do the look when you are started again. Check the lock once more
before you shoot. Keep the scratch root with `stop.sh $ROOT --keep` if you
stop meanwhile, so the look is quick to redo with `launch.sh --no-build`.
A locked screen is a wait, not a failure: end the turn waiting and say what is
already proved rather than reporting that you could not test.

What you genuinely cannot do: tap iOS in the Simulator (there is no Simulator
GUI on this Mac — boot and screenshot only), and judge anything about animation
or feel. Those are the user's, and are worth asking for by name once the rest is
done.

## Two windows on one root

Don't. One root is one host, one control plane and one window's pairing. If you need
a second surface, launch a second root with another slug and stop both. The windows
share one container and its defaults (the bundle id is the real window's), so a
walk can still move the user's own window's sidebar or selected project; the
pairing is the one thing kept apart.

## The Remote

The Remote is built for the generic simulator only, never booted here:

```sh
scripts/build-cache.sh xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD-sim -skipPackagePluginValidation build
```

A fake device (`FakeDeviceLiveTests`) stands in for a phone against a scratch
control plane; the phone's look is the user's.

## The web remote in a browser (071)

`WEB_URL` is the scratch control plane's web remote. Walk it in headless Chrome with a
throwaway profile, never Alex's own browser: `node Web/test/walk/cdp.mjs` is a dependency-free
DevTools client (launch, open, set the viewport, press by accessible name, type, screenshot,
read the console and network). Pair it with a code made as above (`code --client --browser`).
Safari is walked only with Alex's go-ahead, asked with the question tool.
**Open in Browser** (#109) in a walk's window opens no browser: it writes the address, with
`#code=…` when it pairs, to `walks/run-<slug>/opened-url` in the window's container, and takes
Chrome as the default browser. `node Web/test/walk/openinbrowser.mjs <that file> <profile> <out.png>`
opens it in headless Chrome. Run it once per press, on the same profile.

**Before handing back a change to the window's or the Remote's UI**, check the page against it:
1. Run the scene of `node Web/test/walk/parity.mjs <WEB_URL> <browser code> <ROOT> <out dir> <prefix> [scene…]`
   that covers the change, or add a scene. Make a fresh browser code for each run; a code is spent once
   used. The control plane reads `Web/dist` once at start, so after rebuilding the page restart only
   your root's control plane (its `control/control.pid`) with the arguments `launch.sh` used.
2. Add or update the change's row in `specs/071-web-remote/walks/parity.md`: the page's shot, the
   window's shot, and has, partly, lacks or by design.
3. A gap you don't close in the same branch gets a parity issue, named in the commit.
