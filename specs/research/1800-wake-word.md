# Spike #1800: a wake word on the Mac

_2026-10-21, standing lane 1. A spike: it builds no feature. The demo is in
[`1800-wake-word/demo/`](1800-wake-word/demo/). Voice mode, which a wake opens, is #1792
([report](1792-voice-mode.md))._

## The answer in short

- **Possible, with no model of our own.** Apple's on-device `SpeechAnalyzer` (a
  `SpeechDetector` for voice activity in front of a `SpeechTranscriber`, the phrase given as
  context) heard **"Hey Agents" in 19 of 24 tries, with no false wake** in the near misses,
  and woke a median **0.19 s** after the phrase ended. It adds 0 MB to the app and has no
  licence to check.
- **It costs little.** The recogniser runs in the system's `localspeechrecognition` service
  (about 54 MB): **0.5 % of one core in a quiet room, 1.5 % while people talk.** The demo's
  own process used under 1 %. The voice-activity detector halves the quiet cost (1.3 % → 0.5 %).
- **The phrase matters more than the method.** "Hey Agents" was heard best. "Hey Loops" was
  heard in only 12 of 24 ("loose", "Lubes", "Bruce"), and 15 with sound-alike spellings.
  "Okay Agents" was heard in 22 of 24 but woke on "Okay, agents can run in parallel now."
- **Recommended:** "Hey Agents", off by default, on the Mac window only, with the
  `SpeechAnalyzer` route. A keyword model is the plan B if Alex's live test shows too many
  false wakes. The live test with a microphone is on Alex's list (#1933).

## What was measured

The test speech is synthetic, made by `wake-demo clips` with `say`: 8 voices (US, UK,
Australian, Irish and Indian English), 3 speeds (160, 185 and 215 words a minute). For each
phrase, 24 tries, each followed by one of 20 near-miss sentences ("Can you look at the for
loops…", "Hey, look at this graph…", "Okay, agents can run in parallel now", "Hey Lou…",
"Fruit Loops are not a breakfast"), with light noise added. A separate file has the 20 near
misses alone (61 s). The runs are paced like a microphone (`--realtime`). `run-all.sh`
makes every number below again.

| Phrase | Heard | False wakes among the tries | False wakes in the near misses alone | Wake after the phrase ends, median (max) |
|---|---:|---:|---:|---:|
| **Hey Agents** | **19 of 24** | **0** | **0** | **0.19 s (0.78 s)** |
| Okay Agents | 22 of 24 | 1 | 1 | 0.24 s (1.03 s) |
| Hey Loops | 12 of 24 | 0 | 0 | 0.41 s (1.28 s) |
| Hey Loops + 6 sound-alikes | 15 of 24 | 1 | 0 | 0.54 s (1.56 s) |

| The speech service's CPU (one core = 100 %) | |
|---|---:|
| Talk, voice-activity detector on | 1.55 % |
| A quiet room, detector on | 0.53 % |
| A quiet room, detector off | 1.34 % |

The energy figure the issue asks for (Activity Monitor's "energy impact" over an hour) and
an hour of real talk, music and a video call need a person and a microphone: on Alex's
list (#1933). 0.5–1.5 % of one core is in the range of a menu-bar app that is idle.

**Synthetic speech is easier than a room.** It is clean, close and at a steady level. Expect
fewer hits from 3 m and more false wakes with a television on. The live test decides.

**Kokoro was the first choice for the test speech.** With eight Kokoro voices loaded it
crashed in libBNNS on this Mac (macOS 27.0.1, `BNNSGraphContextExecute_v2`), 3 runs of 3.
That finding is in the #1792 report, where it counts against Kokoro.

## The ways to hear one phrase

| Way | Size | Licence | Our phrase | Notes |
|---|---:|---|---|---|
| **`SpeechAnalyzer` + `SpeechDetector`** (the demo) | 0 MB | Apple, on the device | Any phrase, no training | Already used by `Dictation.swift`. Each result is text, so a phrase check is a string match. Cost above |
| openWakeWord | ~3 MB (ONNX) | Code Apache 2.0; **pretrained models CC BY-NC-SA 4.0** (non-commercial) | Needs our own model, trained on synthetic speech | Their models cannot ship in the App Store app. Our own trained model can. Needs an ONNX runtime or a Core ML conversion |
| microWakeWord (ESPHome) | < 100 kB (TFLite) | Apache 2.0, models too | Needs our own model | Built for microcontrollers; very cheap. Needs TFLite or a conversion. Training uses Piper voices |
| Porcupine (Picovoice) | ~1 MB | SDK Apache 2.0, **engine needs an AccessKey and a commercial licence** | Custom phrase in their console | An outside account and a per-user cost; against local-first. Out |
| Mycroft Precise, Snowboy | — | Apache 2.0 / unclear | — | Both unmaintained. Out |
| A Create ML sound classifier | < 1 MB | Ours | Trained on synthetic clips | Apple's sound classification hears sounds, not words; weak on near misses. Not tried |

Decided: the `SpeechAnalyzer` route, because it needs no model, no training and no licence
review, and on the test speech it was quick and had no false wakes with "Hey Agents". Alex
can overrule.

## The phrase

Decided: **"Hey Agents"** as the default, because it was heard best of the three (19 of 24,
0 false wakes, 0.19 s) and it is the app's name. Alex can overrule.

- **"Hey Loops"** (the App Store name, #659) is a poor choice for this recogniser: "loops"
  is not a word it expects after "hey", and it writes "loose", "Lubes", "Lubbs", "Bruce".
  Matching those sound-alikes helped only a little (12 → 15 of 24).
- **"Okay Agents"** wakes inside normal speech ("Okay, agents can run…").
- **The person can change it**, as a text setting with a "Try it" button that listens for
  10 s and says whether it heard the phrase. A phrase of two or three words, not common in
  talk, works best. The setting warns when a phrase is one word.

## What a wake does

- **Which project:** the project of the window's selected session, else the last project
  used. With no window open, the last project used.
- **What opens:** a new chat on that project, in voice mode (#1792), listening for the
  prompt at once. The window comes to the front only if the Mac is not in use by another
  app in full screen. Otherwise a small panel shows "Listening…" and the words.
- **The sound:** the system "Glass" at the wake, as in the demo (voice mode uses system sounds, #1792).
- **Words after the phrase on the same breath** ("Hey Agents, run the tests") become the
  prompt, so the person need not wait for the sound.
- **Several Macs:** each Mac's window listens on its own. Two Macs in one room both wake;
  the setting is per Mac, off by default.

## Privacy and trust

- **Off by default.** A setting turns it on: Settings ▸ Mac ▸ "Listen for 'Hey Agents'".
- **macOS shows its orange microphone dot** the whole time it listens. It cannot be hidden,
  and it should not be. The app adds a menu-bar mark that says it listens, with a switch.
- **Nothing leaves the Mac or goes to disk.** `SpeechTranscriber` runs on the device; the
  demo keeps no audio and no text. Only the words after a wake become a prompt.
- **It stops listening** when the Mac locks or sleeps, during a call (another app uses the
  microphone in a voice-chat mode), and when the setting is off.

## Conflicts

- **Another app or a call uses the microphone.** macOS lets two apps read the same input.
  A call app that turns on voice processing changes the input for everyone. The feature
  should pause while a call is on (`AVAudioApplication` input-mute state and the
  audio session's other-audio checks) rather than wake on the call's audio.
- **The Mac locked or asleep:** stop the engine; start again at unlock.
- **More than one window:** one listener per app, not per window. A wake opens the chat in
  the front window.
- **Dictation in the prompt bar** uses the same `SpeechAnalyzer`. Pause the wake listener
  while dictation runs.

## App Store (#659)

- The App Store window (`App/Agents-Store.entitlements`) already has
  `com.apple.security.device.audio-input` and the microphone and speech recognition usage
  strings (for dictation). A sandboxed Mac app may keep the microphone open in the
  background; macOS has no background-audio limit like iOS.
- App Review asks for consent and a clear sign while it records (guideline 2.5.14). Off by
  default, a setting, the orange dot and the menu-bar mark cover it. The review notes should
  say what the wake word does and that no audio is kept.
- The usage string should say it: "Agents listens for 'Hey Agents' when you turn it on, and
  uses the microphone for dictation."

## The demo

```sh
cd specs/research/1800-wake-word/demo
swift build -c release && W=.build/out/Products/Release/wake-demo
$W clips clips                                        # test speech, 8 voices, 3 phrases
$W detect "Hey Agents" clips/stream-hey-agents.wav --realtime --truth clips/truth-hey-agents.json
$W detect "Hey Agents" clips/negatives.wav            # every wake here is a false one
./run-all.sh                                          # every number in this report, into results.txt
$W listen "Hey Agents"                                # the microphone; Control-C stops
```

`listen` needs the microphone, so Terminal asks for it the first time.

## For a feature issue

- One `WakeListener` in the Mac app: `AVAudioEngine` input → `SpeechDetector` +
  `SpeechTranscriber` with `.volatileResults` and the phrase as context → a phrase match →
  a new voice-mode chat. Matching by text, with the sound-alikes a "Try it" run collects.
- Gate it on voice mode (#1792): a wake opens voice mode, so it ships after.
- The Remote and the web page do not get it (the issue's decision): no Siri, no App
  Shortcuts, no Action button.
