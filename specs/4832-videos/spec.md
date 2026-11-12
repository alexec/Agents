# Videos for 1.0: the catalogue, and a dress rehearsal (#4832)

Status: draft (Product Owner, 2026-11-11). Epic #4832, milestone `1.0 Public release`.

Alex, 2026-11-11: two jobs. (1) Find which videos are needed. (2) Do a dress rehearsal:
write the script of one video (what is shown and what is said), record it, and get it onto
YouTube.

## What we have already

- `scripts/video/` (#1078, #1793) makes a narrated video with no person: a scratch app,
  recorded through its walk socket (no other window can be in the picture), the Chatterbox
  voice (Alex, 2026-10-15), Whisper checks, captions (WebVTT), a contact sheet.
- Seven scenes: A2, U1, U3, U4, U5, U8, U9, and `i-linear`. Their videos were made on
  2026-10-16 and never uploaded. Since then the UI changed: one app (#4225), "project" →
  "folder" (#2617), the Get started card, Auto, voice mode, the Brief.
- `upload.py` uploads **only integration videos**, private, to the playlist `Agents
  integrations`. The YouTube sign-in was never done: the token file is still a copy of the
  client file, and the OAuth app may still be in Testing (#1856).

## 0. Why: three uses of one tool (Alex, 2026-11-11)

Alex's other motive: the same recording tool also gives (a) **videos of changes on a PR**,
and (b) **videos of how to set up an integration**, to help people understand them. The
rehearsal proves the tool for all three. Options, the recommended one first (not decided):

**(a) PR clips.**

1. *Recommended:* a silent **animated WebP** (no sound, about 10–20 s, under 5 MB) made from
   the walk's frames by the same recorder (`make.py` through the walk socket), put on the
   orphan `screenshots` branch by `pr-shots.sh`. It plays inline in the PR body. This is
   #4094. It needs no account and no quota, and a scratch app has nothing of Alex's in it.
2. A narrated MP4 on the Loops channel, **unlisted**, linked from the PR. GitHub shows only
   a link (no player), each upload publishes to an outside site, and the YouTube Data API's
   daily quota allows only a few uploads a day by default (an upload costs most of it). Good
   for a large stack's one review video, not for every PR.
3. An MP4 file on the `screenshots` branch: GitHub shows it only as a link to download.

**(a′) Sound (Alex, 2026-11-11: "I want to test sound").** A WebP clip has no sound, and the
tool records pictures only. The app's sounds are voice mode's speech and sounds. Spike #4844
finds out if a scratch app plays them, how to get them into the take (recommended: a
walk-only tap of what the app plays, mixed under the frames), and if an agent can put an MP4
with sound inline on a PR (an upload in the github.com comment box). Until then: a silent
clip for motion, and a video with sound only where sound is the change.

**(b) Integration set-up videos for people.**

1. *Recommended:* one scene, two cuts. The `i-<name>` scene (#1793) already shows the
   set-up on a real account. Add a **help** cut: plain narration for someone new (what the
   integration is for, where to click, what they see after), no internal words (PKCE, events
   server), public on the Loops channel, on the docs page `docs/how-to/use-<name>.md`. The
   private check cut for Alex stays.
2. A separate scene per integration for help only: more work, and two scenes to keep true.

A public cut needs a **demo workspace** on each provider (a Linear workspace named for the
demo, not Alex's), because the workspace name and the members show in the frames. That is
`needs-account` per provider. Tokens keep the three defences of #1793.

Where these go in the epic: (a) is #4094, which can run now; (b) is a group `setup` in the
catalogue below, after 1.0's usage videos.

## 1. The catalogue

The rules of #1078 stay: two groups, the story leads with what only Agents does (agents that
work together and on their own), every claim is checked against
`docs/reference/feature-matrix.md` before it is said, scratch data only, the person on camera
is "Sam".

- **Marketing:** short, a story, a livelier pace (`style="bright"`). Made again when the UI changes
  enough to matter. Pages: www.agentloops.dev, *Why Agents*, the channel, posts.
- **Usage:** one task each, calm voice, the exact names on the screen. Made again on every
  release (an old UI in a usage video is wrong). Page: the docs page of the same name.
- **Integration:** one per integration, on a real account (#1793). For Alex to check, private.
  Not part of 1.0's public set.

### Marketing

| # | Video | Length | Page | Story | Needs | For 1.0 |
|---|---|---|---|---|---|---|
| M1 | **One afternoon** (hero) | 60 s | www, Why Agents | A change lands, a workflow starts a tester, it waits in line for the simulator (a lease) and spends nothing, wakes, fixes, commits, waits for `main`, a release agent wakes. "You were not asked for anything." | workflow + lease + event in one scene; time cut | yes |
| M2 | **Answer from anywhere** (was A2) | 40 s | www, Why Agents | Four agents working, one asks, the card on the phone, one tap, the Mac carries on. | scene exists (web at phone size); native phone later | yes |
| M3 | **The agents you already have** | 30 s | Why Agents | Claude, Codex and Cursor on one task side by side; Auto picks a runtime; one runs out, the session carries on with another. | several signed-in runtimes; a faked limit | yes |
| M4 | **Talk to your agents** (new) | 30 s | www, Why Agents | Voice mode: say what you want, hear the reply, answer a question by voice. | the installed Mac app only (no mic in a scratch app); see open question 3 | later |
| M5 | **It keeps working without you** | 30 s | Why Agents | Close the window, agents carry on; the Mac restarts, they pick up; the Brief says what happened. | scripted host restart | yes |
| M6 | **Watch the work, not the chat** | 30 s | Why Agents | A live document fills in beside the chat, a diagram arrives, the Changes pane coloured to the word. | — | yes |
| M7 | **One figure, your limit** | 20 s | Why Agents | Spend across runtimes and machines as one figure; a daily limit stops an agent. | seeded usage; a faked limit | later |

### Usage

| # | Video | Length | Docs page | Needs | Scene today | For 1.0 |
|---|---|---|---|---|---|---|
| U1 | **Your first agent** | 60 s | Tutorials ▸ First agent | — | yes, stale | **rehearsal** |
| U2 | **Follow your agents from iPhone** | 60 s | Tutorials ▸ Follow from iPhone | native phone (XCUITest, #1078 item 2) | no | yes |
| U3 | **Answer a question** | 25 s | How-to ▸ Answer a question | — | yes, stale | yes |
| U4 | **Read an agent's changes** | 30 s | How-to ▸ Read an agent's changes | — | yes, stale | yes |
| U5 | **Follow a live document** | 30 s | How-to ▸ Follow a live document | — | yes, stale | yes |
| U6 | **Set up a workflow** | 45 s | How-to ▸ Set up a workflow | time cut | no | yes |
| U7 | **Send while an agent works** | 25 s | How-to ▸ Send while an agent works | — | no | yes |
| U8 | **Start in a worktree** | 25 s | How-to ▸ Start in a worktree | — | yes, stale | yes |
| U9 | **Use Agents in a browser** | 25 s | How-to ▸ Use Agents in a browser | — | yes, stale | yes |
| U10 | **Add a connector from the registry** | 30 s | How-to ▸ Add a connector from the registry | a server with no sign-in | no | yes |
| U11 | **Keep going when a runtime runs out** | 30 s | How-to ▸ Keep going… | a faked limit | no | later |
| U12 | **Limit spending** | 20 s | How-to ▸ Limit spending | seeded usage | no | later |
| U13 | **Add a machine** | 45 s | How-to ▸ Add a machine | the devbox (test-servers) | no | later |
| U14 | **Use Auto** (new) | 25 s | How-to ▸ Use Auto | two runtimes | no | later |
| U15 | **Choose runtime, model and mode** (new) | 25 s | How-to ▸ Choose runtime, model and mode | — | no | later |
| U16 | **Use the simulator pane** (new) | 30 s | How-to ▸ Use the simulator pane | the walk simulator | no | later |

### Integration

One `i-<name>` scene per row in `docs/reference/integrations.md`, private, playlist `Agents
integrations` (#1793). Linear is the pilot; each other one is its own issue under #1793's
follow-ups, when its account is ready. Not in this epic.

### The order

For 1.0: U1 (the rehearsal), then the stale scenes again (U3, U4, U5, U8, U9, M2), then M1
(the hero, the most reach), M6, M5, M3, then the new usage scenes U6, U7, U10, then U2 when
the native phone recording exists. "Later" rows go after 1.0. #1078 makes them, after this
rehearsal.

Decided: the rehearsal video is U1, because it is the first video a new person sees, its
scene and docs page exist, and it needs nothing new; its drift (one app, "folder") is what
every other scene will hit. Alex can overrule.

## 2. The dress rehearsal: U1 "Your first agent"

The rehearsal makes one video through every step that every later video takes, and writes
down what broke. It is not the final U1: it may be made again.

### 2.1 The script: what is shown and what is said

Layout `mac`. Scratch app on `/tmp/run-vid-u1`, person "Sam", folder `weather` (the
tutorial's Fahrenheit bug), runtime Claude. About 60 s after the cuts. Each line starts at
its marker; `fast` spans are cut to the time given. The words below are what is said; the
directions (pauses, pace, tone) are in `scripts/video/scenes/u1.py` (#4964).

| # | Marker | What is shown | What is said | Time |
|---|---|---|---|---|
| 1 | `intro` | The Agents window, empty, the **Get started** card at the top of the sidebar, the first step ticked. | "This is Agents. Here's how to start your first agent." | 4 s |
| 2 | `folder` | **Add a folder** on the card; the folder `weather` is chosen; it appears in the sidebar and the card ticks the step. | "A folder is a directory you work in. Add one, and it appears in the sidebar." | 6 s |
| 3 | `new` | **New Session** on the folder; the start form, the runtime **Claude**. | "Click New Session. The agent works in this folder, with Claude as its runtime." | 6 s |
| 4 | `prompt` | The prompt is typed: *Fix the Celsius conversion and run the tests.* | "Say what you want done. Here: fix the Celsius conversion, and run the tests." | 6 s |
| 5 | `send` | Send; the session appears as **Working** in the sidebar. | "Send it, and the agent starts at once." | 4 s |
| 6 | `ask` | A permission card: the agent wants to edit `Forecast.swift`. **Yes** is clicked. The session's row says it needs you, then working again. | "Before it changes a file or runs a command, it asks. Click Yes." | 7 s |
| 7 | `steps` | `fast(4)`: its steps fill in: the read, the edit, `swift test` passing. | "Its steps appear as it works: what it read, the edit, and the tests it ran." | 8 s |
| 8 | `reply` | The reply; then the **Changes** pane with the one-line fix in colour. | "When it's done, its reply says what it changed, and Changes shows the edit." | 8 s |
| 9 | `end` | The row says **Done**; the card ticks **Start your first agent**. | "That's your first agent." | 3 s |
| — | — | End card: logo, **Loops**, "docs.agentloops.dev". | — | 3 s |

What changes against today's `scenes/u1.py`: "project" → "folder" (lines 2, 3), the Get
started card (lines 1, 2, 9), the Changes pane in line 8, and a last line of its own. The
words follow the tutorial `docs/tutorials/first-agent.md`; if the window says another name,
the window wins and the tutorial gets an issue.

### 2.2 The steps

| Step | What | Who | Issue |
|---|---|---|---|
| 1 | Write the script (2.1). | Product Owner | this spec |
| 2 | Make `make.sh u1` work on today's app (one app, `Agents` program name, the walk socket, the Get started card), change `u1.py` to the script, take it, look at the contact sheet and Whisper's check. | a lane | child: the take |
| 3 | `upload.py` uploads any scene: a playlist per group (`Loops usage`, `Loops marketing`, `Loops integrations`) on the Loops channel, private, the captions from the `.vtt` (`captions.insert`), a thumbnail from the contact sheet, title "<TITLE> — Loops <version>". | a lane | child: upload any scene |
| 4 | The YouTube sign-in (done 2026-11-12, #4837): the agents' Google account **Loops Agents** (agentloops@fastmail.com) owns the channel **Loops** and the Cloud project `loops-videos`, whose OAuth app is In production; `upload.py --sign-in --no-browser`, the address opened in the agents' own Chrome profile. Alex typed the account's password; an agent did the rest. | Alex, with an agent | child: YouTube sign-in (`alex-todo`) |
| 5 | Upload U1, private. Alex watches it on YouTube and says what to change. | a lane, then Alex | child: rehearsal upload |
| 6 | Write the retro below: what broke at each step, the time and money each cost, and an issue for each fix. | the lane of step 5 | same |

Steps 2, 3 and 4 run at the same time; 5 waits for all three.

Decided: the rehearsal upload is **private** (not unlisted or public), because nothing is
published until Alex has watched it, and an unverified API project's uploads are private
anyway. Alex can overrule.

### 2.3 Done when

- U1 is on YouTube, private, in the playlist `Loops usage`, with English captions and a
  thumbnail, and its link is on #4832.
- `make.sh u1 --upload` makes and uploads it again with no other step.
- The retro (2.4) is written, and each thing that broke has an issue.
- Nothing of Alex's is in any frame (the take's checks pass; a person looks at the contact
  sheet).

### 2.4 Retro

(The lane of step 5 writes this: per step, what broke, the time, the cost, the issue.)

**Step 2, the take (#4835, 2026-11-11).**

- *What broke:*
  - The Get started card: `make.py` put it away before every recording. A scene now keeps
    it with `GET_STARTED = True`.
  - The machine lock (#3490): a fresh root shows "Approve the new machine
    <this Mac's name>?" at the top of the sidebar, and this Mac's name holds Alex's. The
    take's private-words check failed on it (the check worked). The scratch machine is now
    "Sam's Mac" (launch.sh's `HOST_NAME`, #3491), and `make.py` approves its card and
    skips the recovery key card it brings before the recording starts.
  - The end card said "Agents"; it says **Loops** and docs.agentloops.dev (open question 4).
  - The disk: the root's `disk-free-override` has done nothing since the Go host (#1314),
    so the machine's row shows the real disk ("Disk low: 33.5 GB free"). Not private, but
    wrong for a tutorial: #4851.
  - Not broken: one app (#4225) and "folder" (#2617) were already in `make.py` and
    launch.sh. `v.project()` is now `v.add_folder()`.
  - Add Folder…'s panel is the system's, in another process: no walk presses it and no
    shot draws it. Line 2 adds the folder through the socket while the line is said; the
    picture shows the folder arrive and the card tick, not the panel.
- *Time:* build 2.5 min (cache warm), the nine lines' voice 8.5 min (once; kept after),
  each take about 2 min (1 min recording, 40 s Whisper). Three takes, two failed on
  the window's own checks. About 1 h of the lane in all.
- *Cost:* one Claude turn in a scratch folder per take (read, edit, `swift test`): a few
  cents each, on the subscription; the window's meter said $0. The take does not log what
  its agent cost: the root is deleted after it.
- *Length:* 42 s with the end card, not 60 s: the lines are short and the agent quick.

**Steps 3 to 5, the upload (#4838, 2026-11-12).** U1 is
[on YouTube](https://youtu.be/4SCWbBAnMxA): private, in `Loops usage`, English captions, 43 s.

- *What broke:*
  - **A new playlist is 404 for a few seconds.** The first `make.sh u1 --upload` made
    `Loops usage`, and its next call (`playlistItems`) answered 404 playlistNotFound. A
    minute later the same call worked. `upload.py` now waits 5, 10, 20 and 30 s on a 404
    before it fails; the self-test's fake answers 404 twice.
  - **Captions need another scope.** The second run uploaded the video, then
    `captions.insert` answered 403 insufficientPermissions: the sign-in of #4837 asked for
    `youtube`, which has no captions. The sign-in now asks for `youtube.force-ssl` (upload,
    playlists, privacy and captions), and `--preflight` fails a token without it. That
    meant a new consent: the agents' Chrome came up `--incognito` from `cdp.mjs start`
    (signed out), and was started again without it; the account chooser took an agent's
    click; Google's "hasn't verified this app" warning went to Alex by a form (#4840), and
    the consent was done in that window. The captionless take is private and out of the
    playlist, not deleted.
  - **No thumbnail:** `thumbnails.set` answers 403 until the channel is verified by a
    phone number. `upload.py` logs it and goes on, so YouTube picked the frame: #4961
    (`alex-todo`).
  - **The title is a build id:** "Your first agent — Loops v0.18.0-404-g14d039882", from
    `git describe` on the lane's branch: #4962.
  - Not broken: the take itself, three times over. Whisper heard 0% of the script wrong
    each time, the sound test passed, and the contact sheet shows only scratch data (Sam's
    Mac, `/tmp/run-vid-u1`, the `weather` folder).
- *Time:* three runs of `make.sh u1 --upload`: 7, 5 and 3.5 min (the voice and the build
  cached after the first). With the two fixes and the new consent, about 45 min of the
  lane; about 5 min of Alex's (the consent, and a form).
- *Cost:* one Claude turn per take in a scratch folder (a few cents each, on the
  subscription). YouTube: no money; three uploads of the 10,000 daily quota units (an
  upload is about 1,600, a caption 400, a playlist call 50).
- *Alex's watch (2026-11-12):* "Great start! The cadence of the audio is off." Alex wants
  the narration written as a script for the voice, as for film or TV, with directions for
  pauses and tone (#4964), and a title card on each video as well as a closing card (#4965).

**After Alex's watch: the voice and the cards (#4964, #4965, 2026-11-12).**

- *The cadence:* the take spoke at 177 words a minute (about 150 is calm), with no pause in
  a line and 0.06–0.4 s between lines. The fix is a directed script: a small part of SSML
  (`<break>`, `<prosody rate>`, `<emphasis>`, and a tone), the form of the two-column A/V
  script, with the words in the spec and the directions in the scene. Chatterbox reads no
  markup (Turbo reads only sounds such as `[laugh]`), so `voice.py` carries out the marks:
  each phrase said on its own, silence for a pause, and 0.9 s after each line.
- *The voice:* Alex heard nine samples of the same script (Chatterbox with and without the
  directions, Apple's Ava and Zoe reading SSML, and five of Kokoro's built-in voices) and
  chose Kokoro's **Heart**, a built-in voice: no sample of a person's voice, no actor.
  Kokoro has no tone or stress, so those marks change only the pace. Kokoro's own package
  was last released in April 2025, so it runs through `mlx-audio` (MIT, 2026-11-09).
- *The cards:* a title card (the logo, the title, "Loops · How to") fades into the window,
  and the end card has the same look and names the docs page (#4965, PR #4973).
- *The take:* the first one failed its private-words check, as it should: the scratch
  Claude agent followed the app's brief, read the person's memory files, and the window
  showed the `cat` with the home folder. The demo folder's rules (`QUIET` in `make.py`)
  now say to read nothing outside the folder. The second take passed and is
  [on YouTube](https://youtu.be/Y2SCoou-miE), private; the first upload is private and out
  of the playlist. The "Make a recovery key" card shows for a moment at the start.
- *Time:* about 2 h of the lane, most of it the samples; about 10 min of Alex's listening.
- *What the next video needs:* nothing more for a private upload. `make.sh <id> --upload`
  is one step now. A public video still waits on open question 2 (the API audit) and on
  Alex's watch of this one.

## Open questions

1. **The channel:** answered (Alex, 2026-11-11, changed 2026-11-12): a new channel for the
   product, **Loops**, on a Google account of the agents' own (Loops Agents,
   agentloops@fastmail.com, #4837), not under Alex's Google account. Google refuses sign-up
   and sign-in in the app's browser (Chrome for Testing), so its pages open in the agents'
   own Chrome profile (`.agents/signups/cdp.mjs`, not incognito, profile
   `chrome-profile-google`).
2. **Public videos** need the YouTube API audit (Google's compliance review) before uploads
   by the API can be public, or Alex makes each one public by hand. Not needed for the
   rehearsal; decided before the first public video.
3. **Voice mode (M4)** works only in the installed app. Record it on the live app with a
   seeded scratch folder, or wait? After 1.0.
4. **Name on camera:** answered (Alex, 2026-11-11): **Loops**, the App Store name, on the
   channel, the playlists, the titles and the end card. Decided: the narration and captions
   say the names the window shows ("Agents" today), because a usage video must match the
   screen; they change when the app's own name changes. Alex can overrule.
