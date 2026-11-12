# Videos with no person (#1078)

The docs site's narrated videos are made by this script, with no hands on a device and no
voice recorded. Make them again when the UI changes: the usage videos on every release, the
marketing ones when the change matters.

```sh
scripts/video/make.sh u1 u3          # build, then make each video in turn
scripts/video/make.sh a2 --no-build  # with the last build in build/DD
scripts/video/make.sh u4 --compose-only   # put the last recording together again
scripts/video/make.sh u1 --upload         # any video, made, checked and uploaded (private)
python3 scripts/video/upload.py --self-test   # every upload call, against a fake YouTube
```

Each video is written to `~/Movies/agents-video/out/<id>.mp4`, 2560×1440 at 30 fps, with
its captions in `<id>.vtt`. The videos go on YouTube, never in git; `--upload` uploads a video
of any group (below).

## What it does

1. **Voice** (`voice.py`): each line of the scene is said by Chatterbox's default voice,
   in two takes (exaggeration 0.65 and 0.85). Whisper (`mlx-whisper`) checks each take
   against the script, and a take with more than one word in ten wrong is not used. A
   usage video takes the calmer take, a marketing video the livelier one. The takes are
   kept in `~/.cache/agents-video/voice`, so a line that has not changed is not said again.
2. **Recording** (`make.py`): run-app launches a scratch set-up on `/tmp/run-vid-<id>`,
   never the live app, with the window opened from outside the checkout so that its
   title names no worktree. The window is recorded through its **walk socket** (#1172):
   it draws each frame itself, in its own process, so no other window can be in the
   picture (not the person's own Agents window, which once was, #1078), and a locked
   screen does not stop a take. The scene presses, selects and types through the same
   socket, so nothing reaches the screen, the keyboard or the app in front. A scene with
   a phone or a browser drives the web page in headless Chrome (`web.mjs`) and records
   it with the DevTools screencast.
3. **Picture** (`frame.py`): the window, with a shadow, its traffic lights drawn on and its
   corners cut, on a cobalt backdrop; the phone in Apple's iPhone bezel; the browser in a
   plain toolbar. The waits marked `fast` are cut
   to a few seconds. Each line starts at the marker the scene wrote when it said it. The
   video starts on a title card (the logo, the scene's `TITLE`, and "Loops · How to" for a
   usage video) and ends on a card of the same look (the logo, **Loops**, the scene's docs
   page), with the Apple trademark line when an iPhone is shown (#4965).

4. **Check**: Whisper hears the finished video against its script, and a contact sheet of
   it (`~/.cache/agents-video/work/<id>/video-sheet.png`) is made to look at before the
   video is kept.

Real Claude agents run in the scenes, on scratch folders: a few cents a video. On camera
the person is called Sam (`launch.sh --person`), and the scratch machine is "Sam's Mac"
(`HOST_NAME`). Its join card (the machine lock) is approved and the recovery key skipped
before the recording starts. The scratch root asks to say it has 500 GB free, but the Go
host does not read that yet (#4851): the machine's row shows the real disk. A scene's
`GET_STARTED = True` keeps the Get started card, which is otherwise put away. A scratch
agent still reads the person's own `~/.claude/CLAUDE.md`: each folder tells it never to
name an instructions file, and a take whose window shows the person's name or their own
instructions fails.

## Integration videos (#1793)

One video per integration, on a real account, made by `scenes/i-<integration>.py` (`GROUP =
"integration"`). Alex watches it to see that the integration works as Alex wants. When the UI
changes, the same scene makes it again.

- **The video Chrome.** The outside site (sign in, where to make a token, approve OAuth) is in
  Chrome beside the window: Chrome on a profile of its own,
  `~/.agents/video/chrome/<integration>`, that Alex signs in to once with
  `scripts/video/make.sh --sign-in <integration>`. It is never Alex's own Chrome profile.
  Chrome quits by itself once the profile has the site's sign-in cookie (#1834); quit it
  with ⌘Q otherwise, because closing the window does not quit Chrome on a Mac.
  The take runs it headless (`web.mjs`), so nothing reaches the screen and a locked screen
  does not stop it. The same Chrome can show the scratch web page in another tab; its pairing
  is forgotten after the take.
- **Tokens: three defences.**
  1. The scene makes a token only for the video (`agents-video-<date>`), with the fewest
     scopes.
  2. Each place that shows a secret is marked: a DOM selector or a token pattern in Chrome
     (`web("secret", pattern=…)`: the page blurs every element whose text or value holds one,
     before it is drawn), an element of the window (`v.hide_in_window(label)`). `frame.hide`
     makes each place unreadable again in every frame as it is kept. Then `tokens.py` reads
     every distinct frame of the window and the browser, and the finished video twice a
     second, with Vision (`ocr.swift`). A frame that shows any 6 characters of a token fails
     the take, and its video is deleted. No check prints a token.
  3. After every take, kept or not, the scene's `revoke(v)` revokes what it made, and each
     token is asked of the provider again: one that is not refused (401) fails the take, and
     the log says to revoke it by hand.
- **Upload** (`upload.py`, #4836): the YouTube Data API v3, **private** always, on the
  `Loops` channel, to the playlist of the scene's `GROUP`: `Loops usage`, `Loops marketing` or
  `Loops integrations`, each made private the first time. The title is `<TITLE> — Loops
  <version>` (`git describe`); the description gives the docs page (the scene's `DOCS`, a path
  on docs.agentloops.dev), the commit, the date and the scene file. The captions are the
  take's `<id>.vtt`, in English (`captions.insert`). The thumbnail is a frame of the take, at
  one of the contact sheet's two-second moments: the scene's `THUMBNAIL` second, or two
  fifths in (`thumbnails.set`; a channel that is not verified yet cannot set one, so the log
  says so and YouTube picks one; Loops is not verified yet, #4961). A playlist made a moment
  before is 404 to YouTube for a few seconds: the calls on it wait and ask again (#4838). A new take replaces the old one in its playlist: the old
  video is made private and taken out of the playlist, never deleted. The local files are
  deleted after a good upload. `upload.py --self-test` proves each call against a fake API. The OAuth client in
  `~/.agents/secrets/youtube-client.json` is the agents' Google account's (Loops Agents, Cloud
  project `loops-videos`, In production; #4837), and its refresh token is
  `youtube-token.json`. The sign-in asks for `youtube.force-ssl`: plain `youtube` has no
  captions (#4838), and `--preflight` fails a token without it. To sign in again, `upload.py --sign-in --no-browser` prints the consent
  address; open it in the agents' own Chrome profile (`chrome-profile-google`, which keeps the
  Google sign-in; start it without `--incognito`), never the app's browser, which Google
  refuses. The app is not verified by Google, so the consent first shows "Google hasn't
  verified this app": Advanced ▸ Go to Loops videos. Without a sign-in the video
  stays in `out/` and the log says why.
- **Its walk hand-off.** A walk's Connect Linear sheet opens no authentication session (that
  is Safari's sheet, on the person's screen): it writes the flow and its address to
  `sign-in.json` in the walk's folder. The scene approves in the video Chrome, reads the code
  from the hand-back page's address, and gives it to the host.

`python3 scripts/video/tokens.py --self-test` (with the venv's Python) proves the check: a
made-up token is read where it shows and not after `frame.hide`, and a page in Chrome with a
pattern secret shows none of it.

### The workflow (#1857)

The `Integration videos` workflow (`.agents/workflows/integration-videos.md`, manual) makes
and uploads them with nobody watching, one at a time under the "build" lease. The release
skill starts it when `make.sh --changed <last tag> <new tag>` lists a scene: the scenes
whose rows in `docs/reference/integrations.md` (the rows whose first cell names the scene's
`TITLE`) have a path in their Where cell that the release changed.

Before each take, `make.sh --preflight <id>` checks what needs Alex's hands: the YouTube
refresh token works and is the `Loops` channel's (`channels?mine=true`), the scene's `GROUP`
has a playlist, and the scene's video Chrome profile has the
site's sign-in cookie and lands signed in when the site is opened. Each failure puts one
line on Alex's list on #1793 (once) and exits 3, so the workflow skips that video and goes
on with the others.

## A scene

`scenes/<id>.py` has `LINES` (the narration), `GROUP` (`usage`, `marketing` or `integration`), `TITLE`, `DOCS` (its docs page), `LAYOUT`
(`mac`, `mac+phone` or `mac+browser`), and two functions: `setup(v)` runs before the
recording starts, and `run(v)` is the recording. `v` is the `Video` in `make.py`:

| Call | What it does |
|---|---|
| `v.add_folder(name, files)` | a committed Git folder under the root, added to the app |
| `v.start(folder, prompt)` | a real agent, as **New Session** would start it |
| `v.select(text)`, `v.press(text)`, `v.unfold(text)` | the window's accessibility tree, read in its own process |
| `v.type(field, text)`, `v.key("return")`, `v.menu(menu, item)` | keys and menu items, sent in the window's process |
| `v.say(key)` | the line starts here; the scene waits until it has been said (`wait=False` goes on at once) |
| `with v.fast(2.0):` | what happens inside is cut to two seconds |
| `v.open_phone()`, `v.web(op, …)` | the web page at iPhone size, and what to do on it |
| `v.open_site(url)`, `v.open_web_tab()` | an integration's site in the video Chrome, and the scratch web page in a tab beside it |
| `v.secret(name, value, refused)` | a token the scene made: looked for in every frame, and `refused()` must be true after `revoke(v)` |
| `v.hide_in_window(label)`, `v.web("secret", selector=…/pattern=…)` | places that show a secret, hidden in every frame |
| `v.tape()` | voice mode's speech and sounds go on a tape from here, mixed under the frames (below) |

An integration scene also has `INTEGRATION`, `CHROME_PROFILE`, `BROWSER_ADDRESS` (the address
drawn in the browser's bar) and `revoke(v)`, which runs after every take.

Sheets and popovers are in the picture, where they sit on the window. The menu bar, a
menu and anything outside the window are not.

## Voice mode's sound (#4854)

A walk plays nothing out loud, so a voice-mode scene calls `v.tape()`: the walk's
`{"cmd": "voice", "tape": "<work>/voice"}` (`VoiceTape`, Debug builds only). From then on voice
mode writes what it would play to that folder, in place of the speaker: each sentence's
samples to `speech.wav` (24 kHz mono) at the time it would play, and a mark in `marks.json`
for each sentence (`said`, `seconds`) and each sound (`sound`, `volume`), timed from the tape's
`start` on the same clock as the frames. The voice still waits as long as each sentence would
play, so what is said, the phases and the strip move as in a real run. The take ends the tape
(`"tape": ""`), and `frame.compose` puts each sentence and each sound
(`/System/Library/Sounds/<name>.aiff`, at its volume) at its place, with the narration, if any.
The sentences are in the captions and in Whisper's check. No speaker, no audio device and no
permission, and the screen may be locked.

`scenes/voice-tape.py` is the take that proves it, not a docs video: voice mode on, a prompt
heard, the reply spoken, voice mode off. A Remote's marks name SystemSoundIDs, which have no
file on the Mac: they are left out, with a warning.

To put such a take on a PR, inline with its sound, see the run-app skill's "A clip with
sound" (#4856): `pr-clip.sh` makes it 720p and under 10 MB, and the app's browser uploads it.

### The sound test (#4855)

After Whisper's check, `sound.py` tests every take's track, and the take fails when one check
fails, with the check's name:

1. **The words:** Whisper hears the sentences of `speech.wav`, and they agree with what the app
   said (the tape's marks, and the walk's `said`, kept in `voice/said.json`): at most one word in
   ten different.
2. **The sounds at their marks:** the mix is louder than −50 dBFS in the 100 ms after each
   sound's mark, and quiet in the 100 ms before it when nothing else plays there.
3. **Nothing else:** where no sentence, sound or narration line plays, the mix is below −50 dBFS.
4. **The length:** the video's track is as long as its frames, within one frame.

`frame.compose` writes `sound.json`, where each part of the track plays in the video's time.
A failed test keeps the video as `failed-<id>.mp4` in the take's folder
(`~/.cache/agents-video/work/<id>/`), with the mix (`scene.mov`), `sound.json` and
`sound-test.json`, for a person to look at. `make.sh --sound-self-test` makes a track with each
fault and shows that the test finds it.

## A PR's silent clip (#4094)

`clip.sh ROOT OUT.webp [-- walk steps… | --seconds N]` uses the same recorder for a PR walk:
the scratch window's frames, as an animated WebP of at most 20 s and 5 MB, for a motion
that a screenshot cannot show. It needs only Pillow (the venv above, else `uv`'s own). The
run-app skill's "A silent clip" says when and how to put it on a PR.

## What it needs

- `ffmpeg` (Homebrew), `uv`, Node and Chrome. The first run makes
  `~/.cache/agents-video/venv` with Chatterbox and mlx-whisper.
- Apple's iPhone 17 Pro bezel (Silver, portrait) from
  [Apple Design Resources](https://developer.apple.com/design/resources/), in
  `~/.agents/video/assets/`. Its licence lets it be shown in our videos but not given
  away, so it is not in the repository.
- Any main screen. On a 2× (Retina) one the window draws at 2× as it is; on a 1× one it
  draws each frame at 2× by itself, through the walk socket's `shot` with `scale` 2 (#1855).
  No screen's mode changes. No Accessibility or Screen Recording permission, and the
  screen may be locked.

## The videos

| # | Video | Scene | Made |
|---|---|---|---|
| A2 | Answer from anywhere | `a2.py` | yes |
| U1 | Your first agent | `u1.py` | yes (again 2026-11-11, #4835) |
| U3 | Answer a question | `u3.py` | yes |
| U4 | Read an agent's changes | `u4.py` | yes |
| U5 | Follow a live document | `u5.py` | yes |
| U8 | Start in a worktree | `u8.py` | yes |
| U9 | Use Agents in a browser | `u9.py` | yes |

| Integration | Scene | Made |
|---|---|---|
| Linear (#1794) | `i-linear.py` | not yet: Alex signs in to the video Chrome first (#1793) |

The rest of the list in #1078 need something first: the native Remote in a simulator
(XCUITest), a workflow, a faked limit, several runtimes, seeded usage, or the devbox.
