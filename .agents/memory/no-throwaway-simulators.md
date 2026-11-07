---
name: no-throwaway-simulators
description: "Don't create or boot iOS simulators to screenshot phone screens; build for the generic simulator destination only and hand the first look to Alex on a device."
metadata:
  type: feedback
  modified: 2026-09-25T03:47:10.899Z
---

On 2026-09-24, during 029, Alex stopped `xcrun simctl create` + boot + a per-device build meant to screenshot the phone's New agent sheet. When asked, he chose "delete it, skip screenshots".

**Why:** he didn't give a reason. Likely the cost (a booted simulator plus a second DerivedData build) for a screen he'll walk himself on a real iPhone anyway.

**How to apply:** for Remote changes, build with `-destination 'generic/platform=iOS Simulator'` (see [[xcodebuild-needs-skip-plugin-validation]]) and stop there. Don't create, boot or install onto a simulator unless Alex asks. Say plainly which phone screens were never seen. This narrows [[no-simulator-gui-on-this-mac]] and the "settle the UX by running it" rule in [[settle-ux-before-building-depth]] for the phone.

**Exception (2026-10-15, #1078):** demo videos must be made with no person ("It is important to do this without Alex"), so the video pipeline may boot and reuse one named iOS 27 simulator and drive it with XCUITest. This is still not a reason for throwaway simulators for ordinary Remote changes.

**Exception (2026-10-16, #1182, PR #1204):** Remote walks use one kept simulator, "Agents Walk" (iPhone 17 Pro, iOS 27), made by `run-app/scripts/remote.sh` and only shut down after a walk, never deleted. Lease it as `Agents Walk simulator`. `walk.py remote …` drives the Debug Remote in it in process (no GUI needed). Still no other simulators.
