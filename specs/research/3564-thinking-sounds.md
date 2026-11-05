# Spike #3564: thinking sounds in place of the working click

**Question.** In voice mode, while the agent works, the app plays the "Working" sound
(Morse at 0.3 volume, every 3 s, #2869). Can the voice make the small sounds a person makes
while they think ("hmm", "mm", "let me see") instead, and how?

**Answer.** Kokoro, the voice we ship, says all the fillers, at 140–240 ms each. It needs no
new files, licence or download. But Alex listened, and the only one Alex likes is "Let me
think." (Alex, 2026-11-05). So:

- The Working sound stays the Morse click. The voice makes no fillers while the agent works.
- "Let me think" becomes a choice for the "Stops listening" sound, the one that plays when
  the prompt goes ("sent").

The demo files are in `~/.agents/research/3564-thinking-sounds/` (open `index.html`). The
build is story #3565.

## What was done

The demo, `specs/research/3564-thinking-sounds/demo`, is a Swift package on FluidAudio 0.17.7,
the version the app pins. It uses the models in the build cache
(`scripts/voice-models.sh`). It has two commands:

- `fillers out/ [voice …]`: 23 fillers in 5 voices (`af_heart`, `af_bella`, `am_michael`,
  `bf_emma`, `bm_george`). 15 fillers are text through the English G2P ("Hmm.", "Huh?",
  "Let me see.", …). 8 are phonemes written by hand (`hmː`, `mːː`, `hmː?`, `ʌː`, …). It writes
  one WAV per voice and filler, and `timings.json`.
- `fillers scene out/ [voice …]`: 50 s of an agent at work, then the start of its reply.
  It writes two copies. One has the Morse click every 3 s (what the app does now). The
  other has thinking sounds at random gaps, with "Huh?" when a tool fails at 30 s.

```sh
cd specs/research/3564-thinking-sounds/demo
../../../../scripts/build-cache.sh swift build -c release
.build/release/fillers /tmp/fillers/
.build/release/fillers scene /tmp/fillers/ af_heart am_michael bf_emma
```

Claude (this agent) cannot hear. So the measures below are of time and length, not of how
human the sounds are. That is Alex's test, from the page above and then on the installed app.

## Measures (Apple M5, Neural Engine)

| | |
|---|---|
| Load (cold, first run after build) | 9.3 s. Warm: 1.4 s. Voice mode loads Kokoro already, so this is no new cost. |
| One filler | 136–238 ms (median about 165 ms). Text and hand-written phonemes cost the same. |
| Six fillers, one voice | about 1 s, once per voice and speed |
| Length | 0.24–0.99 s. British voices and `am_michael` say them more slowly. |
| Memory | about 0.5 s × 24 kHz × 4 B = 48 KB each, under 0.5 MB for a set. The peak of the process, 323 MB, is Kokoro itself. |

**What the G2P does with non-words.** "Hmm." goes to `/hmm./` and "Mm." to `/m./`: the letters
pass through as phonemes. "Uh…" goes to `/ˈʌ…/`, "Um…" to `/ˈʌm…/` and "Huh?" to `/hˈʌ?/`,
which are the right sounds. "Hmm." as text and `hmː` by hand both work. The page has both, so
Alex can keep what sounds human.

## Decisions

Alex's answer (2026-11-05): "I don't love any of these except 'let me think'. Provide that as an
option instead for the 'sent' sound."

1. **Where the sound comes from: Kokoro (a).** It matches the voice that answers and costs one
   synthesis, 172–215 ms. (b) Recorded sounds need a licence, add size and do not match the
   voice. (c) "Still working. Running the tests." (#2358), after 45 s of silence, stays as it
   is.
2. **Which sounds.** Only "Let me think." The others ("Hmm.", "Mm.", "Huh?", "Let me see.",
   "Right…", "Okay." and the phonemes by hand) are out.
3. **When.** Once a prompt, in place of the "sent" sound, when the prompt goes. No fillers while
   the agent works. Not for words said while the voice speaks (barge-in), because then the
   voice stops at once and a spoken line would talk over the person. They keep the sound.
4. **The Working sound** stays Morse, every 3 s. No "Huh?" at a failed tool call.
5. **The setting.** Settings ▸ Voice ▸ Voice mode sounds ▸ Stops listening gets one more choice,
   "Let me think", above the system sounds. The default stays Bottle. Alex can choose it, and
   can make it the default later.

Decided, Alex can overrule:

- Decided: it plays through `VoiceSpeaker`'s player on voice mode's engine, not `NSSound`,
  because then the echo cancellation removes it from the microphone. The microphone opens
  again for words while the agent works. Words heard in the 2 s after it that are only "let me
  think" are dropped, not sent as a prompt.
- Decided: it is made once, at load, just after the "Hi." that warms the voice up, and again
  when the voice or speed changes. One synthesis of about 200 ms there costs nothing a person
  notices. It is ready at the first prompt.
- Decided: the same on the Remote. Its "Stops listening" is system sound 1001 now
  (`VoiceSound.play`, iOS). It plays "Let me think" when that is the choice.

## The Remote (6)

`Shared/UI/Voice` is shared, and the Remote has Kokoro and `VoiceSpeaker` already. So the
same code works on iPhone and iPad. Not measured on a phone: one synthesis at load. The story
measures it on the iPhone with `devicectl`.

## Cost (7)

One phrase: 172–215 ms of Neural Engine time at load (measured in five voices),
0.70–0.98 s of audio, under 100 KB of memory.

## Follow-up

Story #3565: "Let me think" as a choice for the "Stops listening" sound in voice mode (Mac
and Remote). Web: by design, no voice mode.
