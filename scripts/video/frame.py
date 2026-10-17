"""Puts a scene's recordings on the backdrop, cuts the waits, and lays the narration on (#1078).

The picture, as Alex chose: the Mac window with its shadow on a soft cobalt backdrop, and the
phone inside Apple's iPhone bezel, which is read from ~/.agents/video/assets (its licence lets
it be shown in a video, not given away, so it is not in git). A scene's LAYOUT says what is on
the backdrop: "mac", "mac+phone" or "mac+browser".

The window draws its own frames (the walk socket, #1172), so no other window can be in them and
there is no recording badge. A layer render leaves out the window's buttons and its rounded
corners: the traffic lights of a window that is not key are drawn over each frame, and the
corners are cut by a mask.

Time: t=0 is the Mac recording's first frame. The scene's markers are unix times. A `fast`
span is cut to its most seconds, sped up; every marker after it moves with it. Each narration
line starts at its `say` marker. The captions (WebVTT) are the lines, at the same times.
"""
import json
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 2560, 1440, 30
ASSETS = Path.home() / ".agents/video/assets"
BEZEL = ASSETS / "iPhone 17 Pro - Silver - Portrait.png"
# The bezel's screen, in its own pixels (1350×2760): the iPhone 17 Pro's 1206×2622 at 3×.
SCREEN = (72, 69, 1206, 2622)
SCREEN_RADIUS = 190
# The web page at iPhone size, in CSS pixels, under a status bar as tall as the Dynamic Island's.
PHONE_VIEW = (402, 820)
STATUS_BAR = 54
# A window that is not key, as macOS 26 draws it, in points: the traffic lights' middles, their
# size, and the corners' radius.
LIGHTS, LIGHT_Y, LIGHT_D, CORNER = (26, 49, 72), 26, 13, 19
LOGO = Path(__file__).resolve().parent.parent.parent / "docs/assets/logo.png"
FONT = "/System/Library/Fonts/SFNS.ttf"
TRADEMARK = "iPhone and Mac are trademarks of Apple Inc., registered in the U.S. and other countries."


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *map(str, args)], check=True)


def font(size, weight=None):
    f = ImageFont.truetype(FONT, size)
    if weight:
        try:
            f.set_variation_by_name(weight)
        except Exception:
            pass
    return f


# --- the still pictures ------------------------------------------------------------------
def backdrop(path):
    """A soft cobalt gradient, lighter at the top left, with a darker edge."""
    import numpy as np
    top, bottom = np.array((58, 98, 196), float), np.array((16, 32, 92), float)
    y, x = np.mgrid[0:H, 0:W]
    t = np.clip((x / W) * 0.45 + (y / H) * 0.75, 0, 1)[..., None]
    img = Image.fromarray((top + (bottom - top) * t).astype("uint8"))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse((-W * 0.2, -H * 0.5, W * 0.7, H * 0.7), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    img = Image.composite(Image.new("RGB", (W, H), (120, 160, 240)), img, glow)
    img.save(path)


def shadow(size, radius, path, blur=40, alpha=120, spread=20):
    w, h = size
    pad = blur * 3
    img = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle((pad - spread // 2, pad, pad + w + spread // 2, pad + h + spread),
                                          radius, fill=(0, 0, 20, alpha))
    img.filter(ImageFilter.GaussianBlur(blur)).save(path)
    return pad


def rounded_mask(size, radius, path):
    img = Image.new("L", size, 0)
    ImageDraw.Draw(img).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    img.save(path)


def status_bar(width_px, height_px, colour, path, dark_text):
    """9:41, signal, Wi-Fi and a full battery, as on Apple's own screenshots."""
    img = Image.new("RGB", (width_px, height_px), colour)
    d = ImageDraw.Draw(img)
    ink = (0, 0, 0) if dark_text else (255, 255, 255)
    s = height_px / 162
    d.text((int(150 * s), int(height_px * 0.56)), "9:41", font=font(int(52 * s), "Semibold"), fill=ink, anchor="mm")
    x, y = width_px - int(110 * s), int(height_px * 0.56)
    d.rounded_rectangle((x - 38 * s, y - 18 * s, x + 38 * s, y + 18 * s), 9 * s, outline=ink, width=max(2, int(3 * s)))
    d.rounded_rectangle((x - 32 * s, y - 12 * s, x + 32 * s, y + 12 * s), 5 * s, fill=ink)
    for i, hgt in enumerate((10, 16, 22, 28)):
        bx = width_px - int(300 * s) + i * int(14 * s)
        d.rounded_rectangle((bx, y + 14 * s - hgt * s, bx + 9 * s, y + 14 * s), 2, fill=ink)
    cx = width_px - int(205 * s)
    for r in (30, 20, 10):
        d.pieslice((cx - r * s, y + 12 * s - r * s, cx + r * s, y + 12 * s + r * s), 225, 315, fill=ink)
        d.pieslice((cx - (r - 6) * s, y + 12 * s - (r - 6) * s, cx + (r - 6) * s, y + 12 * s + (r - 6) * s), 225, 315,
                   fill=colour if r > 10 else ink)
    img.save(path)


def browser_bar(width_px, path, url="localhost:8792"):
    """A plain browser toolbar: three dots and an address."""
    h = 104
    img = Image.new("RGB", (width_px, h), (236, 238, 242))
    d = ImageDraw.Draw(img)
    for i, c in enumerate(((255, 95, 87), (254, 188, 46), (40, 200, 64))):
        d.ellipse((36 + i * 44, 38, 64 + i * 44, 66), fill=c)
    d.rounded_rectangle((width_px * 0.25, 22, width_px * 0.75, 82), 30, fill=(255, 255, 255))
    d.text((width_px * 0.5, 52), url, font=font(34), fill=(80, 84, 92), anchor="mm")
    img.save(path)
    return h


def end_card(path, phone):
    img = Image.open(path.parent / "backdrop.png").convert("RGBA")
    logo = Image.open(LOGO).convert("RGBA")
    logo.thumbnail((300, 300))
    img.alpha_composite(logo, ((W - logo.width) // 2, H // 2 - logo.height - 40))
    d = ImageDraw.Draw(img)
    d.text((W // 2, H // 2 + 50), "Agents", font=font(120, "Bold"), fill="white", anchor="mm")
    d.text((W // 2, H // 2 + 160), "Your coding agents, wherever you are.", font=font(52), fill=(220, 230, 255), anchor="mm")
    if phone:
        d.text((W // 2, H - 60), TRADEMARK, font=font(26), fill=(190, 205, 240), anchor="mm")
    img.convert("RGB").save(path)


# --- time ----------------------------------------------------------------------------------
class Timeline:
    """Maps recorded time to video time, with the fast spans cut short."""

    def __init__(self, marks, start, end):
        self.spans = []  # (from, to, speed)
        fast_from, most = None, None
        for name, at in marks:
            t = at - start
            if name.startswith("fast:"):
                fast_from, most = t, float(name.split(":")[1])
            elif name == "slow" and fast_from is not None:
                length = t - fast_from
                if length > most:
                    self.spans.append((fast_from, t, length / most))
                fast_from = None
        self.end = end

    def segments(self):
        """[(from, to, speed)] covering 0…end, in order."""
        out, at = [], 0.0
        for a, b, speed in self.spans:
            if a > at:
                out.append((at, a, 1.0))
            out.append((a, b, speed))
            at = b
        if self.end > at:
            out.append((at, self.end, 1.0))
        return out

    def __call__(self, t):
        video = 0.0
        for a, b, speed in self.segments():
            if t <= b:
                return video + (max(t, a) - a) / speed
            video += (b - a) / speed
        return video


# --- the composition ------------------------------------------------------------------------
def web_video(work, start, size, out):
    """The screencast frames as a 30 fps video starting at t=0 (the first frame held before)."""
    times = json.loads((work / "web/frames.json").read_text())
    frames = sorted((work / "web/frames").glob("*.jpg"))
    lines = []
    for i, path in enumerate(frames):
        next_time = times[i + 1] if i + 1 < len(times) else times[i] + 1.0
        lines.append(f"file '{path}'\nduration {max(0.001, next_time - times[i]):.4f}")
    lines.append(f"file '{frames[-1]}'")
    (work / "web/frames.txt").write_text("\n".join(lines) + "\n")
    lead = max(0.0, times[0] - start)
    ffmpeg("-f", "concat", "-safe", "0", "-i", work / "web/frames.txt",
           "-vf", f"scale={size[0]}:{size[1]}:flags=lanczos,fps={FPS},tpad=start_duration={lead:.3f}:start_mode=clone",
           "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", out)


def traffic_lights(scale, path):
    """The grey traffic lights of a window that is not key, on a clear picture as wide as them."""
    size = (round((LIGHTS[-1] + LIGHT_D) * scale), round((LIGHT_Y + LIGHT_D) * scale))
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    r = LIGHT_D * scale / 2
    for x in LIGHTS:
        cx, cy = x * scale, LIGHT_Y * scale
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(224, 226, 230, 255),
                     outline=(188, 190, 194, 255), width=max(1, round(scale / 2)))
    img.save(path)


def page_colour(work):
    first = sorted((work / "web/frames").glob("*.jpg"))[-1]
    img = Image.open(first).convert("RGB")
    return img.getpixel((img.width // 2, 2))


def compose(scene, takes, work, out_dir):
    data = json.loads((work / "marks.json").read_text())
    start, marks = data["mac_start"], data["marks"]
    end = next(at for name, at in marks if name == "end") - start
    art = work / "art"
    art.mkdir(exist_ok=True)
    backdrop(art / "backdrop.png")
    layout = getattr(scene, "LAYOUT", "mac")
    still = Image.open(work / "still.png").convert("RGBA")
    mac_w, mac_h = still.size

    inputs, graph = [art / "backdrop.png"], []
    loops = {0}

    def add(path, loop=True):
        inputs.append(path)
        if loop:
            loops.add(len(inputs) - 1)
        return len(inputs) - 1

    # Where everything goes.
    phone_h = 1240
    k = phone_h / 2760
    phone_w = round(1350 * k)
    if layout == "mac":
        box = (W - 320, H - 200)
        mac_x0 = None
    elif layout == "mac+phone":
        box = (W - phone_w - 3 * 110, H - 260)
        mac_x0 = 110
    else:  # mac+browser
        box = (1560, 1000)
        mac_x0 = 110
    scale = min(box[0] / mac_w, box[1] / mac_h)
    mw, mh = round(mac_w * scale / 2) * 2, round(mac_h * scale / 2) * 2
    mx = (W - mw) // 2 if mac_x0 is None else mac_x0
    my = (H - mh) // 2 if layout != "mac+browser" else 90

    # The window: its traffic lights drawn on, its corners cut, a shadow under it.
    traffic_lights(data.get("scale", 2), art / "lights.png")
    rounded_mask((mw, mh), round(CORNER * data.get("scale", 2) * scale), art / "mac-mask.png")
    pad = shadow((mw, mh), 26, art / "mac-shadow.png")
    i_mac = add(work / "mac.mov", loop=False)
    i_lights, i_mask, i_shadow = add(art / "lights.png"), add(art / "mac-mask.png"), add(art / "mac-shadow.png")
    graph += [
        f"[{i_mac}:v]fps={FPS},scale={mac_w}:{mac_h},format=rgba[mac0]",
        f"[mac0][{i_lights}:v]overlay=0:0[mac1]",
        f"[mac1]scale={mw}:{mh}:flags=lanczos,format=rgba[mac2]",
        f"[{i_mask}:v]format=gray[mmask]",
        f"[mac2][mmask]alphamerge[mac]",
        f"[0:v][{i_shadow}:v]overlay={mx - pad}:{my - pad}[s1]",
        f"[s1][mac]overlay={mx}:{my}:eof_action=repeat[s2]",
    ]
    last = "s2"

    if layout == "mac+phone":
        px, py = W - phone_w - 150, (H - phone_h) // 2
        sx, sy, sw, sh = (round(v * k) for v in SCREEN)
        bar_h = round(sh * STATUS_BAR / (STATUS_BAR + PHONE_VIEW[1]))
        page_h = (sh - bar_h) // 2 * 2
        bar_h = sh - page_h
        sw -= sw % 2
        web_video(work, start, (sw, page_h), work / "web.mp4")
        colour = page_colour(work)
        status_bar(sw, bar_h, colour, art / "status.png", dark_text=sum(colour) > 380)
        rounded_mask((sw, sh), round(SCREEN_RADIUS * k), art / "screen-mask.png")
        bezel = Image.open(BEZEL).resize((phone_w, phone_h), Image.LANCZOS)
        bezel.save(art / "bezel.png")
        i_web, i_status = add(work / "web.mp4", loop=False), add(art / "status.png")
        i_smask, i_bezel = add(art / "screen-mask.png"), add(art / "bezel.png")
        graph += [
            f"[{i_status}:v][{i_web}:v]vstack,format=rgba[scr0]",
            f"[{i_smask}:v]format=gray[smask]",
            f"[scr0][smask]alphamerge[scr]",
            f"[{last}][scr]overlay={px + sx}:{py + sy}:eof_action=repeat[p1]",
            f"[p1][{i_bezel}:v]overlay={px}:{py}[p2]",
        ]
        last = "p2"
    elif layout == "mac+browser":
        view_w, view_h = scene.BROWSER
        bw = 1500
        page_h = round(bw * view_h / view_w / 2) * 2
        bar = browser_bar(bw, art / "browser-bar.png")
        bh = bar + page_h
        web_video(work, start, (bw, page_h), work / "web.mp4")
        bx0, by0 = W - bw - 110, H - bh - 90
        rounded_mask((bw, bh), 24, art / "browser-mask.png")
        bpad = shadow((bw, bh), 24, art / "browser-shadow.png")
        i_web, i_bar = add(work / "web.mp4", loop=False), add(art / "browser-bar.png")
        i_bmask, i_bshadow = add(art / "browser-mask.png"), add(art / "browser-shadow.png")
        graph += [
            f"[{i_bar}:v][{i_web}:v]vstack,format=rgba[br0]",
            f"[{i_bmask}:v]format=gray[bmask]",
            f"[br0][bmask]alphamerge[br]",
            f"[{last}][{i_bshadow}:v]overlay={bx0 - bpad}:{by0 - bpad}[b1]",
            f"[b1][br]overlay={bx0}:{by0}:eof_action=repeat[b2]",
        ]
        last = "b2"

    # The fast spans, cut short.
    timeline = Timeline(marks, start, end)
    segments = timeline.segments()
    graph.append(f"[{last}]trim=0:{end:.3f},setpts=PTS-STARTPTS,split={len(segments)}" + "".join(f"[g{i}]" for i in range(len(segments))))
    for i, (a, b, speed) in enumerate(segments):
        graph.append(f"[g{i}]trim={a:.3f}:{b:.3f},setpts=(PTS-STARTPTS)/{speed:.4f},fps={FPS}[c{i}]")
    graph.append("".join(f"[c{i}]" for i in range(len(segments))) + f"concat=n={len(segments)}:v=1:a=0[cut]")
    length = timeline(end)

    # The scene fades in; the end card comes after, in a second pass (one graph that waits on
    # the card while it renders the scene stalls).
    end_card(art / "end.png", phone=layout == "mac+phone")
    card = 3.0
    graph.append(f"[cut]format=yuv420p,fps={FPS},settb=1/{FPS},fade=t=in:st=0:d=0.5[vout]")
    total = length - 0.8 + card + 1

    # The narration, each line at its marker.
    cues, audio = [], []
    for name, at in marks:
        if not name.startswith("say:"):
            continue
        key = name[4:]
        take = takes[key]
        t = timeline(at - start)
        cues.append((t, t + take["duration"], take["text"]))
        i = add(take["path"], loop=False)
        audio.append(f"[{i}:a]adelay={int(t * 1000)}:all=1[a{len(audio)}]")
    graph += audio
    graph.append("".join(f"[a{i}]" for i in range(len(audio))) +
                 f"amix=inputs={len(audio)}:normalize=0,apad,atrim=0:{length:.3f},loudnorm=I=-16:TP=-1.5,aresample=48000[aout]")

    args = []
    for i, path in enumerate(inputs):
        if i in loops:
            # A still lasts as long as the recording, so no stream waits for ever on it.
            args += ["-loop", "1", "-framerate", str(FPS), "-t", f"{end + card + 2:.3f}"]
        args += ["-i", path]
    out_dir.mkdir(parents=True, exist_ok=True)
    mp4 = out_dir / f"{scene.ID}.mp4"
    (work / "graph.txt").write_text(";\n".join(graph))
    encode = ["-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-r", str(FPS)]
    ffmpeg(*args, "-/filter_complex", work / "graph.txt", "-map", "[vout]", "-map", "[aout]",
           "-t", f"{length:.3f}", *encode, "-c:a", "pcm_s16le", work / "scene.mov")
    ffmpeg("-loop", "1", "-framerate", str(FPS), "-t", f"{card + 1}", "-i", art / "end.png",
           *encode, work / "end.mp4")
    ffmpeg("-i", work / "scene.mov", "-i", work / "end.mp4", "-filter_complex",
           f"[0:v]settb=1/{FPS}[a];[1:v]settb=1/{FPS}[b];"
           f"[a][b]xfade=transition=fade:duration=0.8:offset={length - 0.8:.3f}[v];[0:a]apad,atrim=0:{total:.3f}[s]",
           "-map", "[v]", "-map", "[s]", *encode, "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", mp4)
    write_vtt(cues, out_dir / f"{scene.ID}.vtt")
    check_overlaps(cues)
    return mp4


def write_vtt(cues, path):
    def stamp(t):
        h, rest = divmod(t, 3600)
        m, s = divmod(rest, 60)
        return f"{int(h):02}:{int(m):02}:{s:06.3f}"

    out = ["WEBVTT", ""]
    for n, (a, b, text) in enumerate(cues, 1):
        lines, line = [], ""
        for word in text.split():
            if len(line) + len(word) + 1 > 42 and line:
                lines.append(line)
                line = word
            else:
                line = f"{line} {word}".strip()
        lines.append(line)
        out += [str(n), f"{stamp(a)} --> {stamp(b)}", *lines, ""]
    path.write_text("\n".join(out))


def check_overlaps(cues):
    for (a1, b1, t1), (a2, _, t2) in zip(cues, cues[1:]):
        if a2 < b1 - 0.05:
            print(f"  warning: '{t2[:30]}…' starts {b1 - a2:.1f}s before '{t1[:30]}…' ends")
