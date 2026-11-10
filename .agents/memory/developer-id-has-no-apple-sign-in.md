---
name: developer-id-has-no-apple-sign-in
description: Apple leaves com.apple.developer.applesignin out of every Developer ID profile; only the one Mac app's Live build (development profile "Agents Development") has Sign in with Apple
metadata:
  type: project
---

Apple does not put `com.apple.developer.applesignin` in a **Developer ID** profile, also when the App ID has the capability. The profile `Agents Developer ID` (`com.alexecollins.agents.host`, made twice on 2026-11-09, #4283) has only the app id, team and keychain groups. So the release's Developer ID app cannot open Apple's sheet and shows the line from #4280 in place of the button. Only the `Live` build that `ship-app` installs has the entitlement: `Host/AgentsHost-Live.entitlements`, signed with Apple Development and the profile `Agents Development`, which names Alex's Mac (#4286).

**Why:** a lane asked for a new `release` secret with the Developer ID profile (#2781). That profile gives the release no entitlement, so the secret is not needed.

**How to apply:** do not add a Developer ID profile to `scripts/release-host.sh` or the release job for Sign in with Apple. To check a profile: `security cms -D -i <file> | plutil -extract Entitlements xml1 -o - -`. Sign in with Apple in a released Mac app needs another way (the web flow, #4228), not a profile. The `Agents Development` profile expires 2027-11-10. See [[apple-sign-in-on]].
