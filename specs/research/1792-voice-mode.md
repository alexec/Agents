# Spike #1792: voice mode and a small on-device voice

_2026-10-20, standing lane 1. A spike: it builds no feature. The demo is in
[`1792-voice-mode/demo/`](1792-voice-mode/demo/)._

## The answer in short

- **Voice mode is possible with what we have.** Listening is done (`Dictation.swift`). The
  reply is a separate entry kind, so thoughts and tool calls are never spoken. A text in
  front of the prompt makes the agents answer in short spoken sentences. A cleaner makes
  any reply speakable when they do not.
- **Use Paradee-8M (int8) as the one voice, on all three clients.** On this Mac it is 5×
  faster than Kokoro (first sound 45 ms, RTF 0.014), and on-device recognition hears it as
  well as it hears Kokoro. It adds about 24 MB to an app: 12 MB of models and 11.5 MB of
  G2P and lexicon. That is small enough to ship inside the app, with no download.
- **Kokoro is not an option on the Remote.** The Remote's lowest OS is iOS 27.0. FluidAudio
  0.17.7 marks Kokoro ANE as unsafe on all of iOS 27 (a libBNNS crash after about an hour,
  FluidAudio#889). Corpospeak turns Kokoro off on iOS 26.4 and later for the same crash.
  FluidAudio counts macOS 27 as safe, but this spike saw the crash on this Mac too: macOS
  27.0.1 (26A434), `EXC_BREAKPOINT` in `BNNSGraphContextExecute_v2`, on its first sentence
  with eight Kokoro voices loaded (the #1800 test speech), in 3 runs of 3. With one voice
  loaded it ran all 30 replies of this spike.
- **The web page can speak too, with no GPL.** Paradee 1.1's 8.5 MB ONNX file runs in WASM
  with no WebGPU (first sound 72–163 ms, RTF 0.042 in Chrome). Browser phonemizers use
  eSpeak NG (GPL-3.0). The page can get the phonemes from the Mac instead, as short text
  on the wire.
- **What still needs Alex:** the blind listen and the Safari checks on the Mac and the iPhone.
  They are on Alex's list (#1920). None of them blocks the decision. If Paradee fails
  the listen, the fallback is the same plan with Kokoro on the Mac and the web only.

## What was measured

### The two voices on this Mac

`voice-demo render`, 10 fixture replies (median 49 spoken words, 11–32 s of audio each), a
sentence at a time, models warm, Mac on macOS 27, `.cpuOnly` for Paradee and the ANE route
for Kokoro:

| | Paradee-8M int8 (FluidAudio 0.17.7, v1.0 weights) | Kokoro-82M ANE `af_heart` |
|---|---:|---:|
| Models on disk | 12 MB + 11.5 MB shared G2P/lexicon | 87 MB + 11.5 MB shared G2P/lexicon |
| First load (download and Core ML compile) | 7.5 s | 13.3 s |
| First sound in a new process (models compiled, loaded on first use) | 0.54–0.63 s | 0.62–0.68 s |
| First sound with the models loaded, median | 45 ms | 232 ms |
| Real-time factor, median | 0.014 | 0.069 |
| Peak memory of the process | 274 MB | 346 MB |

Most of the memory is the shared English front end (BART G2P and the 10 MB lexicon), not
the voice. Both voices need it.

**Can a recogniser follow it?** Three replies in each voice, through the same
`SpeechAnalyzer` path the apps use (`~/Kokoro/bench/transcribe.swift`). Both came back
almost word for word, and they made the same mistakes ("main" heard as "Maine",
"daemon" as "demon"). Paradee said "2 lines" where Kokoro said "two lines". By this
measure Paradee is as clear as Kokoro. Whether Alex likes it as much is the blind listen's
question.

### Paradee in the browser

`demo/web/index.html` runs Paradee **1.1** int8 (`onnx/paradee_int8.onnx`, 8.5 MB, Apache
2.0) in onnxruntime-web 1.20 on WASM, one thread, no WebGPU. The phonemes came from the Mac
(`voice-demo phonemes`). Headless Chrome 155 on this Mac:

| Load (config, phonemes, 8.5 MB model) | First sound | Real-time factor |
|---:|---:|---:|
| 2.5 s | 72–163 ms | 0.042 |

Not checked: Safari. safaridriver cannot start a session while Alex's own Safari is open,
and iOS Safari needs the phone. The page is built so that one tap on Play checks it (on
Alex's list). Paradee needs no WebGPU, so the page-reload crash of kokoro-js on WebGPU in
iOS Safari (open-webui #31830) does not apply.

**The licence trap is the phonemizer, not the model.** Paradee's own browser path
(`web/misaki.js`) maps **eSpeak NG** phonemes to misaki's. eSpeak NG is GPL-3.0, and Agents
is MIT. There are three ways around it:

1. **The Mac makes the phonemes (recommended).** The host already has FluidAudio's misaki
   lexicon and BART G2P (Apache 2.0). It sends a phoneme string beside each reply sentence,
   about 1.5× the text, as a field on the wire. The browser loads only the 8.5 MB model.
   This is what the demo does.
2. **Port the misaki lexicon to JS** (10 MB of JSON), with no neural fallback for unknown
   words. That is larger and worse.
3. eSpeak NG in WASM. Not allowed (GPL).

### The voice-mode text, two runtimes

`demo/compare.sh` ran the 10 prompts in `demo/prompts.txt` on a run-app scratch host,
Claude and Grok, with the draft voice-mode text in front and without it:

| Runtime | Voice text | Replies | Words, median (min–max) | With markdown | With a path or file name | Turn stopped to wait on the person |
|---|---|---:|---:|---:|---:|---:|
| Claude | without | 9 of 10 | 138 (20–156) | 9 | 8 | 1 |
| Claude | **with** | 10 of 10 | **48 (26–59)** | **0** | **0** | 0 |
| Grok | without | 9 of 10 | 18 (10–25) | 6 | 1 | 5 |
| Grok | **with** | 10 of 10 | **21 (16–46)** | **1** | 1 | 4 |

Cursor was the planned second runtime, but it is not signed in on this Mac (`signInRefused`),
and Copilot is over its monthly quota, so Grok took its place. The raw turns are not kept:
they are scratch output, and `compare.sh` makes them again.

- **The text works.** Claude's replies with it are short, plain spoken sentences with no
  markdown and no paths. Without it, nine of ten have tables, lists or code. The cleaner
  still runs on every reply, because a runtime can ignore the text.
- **48 words is about 20 seconds of speech.** That is the right length. The longest, 59
  words, is 25 seconds.
- **It did not make Claude ask.** "Should wordsPerMinute be 150 or 170? Ask me if you need
  to" was answered with a choice ("I chose 150, because…"), not a question.
- **Grok stops to ask in about half its turns,** before it acts (it has no way to ask over
  ACP, so its question goes to the person as a needs-answer). Its "reply" is then the line
  before the stop: "I will add one test and run it." In voice mode the spoken end of such a
  turn must be the question itself (question 3 below).

### The cleaner

`Speakable` (`demo/Sources/Speakable/`) turns a reply into sentences a voice can read.
None of the three earlier apps had one. Its rules, each from a fixture reply that needed it:

| In the reply | Spoken |
|---|---|
| A fenced code block | "A shell code block, 3 lines, is on the screen." |
| A table | "A table with 3 rows, of Runtime, Mean words, Longest and Used markdown." |
| `Shared/UI/Chat/Dictation.swift:142` | "Dictation dot swift, line 142" |
| `DictationTests.testStartTwice` | "Dictation Tests test Start Twice" |
| `$S/stop.sh $ROOT`, any inline command | "a command" |
| https://github.com/… | "a link on Github" |
| 9dfda6049 | "a commit" |
| PR #1802 / #1811 | "PR 1802" / "number 1811" |
| **bold**, bullets, headings, `→`, `−` | the words; "to"; "minus" |
| 30 s, 20 min, 80 ms | "30 seconds", "20 minutes", "80 milliseconds" |
| `remote: same, web: …` parity lines | left out |

Seen in the WAVs, still to do in the feature: clock times ("10:42:07" is read as "10 hours,
42 minutes and 7 seconds"), camel-case names outside backticks, and version numbers such
as "v0.8.0".

## The questions the issue asked

**1. Which model?** Paradee-8M int8, in the app, on all three clients. Kokoro as a
Background Assets pack is not needed. On iOS 27 it is not safe to run anyway.
Decided: Paradee, because it is the only one of the two that is small enough to ship in
every client and is not flagged unsafe on the Remote's OS. Alex can overrule after the
blind listen.

The Core ML numbers on the iPhone (first sound, RTF, memory, first compile) and an hour of
synthesis there need a native build on the phone. They move to the feature issue's first
build, where they cost nothing extra. The web page on iPhone Safari (#1920) gives a first look.

Two cautions:
- FluidAudio's Paradee is **beta** and converts **v1.0**. v1.1 (3× faster, less buzz) is
  only in ONNX so far. The web page uses v1.1. The Mac and the iPhone should move to a
  v1.1 Core ML build when FluidAudio has one.
- Paradee runs on the CPU, not the Neural Engine. Its LSTMs abort on the GPU. Whether the
  CPU path meets the same libBNNS bug as Kokoro on iOS 27 is not known. An hour of
  synthesis on the iPhone, in the feature's first build, will show it.

**2. What does voice mode do before the model is ready?** With Paradee in the app there is
nothing to wait for except the first Core ML compile, 7.5 s on this Mac, once per install.
Compile it at the first launch after an update, not at the first spoken reply, and load
it when voice mode turns on, so the first reply does not wait the extra half second. If it is
still compiling, show the reply and say nothing. There is no Apple fallback.

**3. A turn that runs for minutes, and a question card.**
- At the start: the system "sent" sound. While the turn runs: nothing. A spoken "still
  working" every minute gets in the way.
- At the end: speak the reply. If it is long (more than about 60 words), speak the first
  three sentences, then "The rest is on the screen."
- A question card: speak the question, then the options as "Option one: Keychain. Option
  two: File." Listen for the answer: "one", "the first", or the option's own words. Fixture
  4 shows that the cleaner already speaks a numbered choice well.
- A permission card: "Claude wants to run a command. Allow?" Yes or no.

**4. No talking over the reply, a Stop button only?** Yes, for the first version. The demo
speaks a sentence at a time, so Stop (or a new prompt) can stop between two sentences with
no cut-off word. Barge-in needs echo cancellation and comes later.

**5. Remote only, or all three clients?** All three. Each client makes its own audio, and
the costs are small: 24 MB in the Mac app and the Remote, and an 8.5 MB model fetched once
by the web page. The web page's microphone is a separate item: it has none today, and the
browser's own speech recognition sends the audio to a server.
Decided: all three clients, the web page with speaking only until it has a microphone, because
the voice is what is new and it fits all three. Alex can overrule.

## The demo

```sh
cd specs/research/1792-voice-mode/demo
swift test                                                 # the cleaner's rules
swift build -c release && B=.build/out/Products/Release
$B/voice-demo clean Fixtures/replies.json                  # what would be spoken
$B/voice-demo render paradee Fixtures/replies.json /tmp/v  # WAVs + timings
$B/voice-demo render kokoro  Fixtures/replies.json /tmp/v
$B/voice-demo blind /tmp/v                                 # 10 shuffled A/B pairs + a key
$B/voice-demo speak paradee "Done. I fixed **the bug** in \`Sources/App/main.swift:12\`."

# A real voice-mode turn on a run-app scratch root, spoken:
eval "$(../../../../.claude/skills/run-app/scripts/launch.sh --slug voice --no-window)"
mkdir -p $ROOT/work && git -C $ROOT/work init -q   # and add the project (run-app skill)
./voice-turn.py $ROOT claude "What does this project contain?" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["reply"])' \
  | $B/voice-demo speak paradee -

# The web page: phonemes from the Mac, the model in the browser
mkdir -p /tmp/v/web && cp web/index.html /tmp/v/web/
$B/voice-demo phonemes Fixtures/replies.json > /tmp/v/web/phonemes.json
web/serve.py /tmp/v/web 8817    # then open http://127.0.0.1:8817/ and press Play
```

The fixture replies were written for the spike in the shape of real replies (paths, code,
tables, numbered choices, links, commit hashes, parity lines). They are not copied from
real transcripts.

## For the feature issue

- The wire: a `voice` flag on `PromptRequest` (a `Packages/Wire` schema change) puts the
  voice-mode text in front of the prompt through `QueuedPrompt.Preface`. A `phonemes` field
  beside a reply's sentences serves the web page.
- `Speakable` moves into `AgentsKitCore` with its tests. The web page uses the host's
  spoken text and phonemes, so there is one cleaner, in Swift.
- Speak from `TurnParts.reply`, a sentence at a time. Speak as the reply streams in
  (`agentMessage` pieces) only after a sentence ends.
- FluidAudio is a large dependency. Put it in its own target that only the apps link, not in
  `AgentsKitCore`, so `swift test` does not resolve it.
