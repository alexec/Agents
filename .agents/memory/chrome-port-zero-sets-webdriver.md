---
name: chrome-port-zero-sets-webdriver
description: Google Chrome 157 started with --remote-debugging-port=0 sets navigator.webdriver true on every page; a fixed port leaves it false
metadata:
  type: project
---

Google Chrome stable (157, macOS) started with `--remote-debugging-port=0` says `navigator.webdriver === true` on every page, also tabs Playwright opens. The same Chrome with a fixed port (agentsd picks a free one) says `false`. Measured in #5207 by changing one flag at a time; chromedp's CDP session, env and the other flags did not change it. With a fixed port Chrome also writes no `DevToolsActivePort`: read the address from `http://127.0.0.1:<port>/json/version`.

**Why:** Google's sign-in and other bot checks look at `navigator.webdriver` (#4837, [[google-refuses-the-agents-browser]]).

**How to apply:** never start the agents' Google Chrome with port 0 (`Go/internal/browser/browser.go`, `launchChrome`). macOS also keeps part of a window on the screen: 1 point across at x = -(width-1), and about 129 points up from the bottom of a 1440-point display.
