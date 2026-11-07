---
name: scratch-app-opens-no-window
description: run-app launch.sh can leave the scratch app with no window and no daemon; saved window state is the cause, -ApplePersistenceIgnoreState YES fixes it
metadata:
  type: reference
---

Seen 2026-09-24: `launch.sh` built fine, the app process sat idle in its run loop with **no
windows**, and no `daemon.sock` ever appeared ("no daemon.sock under … after 20s", no
daemon.log). The window is what starts the daemon, so no window means no daemon.

Fix: launch by hand with the same `env -i … open -n -g <app> --args --root $ROOT` plus
`-ApplePersistenceIgnoreState YES`. The socket came up in seconds. Likely the shared
bundle id's saved state restoring zero windows — see [[scratch-copies-share-the-real-apps-defaults]].

**How to apply:** if it recurs, add the flag to `.claude/skills/run-app/scripts/launch.sh`
(not yet done, it's the shared tree). Related: [[drive-a-scratch-window-by-pid-with-ax]].

Recurred 2026-09-24 (033 walk) in a second form: the daemon *was* up and an agent ran, but
the app had zero windows (`ui.swift windows` empty). Same fix: kill only that app pid and
reopen with the flag. Also found then: scroll-wheel CGEvents posted to the pid do not scroll a
window that is behind another, so scroll-position behaviour stays part of Alex's walk.

**Cause found 2026-09-25 (mac-menus):** SwiftUI names a `WindowGroup`'s saved window after the
full type of its content, modifiers included (see the `NSWindow Frame SwiftUI.WindowGroup<…>` keys
in `defaults read com.alexecollins.agents`). A branch that adds or removes a modifier on
`ContentView()` in `AgentsApp` renames it; the saved window then matches no scene and the app opens
with none — and so would the real app on its first launch of that build. Keep that expression
exactly `ContentView(…).environment(model).onChange(…)` and pass anything new through
`ContentView`'s own properties. A `Window` scene has the same problem even with
`.defaultLaunchBehavior(.presented)`.

**Not this bug (#1131, 2026-10-16):** "no on-screen window" with a window that *does* exist,
`off`, on the desktop's Space because Alex's front app was full screen. Calculator opened with
`open -g` does the same. Since PR #1132 `ui.swift windows` lists it with on|off, `shot.sh`
captures it, and `launch.sh` prints `WINDOW_ON`; AX still cannot reach it.
