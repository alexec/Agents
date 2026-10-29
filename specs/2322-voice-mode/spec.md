# Feature Specification: Voice mode on the Mac and the Remote

**Feature Branch**: `agents/are-expedited-voice-mode`

**Created**: 2026-10-22

**Status**: Being built, in the pull requests listed under "Slices".

**Milestone**: none (`expedite`, priority high). It can merge before 0.11 ships.

**Input**: Issue #2322. The spike #1792 found what to build: report `specs/research/1792-voice-mode.md`, demo in PR #1926. Alex's design notes are on #1792 (2026-10-20).

## Why this feature exists

**The person talks to a project and hears the reply.** They can walk, cook or drive and still
work with an agent. The Mac window and the Remote (iPhone and iPad) do it. The web page does
not (Alex, 2026-10-22: "would be weird").

## What the person sees

1. **Voice mode**, a switch on each device: Settings ▸ Voice on the Mac and the Remote (#2869;
   was under Appearance on the Mac). On at first since #2869: nothing loads and no microphone
   opens until the voice button is pressed. Off, the chat has no voice control and no voice
   model is loaded. The same page sets the voice, its speed, the pause between sentences, the
   wait before the words go, and plays a sample of them; on the Mac it also picks each sound
   and plays it (#2869).
2. **A voice button in the prompt bar**, beside the dictate button, when the switch is on, in a
   chat and in a new session, whose first words start it. On, only the field changes, to the
   words heard or said: every pill and option stays, Stop is where send and stop are, and the
   button is the moving blue waveform (#2869). It turns on voice mode for this chat:
   - the microphone opens (the system's "listening" sound), and what the person says goes into
     the prompt, as dictation does;
   - after a pause of 2.5 seconds with words in the prompt, the prompt is sent (the "sent"
     sound), with the voice-mode text in front of it;
   - when the turn ends, the reply is spoken, a sentence at a time. A reply of more than 60
     words speaks its first three sentences and then "The rest is on the screen.";
   - then the microphone opens again for the next prompt.
3. **Stop** ends voice mode. One press of the stop symbol, or Escape, stops the voice at once and closes the microphone. What was not spoken stays on the screen. Talking over the voice, which stops it and keeps listening, is barge-in (#2358), not this button.
4. **A turn that stops to ask** (a question card, or Grok's question as a waiting turn) speaks
   the question, then its options with numbers: "Two choices. One: Keychain. Two: File. One
   is recommended." The person says a number or the choice's words; voice mode says
   "Sending: File." and sends it unless the person says "no" within 2 seconds.
5. **Sounds**: built-in system sounds only. Mac: `NSSound(named:)`, each one chosen in Settings ▸
   Voice. iPhone and iPad: `AudioServicesPlaySystemSound`. Moments: starts listening (once the
   microphone really hears), stops listening (the words went), working (every few seconds while
   the agent works and nothing is said), still listening, question waiting, error, voice mode
   ends (#2869).

## Decisions

| Question | Answer | Who, when |
|---|---|---|
| Clients | The Mac and the Remote. Web: by design, none. | Alex, 2026-10-22 |
| The setting | Per device, in `WindowDefaults.store`, as Show thoughts is (#1725). On by default since #2869. | Alex, 2026-10-22; default decided on #2322, then on #2869 |
| The voice | Kokoro-82M through FluidAudio 0.17.7's Neural Engine build, `af_heart` at first and 28 American and British English voices to choose from, inside each app (about 104 MB), no download. Loaded as voice mode turns on, while the person speaks. Was Paradee-8M (#1920). The integration videos' Chatterbox was tried and is too slow on device: over ten minutes of GPU compile per process for the full model, three seconds per second of speech for Nano. | Alex, #2869, 2026-10-29 |
| How fast it listens | Within 100 ms of the press on the Mac: echo cancellation is set up when the voice button shows and kept between uses; the microphone is on only while voice mode is. | Alex, #2869, 2026-10-29 |
| Listening | `Dictation.swift` (`SpeechAnalyzer`), on the device. | #2322 |
| What is spoken | Only the reply (`TurnParts.reply`), cleaned by `Speakable`. Never thoughts or tool calls. | #2322 |
| Short replies | `PromptRequest.voice` makes the daemon put the voice-mode text in front of the words, as the prompt's preface. The person's bubble shows only their words. | #2322 |
| Where voice mode turns on | A button by the prompt box that puts this chat in voice mode, not a mode for the whole app. | Decided 2026-10-22, because a chat is what is spoken to, and one tap undoes it |
| Speech while a turn runs | It goes on the queue as a queued prompt (#95), as typed words do. | Decided 2026-10-22, because the queue is there and every runtime takes it |
| Model files | Not in git. `scripts/voice-models.sh` fetches them at a pinned Hugging Face revision, checks each SHA-256, turns the JSON voices into the `.bin` FluidAudio reads, and keeps them in the build cache. A build phase copies them into each app. | Decided 2026-10-22, because 23 MB of binaries in git stays in every clone for ever |

## Slices

1. **The wire, the cleaner, the spec.** `PromptRequest.voice` (`Packages/Wire`, Go, Swift) and
   the daemon's voice preface; `Speakable` in `AgentsKitCore` with its tests, now also clock
   times, versions, camel case outside backticks and the long-reply cut.
2. **Voice mode on the Mac and the Remote.** `Shared/UI/Voice/`: the setting, the button, the
   loop (listen, send, speak), Stop, the sounds, FluidAudio and the bundled models. One change
   for both apps, because both compile `Shared/UI`.
3. **Questions by voice.** A question card with one set of choices is read out with numbers
   and answered by voice ("two", "the second", or the choice's words): "Sending: File.", with
   2 seconds to say "no". Any other form says "This one needs your screen." (`SpokenQuestion`).
4. **Barge-in, approvals by voice, plans, a still-working line:** #2358. Barge-in is in #2375
   (the voice and the microphone on one audio engine, repaired in #2419). A permission the
   agent waits on is read out (`SpokenPermission`): a read, a search, or an edit inside the
   agent's own worktree is answered by voice, "yes" allows it once (never "always", with 2
   seconds to say "no") and "no" refuses it; anything else ends "This one needs your
   screen.". A plan to approve is read as its number of steps and the first two, then
   "Approve the plan?". After 45 s of nothing said or heard while a turn runs, voice mode
   says "Still working." and the current tool call's line, once a step (`StillWorking`).
   Measurement on real speakers, AirPods and the iPhone is on Alex's list (#2222).

## Not in this feature

- The wake word on the Mac (#1800). Shipped in #2420 and removed in #2869 (Alex, 2026-10-29).
- The web page. No voice model in WASM and no phonemes on the wire.

## Still to measure

- The iPhone's Core ML numbers (first sound, real-time factor, memory) and an hour of synthesis
  there: does Kokoro meet the libBNNS bug on iOS 27? On Alex's checklist #2222. The Mac trapped
  in libBNNS once (2026-10-29), most likely two Core ML runs at once; `KokoroVoice` now runs one at
  a time.
- Barge-in on the iPhone speaker, on AirPods and on the Mac speakers: does the app's own voice
  stop itself?
