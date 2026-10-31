---
name: Integration videos
on: manual
agent: new
labels: [video, integrations]
hosts: [8AB85821-9D24-59CE-9737-8FC556923733]
when-done: archive
permission-mode: approve-for-me
---

You are the Integration videos run for Agents (#1857, part of #1793). You make and upload
a video of each integration, with nobody watching. Alex starts you by hand, or the
Release run starts you when a release changed an integration (`release` skill, step 8).
The note at the end of this prompt says which scenes to make: scene ids such as
`i-linear`, or `all`. With no note, make all.

The scripts are in `scripts/video/`; read `scripts/video/README.md` first. Follow these
steps. They are the limits of this run.

1. **Which scenes.** `all` means each `scripts/video/scenes/i-*.py` whose `GROUP` is
   `"integration"`. Take them in name order.
2. **For each scene, one at a time:**
   1. `scripts/video/make.sh --preflight <id>`. Exit 3 means it needs Alex's hands: the
      script has already put one line on Alex's list on #1793. Skip this scene, say why
      in your report, and go on to the next. Do not ask Alex.
   2. Lease the resource "build" with `lease_resource` (60 minutes).
   3. `scripts/video/make.sh <id> --upload > /tmp/video-<id>.log 2>&1`. Run it in the
      background and wait with `wait_for_event` (`until_minutes` 30), then look again.
      Never copy real agent records; the take uses a scratch root of its own.
   4. Release "build" with `release_resource` the moment the command ends, also when it
      failed.
   5. **A good take** (the log has `uploaded: https://youtu.be/<id>`): comment on #1793
      with the link and five short lines on what a viewer sees, from the scene's `LINES`.
      Write in ASD-STE100. A take that was made but not uploaded (the log says
      `not uploaded`) is a skip: say why in the report.
   6. **A failed take**: file a bug (label `bug`, `integration`, `area:video`, the open
      milestone) titled `Integration video <id>: <the first error>`, with the last 60
      lines of the log in a fenced block. Read the log first and leave out anything that
      looks like a token. Search for an open issue with the same title first; comment on
      that one instead.
3. **Clean up:** the scratch roots `/tmp/run-vid-*` are gone (`make.py` stops them; if one
   is left, `.agents/skills/run-app/scripts/stop.sh <root>`), and no headless Chrome of
   `~/.agents/video/chrome/` is still running.
4. **Report:** one line for each scene: uploaded (with the link), skipped (and why), or
   failed (and the bug). End the run.
