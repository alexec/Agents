"""The token check (#1794): reads frames with OCR (Vision, ocr.swift) and fails a take that
shows any part of a secret the scene made.

"Any part" is any run of PART characters of the secret's own part (a provider's public prefix,
such as lin_api_, is not secret). Letters Vision mixes up (O and 0, l, I and 1) count as the
same. A finding names the frame and how many runs it read, never the characters: this check
must not put a token in a log either.

    python3 scripts/video/tokens.py --self-test   draws a made-up token, finds it, hides it
                                                  (frame.hide) and finds nothing
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = Path.home() / ".cache/agents-video"
OCR = CACHE / "ocr"
PART = 6
PUBLIC_PREFIXES = ("lin_api_", "lin_oauth_", "lin_", "glpat-", "dop_v1_", "ghp_", "gho_", "github_pat_")
SAME = str.maketrans({"o": "0", "i": "1", "l": "1", "|": "1", "s": "5", "z": "2", "b": "8"})


class TokenShown(RuntimeError):
    pass


def _plain(text):
    return "".join(text.split()).lower().translate(SAME)


def parts(secret):
    """Every run of PART characters of the secret's own part, as OCR text is compared."""
    body = secret
    for prefix in PUBLIC_PREFIXES:
        if body.startswith(prefix):
            body = body[len(prefix):]
            break
    body = _plain(body)
    if len(body) < PART:
        return {body} if body else set()
    return {body[i:i + PART] for i in range(len(body) - PART + 1)}


def ocr_binary():
    """ocr.swift, compiled once into the cache (and again when it changes)."""
    source = HERE / "ocr.swift"
    if not OCR.exists() or OCR.stat().st_mtime < source.stat().st_mtime:
        OCR.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(source), "-o", str(OCR)], check=True, capture_output=True)
    return OCR


def read(paths):
    """{path: [lines Vision read]} for each picture."""
    paths = [str(p) for p in paths]
    if not paths:
        return {}
    done = subprocess.run([str(ocr_binary())], input="\n".join(paths) + "\n", capture_output=True, text=True, check=True)
    return {answer["path"]: answer["text"] for answer in map(json.loads, done.stdout.splitlines())}


def findings(paths, secrets):
    """[(path, runs)] for each picture that shows a run of a secret."""
    wanted = [parts(s) for s in secrets if s]
    found = []
    for path, lines in read(paths).items():
        text = _plain(" ".join(lines))
        runs = sum(1 for each in wanted for run in each if run in text)
        if runs:
            found.append((path, runs))
    return found


def check(paths, secrets, what):
    """Raises TokenShown when any of `paths` shows a run of a secret."""
    paths = list(paths)
    found = findings(paths, secrets)
    if found:
        first = Path(found[0][0]).name
        raise TokenShown(f"{what}: {len(found)} of {len(paths)} frames show part of a token "
                         f"(the first, {first}, {found[0][1]} runs of {PART}): the take is not kept")
    return len(paths)


def check_video(mp4, secrets, every=0.5):
    """The finished video, a frame every `every` seconds, read the same way."""
    with tempfile.TemporaryDirectory(prefix="agents-video-ocr-") as folder:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(mp4), "-vf", f"fps={1 / every}",
                        os.path.join(folder, "%06d.png")], check=True)
        return check(sorted(Path(folder).glob("*.png")), secrets, Path(mp4).name)


def self_test():
    """A made-up token drawn as a page would, then hidden as frame.py hides it."""
    sys.path.insert(0, str(HERE))
    import frame
    from PIL import Image, ImageDraw
    secret = "lin_api_" + "Q7mZ4kT9wX2pR8vN5cB1hJ6dF3sL0gY"
    img = Image.new("RGB", (1600, 300), "white")
    draw = ImageDraw.Draw(img)
    draw.text((40, 60), "Your new API key", font=frame.font(40), fill="black")
    draw.text((40, 150), secret, font=frame.font(44), fill="black")
    box = draw.textbbox((40, 150), secret, font=frame.font(44))
    with tempfile.TemporaryDirectory() as folder:
        shown, hidden = Path(folder, "shown.png"), Path(folder, "hidden.png")
        img.save(shown)
        frame.hide(img.copy(), [(box[0], box[1], box[2] - box[0], box[3] - box[1])]).save(hidden)
        seen = findings([shown], [secret])
        assert seen, "the check did not read the token where it shows"
        assert not findings([hidden], [secret]), "the check read the token after frame.hide"
        assert any("API key" in line for line in read([hidden])[str(hidden)]), "OCR read nothing at all"
    print(f"self-test: the token was read where it shows ({seen[0][1]} runs) and not after frame.hide")
    browser_test(secret)


def browser_test(secret):
    """web.mjs with a pattern secret: a page that shows the token, recorded in headless Chrome
    on a throwaway profile, must show no part of it in any frame."""
    page = ("<body style='font: 28px -apple-system; padding: 40px'><h1>Personal API keys</h1>"
            f"<p>Your new key</p><div><code>{secret}</code></div>"
            f"<input style='font-size: 24px; width: 900px' value='{secret}'></body>")
    with tempfile.TemporaryDirectory(prefix="agents-video-test-") as folder:
        Path(folder, "page.html").write_text(page)
        web = subprocess.Popen(["node", str(HERE / "web.mjs"), os.path.join(folder, "chrome")],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=HERE)

        def call(op, **args):
            web.stdin.write(json.dumps({"op": op, **args}) + "\n")
            web.stdin.flush()
            answer = json.loads(web.stdout.readline())
            assert answer["ok"], f"web {op}: {answer.get('error')}"
            return answer["value"]

        try:
            call("open", url="about:blank", width=1100, height=500, tab="site")
            call("secret", pattern=r"lin_(api|oauth)_[A-Za-z0-9]{8,}")
            call("record", dir=os.path.join(folder, "rec"))
            call("open", url=f"file://{folder}/page.html", width=1100, height=500, tab="site")
            call("waitFor", expr="document.querySelector('[data-agents-secret]')")
            import time
            time.sleep(1.5)
            call("shot", path=os.path.join(folder, "shot.png"))
            call("stop")
        finally:
            try:
                call("close")
            except Exception:
                pass
            web.wait(timeout=20)
        frames = sorted(Path(folder, "rec/frames").glob("*.jpg"))
        assert frames, "web.mjs recorded no frame"
        assert not findings(frames + [Path(folder, "shot.png")], [secret]), "a frame from Chrome shows part of the token"
        assert any("Personal API keys" in line for lines in read([Path(folder, "shot.png")]).values() for line in lines), \
            "OCR read nothing of the page"
    print(f"self-test: Chrome hid the token in all {len(frames)} frames and the screenshot")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        print(__doc__)
