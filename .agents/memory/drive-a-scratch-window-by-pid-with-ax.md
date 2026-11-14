---
name: drive-a-scratch-window-by-pid-with-ax
description: "How to open chats and files in a scratch Agent Loops instance and screenshot it while Alex is using the Mac, with no clicks and no focus change: a Swift AXUIElement helper addressed by pid, and screencapture -l by window id."
metadata: 
  type: project
  modified: 2026-09-26T02:58:32.436Z
---

Verified 2026-09-24 with Alex active at the Mac (idle 0.2s) and three other `Agents`
processes running. Nothing was raised, clicked or typed.

1. **Launch behind:** `env -i … open -g -n <Agent Loops.app> --args --root /tmp/<scratch>`
   (`-g` keeps it out of front). Scratch root = copies of the live root's `agents/`,
   `projects.json`, `workflows.json`.
2. **Window id, not coordinates:** a tiny Swift binary calling
   `CGWindowListCopyWindowInfo` and filtering `kCGWindowOwnerPID` gives the window number;
   then `screencapture -x -l <id>` captures that window even though it is behind his.
   (JXA for the same call returns nothing; a compiled Swift script works.)
3. **Drive by pid with AXUIElement, not AppleScript:** `entire contents` in System
   Events serialises every element as `… of process "Agents"`, which with several
   processes of that name resolves to the wrong one or fails (-1728). A Swift helper
   built on `AXUIElementCreateApplication(pid)` walks children, matches on
   title/description/value, and `AXUIElementPerformAction(kAXPressAction)` opens an agent
   card or a files-pane row without focus. Agent cards are `AXButton`s whose description
   is "<outcome>, <title>, <summary>, <runtime>"; the project sidebar is an `AXOutline`
   of `AXRow`s; files-pane rows are `AXButton`s by file name.
   Exception that works (2026-09-25): an exact path addressed by pid, e.g.
   `tell (first process whose unix id is <pid>) to click menu item "Settings…" of menu 1
   of menu bar item 2 of menu bar 1`, then `click button "Agents" of toolbar 1 of window
   "Appearance"`. Use it when `ui.swift press` would hit a longer label (it presses the
   LAST substring match, e.g. "Services Settings…").
4. **Give the tools a session-unique directory.** `/tmp/agents-scale-tools/ax` was
   overwritten mid-walk by another session using the same path; it happened to keep
   working. Use `/tmp/<something>-$$`.

**Why:** `click at` and `set frontmost` land in whatever is in front, which is his window
at the same coordinates ([[drive-the-scratch-app-only-when-alex-is-away]]). AX actions
and window-id capture never touch the cursor or focus, so the walk can happen while he
is working.

**Now packaged.** Since 2026-09-24 all of this lives in the repository as the `run-app`
skill (`.claude/skills/run-app/`): `launch.sh` (build, `env -i … open -g -n --args --root`),
`rpc.py` (the daemon socket, permissions answered headlessly), `shot.sh`, `ui.swift`
(windows/dump/find/press/set by pid), `stop.sh` (window, then the pid in that root's
daemon.lock, then the root). Invoke the skill rather than rewriting these into /tmp.

**How to apply:** for any "screenshot the app" ask, use the `run-app` skill; fall back to
the guarded click only for things with no AX action.
Related: [[agents-app-hosts-this-session]], [[launch-the-app-with-a-clean-environment]].


**A locked screen blocks both.** When Alex's screen is locked, `shot.sh` / `screencapture -l`
fails with "could not create image from window", and the AX dump returns only the menu bar,
not the window's contents. Check with `ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked`
(1 = locked) before spending time on it. The socket still works, so prove the data side
through `rpc.py` and leave the screenshot for when he is back. (2026-09-24)


**Quirks seen 2026-09-24 (030 walk):**
- `ui.swift set` puts text in the prompt field but doesn't update the SwiftUI binding, so Send
  does nothing. The workflows example link (`offeredPrompt`) fills it for real.
- `press "Send"` hits the Services item "Send to Claude", because matches are tried last-first.
  Use `"Send | Send"`.
- Alert buttons: pressing works, but AX reports failure because the alert is gone. Check the
  effect, not the message.

**2026-09-25 20:45:** after the real app was restarted onto a new build (2706f1e, with the
security review's code signing checks), this session lost Accessibility: osascript and
ui.swift both fail with "not allowed assistive access" (-1719). Screenshots by window id still
work. Walks that press menus or send keys need Alex to re-grant Accessibility in System
Settings ▸ Privacy & Security ▸ Accessibility for the app hosting the session.

**Exact-match press (2026-10-01):** ui.swift only matches substrings and presses the LAST
match, so "Back" hit a "Background" menu item and "Yes" hit "Yes, and allow…". Use a
throwaway copy: `sed 's/label(element).lowercased().contains(needle)/label(element).lowercased() == needle/' ui.swift > /tmp/<slug>-ui-exact.swift`.
`select <pid> "<row text>"` opens a session row (press does not). To hold an answer in
flight for a screenshot, `kill -STOP` your own root's daemon.lock pid, press, shoot, `kill -CONT`;
left stopped ~50s, the window's call fails ("closed") — a real failure path. See [[stacked-accessibility-labels-crash-appkit]].

**What does and doesn't reach SwiftUI (#87 walk, 2026-10-01).**
- `ui.swift set` (AXValue) shows the text but never reaches the `TextField`'s binding, so Send stays disabled. To type: front-check the pid, set `AXFocused` on the field (match it by `AXPlaceholderValue` or by position), then post key events with `CGEvent.postToPid` carrying a unicode string. That does reach the binding.
- AXPress on an item in a SwiftUI **context menu** (via AXShowMenu) reports success and does nothing. **Menu-bar** items do work by AXPress: menu bar ▸ title ▸ children[0] ▸ item. They read `AXEnabled=false` while any modal alert is up in the app.
- `ui.swift press "Send"` matched the Services item "Send to Claude" and left two "problem with the input to the Service" alerts in the scratch app. Those alerts quietly disabled every menu. Look for `AXWindow · alert` in `dump` when menus act dead.
- A slow host for pending states: `kill -STOP <the root's daemon.lock pid>` for a few seconds, then `-CONT`. Held for about 60–90 s, the window answers "That host went offline before it answered". The host still acts on the call when it is resumed.
