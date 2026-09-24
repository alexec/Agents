---
name: run-app
description: Build, launch and drive this Mac app (Agents) on a scratch daemon of its own, so a change can be seen working without touching the real daemon or asking the user to click anything. Use whenever asked to run, start, screenshot, walk or manually verify the app, or whenever a change to App/, Daemon/, Bridge/, Remote/ or Packages/AgentsKit needs proving beyond `swift test`.
---

# Run and test this app

The window is one thing and the agents are another: `agentsd` owns them, and the
root it is pointed at *is* its identity — its lock, its socket, its agents. Two
roots are two daemons that know nothing of each other. That is the whole basis
of this skill: you get a daemon of your own, so nothing you do reaches the
user's agents, and nothing of theirs reaches yours.

**Test your own change. Do not hand the user a list of steps to walk.** Almost
everything the window can do, the socket can do too, with no screen involved.
Ask for the user only after you have run what you can and are stuck on something
genuinely visual — and say what you already saw.

## The loop

```sh
S=.claude/skills/run-app/scripts

# 1. build and launch on a fresh root (prints ROOT, APP_PID, DAEMON_PID)
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

`launch.sh` builds with `xcodegen generate` and
`xcodebuild -scheme Agents -destination 'platform=macOS' -configuration Debug
-derivedDataPath build/DD -skipPackagePluginValidation`. Skip the build with
`--no-build` when nothing has changed since the last one. The build log is at
`/tmp/run-<slug>-build.log`.

## Rules that are not optional

1. **Never `pkill -f agentsd`, never `killall Agents`.** This session is hosted
   by the user's own Agents app and its daemon. The only daemon you may kill is
   the pid in *your* root's `daemon.lock`, which is what `stop.sh` does.
2. **Always stop what you started**, including when the test failed or you are
   about to hand back. A left-behind window and daemon are the user's problem to
   find. `stop.sh $ROOT` removes the root too; `stop.sh $ROOT --keep` leaves it
   for reading and still stops the processes.
3. **Launch with `env -i`** — `launch.sh` does. `open` hands this session's
   environment to the app, and the `CLAUDE_*` variables in it reach every
   runtime the daemon starts; an agent started that way stops authenticating
   the moment this session ends.
4. **Keep the root short.** A Unix socket may be named with 104 bytes and no
   more, and the socket is `<root>/daemon.sock`. `/tmp/run-<slug>` is the shape, and `/tmp/ag-*` is not: the live tests in
   `AgentsKitTests` keep their own temporary roots there.
5. **The window launches behind** (`open -n -g`), so it does not take the screen
   off the user mid-keystroke. Use `--front` only if you must, and prefer it
   when nobody is at the keyboard:
   `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1e9)}'`.

## Driving it without the screen

`rpc.py` speaks the daemon's JSON-RPC — one object per line over the socket, the
same protocol the window speaks. Every method is in
`Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`; read
`Method` and `Notification` there rather than guessing.

```sh
$S/rpc.py $ROOT call daemon/ping
$S/rpc.py $ROOT call projects/list
$S/rpc.py $ROOT call agents/transcript '{"agentID":"…"}'
$S/rpc.py $ROOT watch 60 agent/changed agent/entry    # notifications as they arrive
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
what it was doing; `$ROOT/agents/<uuid>/agent.json` and `transcript.jsonl` are
the record itself and are plain to `cat`.

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
```

`ui.swift` needs Accessibility permission for whatever process runs it; if it
says it has none, screenshots and the socket still work and are usually enough.
`screencapture -l <window id>` and AX actions both work on a window that is not
in front, which is what makes this safe while somebody is working. A card in
this app is usually the `Button` itself, so `press` walks up from a matching
label to the nearest pressable ancestor. Typing is the weak spot: keystrokes go
wherever focus is, so use `ui.swift set` on a field, or the socket, rather than
`cliclick`-style synthetic keys.

What you genuinely cannot do: tap iOS in the Simulator (there is no Simulator
GUI on this Mac — boot and screenshot only), and judge anything about animation
or feel. Those are the user's, and are worth asking for by name once the rest is
done.

## Two windows on one root

Don't. One root is one daemon and one window's worth of state. If you need a
second surface, launch a second root with another slug and stop both.
