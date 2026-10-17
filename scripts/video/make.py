"""Makes the docs site's narrated videos with no person (#1078).

    scripts/video/make.sh <id>… [--no-build] [--keep] [--voice-only] [--compose-only]

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

Nothing is uploaded. Real Claude agents run in the scenes, on scratch projects: a few cents
a video.
"""
import argparse
import base64
import importlib.util
import json
import os
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
import voice  # noqa: E402


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

    def __init__(self, root, folder, fps=12):
        super().__init__(daemon=True)
        self.walk, self.folder, self.every = Walk(root), folder, 1 / fps
        self.folder.mkdir(parents=True, exist_ok=True)
        self.frames, self.size, self.error = [], None, None
        self.started, self.running = threading.Event(), True
        self.fast = False  # in a span cut short: a few frames do

    def run(self):
        last = None
        try:
            while self.running:
                began = time.time()
                reply = self.walk.call("shot", shadows=False)
                if not reply.get("ok"):
                    raise RuntimeError(f"shot: {reply.get('error')}")
                png = base64.b64decode(reply["png"])
                digest = zlib.crc32(png)
                if digest != last:
                    if self.size is None:
                        self.size = (reply["width"] * 2, reply["height"] * 2)
                    path = self.folder / f"{len(self.frames):06d}.png"
                    path.write_bytes(png)
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

    def start_time(self):
        self.started.wait(20)
        if self.error or not self.frames:
            raise RuntimeError(f"recorder: {self.error or 'no frame'}")
        return self.frames[0][1]

    def finish(self, out, end):
        self.running = False
        self.join(10)
        if self.error:
            raise RuntimeError(f"recorder: {self.error}")
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

    def __init__(self, profile):
        self.proc = subprocess.Popen(["node", str(HERE / "web.mjs"), profile], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, cwd=HERE)

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
        self.rpc("projects/add", {"folder": f"file://{folder}"})
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

    def size(self, width, height, x=40, y=40):
        """The window's frame, its top left on the main screen, where it draws at 2×."""
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
        if placed.get("scale") != 2:
            raise RuntimeError(f"the window draws at {placed.get('scale')}×, not 2×: is the main screen a Retina one?")
        time.sleep(1.5)
        scene.setup(v)
        time.sleep(2.0)
        v.tidy()
        time.sleep(1.0)
        Path(work / "still.png").write_bytes(base64.b64decode(v.walk.call("shot")["png"]))
        recorder = v.recorder = Recorder(root, work / "frames")
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
        recorder.finish(work / "mac.mov", time.time())
        (work / "marks.json").write_text(json.dumps({"mac_start": mac_start, "scale": 2, "marks": v.marks}, indent=1))
        contact_sheet(work)
    finally:
        if recorder:
            recorder.running = False
        v.stop(keep=keep)


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenes", nargs="+")
    parser.add_argument("--no-build", action="store_true", help="use the last build/DD")
    parser.add_argument("--keep", action="store_true", help="keep the scratch root to read")
    parser.add_argument("--voice-only", action="store_true")
    parser.add_argument("--compose-only", action="store_true", help="compose the last recording again")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    built = args.no_build
    for scene_id in args.scenes:
        scene = load_scene(scene_id)
        work = CACHE / "work" / scene.ID
        takes = voice.speak(scene, CACHE / "voice")
        if args.voice_only:
            continue
        if not args.compose_only:
            if work.exists():
                shutil.rmtree(work)
            work.mkdir(parents=True)
            record_scene(scene, takes, work, build=not built, keep=args.keep)
            built = True
        mp4 = frame.compose(scene, takes, work, OUT)
        check(scene, mp4, work)
        log(scene.ID, "made", mp4)


if __name__ == "__main__":
    main()
