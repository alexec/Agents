# 044 walk: the look gate (T016)

This is the site as built on 2026-09-25, served locally from `site/` and captured with headless Chrome. The home
page and *Your first agent* are real. The other three sections are empty indexes until you've approved this
layout, tone and depth.

## Home

![The home page on a desktop](site-home.png)

At phone width it fits without sideways scroll (captured at 500 px, the narrowest headless Chrome would draw):

![The home page at phone width](site-home-narrow.png)

## Your first agent

![The first tutorial on a desktop](site-first-agent.png)

The tutorial was walked for real on a scratch copy of the app (`/tmp/run-044`, built from this branch):
- The first shot is the one project page with the prompt.
- The agent was given "Why does the test fail? Fix it." in `weather-app`, which has a Fahrenheit/Celsius bug and one
  failing test.
- Claude asked three times (read and run the tests, edit `Forecast.swift`, run them again). The card's buttons
  are **Yes**, **Yes, and don't ask again…** and **No**.
- It ended in **Complete** as "Fix failing Forecast test", with a one-line fix and "Commit the fix." offered next.

The five pictures in the tutorial come from that run.

## Found along the way

- **No way to install but Xcode.** There are no releases, so the tutorial's first step is clone, `xcodegen`, build
  (your choice, 2026-09-25).
- **The iPhone tutorial needs `agents-bridge` started by hand**, and the bridge itself says it has no pairing and
  no encryption on the LAN. The draft says so in a warning box. It has no pictures yet; they are yours (T014).
- **A fresh worktree does not build** until `App/Resources/servers/` exists. It is gitignored (037's Linux
  binaries). The build copies it as a folder and fails if it is missing. An empty folder was enough here.

## Still to do after the gate

- The ten how-to guides, the six reference pages and the five explanations (T017–T040).
- The publish workflow (T047), and turning on Pages (T048), which is yours.
- The privacy pass, the phone-width pass and the quickstart run (T050–T053).
