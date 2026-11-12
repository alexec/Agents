---
name: voice-mode-not-in-scratch-app
description: "Real voice mode (mic + speech) only works in the installed Mac app, not a run-app scratch window; walk it with the voice walk command instead"
metadata:
  type: feedback
  modified: 2026-11-11T23:30:00.000Z
---

Voice mode (#2322/#2375, merged in PR #2377 on 2026-10-22) works in the installed Mac app but not in a run-app scratch window. Alex tried it there several times and gave up: "only works installed on mac, not working in scratch app".

**Why:** the scratch copy is a different build and signature on a walk root. Its microphone, speech recognition and voice processing don't work the way they do in the installed app.

**How to apply:** walk voice-mode changes in a scratch window with the walk socket's `{"cmd":"voice","walk":true,"heard":"…"}` (no microphone, no sound). Don't open a scratch app for Alex to talk to. The real test is the installed app, which is Alex's to install (ship-app). Related: [[the-run-app-skill-is-how-to-test-a-change]], [[walk-what-you-ship]].

**A walked reply that is spoken stops the app (2026-11-11, #4844, bug #4853).** Kokoro loads in a scratch app, but when the walk's reply goes to `speaking`, the app stops with SIGTRAP in the system's voice processing (`libBNNS` ← `Espresso`, after `VoiceProcessor … failed to run downlink DSP (state fault)`). Until #4853 is fixed, a walk can go only as far as `listening`, the prompt sent, and `heard`. Do not expect `said` to fill. A walk plays no voice-mode sound by design. To get the sound into a video, use the walk-only tape (#4854), not a recording of the speakers.
