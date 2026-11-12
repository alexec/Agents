"""A PR's silent clip (#4094): a short animated WebP of a scratch window, for motion.

    scripts/video/clip.sh ROOT OUT.webp [--seconds N] [--width W] [--fps F] [-- COMMAND…]

ROOT is a run-app scratch root (/tmp/run-<slug>) or `remote` (the Remote in the walk
simulator). The frames come from make.py's Recorder: the window draws each one itself,
through its walk socket (#1172), so no other window can be in the clip and a locked screen
does not stop it. With a COMMAND (walk.py steps: a scroll, a press, a key), the clip runs
from just before it starts to a second after it ends; without one, for --seconds.

The clip is an animated WebP, because an animated image in `![](…)` plays inline in a PR
from the `screenshots` branch (pr-shots.sh), where a video file shows only as a link. A clip
with sound is pr-clip.sh's (#4856). It keeps at most MOST_SECONDS, and is made smaller until
it is under LIMIT_BYTES, or fails.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make import Recorder  # noqa: E402

MOST_SECONDS = 20
LIMIT_BYTES = 5 * 1024 * 1024
HOLD_LAST = 1.0  # the last frame stays this long before the clip loops
# Under a window's clear sidebar, the grey a light sidebar shows over a plain desktop (as
# Recorder.finish puts under the video's frames).
BACKDROP = (0xEA, 0xEC, 0xF0, 255)


def log(*parts):
    print(*parts, file=sys.stderr, flush=True)


def record(root, seconds, fps, command):
    folder = Path(tempfile.mkdtemp(prefix="agents-clip-"))
    recorder = Recorder(root, folder, fps=fps)
    recorder.start()
    try:
        began = recorder.start_time()
        code = 0
        if command:
            code = subprocess.run(command).returncode
            time.sleep(1.0)
        else:
            time.sleep(seconds)
        end = time.time()
        recorder.running = False
        recorder.join(10)
        if recorder.error:
            raise SystemExit(f"clip: recorder: {recorder.error}")
        return folder, list(recorder.frames), began, end, code
    except BaseException:
        recorder.running = False
        shutil.rmtree(folder, ignore_errors=True)
        raise


def timeline(frames, began, end):
    """Each frame with how long it shows, in ms, cut to MOST_SECONDS."""
    if end - began > MOST_SECONDS:
        log(f"clip: {end - began:.0f} s recorded; the clip keeps the first {MOST_SECONDS} s")
        end = began + MOST_SECONDS
    kept = [(path, at) for path, at in frames if at < end] or frames[:1]
    times = [at for _, at in kept] + [end]
    shown = [(path, max(20, round((following - at) * 1000))) for (path, at), following in zip(kept, times[1:])]
    path, ms = shown[-1]
    shown[-1] = (path, max(ms, round(HOLD_LAST * 1000)))
    return shown


def picture(path, canvas, width):
    """The frame on the backdrop, at the top left of a canvas the size of the largest frame
    (a window that is resized draws frames of other sizes), at most `width` wide."""
    img = Image.open(path).convert("RGBA")
    flat = Image.new("RGBA", canvas, BACKDROP)
    flat.alpha_composite(img)
    if canvas[0] > width:
        flat = flat.resize((width, round(canvas[1] * width / canvas[0])), Image.LANCZOS)
    return flat.convert("RGB")


def write(shown, out, width):
    """The animated WebP, made smaller until it is under LIMIT_BYTES."""
    sizes = [Image.open(path).size for path, _ in shown]
    canvas = (max(w for w, _ in sizes), max(h for _, h in sizes))
    for quality, scale in ((70, 1.0), (55, 1.0), (55, 0.8), (40, 0.65)):
        w = round(min(width, canvas[0]) * scale)
        images = [picture(path, canvas, w) for path, _ in shown]
        images[0].save(out, "WEBP", save_all=True, append_images=images[1:],
                       duration=[ms for _, ms in shown], loop=0, quality=quality, method=4)
        size = out.stat().st_size
        if size < LIMIT_BYTES:
            return size, images[0].size
        log(f"clip: {size / 1048576:.1f} MB at {w} px wide and quality {quality}: smaller")
    out.unlink(missing_ok=True)
    raise SystemExit(f"clip: still over {LIMIT_BYTES // 1048576} MB: record less, or a smaller --width")


def sheet(out, count=6):
    """A contact sheet of up to `count` of the clip's frames, outside OUT's folder (so
    pr-shots.sh never takes it), for a person or an agent to look at before the push."""
    clip = Image.open(out)
    picks = sorted({round(i * (clip.n_frames - 1) / max(1, count - 1)) for i in range(count)})
    w, h = clip.size
    page = Image.new("RGB", (w * 2, h * ((len(picks) + 1) // 2)), "white")
    for i, k in enumerate(picks):
        clip.seek(k)
        page.paste(clip.convert("RGB"), ((i % 2) * w, (i // 2) * h))
    path = Path(tempfile.gettempdir()) / f"{out.stem}-sheet.png"
    page.save(path)
    return path


def main():
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        at = argv.index("--")
        argv, command = argv[:at], argv[at + 1:]
    parser = argparse.ArgumentParser(description="A PR's silent clip (#4094)")
    parser.add_argument("root", help="a scratch root (/tmp/run-<slug>) or remote")
    parser.add_argument("out", type=Path, help="<client>-<state>.webp, for pr-shots.sh")
    parser.add_argument("--seconds", type=float, default=5, help="how long, with no COMMAND")
    parser.add_argument("--width", type=int, default=960, help="the clip's most width in pixels")
    parser.add_argument("--fps", type=float, default=10, help="the most frames a second")
    args = parser.parse_args(argv)
    if args.out.suffix != ".webp":
        raise SystemExit("clip: OUT must end .webp")
    if not command and not 0 < args.seconds <= MOST_SECONDS:
        raise SystemExit(f"clip: --seconds must be over 0 and at most {MOST_SECONDS}")
    args.out.parent.mkdir(parents=True, exist_ok=True)

    folder, frames, began, end, code = record(args.root, args.seconds, args.fps, command)
    try:
        if code != 0:
            raise SystemExit(f"clip: the command failed ({code}); no clip")
        shown = timeline(frames, began, end)
        size, (w, h) = write(shown, args.out, args.width)
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    seconds = sum(ms for _, ms in shown) / 1000
    log(f"clip: {len(shown)} frames, {seconds:.1f} s, {w}x{h}, {size / 1024:.0f} KB")
    log(f"clip: look at its frames before you push it: {sheet(args.out)}")
    print(os.fspath(args.out))


if __name__ == "__main__":
    main()
