# Videos with no person (#1078)

The docs site's narrated videos are made by this script, with no hands on a device and no
voice recorded. Make them again when the UI changes: the usage videos on every release, the
marketing ones when the change matters.

```sh
scripts/video/make.sh u1 u3          # build, then make each video in turn
scripts/video/make.sh a2 --no-build  # with the last build in build/DD
scripts/video/make.sh u4 --compose-only   # put the last recording together again
scripts/video/make.sh i-linear --upload   # an integration video, made, checked and uploaded
```

Each video is written to `~/Movies/agents-video/out/<id>.mp4`, 2560×1440 at 30 fps, with
its captions in `<id>.vtt`. The videos go on YouTube, never in git. Alex uploads the usage
and marketing videos; `--upload` uploads an integration video (below).

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
   video ends on a card with the logo, and the Apple trademark line when an iPhone is shown.

4. **Check**: Whisper hears the finished video against its script, and a contact sheet of
   it (`~/.cache/agents-video/work/<id>/video-sheet.png`) is made to look at before the
   video is kept.

Real Claude agents run in the scenes, on scratch folders: a few cents a video. On camera
the person is called Sam (`launch.sh --person`), and the scratch root says it has 500 GB
free, so the real disk is never shown. A scratch agent still reads the person's own
`~/.claude/CLAUDE.md`: each folder tells it never to name an instructions file, and a
take whose window shows the person's name or their own instructions fails.

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
- **Upload** (`upload.py`): the YouTube Data API v3, **private**, to the playlist `Agents
  integrations`. The title names the integration and the app version (`git describe`); the
  description gives the commit, the date and the scene file. A new take replaces the old one in
  the playlist: the old video is made private and taken out of the playlist, never deleted.
  The local file is deleted after a good upload. Until Alex's steps on #1793 are done (the
  OAuth client in `~/.agents/secrets/youtube-client.json`, then `upload.py --sign-in`; with
  `--no-browser` it only prints the consent address, for an agent to open in the Safari MCP), the
  video stays in `out/` and the log says why.
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
refresh token works (`channels?mine=true`), and the scene's video Chrome profile has the
site's sign-in cookie and lands signed in when the site is opened. Each failure puts one
line on Alex's list on #1793 (once) and exits 3, so the workflow skips that video and goes
on with the others.

## A scene

`scenes/<id>.py` has `LINES` (the narration), `GROUP` (`usage`, `marketing` or `integration`), `LAYOUT`
(`mac`, `mac+phone` or `mac+browser`), and two functions: `setup(v)` runs before the
recording starts, and `run(v)` is the recording. `v` is the `Video` in `make.py`:

| Call | What it does |
|---|---|
| `v.folder(name, files)` | a committed Git folder under the root, added to the app |
| `v.start(folder, prompt)` | a real agent, as **New Session** would start it |
| `v.select(text)`, `v.press(text)`, `v.unfold(text)` | the window's accessibility tree, read in its own process |
| `v.type(field, text)`, `v.key("return")`, `v.menu(menu, item)` | keys and menu items, sent in the window's process |
| `v.say(key)` | the line starts here; the scene waits until it has been said (`wait=False` goes on at once) |
| `with v.fast(2.0):` | what happens inside is cut to two seconds |
| `v.open_phone()`, `v.web(op, …)` | the web page at iPhone size, and what to do on it |
| `v.open_site(url)`, `v.open_web_tab()` | an integration's site in the video Chrome, and the scratch web page in a tab beside it |
| `v.secret(name, value, refused)` | a token the scene made: looked for in every frame, and `refused()` must be true after `revoke(v)` |
| `v.hide_in_window(label)`, `v.web("secret", selector=…/pattern=…)` | places that show a secret, hidden in every frame |

An integration scene also has `INTEGRATION`, `CHROME_PROFILE`, `BROWSER_ADDRESS` (the address
drawn in the browser's bar) and `revoke(v)`, which runs after every take.

Sheets and popovers are in the picture, where they sit on the window. The menu bar, a
menu and anything outside the window are not.

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
| U1 | Your first agent | `u1.py` | yes |
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
