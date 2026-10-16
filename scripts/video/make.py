"""Makes the docs site's narrated videos with no person (#1078).

    scripts/video/make.sh <id>… [--no-build] [--keep] [--voice-only] [--compose-only]

For each scene in scenes/<id>.py it:
1. speaks each narration line with Chatterbox, two takes, and keeps a take only when Whisper
   hears the words of the script (voice.py);
2. launches a scratch app with run-app on /tmp/run-vid-<id>, never the live app, and records
   its window (record.swift) and, if the scene has one, the web page in headless Chrome at
   iPhone or desktop size (web.mjs), while the scene drives them through the socket, the
   accessibility tree and keys posted to the window's pid;
3. puts the recordings on the backdrop (frame.py), cuts the waits short, places each line at
   the marker the scene wrote when it spoke, and writes <id>.mp4 and <id>.vtt to
   ~/Movies/agents-video/out/.

Nothing is uploaded. Real Claude agents run in the scenes, on scratch projects: a few cents
a video.
"""
import argparse
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SKILL = REPO / ".claude/skills/run-app/scripts"
CACHE = Path.home() / ".cache/agents-video"
BIN = CACHE / "bin"
OUT = Path(os.environ.get("AGENTS_VIDEO_OUT", Path.home() / "Movies/agents-video/out"))

sys.path.insert(0, str(SKILL))
sys.path.insert(0, str(HERE))
from rpc import Client  # noqa: E402
import frame  # noqa: E402
import voice  # noqa: E402


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def run(*cmd, check=True, capture=True, **kw):
    result = subprocess.run([str(c) for c in cmd], capture_output=capture, text=True, **kw)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, cmd))}: {result.stdout}{result.stderr}")
    return result.stdout.strip() if capture else ""


def compile_helpers():
    BIN.mkdir(parents=True, exist_ok=True)
    for name in ("record", "keys"):
        source, binary = HERE / f"{name}.swift", BIN / name
        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            log("compiling", name)
            run("swiftc", "-O", "-o", binary, source)


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
            raise RuntimeError(f"web {op}: {answer['error']}")
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
        self.agents = {}
        self.answer_permissions = True

    # --- the scratch set-up -------------------------------------------------------------
    def launch(self, build):
        args = [SKILL / "launch.sh", "--slug", f"vid-{self.scene.ID}", "--appearance", "light", "--outside-checkout"]
        if not build:
            args.append("--no-build")
        out = run(*args)
        for line in out.splitlines():
            if "=" in line and line.split("=", 1)[0].isupper():
                key, value = line.split("=", 1)
                self.env[key] = value.strip().strip("'\"")
        self.pid = self.env["APP_PID"]
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
        while not self.stopping:
            time.sleep(0.7)
            if not self.answer_permissions:
                continue
            try:
                for ask in client.call("permissions/pending") or []:
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

    # --- the window ---------------------------------------------------------------------
    def ui(self, verb, *args, check=False):
        return run("swift", SKILL / "ui.swift", verb, self.pid, *args, check=check)

    def press(self, label):
        return self.ui("press", label)

    def select(self, label):
        return self.ui("select", label)

    def unfold(self, label):
        return self.ui("unfold", label)

    def find(self, label):
        return self.ui("find", label)

    def keys(self, *args):
        return run(BIN / "keys", args[0], self.pid, *args[1:], check=False)

    def type(self, field, text, ms=45):
        return self.keys("type", field, text, str(ms))

    def select_agent(self, agent_id):
        """Opens an agent's conversation from its row in the sidebar."""
        title = self.agent(agent_id).get("title", "")
        return self.select(title[:40])

    def type_on_page(self, text, ms=45):
        """Types into the live page in the files pane, where its caret is."""
        return self.keys("type", "@AXTextArea", text, str(ms))

    def opened_url(self):
        """The address Open in Browser wrote, in place of opening a browser (#109)."""
        path = (Path.home() / "Library/Containers/com.alexecollins.agents.store/Data/Library/Application Support"
                / f"Agents/walks/run-vid-{self.scene.ID}/opened-url")
        return path.read_text().strip() if path.exists() else None

    def key(self, name):
        return self.keys("key", name)

    def tidy(self):
        """Puts away the Get started card and a milestone's note, if they are showing."""
        for label in ("Dismiss Get started", "Dismiss milestone"):
            self.press(label)

    def menu(self, menu, item):
        return self.keys("menu", menu, item)

    def window_id(self):
        out = self.ui("windows")
        best, wid = 0, None
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and "x" in parts[1]:
                w, h = (int(float(n)) for n in parts[1].split("x")[:2])
                if w * h > best:
                    best, wid = w * h, parts[0]
        if wid is None:
            raise RuntimeError(f"no window for pid {self.pid}: {out!r}; running: {run('pgrep', '-fl', 'walk run-vid', check=False)}")
        return wid

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

        def __exit__(self, *exc):
            self.video.mark("slow")

    def fast(self, most=2.0):
        """Everything in the block is cut down to `most` seconds, sped up."""
        return self._Fast(self, most)


def idle_seconds():
    out = run("ioreg", "-c", "IOHIDSystem")
    return min(int(line.split()[-1]) // 1_000_000_000 for line in out.splitlines() if "HIDIdleTime" in line)


def locked():
    return "CGSSessionScreenIsLocked" in run("ioreg", "-n", "Root", "-d1", "-a")


def away_enough():
    """Alex records only while away (#1078): idle two minutes or more, the screen unlocked, and
    the display not about to sleep (it sleeps at ten minutes, and locks five after)."""
    idle = idle_seconds()
    if locked():
        return False, "the screen is locked"
    if idle < 120:
        return False, f"someone is at the Mac (idle {idle}s)"
    if idle > 420:
        return False, f"the display sleeps soon (idle {idle}s)"
    return True, f"idle {idle}s"


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
        v.keys("size", *map(str, getattr(scene, "WINDOW", (1280, 780))), "40", "40")
        time.sleep(1.5)
        scene.setup(v)
        time.sleep(2.0)
        v.tidy()
        time.sleep(1.0)
        wid = v.window_id()
        run("screencapture", "-x", "-o", "-l", wid, work / "still.png")
        recorder = subprocess.Popen([str(BIN / "record"), wid, str(work / "mac.mov")],
                                    stdout=subprocess.PIPE, text=True)
        first = recorder.stdout.readline().split()
        if not first or first[0] != "start":
            raise RuntimeError(f"recorder: {' '.join(first)}")
        mac_start = float(first[1])
        if v.web:
            v.web("record", dir=str(work / "web"))
        v.mark("begin")
        scene.run(v)
        v.mark("end")
        time.sleep(0.5)
        if v.web:
            v.web("stop")
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=30)
        (work / "marks.json").write_text(json.dumps({"mac_start": mac_start, "marks": v.marks}, indent=1))
    finally:
        if recorder and recorder.poll() is None:
            recorder.kill()
        v.stop(keep=keep)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenes", nargs="+")
    parser.add_argument("--no-build", action="store_true", help="use the last build/DD")
    parser.add_argument("--keep", action="store_true", help="keep the scratch root to read")
    parser.add_argument("--voice-only", action="store_true")
    parser.add_argument("--compose-only", action="store_true", help="compose the last recording again")
    parser.add_argument("--when-away", action="store_true",
                        help="record a scene only while nobody is at the Mac; stop with 3 otherwise")
    args = parser.parse_args()
    compile_helpers()
    OUT.mkdir(parents=True, exist_ok=True)
    built = args.no_build
    for scene_id in args.scenes:
        scene = load_scene(scene_id)
        work = CACHE / "work" / scene.ID
        takes = voice.speak(scene, CACHE / "voice")
        if args.voice_only:
            continue
        if not args.compose_only:
            if args.when_away:
                ok, why = away_enough()
                if not ok:
                    log(scene.ID, "not recorded:", why)
                    sys.exit(3)
            if work.exists():
                shutil.rmtree(work)
            work.mkdir(parents=True)
            record_scene(scene, takes, work, build=not built, keep=args.keep)
            built = True
        mp4 = frame.compose(scene, takes, work, OUT)
        log(scene.ID, "made", mp4)


if __name__ == "__main__":
    main()
