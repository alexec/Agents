---
name: Ship after PR merge
on:
  - pr.merged
agent: new
cooldown: 1h
when-done: archive
permission-mode: approve-for-me
---
For each merged pull request, ship the app from main and install to the Mac. Fetch origin, reset the main checkout to origin/main (clean tree), and run from the main checkout (not a worktree). Use the ship-app skill at `.agents/skills/ship-app/SKILL.md`. Follow the skill and run `.agents/skills/ship-app/scripts/ship.sh` (or `.claude/skills/ship-app/scripts/ship.sh` if needed). Lease the shared resource `build` before the build and release it as soon as the script ends. The script installs the Mac app by default; do not pass `--no-mac`. Run unattended: do not ask the user any questions and do not wait for them. Install the Remote on the paired iPhone and iPad if they are available. If a paired device is unavailable because it is asleep, off Wi-Fi or unplugged, skip it and continue (do not retry in a loop). Report the merged pull request, which devices were installed/skipped, and the ship result.