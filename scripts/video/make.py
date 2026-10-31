"""Makes the docs site's narrated videos with no person (#1078).

    scripts/video/make.sh <id>… [--no-build] [--keep] [--voice-only] [--compose-only] [--upload]
    scripts/video/make.sh --sign-in <integration>
    scripts/video/make.sh --preflight <id>…        what needs Alex's hands, before a take (#1857)
    scripts/video/make.sh --changed <from> [<to>]  the integration scenes a release changed

For each scene in scenes/<id>.py it:
1. speaks each narration line with Chatterbox, two takes, and keeps a take only when Whisper
   hears the words of the script (voice.py);
2. launches a scratch app with run-app on /tmp/run-vid-<id>, never the live app, and records
   its window through its walk socket (#1172): the window draws each frame itself, in its own
   process, so no other window (not the person's own Agents window) can be in the picture,
   and a locked screen does not stop it. If the scene has one, the web page in headless
   Chrome at iPhone or desktop size (web.mjs) is recorded too. The scene drives them through
   the host's socket and the walk socket: nothing reaches the screen, the keyboard or the
   app in front;
3. puts the recordings on the backdrop (frame.py), cuts the waits short, places each line at
   the marker the scene wrote when it spoke, and writes <id>.mp4 and <id>.vtt to
   ~/Movies/agents-video/out/.

An integration scene (GROUP "integration", scenes/i-<integration>.py, #1793) also shows the
outside site in the video Chrome (a profile of its own, signed in once by the person), makes a
token only for the video, and marks each place that shows one. Those places are hidden in
every frame as it is kept; then every frame is read with OCR (tokens.py) and a take that shows
any part of a token fails. After the take the scene revokes each token, and a token that the
provider still takes fails the take too.

Nothing is uploaded unless --upload is given (upload.py: private, to the playlist "Agents
integrations"). Real Claude agents run in the scenes, on scratch projects: a few cents a
video.
"""
import argparse
import base64
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SKILL = REPO / ".claude/skills/run-app/scripts"
CACHE = Path.home() / ".cache/agents-video"
OUT = Path(os.environ.get("AGENTS_VIDEO_OUT", Path.home() / "Movies/agents-video/out"))

sys.path.insert(0, str(SKILL))
sys.path.insert(0, str(HERE))
from rpc import Client  # noqa: E402
from walk import Walk  # noqa: E402
import frame  # noqa: E402
import tokens  # noqa: E402
import voice  # noqa: E402

# The video Chrome's profiles (#1794): one per integration, signed in once by the person with
# `make.sh --sign-in <integration>`. Never the person's own Chrome profile.
CHROME_PROFILES = Path.home() / ".agents/video/chrome"


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def run(*cmd, check=True, capture=True, **kw):
    result = subprocess.run([str(c) for c in cmd], capture_output=capture, text=True, **kw)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, cmd))}: {result.stdout}{result.stderr}")
    return result.stdout.strip() if capture else ""


class Recorder(threading.Thread):
    """The window's frames, each drawn by the window itself through its walk socket, about
    `fps` a second. A frame is kept only when it differs from the one before, with the time
    it was drawn; `finish` makes them a .mov at 30 fps and deletes them."""

    def __init__(self, root, folder, fps=12, scale=None):
        super().__init__(daemon=True)
        self.walk, self.folder, self.every = Walk(root), folder, 1 / fps
        # On a 1× screen the window draws each frame at 2× all the same (#1855).
        self.scale = {"scale": scale} if scale else {}
        self.folder.mkdir(parents=True, exist_ok=True)
        self.frames, self.size, self.error = [], None, None
        self.started, self.running = threading.Event(), True
        self.fast = False  # in a span cut short: a few frames do
        # Labels of the window's elements that show a secret (#1794): hidden in each frame
        # before it is written.
        self.secret_labels = []

    def run(self):
        last = None
        try:
            while self.running:
                began = time.time()
                reply = self.walk.call("shot", shadows=False, **self.scale)
                if not reply.get("ok"):
                    raise RuntimeError(f"shot: {reply.get('error')}")
                png = base64.b64decode(reply["png"])
                digest = zlib.crc32(png)
                if digest != last:
                    if self.size is None:
                        self.size = (reply["width"] * 2, reply["height"] * 2)
                    path = self.folder / f"{len(self.frames):06d}.png"
                    path.write_bytes(self.hidden(png) if self.secret_labels else png)
                    self.frames.append((path, (began + time.time()) / 2))
                    last = digest
                self.started.set()
                # A shot is drawn on the window's main thread: leave it at least as long
                # again for its own work, or a page typing itself out falls behind.
                took = time.time() - began
                time.sleep(max(took, (0.5 if self.fast else self.every) - took))
        except Exception as error:
            self.error = error
            self.started.set()

    def hidden(self, png):
        """The frame with every element a secret label names hidden (frame.hide). An element
        the window cannot place hides the whole frame: a frame never shows one by mistake."""
        from PIL import Image
        img = Image.open(io.BytesIO(png)).convert("RGBA")
        boxes = []
        for label in self.secret_labels:
            for line in self.walk.call("find", text=label).get("matches", []):
                if " @" not in line:
                    boxes.append((0, 0, img.width, img.height))
                    continue
                where, size = line.rsplit(" @", 1)[1].split(" ")[:2]
                x, y = (float(n) * 2 for n in where.split(","))
                w, h = (float(n) * 2 for n in size.split("x"))
                boxes.append((x, y, w, h))
        out = io.BytesIO()
        frame.hide(img, boxes).save(out, "PNG")
        return out.getvalue()

    def start_time(self):
        self.started.wait(20)
        if self.error or not self.frames:
            raise RuntimeError(f"recorder: {self.error or 'no frame'}")
        return self.frames[0][1]

    def finish(self, out, end, secrets=()):
        self.running = False
        self.join(10)
        if self.error:
            raise RuntimeError(f"recorder: {self.error}")
        if secrets:
            n = tokens.check([path for path, _ in self.frames], secrets, "the window")
            log(f"token check: none of the window's {n} frames shows part of a token")
        # The concat demuxer shows each frame until the next one's time.
        times = [at for _, at in self.frames] + [max(end, self.frames[-1][1] + 0.1)]
        with open(self.folder / "frames.txt", "w") as listing:
            for (path, at), following in zip(self.frames, times[1:]):
                listing.write(f"file '{path}'\nduration {following - at:.4f}\n")
            listing.write(f"file '{self.frames[-1][0]}'\n")
        # Glass draws nothing of its own off screen, so the sidebar is clear: under it, the
        # grey a light sidebar shows over a plain desktop.
        frame.ffmpeg("-f", "concat", "-safe", "0", "-i", self.folder / "frames.txt",
                     "-f", "lavfi", "-i", f"color=c=0xEAECF0:s={self.size[0]}x{self.size[1]}:r={frame.FPS}",
                     "-filter_complex", f"[0:v]fps={frame.FPS},format=rgba[w];[1:v][w]overlay=shortest=1,format=yuv420p",
                     "-c:v", "libx264", "-preset", "fast", "-crf", "12", out)
        log(f"recorded {len(self.frames)} distinct frames")
        shutil.rmtree(self.folder)


class Web:
    """The web page in headless Chrome, driven through web.mjs."""

    def __init__(self, profile, headed=False):
        self.proc = subprocess.Popen(["node", str(HERE / "web.mjs"), profile, json.dumps({"headed": headed})],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=HERE)

    def __call__(self, op, **args):
        self.proc.stdin.write(json.dumps({"op": op, **args}) + "\n")
        self.proc.stdin.flush()
        answer = json.loads(self.proc.stdout.readline() or '{"ok":false,"error":"web.mjs ended"}')
        if not answer["ok"]:
            if op != "shot":
                try:
                    self("shot", path=str(CACHE / "web-failed.png"))
                except Exception:
                    pass
            raise RuntimeError(f"web {op}: {answer['error']} (the page: {CACHE / 'web-failed.png'})")
        return answer["value"]

    def close(self):
        try:
            self("close")
        except Exception:
            pass
        self.proc.wait(timeout=20)


class Video:
    """What a scene drives. A scene's setup(v) runs before recording, its run(v) during it."""

    def __init__(self, scene, root, takes, work):
        self.scene, self.root, self.takes, self.work = scene, root, takes, work
        self.marks = []
        self.env = {}
        self.web = None
        self.recorder = None
        self.agents = {}
        self.answer_permissions = True
        # Integration scenes (#1794): the tokens the scene made, each with how to prove the
        # provider refuses it once it is revoked. Kept in memory only, never logged.
        self.secrets = []

    # --- the scratch set-up -------------------------------------------------------------
    def launch(self, build):
        # The real disk's free space is not the video's: a scratch root says its own (Debug).
        Path(self.root).mkdir(parents=True)
        (Path(self.root) / "disk-free-override").write_text("500GB\n")
        args = [SKILL / "launch.sh", "--seeded", "--slug", f"vid-{self.scene.ID}", "--appearance", "light", "--outside-checkout", "--person", "Sam"]
        if not build:
            args.append("--no-build")
        out = run(*args)
        for line in out.splitlines():
            if "=" in line and line.split("=", 1)[0].isupper():
                key, value = line.split("=", 1)
                self.env[key] = value.strip().strip("'\"")
        self.pid = self.env["APP_PID"]
        self.walk = Walk(self.root)
        self.client = Client(self.root)
        # Agents call the person by the Mac account's first name; on camera it is a made-up one.
        self.rpc("person/set", {"name": "Sam"})
        self.host_app = REPO / "build/DD/Build/Products/Debug/Agents Host.app"
        self.stopping = False
        threading.Thread(target=self._permissions, daemon=True).start()

    def _permissions(self):
        """A scene's agents get a yes to every permission, as rpc.py start gives, while
        answer_permissions is on. A scene that shows the card turns it off."""
        client = Client(self.root)
        seen = {}
        while not self.stopping:
            time.sleep(0.7)
            if not self.answer_permissions:
                seen.clear()
                continue
            try:
                for ask in client.call("permissions/pending") or []:
                    # One the window has just answered is still pending while its answer is
                    # on the way: answered here too, the window says it was answered already.
                    if time.time() - seen.setdefault(ask["id"], time.time()) < 3:
                        continue
                    client.call("permissions/answer", {"permissionID": ask["id"], "optionID": "allow-once"})
            except Exception as error:
                log("permission answer failed:", error)

    def stop(self, keep=False):
        self.stopping = True
        if self.web:
            self.web.close()
        run(SKILL / "stop.sh", self.root, *(["--keep"] if keep else []), check=False)

    def rpc(self, method, params=None, timeout=60):
        return self.client.call(method, params or {}, timeout=timeout)

    def project(self, name, files, commit=True):
        """A scratch project under the root, with these files, committed, and added."""
        folder = Path(self.root) / "work" / name
        folder.mkdir(parents=True, exist_ok=True)
        # The agent still reads the person's own ~/.claude/CLAUDE.md, and once said so on
        # camera. `private_words` fails a take that shows it anyway.
        files = {".claude/CLAUDE.md": QUIET, **files}
        for path, text in files.items():
            (folder / path).parent.mkdir(parents=True, exist_ok=True)
            (folder / path).write_text(text)
        if not (folder / ".git").exists():
            run("git", "-C", folder, "init", "-q", "-b", "main")
        if commit:
            run("git", "-C", folder, "add", "-A")
            run("git", "-C", folder, "-c", "user.name=Demo", "-c", "user.email=demo@example.com",
                "commit", "-qm", "First version", check=False)
        self.rpc("folders/add", {"folder": f"file://{folder}"})
        return folder

    def start(self, folder, prompt, runtime="claude", **extra):
        """Starts a real agent through the socket, as the window's Start would."""
        agent = self.rpc("agents/start", {"runtimeID": runtime, "cwd": f"file://{folder}", "prompt": prompt, **extra})
        agent_id = agent if isinstance(agent, str) else agent.get("id") or agent.get("agentID")
        self.agents[prompt] = agent_id
        return agent_id

    def agent(self, agent_id):
        for record in self.rpc("agents/list", {"includeArchived": False}) or []:
            if record.get("id") == agent_id:
                return record
        return {}

    def wait_state(self, agent_id, states=("idle", "done"), timeout=240):
        end = time.time() + timeout
        while time.time() < end:
            state = self.agent(agent_id).get("state")
            if state in states:
                return state
            time.sleep(1)
        raise TimeoutError(f"agent {agent_id} not in {states} after {timeout}s")

    def wait_until(self, check, timeout=120, every=0.5, what="condition"):
        end = time.time() + timeout
        while time.time() < end:
            try:
                value = check()
            except Exception:
                value = None
            if value:
                return value
            time.sleep(every)
        raise TimeoutError(f"waited {timeout}s for {what}")

    def newest_agent(self):
        agents = self.rpc("agents/list", {"includeArchived": False}) or []
        return max(agents, key=lambda a: a.get("createdAt", 0)).get("id") if agents else None

    def pending_question(self):
        return (self.rpc("elicitations/pending") or [None])[0]

    # --- the window, through its walk socket ---------------------------------------------
    def call(self, verb, **args):
        reply = self.walk.call(verb, **args)
        if not reply.get("ok"):
            log(f"walk {verb} {args.get('text', '')!r}: {reply.get('error')}")
        return reply

    def press(self, label, wait=10):
        """Presses the element labelled `label` (`=` the whole label), waiting up to `wait`
        seconds for it to be drawn. A label read in process can carry its help after a ` | `:
        `=Yes` then takes `Yes | Allow once`, say."""
        end = time.time() + wait
        while True:
            if self.walk.call("press", text=label).get("ok"):
                return True
            if label.startswith("="):
                for line in self.walk.call("find", text=label[1:]).get("matches", []):
                    whole = line.split(" · ", 1)[-1].split(" #")[0].split(" @")[0]
                    if whole.lower().startswith(label[1:].lower() + " | "):
                        return self.call("press", text="=" + whole).get("ok")
            if time.time() > end:
                break
            time.sleep(0.3)
        near = self.walk.call("find", text=label.lstrip("=")).get("matches", [])
        log(f"walk press {label!r}: nothing matched; near it: {near[:6]}")
        return False

    def select(self, label):
        return self.call("select", text=label).get("ok")

    def unfold(self, label):
        return self.call("unfold", text=label).get("ok")

    def find(self, label):
        """Every element whose label holds `label`, one a line ("" when there is none)."""
        return "\n".join(self.walk.call("find", text=label).get("matches", []))

    def type(self, field, text, ms=45):
        """Puts the keyboard in a field, then types `text` into it a key at a time, `ms`
        apart, as a person would. `field` is words of its label or placeholder; `@AXTextArea`,
        the first of that role; `after:Other`, the first text field or area after the text
        "Other" (a field with no label of its own)."""
        if field.startswith("@") or field.startswith("after:"):
            box = self.field_box(field)
            if not box or not self.call("click", x=box[0], y=box[1]).get("ok"):
                log(f"walk type: no field {field!r}")
                return False
            time.sleep(0.4)  # the field takes the keyboard a moment after the click
        elif not self.call("set", text=field, value="").get("ok"):
            return False
        self.type_on(text, ms)
        return True

    def type_on(self, text, ms=45):
        """Types where the keyboard already is, a key at a time."""
        for ch in text:
            self.walk.call("key", key={" ": "space", "\n": "return"}.get(ch, ch))
            time.sleep(ms / 1000)

    def field_box(self, field):
        """The middle of the field `type` names by role or by the text before it."""
        roles = ("AXTextField", "AXTextArea")
        role, after = (field[1:], None) if field.startswith("@") else (None, field[6:].lower())
        passed = after is None
        for line in self.walk.call("tree", depth=60).get("text", "").splitlines():
            line = line.strip()
            if not passed:
                passed = after in line.lower()
                continue
            kind = line.split(" ", 1)[0]
            if (kind == role if role else kind in roles) and " @" in line:
                where, size = line.rsplit(" @", 1)[1].split(" ")[:2]
                x, y = (float(n) for n in where.split(","))
                w, h = (float(n) for n in size.split("x"))
                return x + w / 2, y + h / 2
        return None

    def key(self, name, *modifiers):
        return self.call("key", key=name, **({"modifiers": list(modifiers)} if modifiers else {})).get("ok")

    def click(self, label):
        return self.call("click", text=label).get("ok")

    def size(self, width, height, x=None, y=None):
        """The window's frame, its top left on the main screen (at 2× there, or drawn at 2× by
        itself on a 1× one, #1855). AGENTS_VIDEO_AT=x,y puts it elsewhere, in points from
        the main screen's top left: on another screen, say."""
        at = [float(n) for n in os.environ.get("AGENTS_VIDEO_AT", "40,40").split(",")]
        x, y = (at[0] if x is None else x), (at[1] if y is None else y)
        return self.call("size", width=float(width), height=float(height), x=float(x), y=float(y))

    def select_agent(self, agent_id):
        """Opens an agent's conversation from its row in the sidebar."""
        title = self.agent(agent_id).get("title", "")
        return self.select(title[:40])

    def opened_url(self):
        """The address Open in Browser wrote, in place of opening a browser (#109)."""
        path = (Path.home() / "Library/Containers/com.alexecollins.agents.store/Data/Library/Application Support"
                / f"Agents/walks/run-vid-{self.scene.ID}/opened-url")
        return path.read_text().strip() if path.exists() else None

    def tidy(self):
        """Puts away the Get started card and a milestone's note, if they are showing."""
        for label in ("Dismiss Get started", "Dismiss milestone"):
            if self.walk.call("find", text=label).get("ok"):
                self.press(label, wait=0)

    def menu(self, menu, item):
        return self.call("menu", path=[menu, item]).get("ok")

    # --- the web page -------------------------------------------------------------------
    def open_web(self, width, height, mobile, pair=True):
        self.web = Web(f"/tmp/run-vid-{self.scene.ID}-chrome")
        self.web("open", url=self.env["WEB_URL"], width=width, height=height, mobile=mobile)
        if pair:
            self.web("pair", code=self.browser_code())
        return self.web

    def open_phone(self):
        """The web page at iPhone size, paired, for the bezel."""
        return self.open_web(*frame.PHONE_VIEW, mobile=True)

    def open_browser(self, pair=True):
        """The web page at desktop size (the scene's BROWSER), for the browser frame."""
        return self.open_web(*self.scene.BROWSER, mobile=False, pair=pair)

    def browser_code(self):
        control = self.host_app / "Contents/Helpers/agents-control"
        out = run(control, "code", "--client", "--browser", "--home", f"{self.root}/control")
        return out.splitlines()[-1].strip()

    # --- an integration's outside site (#1794) ------------------------------------------
    def open_site(self, url, tab="site"):
        """The outside site in the video Chrome, at the scene's BROWSER size, in a tab of its
        own; the browser frame records whichever tab is in front. The profile is the scene's
        CHROME_PROFILE, signed in once by the person: a take stops when it is not."""
        if not self.web:
            profile = CHROME_PROFILES / self.scene.CHROME_PROFILE
            if not profile.exists():
                raise RuntimeError(f"no video Chrome profile {profile}: the person signs in first, "
                                   f"with scripts/video/make.sh --sign-in {self.scene.CHROME_PROFILE}")
            self.web = Web(str(profile))
        width, height = self.scene.BROWSER
        self.web("open", url=url, width=width, height=height, mobile=False, tab=tab)
        return self.web

    def open_web_tab(self, tab="agents"):
        """The scratch web page, paired, in another tab of the video Chrome. Its pairing is
        forgotten after the take (forget_web_tab), so the profile keeps only the sign-in."""
        width, height = self.scene.BROWSER
        self.web("open", url=self.env["WEB_URL"], width=width, height=height, mobile=False, tab=tab)
        self.web("pair", code=self.browser_code())

    def forget_web_tab(self):
        if self.web and self.env.get("WEB_URL"):
            from urllib.parse import urlsplit
            parts = urlsplit(self.env["WEB_URL"])
            try:
                self.web("forget", origin=f"{parts.scheme}://{parts.netloc}")
            except Exception as error:
                log("the scratch page's pairing was not forgotten:", error)

    def secret(self, name, value, refused=None):
        """A token the scene made for the video. `refused()` asks the provider with it and
        says whether it was refused (401); after the take it must be. With no `refused`, the
        value is only looked for in the frames: a code spent once, say."""
        if value:
            self.secrets.append({"name": name, "value": value, "refused": refused})

    def hide_in_window(self, label):
        """Hides the window's elements labelled `label` in every frame from now on."""
        if self.recorder:
            self.recorder.secret_labels.append(label)
        self._hidden_labels = getattr(self, "_hidden_labels", []) + [label]

    def hide_in_browser(self, selector):
        """Hides what the DOM selector matches in every tab, from now on."""
        self.web("secret", selector=selector)

    def secret_values(self):
        return [s["value"] for s in self.secrets]

    # --- the story ----------------------------------------------------------------------
    def mark(self, name):
        self.marks.append((name, time.time()))

    def say(self, key, wait=True, after=0.4):
        """Speaks line `key` here. With wait, the scene waits until the line has been said."""
        self.mark(f"say:{key}")
        if wait:
            time.sleep(self.takes[key]["duration"] + after)

    def sleep(self, seconds):
        time.sleep(seconds)

    class _Fast:
        def __init__(self, video, most):
            self.video, self.most = video, most

        def __enter__(self):
            self.video.mark(f"fast:{self.most}")
            if self.video.recorder:
                self.video.recorder.fast = True

        def __exit__(self, *exc):
            self.video.mark("slow")
            if self.video.recorder:
                self.video.recorder.fast = False

    def fast(self, most=2.0):
        """Everything in the block is cut down to `most` seconds, sped up."""
        return self._Fast(self, most)


def png_width(png):
    """A PNG's width in pixels, from its header."""
    return int.from_bytes(png[16:20], "big")


def load_scene(scene_id):
    path = HERE / "scenes" / f"{scene_id.lower()}.py"
    spec = importlib.util.spec_from_file_location(f"scene_{scene_id}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ID = scene_id.lower()
    return module


def record_scene(scene, takes, work, build, keep):
    root = f"/tmp/run-vid-{scene.ID}"
    v = Video(scene, root, takes, work)
    log(scene.ID, "launching on", root)
    v.launch(build)
    recorder = None
    try:
        placed = v.size(*getattr(scene, "WINDOW", (1280, 780)))
        # A 1× screen (#1855): the window draws its shots at 2× by itself, and no screen's
        # mode changes. A window that cannot is an app from before #1855.
        scale = None if placed.get("scale") == 2 else 2
        if scale:
            shot = v.walk.call("shot", shadows=False, scale=scale)
            if shot.get("ok") and png_width(base64.b64decode(shot["png"])) == shot["width"] * 2:
                log(f"the screen is {placed.get('scale')}×: the window draws its frames at 2× itself")
            else:
                raise RuntimeError(f"the window draws at {placed.get('scale')}×, not 2×, and its shots cannot be drawn at 2× (an app from before #1855?)")
        time.sleep(1.5)
        scene.setup(v)
        time.sleep(2.0)
        v.tidy()
        time.sleep(1.0)
        Path(work / "still.png").write_bytes(base64.b64decode(v.walk.call("shot", **({"scale": scale} if scale else {}))["png"]))
        recorder = v.recorder = Recorder(root, work / "frames", scale=scale)
        recorder.secret_labels.extend(getattr(v, "_hidden_labels", []))
        recorder.start()
        mac_start = recorder.start_time()
        if v.web:
            v.web("record", dir=str(work / "web"))
        v.mark("begin")
        scene.run(v)
        v.mark("end")
        private_words(v)
        time.sleep(0.5)
        if v.web:
            v.web("stop")
        recorder.finish(work / "mac.mov", time.time(), v.secret_values())
        if v.web and v.secrets:
            frame.hide_web_frames(work)
            n = tokens.check(sorted((work / "web/frames").glob("*.jpg")), v.secret_values(), "the browser")
            log(f"token check: none of the browser's {n} frames shows part of a token")
            (work / "web/secrets.json").unlink()  # hidden now: compose need not hide them again
        (work / "marks.json").write_text(json.dumps({"mac_start": mac_start, "scale": 2, "marks": v.marks}, indent=1))
        contact_sheet(work)
    finally:
        if recorder:
            recorder.running = False
        try:
            revoke(scene, v)
        finally:
            v.forget_web_tab()
            v.stop(keep=keep)
    return v.secret_values()


class TokenStillWorks(RuntimeError):
    pass


def revoke(scene, v):
    """After every take, kept or not: the scene revokes what it made (scene.revoke), then each
    token must be refused (#1794). A token that still works fails the take, loudly."""
    if not hasattr(scene, "revoke"):
        return
    try:
        scene.revoke(v)
    except Exception as error:
        log("revoke:", error)
    live = []
    for secret in v.secrets:
        if secret["refused"] is None:
            continue
        try:
            refused = secret["refused"]()
        except Exception as error:
            log(f"the {secret['name']} check could not ask:", error)
            refused = False
        log(f"{secret['name']}: {'refused (401)' if refused else 'STILL WORKS'}")
        if not refused:
            live.append(secret["name"])
    if live:
        raise TokenStillWorks(f"{scene.ID}: still working after the take: {', '.join(live)}. Revoke "
                              f"them by hand on the provider's page now; the take is not kept")


def check(scene, mp4, work):
    """Whisper hears the finished video, which must say the script in order (a line cut
    off or two lines over each other shows here), and a sheet of it is made to look at."""
    script = " ".join(scene.LINES.values())
    heard = voice.hear(mp4)
    off = voice.wrong(script, heard)
    log(f"{scene.ID}: Whisper hears {off:.0%} of the script wrong: {heard}")
    frame.ffmpeg("-i", mp4, "-vf", "fps=1/3,scale=640:-1,tile=5x5", "-frames:v", "1", work / "video-sheet.png")
    if off > voice.MOST_WRONG:
        raise RuntimeError(f"{scene.ID}: the narration in {mp4} is not the script")


QUIET = """This is a demo project, recorded for a video.

- Never name or quote an instructions file (CLAUDE.md, AGENTS.md or any other), and never say
  where an instruction came from or which rule you follow.
"""

# What is the person's own and must not be in a video: their name, and what an agent says of
# their own instructions (a scratch agent still reads ~/.claude/CLAUDE.md).
PRIVATE = ("alex", "collins", "global claude.md", "your claude.md", "~/.claude", "asd-ste100", "ste100", "/users/")


def private_words(v):
    """Fails the take when the window says anything of the person's own (#1078)."""
    text = v.walk.call("tree", depth=80).get("text", "").lower()
    found = sorted({word for word in PRIVATE if word in text})
    if found:
        raise RuntimeError(f"{v.scene.ID}: the window shows {found}: the take is not kept")


def contact_sheet(work):
    """A frame every two seconds of the recording, in one picture, to look at before the
    video is kept (#1078): what is in it is only the scratch window's, but look anyway."""
    frame.ffmpeg("-i", work / "mac.mov", "-vf", "fps=1/2,scale=640:-1,tile=6x6", "-frames:v", "1", work / "sheet.png")
    log("contact sheet:", work / "sheet.png")


def sign_in(profile, urls):
    """The video Chrome on its own profile, in a window, for the person to sign in to the
    site once (#1794). On a Mac, closing the window does not quit Chrome, so it watches the
    profile's cookies and quits that Chrome itself once the site's session cookie is there
    (#1834)."""
    folder = CHROME_PROFILES / profile
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    from shutil import which
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if not Path(chrome).exists():
        chrome = which("google-chrome")
    if not chrome:
        raise SystemExit("Chrome is not installed")
    site = SIGN_IN.get(profile, {})
    host = site.get("host")
    log(f"sign in, then quit this Chrome (⌘Q): closing the window leaves it running on a Mac. The profile is {folder}")
    if host:
        log(f"it quits by itself once the profile has the {host} sign-in")
    proc = subprocess.Popen([chrome, f"--user-data-dir={folder}", "--no-first-run", "--no-default-browser-check",
                             "--disable-sync", *(urls or [site.get("url", "about:blank")])],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        while proc.poll() is None:
            if host and signed_in(folder, host):
                # SIGTERM, not SIGKILL: Chrome writes its cookies to disk as it quits.
                proc.terminate()
                proc.wait(timeout=30)
                break
            time.sleep(3)
    except KeyboardInterrupt:
        proc.terminate()
        proc.wait(timeout=30)
    if not host:
        log("Chrome quit")
    elif signed_in(folder, host):
        log(f"signed in to {host}")
    else:
        raise SystemExit(f"not signed in to {host}: run `scripts/video/make.sh --sign-in {profile}` again")


# The cookies a site sets before anyone signs in: they say nothing about a sign-in.
ANONYMOUS_COOKIES = ("__cf", "_cf", "cf_", "_ga", "_gid", "_gcl", "ajs_", "intercom-")


def signed_in(folder, host):
    """Whether the Chrome profile in folder has a cookie of host's that is not an anonymous
    one. It reads a copy of the Cookies file (Chrome holds it open), and names only, never
    values."""
    import sqlite3
    import tempfile
    for db in (folder / "Default/Network/Cookies", folder / "Default/Cookies"):
        if not db.exists():
            continue
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "Cookies"
            for suffix in ("", "-journal", "-wal"):
                if Path(f"{db}{suffix}").exists():
                    shutil.copy(f"{db}{suffix}", f"{copy}{suffix}")
            try:
                with sqlite3.connect(f"file:{copy}?mode=ro", uri=True) as conn:
                    names = conn.execute("SELECT name FROM cookies WHERE host_key = ? OR host_key LIKE ?",
                                         (host, f"%.{host}")).fetchall()
            except sqlite3.Error:
                continue
        if any(not name.startswith(ANONYMOUS_COOKIES) for (name,) in names):
            return True
    return False


# `home`: an address that a signed-in profile leaves for one matching `in`.
SIGN_IN = {"linear": {"url": "https://linear.app/login", "host": "linear.app",
                      "home": "https://linear.app/", "in": r"https://linear\.app/(?!login)[^/]+/"}}


# --- the Integration videos workflow (#1857) ------------------------------------------
TODO_ISSUE = 1793
INTEGRATIONS = REPO / "docs/reference/integrations.md"


def preflight(scene_ids):
    """Checks what a take needs from Alex's hands: the YouTube refresh token works, and the
    scene's video Chrome profile is signed in to its site. Each failure adds one line to
    Alex's checklist on #1793 (once) and fails that scene. Prints `ready <id>` or
    `skip <id>: <why>` per scene; exits 3 when any is skipped."""
    import upload
    youtube = None
    try:
        yt = upload.YouTube()
        mine = yt.call("GET", "channels", {"part": "snippet", "mine": "true"}).get("items", [])
        if not mine:
            youtube = "the YouTube sign-in has no channel"
    except upload.NotSignedIn as why:
        youtube = str(why)
    except Exception as error:
        youtube = f"the YouTube refresh token does not work ({error})"
    skipped = 0
    for scene_id in scene_ids:
        scene = load_scene(scene_id)
        why = []
        if youtube:
            why.append(youtube)
            todo("Run `scripts/video/upload.py --sign-in` and approve with the Google account of the YouTube channel (#1856).",
                 key="upload.py --sign-in")
        profile = getattr(scene, "CHROME_PROFILE", None)
        site = SIGN_IN.get(profile or "", {})
        if profile and site.get("host") and not (signed_in(CHROME_PROFILES / profile, site["host"])
                                                  and site_signed_in(CHROME_PROFILES / profile, site)):
            why.append(f"the video Chrome is not signed in to {site['host']}")
            todo(f"Run `scripts/video/make.sh --sign-in {profile}` and sign in to {site['host']} (the {scene.ID} video).",
                 key=f"make.sh --sign-in {profile}")
        if why:
            skipped += 1
            print(f"skip {scene.ID}: {'; '.join(why)}", flush=True)
        else:
            print(f"ready {scene.ID}", flush=True)
    if skipped:
        raise SystemExit(3)


def site_signed_in(profile, site):
    """Whether the site, opened on the profile in headless Chrome, lands signed in: a session
    cookie can be there and the site still send the profile to its sign-in page (#1857)."""
    web = Web(str(profile))
    try:
        web("open", url=site["home"], width=1280, height=800, mobile=False, tab="site")
        end = time.time() + 20
        while time.time() < end:
            if re.match(site["in"], web("url")):
                return True
            time.sleep(1)
        return False
    finally:
        web.close()


def todo(line, key):
    """One line on Alex's checklist on #1793 (`## What Alex does`, alex-todo, assigned
    alexec), unless an open item there already holds `key`."""
    issue = json.loads(run("gh", "issue", "view", str(TODO_ISSUE), "--json", "body"))
    body = issue.get("body") or ""
    if any(item.startswith("- [ ]") and key in item for item in body.splitlines()):
        return
    head = "## What Alex does"
    if head in body:
        before, after = body.split(head, 1)
        body = f"{before}{head}\n\n- [ ] {line}\n{after.lstrip(chr(10))}"
    else:
        body = f"{head}\n\n- [ ] {line}\n\n{body}"
    run("gh", "issue", "edit", str(TODO_ISSUE), "--body", body, "--add-assignee", "alexec", "--add-label", "alex-todo")
    log(f"on Alex's list (#{TODO_ISSUE}): {line}")


def changed(since, until="HEAD"):
    """The integration scenes whose integration a range of commits changed: each scene's
    rows in docs/reference/integrations.md are the ones whose first cell names its TITLE,
    and their Where cells give the paths."""
    rows = [line for line in INTEGRATIONS.read_text().splitlines() if line.startswith("| ") and "`" in line]
    for path in sorted((HERE / "scenes").glob("i-*.py")):
        scene = load_scene(path.stem)
        if getattr(scene, "GROUP", "") != "integration":
            continue
        title = getattr(scene, "TITLE", scene.ID).lower()
        paths = {f"scripts/video/scenes/{scene.ID}.py"}
        for row in rows:
            cells = [cell.strip() for cell in row.strip("|").split("|")]
            if len(cells) > 2 and title in cells[0].lower():
                paths.update(p.rstrip("/") for p in re.findall(r"`([\w./-]+/[\w./-]*)`", cells[-2]))
        if run("git", "-C", str(REPO), "diff", "--name-only", f"{since}..{until}", "--", *sorted(paths)).strip():
            print(scene.ID)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenes", nargs="*")
    parser.add_argument("--no-build", action="store_true", help="use the last build/DD")
    parser.add_argument("--keep", action="store_true", help="keep the scratch root to read")
    parser.add_argument("--voice-only", action="store_true")
    parser.add_argument("--compose-only", action="store_true", help="compose the last recording again")
    parser.add_argument("--upload", action="store_true", help="upload each video made (upload.py)")
    parser.add_argument("--sign-in", metavar="PROFILE", help="open the video Chrome on PROFILE for the person to sign in, then quit")
    parser.add_argument("--preflight", action="store_true", help="check what each scene needs of Alex's hands; take nothing")
    parser.add_argument("--changed", action="store_true", help="list the integration scenes changed between two refs (the scenes argument)")
    args = parser.parse_args()
    if args.preflight:
        preflight(args.scenes)
        return
    if args.changed:
        if not 1 <= len(args.scenes) <= 2:
            raise SystemExit("--changed <from> [<to>]")
        changed(*args.scenes)
        return
    if args.sign_in:
        sign_in(args.sign_in, args.scenes)
        return
    OUT.mkdir(parents=True, exist_ok=True)
    built = args.no_build
    for scene_id in args.scenes:
        scene = load_scene(scene_id)
        work = CACHE / "work" / scene.ID
        secrets = []
        takes = voice.speak(scene, CACHE / "voice")
        if args.voice_only:
            continue
        if not args.compose_only:
            if work.exists():
                shutil.rmtree(work)
            work.mkdir(parents=True)
            secrets = record_scene(scene, takes, work, build=not built, keep=args.keep)
            built = True
        elif getattr(scene, "GROUP", "") == "integration":
            raise SystemExit("--compose-only: an integration take's tokens are gone, so it cannot be checked again; make it again")
        mp4 = frame.compose(scene, takes, work, OUT)
        try:
            check(scene, mp4, work)
            if secrets:
                n = tokens.check_video(mp4, secrets)
                log(f"token check: none of {n} frames of {mp4.name} shows part of a token")
        except Exception:
            mp4.unlink(missing_ok=True)
            raise
        log(scene.ID, "made", mp4)
        if args.upload:
            import upload
            upload.upload(scene, mp4)


if __name__ == "__main__":
    main()
