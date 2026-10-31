# Promotional screenshots

The site's pictures (`www/assets/shots/`) and the App Store's (`promo/app-store/screenshots/`)
come from a scratch set-up with made-up folders and agents, never the real one. Take them
again when the UI changes, with the run-app skill:

1. Lease `build`. Launch a scratch set-up with a made-up name for the person:

   ```sh
   mkdir -p /tmp/run-promo && echo 500GB > /tmp/run-promo/disk-free-override
   .claude/skills/run-app/scripts/launch.sh --seeded --slug promo --appearance light --outside-checkout --person Sam
   ```

2. Stage it: `python3 promo/shots/stage.py /tmp/run-promo`. It adds three folders
   (weather-app, recipe-box, billing-service) and starts small Claude agents in them. Say yes
   to their permissions (`rpc.py … call permissions/pending`, then `permissions/answer`), and
   leave the currency question unanswered: it is the "Needs you" agent.
3. **Mac**: `walk.py /tmp/run-promo size 1440 900`, put away the Get started and milestone
   cards, unfold the folders, select an agent, and `walk.py … shot`. On a 1× screen the shot
   is 1440×900; on a Retina screen it is 2880×1800. Both are App Store sizes.
4. **Web**: a browser code (`agents-control code --client --browser --home /tmp/run-promo/control`)
   and `scripts/video/web.mjs` at 1440×900.
5. **iPhone and iPad**: build the Remote for the simulator, lease `Agents Walk simulator`, and
   use the kept walk simulators by their device type, so the shots come out at App Store sizes:
   `AGENTS_WALK_SIM="iPhone 17 Pro Max"` (1320×2868, 6.9-inch) and
   `AGENTS_WALK_SIM="iPad Pro 13-inch (M5) (16GB)"` (2064×2752, 13-inch). Pair each with
   `remote.sh up APP -- -pair "$(agents-control code --client …)"`, then `walk.py remote shot`.
6. Close everything: `remote.sh down` for each simulator, `stop.sh /tmp/run-promo` (it must
   print `clean`), and release the leases.

The agents still read the person's own `~/.claude/CLAUDE.md`. Look at every shot for the
person's name or their own instructions before you keep it.
