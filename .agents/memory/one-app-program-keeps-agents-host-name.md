---
name: one-app-program-keeps-agents-host-name
description: The Mac app is Agent Loops.app (#5297; was Agents.app, #4225), but its program is still Contents/MacOS/Agents Host; match every name in pgrep
metadata:
  type: project
---

Since #4225 (2026-11-09) the window and Agents Host are one app, with Agents Host's bundle ID. It was `Agents.app`; since #5297 (2026-11-13) it is `Agent Loops.app` (`PRODUCT_NAME`; `PRODUCT_MODULE_NAME` stays `Agents`). Its program is still `Contents/MacOS/Agents Host` (`EXECUTABLE_NAME` in project.yml). #4229 removed the App Store window (`Agents Store.app`). agentsd's self-update renames an `Agents.app` or `Agents Host.app` to `Agent Loops.app` (takeNewName), and a release carries `Agents-<v>.zip` and `Agents-Host-<v>.zip` for the copies that fetch those names.

**Why:** each login item was registered with `BundleProgram Contents/MacOS/Agents Host`, and launchd runs that path in whatever bundle a self-update puts in place. A new program name would leave an updated alpha install with no host.

**How to apply:** a `pgrep`/`ps` match on the window's process uses `(Agent Loops|Agents)\.app/Contents/MacOS/Agents( Host)? --walk …` (run-app's scripts do). Do not rename the program until every install has registered its login items again from a copy with the new name. See [[walk-what-you-ship]].
