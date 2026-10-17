# Videos with no person (#1078)

The docs site's narrated videos are made by this script, with no hands on a device and no
voice recorded. Make them again when the UI changes: the usage videos on every release, the
marketing ones when the change matters.

```sh
scripts/video/make.sh u1 u3          # build, then make each video in turn
scripts/video/make.sh a2 --no-build  # with the last build in build/DD
scripts/video/make.sh u4 --compose-only   # put the last recording together again
```

Each video is written to `~/Movies/agents-video/out/<id>.mp4`, 2560×1440 at 30 fps, with
its captions in `<id>.vtt`. Nothing is uploaded. The videos go on YouTube, never in git,
and Alex uploads them until the YouTube API project passes Google's audit.

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

Real Claude agents run in the scenes, on scratch projects: a few cents a video. On camera
the person is called Sam (`launch.sh --person`), and the scratch root says it has 500 GB
free, so the real disk is never shown. A scratch agent still reads the person's own
`~/.claude/CLAUDE.md`: each project tells it never to name an instructions file, and a
take whose window shows the person's name or their own instructions fails.

## A scene

`scenes/<id>.py` has `LINES` (the narration), `GROUP` (`usage` or `marketing`), `LAYOUT`
(`mac`, `mac+phone` or `mac+browser`), and two functions: `setup(v)` runs before the
recording starts, and `run(v)` is the recording. `v` is the `Video` in `make.py`:

| Call | What it does |
|---|---|
| `v.project(name, files)` | a committed Git project under the root, added to the app |
| `v.start(folder, prompt)` | a real agent, as **New Session** would start it |
| `v.select(text)`, `v.press(text)`, `v.unfold(text)` | the window's accessibility tree, read in its own process |
| `v.type(field, text)`, `v.key("return")`, `v.menu(menu, item)` | keys and menu items, sent in the window's process |
| `v.say(key)` | the line starts here; the scene waits until it has been said (`wait=False` goes on at once) |
| `with v.fast(2.0):` | what happens inside is cut to two seconds |
| `v.open_phone()`, `v.web(op, …)` | the web page at iPhone size, and what to do on it |

Sheets and popovers are in the picture, where they sit on the window. The menu bar, a
menu and anything outside the window are not.

## What it needs

- `ffmpeg` (Homebrew), `uv`, Node and Chrome. The first run makes
  `~/.cache/agents-video/venv` with Chatterbox and mlx-whisper.
- Apple's iPhone 17 Pro bezel (Silver, portrait) from
  [Apple Design Resources](https://developer.apple.com/design/resources/), in
  `~/.agents/video/assets/`. Its licence lets it be shown in our videos but not given
  away, so it is not in the repository.
- A main screen at 2× (Retina): the window is put on it, and a take on a 1× screen stops.
  No Accessibility or Screen Recording permission, and the screen may be locked.

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

The rest of the list in #1078 need something first: the native Remote in a simulator
(XCUITest), a workflow, a faked limit, several runtimes, seeded usage, or the devbox.
