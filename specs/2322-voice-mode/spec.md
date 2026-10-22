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

1. **Voice mode**, a switch on each device: Settings ▸ Appearance ▸ Voice on the Mac, Settings ▸
   Voice on the Remote. Off at first. Off, the chat has no
   voice control and no voice model is loaded.
2. **A voice button in the prompt bar**, beside the dictate button, when the switch is on. It
   turns on voice mode for this chat:
   - the microphone opens (the system's "listening" sound), and what the person says goes into
     the prompt, as dictation does;
   - after a pause of 2.5 seconds with words in the prompt, the prompt is sent (the "sent"
     sound), with the voice-mode text in front of it;
   - when the turn ends, the reply is spoken, a sentence at a time. A reply of more than 60
     words speaks its first three sentences and then "The rest is on the screen.";
   - then the microphone opens again for the next prompt.
3. **Stop** stops the voice at once. What was not spoken stays on the screen. The button again ends voice mode.
4. **A turn that stops to ask** (a question card, or Grok's question as a waiting turn) speaks
   the question, then its options with numbers: "Two choices. One: Keychain. Two: File."
5. **Sounds**: built-in system sounds only. Mac: `NSSound(named:)`. iPhone and iPad:
   `AudioServicesPlaySystemSound`. Moments: microphone open, prompt sent, done, question
   waiting, error.

## Decisions

| Question | Answer | Who, when |
|---|---|---|
| Clients | The Mac and the Remote. Web: by design, none. | Alex, 2026-10-22 |
| The setting | Per device, in `WindowDefaults.store`, as Show thoughts is (#1725). Off by default. | Alex, 2026-10-22; default decided on #2322 |
| The voice | Paradee-8M int8, through FluidAudio 0.17.7's Core ML build, inside each app (about 24 MB), no download. Loaded when voice mode turns on. Kokoro is out. | Alex's blind listen, #1920, 2026-10-22 |
| Listening | `Dictation.swift` (`SpeechAnalyzer`), on the device. | #2322 |
| What is spoken | Only the reply (`TurnParts.reply`), cleaned by `Speakable`. Never thoughts or tool calls. | #2322 |
| Short replies | `PromptRequest.voice` makes the daemon put the voice-mode text in front of the words, as the prompt's preface. The person's bubble shows only their words. | #2322 |
| Where voice mode turns on | A button by the prompt box that puts this chat in voice mode, not a mode for the whole app. | Decided 2026-10-22, because a chat is what is spoken to, and one tap undoes it |
| Speech while a turn runs | It goes on the queue as a queued prompt (#95), as typed words do. | Decided 2026-10-22, because the queue is there and every runtime takes it |
| Model files | Not in git. `scripts/voice-models.sh` fetches them at a pinned Hugging Face revision, checks each SHA-256, and keeps them in the build cache. A build phase copies them into each app. | Decided 2026-10-22, because 23 MB of binaries in git stays in every clone for ever |

## Slices

1. **The wire, the cleaner, the spec.** `PromptRequest.voice` (`Packages/Wire`, Go, Swift) and
   the daemon's voice preface; `Speakable` in `AgentsKitCore` with its tests, now also clock
   times, versions, camel case outside backticks and the long-reply cut.
2. **Voice mode on the Mac and the Remote.** `Shared/UI/Voice/`: the setting, the button, the
   loop (listen, send, speak), Stop, the sounds, FluidAudio and the bundled models. One change
   for both apps, because both compile `Shared/UI`.
3. **Questions and barge-in.** A question card read out and answered by voice ("two", "the
   first", or the option's words). The person can talk over the voice: the input node's voice
   processing (echo cancellation) stays on while the app speaks, and about 400 ms of speech
   stops the voice.
4. **Approvals by voice**, later: low-risk requests once only, never high-risk ones ("This one
   needs your screen.").

## Not in this feature

- The wake word on the Mac (#1800). It opens this voice mode, after it ships.
- The web page. No Paradee in WASM and no phonemes on the wire.
- Paradee v1.1 in Core ML. Move to it when FluidAudio has it.

## Still to measure

- The iPhone's Core ML numbers (first sound, real-time factor, memory) and an hour of synthesis
  there: does Paradee's CPU path meet the libBNNS bug that Kokoro meets on iOS 27? On Alex's
  checklist #2222.
- Barge-in on the iPhone speaker, on AirPods and on the Mac speakers: does the app's own voice
  stop itself?
