# Spike #3564: thinking sounds in place of the working click

**Question.** In voice mode, while the agent works, the app plays the "Working" sound
(Morse at 0.3 volume, every 3 s, #2869). Can the voice make the small sounds a person makes
while they think ("hmm", "mm", "let me see") instead, and how?

**Answer.** Yes. Kokoro, the voice we ship, says them well enough to try. It makes each one
in 140–240 ms, and they need no new files, licence or download. Alex decides by ear: the
demo files are in `~/.agents/research/3564-thinking-sounds/` (open `index.html`). The build
is follow-up story #3565.

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

## Decisions on questions 1–5 (Alex can overrule)

1. **Where the sounds come from: Kokoro (a).** Decided: Kokoro says the fillers, made once
   per voice and speed, because they then match the voice that answers, and it costs about
   1 s of Neural Engine time and no new files. (b) Recorded sounds need a licence, add size
   and do not match the voice. (c) A spoken line at a tool call is "Still working. Running
   the tests." (#2358) already, after 45 s of silence. It stays as it is.
2. **Does Kokoro say "hmm" well?** Measured: yes, it says all 23 without a failure, in the
   time above. How human they sound is Alex's ear. The set to start with, before Alex
   listens: "Hmm.", "Hmmm…", "Mm.", "Let me see.", "Right…", "Okay.". Change it after
   listening to the page.
3. **When and how often.** Decided:
   - The first filler 1–2 s after the "sent" sound, so the click is not followed at once
     by a voice.
   - After that, one at a random gap of 2× to 4× "Working sound every" (6–12 s at the
     default of 3 s). Never the same filler twice running.
   - Only when `ticksInSilence` is true and nothing is in the speech queue. Never while the
     voice speaks, asks a question, waits for a "no", or hears words.
   - The fillers are played through `VoiceSpeaker`'s player on voice mode's engine, not
     `NSSound`. Then the echo cancellation removes them from the microphone. If one gets
     through, `VoiceModeWords.backchannel` already ignores "hmm", "mm", "okay" and "right"
     as barge-in. But words heard while the agent works are a prompt, not barge-in. So the
     story must also drop words heard that are only backchannel and match a filler said in
     the last 2 s.
   - Volume 0.5. That is quieter than the reply (1.0) and louder than Morse (0.3), because a
     voice at 0.3 is hard to hear.
4. **Which sound for which moment.** Decided: the "hmm" family while the agent works. "Huh?"
   once in a turn, at the first tool call that fails. Not at a question card: a question
   keeps its own sound ("Purr") and the spoken question. Two sounds there would say the same
   thing twice.
5. **The setting.** Decided: Settings ▸ Voice ▸ Voice mode sounds ▸ Working gets one more choice,
   "Thinking sounds", above the system sounds. The default stays Morse until Alex has
   listened on the installed app. Then the story changes the default when Alex says so.
   "Working sound every" stays. For thinking sounds it sets the gap as in 3.

## The Remote (6)

`Shared/UI/Voice` is shared, and the Remote has Kokoro and `VoiceSpeaker` already. So the
same code works on iPhone and iPad. Now the Remote plays system sound 1105 for "Working"
(`VoiceSound.play`, iOS). The story replaces that with the same picker. Not measured on a
phone: six fillers at about 0.2 s each is about 1 s of Neural Engine time once per voice. The
story measures it on the iPhone with `devicectl` before it ships.

## Cost (7)

- **Do not make the fillers at load.** `KokoroVoice` runs one Core ML call at a time. Six
  fillers at load would put about 1 s in front of the first reply.
- Make each filler the first time it is needed, in the silence while the agent works, when
  the voice is idle. Keep them in memory for the voice and speed.
- A change of voice or speed in Settings drops them.
- An on-disk cache is not needed for 1 s of work.

## Follow-up

Story #3565: "Thinking sounds" as a choice for the Working sound in voice mode (Mac and
Remote). Web: by design, no voice mode.
