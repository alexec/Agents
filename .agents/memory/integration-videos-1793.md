---
name: integration-videos-1793
description: "Alex 2026-10-20 wants a scripted, repeatable video per integration on a real account, tokens blurred + revoked, uploaded private to YouTube"
metadata:
  type: project
  modified: 2026-10-20T19:40:21.127Z
---

Alex (2026-10-20) wants one video per integration, made by a script in `scripts/video/` (#1078), so it can be made again when the UI changes. Epic #1793; Linear pilot #1794 (lane 5C5AD1CA). Tokens: a token made for the video only, blurred in the frames, an OCR check, then revoked and proved dead (401). Uploads go private to the Loops channel, a playlist per scene GROUP ("Loops integrations" for these; #4836). Alex's steps (YouTube OAuth client, Linear sign-in in the video Chrome profile) are on #1793 with alex-todo.

**Why:** Alex can watch a video to check that an integration works as Alex wants, instead of doing each step by hand (see [[alex-tests-every-integration]]).

**How to apply:** each new integration gets an `i-<name>` scene; the release re-makes the videos whose integration paths changed.
