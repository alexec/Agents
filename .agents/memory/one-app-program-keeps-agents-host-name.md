---
name: one-app-program-keeps-agents-host-name
description: Since #4225 the Mac app is Agents.app, but its program is still Contents/MacOS/Agents Host; match both names in pgrep
metadata:
  type: project
---

Since #4225 (2026-11-09) the window and Agents Host are one app, `Agents.app`, with Agents Host's bundle ID. Its program is still `Contents/MacOS/Agents Host` (`EXECUTABLE_NAME` in project.yml). #4229 removed the App Store window (`Agents Store.app`).

**Why:** each login item was registered with `BundleProgram Contents/MacOS/Agents Host`, and launchd runs that path in whatever bundle a self-update puts in place. A new program name would leave an updated alpha install with no host.

**How to apply:** a `pgrep`/`ps` match on the window's process uses `Agents.app/Contents/MacOS/Agents( Host)? --walk …` (run-app's scripts do). Do not rename the program until every install has registered its login items again from a copy with the new name. See [[walk-what-you-ship]].
