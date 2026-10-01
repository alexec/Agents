# Quickstart: walking 071 on scratch

Walks use scratch roots only. Never use the live control plane's port 8792, the real root,
Alex's own browser profile or his paired devices.
- **The browser:** headless Chrome with a throwaway profile under the scratch root, driven by
  `Web/test/walk/cdp.mjs` (research R10).
- **The scratch Mac window:** driven by the run-app skill beside it.
- **Safari:** only where a step says so, and only with Alex's go-ahead.

Record each walk in `walks/` with its screenshots.

Wire and listener details are in [contracts/](contracts/). Records and the browser's key are in
[data-model.md](data-model.md).

## 0. The spike (T001)

```sh
cd specs/071-web-remote/spikes/s1-browsers
python3 -m http.server 8893 --bind 127.0.0.1 &
node run-chrome.mjs http://localhost:8893/     # headless: run, quit, relaunch on the same profile, run again
```

Expect `results.md` to show, for Chrome, every check true, and the vectors to match
`Web/test/vectors.json`. Then:
- Safari, by hand: open the page, press **Run**, quit Safari, reopen it, press **Run** again.
  Copy the text into `results.md`.
- 127.0.0.1 control: the same page at `http://127.0.0.1:8893/` must also be a secure context.

## 1. A scratch control plane serving the page

```sh
S=/tmp/web1; rm -rf $S; mkdir -p $S
scripts/web.sh check                       # generated.ts and dist fresh; no Node needed for the manifest half
# run-app starts the scratch Agents Host with --web <checkout>/Web/dist --web-port 8893
```

Then check:
- `curl -sI http://localhost:8893/` gives 200 with every header in
  contracts/loopback-listener.md.
- `curl -sI http://127.0.0.1:8893/x` gives 308 to `localhost`.
- `curl -sI -H 'Host: evil.test:8893' http://127.0.0.1:8893/` gives 421.
- An upgrade with `Origin: http://evil.test` gives 403.
- `lsof -iTCP:8893 -sTCP:LISTEN` shows only `127.0.0.1` and `::1`.

## 2. Pair (US1)

1. In the scratch window: **Settings ▸ Control plane ▸ Clients ▸ Pair a Browser…**, then
   **Device**, then **Copy**.
2. `node Web/test/walk/pair.mjs http://localhost:8893 "<code>"` opens the page, screenshots the
   pairing screen (frame E), pastes the code and screenshots the projects.
3. Check that the scratch window's Clients shows **Chrome on <Mac name>**, a browser, as a
   device.
4. Relaunch headless Chrome on the same profile. The page connects with no code.
5. Forget it in the scratch window. Within 2 s the page shows **This browser was forgotten**
   (frame F), and IndexedDB `agents` is gone.
6. Pair again, then press **Forget This Browser…** in the page. The scratch window's Clients no
   longer lists it.

## 3. The layout walk (Phase 4, before depth)

Seed the scratch root with 3 projects on one host and 12 sessions (run-app's seeding), and one
session with a long chat.

```sh
node Web/test/walk/layout.mjs http://localhost:8893 --widths 1600,1440,1000,390 --out specs/071-web-remote/walks/layout
```

Each width is screenshotted with a session open, next to frames A–D. At 390 the script steps
projects, then sessions, then chat, then the browser's Back twice. Expect:
- nothing cut off or overlapping;
- the prompt pinned to the foot of the chat at every width;
- the projects folded into a menu at 1000;
- the browser's name and grant at the foot of the projects column at 1440 and 1600, and in the
  ··· menu at 1000 and 390.

Alex looks at the screenshots before depth begins.

## 4. Read and answer (US2)

Start a real Claude turn from the scratch window that asks a question and then asks permission
to run a command. Open the session in the page. Answer both there. Expect:
- the scratch window shows both answered;
- the turn carries on;
- `walk/compare.mjs` finds the concise turn, steps and details matching the window's AX text;
- the median update lag, read from both clients' receive timestamps, is at most 0.5 s.

## 5. Send and steer (US3)

From the page:
1. start an agent in a new worktree with a picture attached;
2. queue a second prompt, then **Send now**;
3. change the model;
4. park, unpark, stop and archive it;
5. add and remove a label.

The scratch window shows each step.

## 6. Away and back (US7)

With a session open mid-turn, stop the scratch Agents Host's control plane for 60 s, then start
it again. Expect:
- **Can't reach the control plane** within 5 s, with everything greyed out and the draft kept;
- caught up within 5 s of the return, with no reload.

## 7. Files, changes, a live page (US4); workflows (US5)

- Run a turn that edits two files and calls `show_file` on a Markdown page it writes. Expect:
  - the changes view lists both files with their diffs;
  - the live page opens and follows each edit;
  - typing on it reaches the file.
- Open an `.html` file and an `.svg` with a `<script>`. Expect source and a picture, and
  nothing run (a CDP `Runtime.consoleAPICalled` and `Network.requestWillBeSent` listener finds
  nothing).
- Run a seeded workflow with **Run Now**. Its session appears in the page and in the window.

## 8. Closing walk

Repeat 2–7 at 1440 wide. Then, with Alex's go-ahead, 2, 4 and 6 in Safari, by hand or under
the screen lease. For SC-008, record every request the page made through CDP's `Network`
domain, check they all went to `localhost:8893`, and grep the console and the control plane's
log for the code, the key and a message's text.
