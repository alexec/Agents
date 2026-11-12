---
name: voice-mode-not-in-scratch-app
description: "Real voice mode (mic + speech) only works in the installed Mac app, not a run-app scratch window; walk it with the voice walk command instead"
metadata:
  type: feedback
  modified: 2026-11-12T17:10:00.000Z
---

Voice mode (#2322/#2375, merged in PR #2377 on 2026-10-22) works in the installed Mac app but not in a run-app scratch window. Alex tried it there several times and gave up: "only works installed on mac, not working in scratch app".

**Why:** the scratch copy is a different build and signature on a walk root. Its microphone, speech recognition and voice processing don't work the way they do in the installed app.

**How to apply:** walk voice-mode changes in a scratch window with the walk socket's `{"cmd":"voice","walk":true,"heard":"…"}` (no microphone, no sound). Don't open a scratch app for Alex to talk to. The real test is the installed app, which is Alex's to install (ship-app). Related: [[the-run-app-skill-is-how-to-test-a-change]], [[walk-what-you-ship]].

**A walked reply that is spoken often stops the app (2026-11-12, #4853).** On macOS 27.0.1 the scratch app stopped in about 5 of 11 walks, with SIGTRAP in Kokoro's own Core ML run (`libBNNS` `BNNSGraphContextExecute_v2` ← `Espresso` on `com.apple.e5rt.concurrentExecutionQueue`), while it made the first reply sentence. It is not voice processing: it also stops with echo cancellation off, and with the walk-only tape (#4854), where the audio engine never starts. The same FluidAudio 0.17.7, models, route, voice and speed in a small program outside the app ran 48 of 48 times with no crash (Release and Debug, every route, a 12 s pause after loading). FluidAudio closed its BNNS crash on the 27 line as Apple's (FluidInference/FluidAudio#889); 27.2 may fix it. So a walk can stop at any reply. Run it again when it stops, and do not expect `said` to fill every time. A walk plays no voice-mode sound by design. To get the sound into a video, use the walk-only tape (#4854), not a recording of the speakers.
