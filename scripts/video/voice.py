"""The narration: Kokoro's built-in voice Heart, said from a directed script (#1078, #4964).

A scene's line is plain words, or a directed line: a small part of W3C SSML,

    <speak style="calm">Say what you want done.<break time="500ms"/>
      <prosody rate="92%">Here: fix the Celsius conversion,</prosody></speak>

- `<break time="…ms"/>`: a pause of that length.
- `<prosody rate="…%">`: slower or faster than the voice's own pace.
- `<emphasis>`: a stressed word. Kokoro cannot stress a word: it says it as written.
- `style` on `<speak>` (not SSML): the tone, `calm`, `warm` or `bright`. Kokoro has no tone,
  so a tone is only a pace (`STYLES`); the mark stays in the script for the next voice.

Each phrase between pauses is said on its own by Kokoro (Apache-2.0, through mlx-audio), the
pauses are silence, and the line is one file. Whisper (`mlx-whisper`) hears each line, which
must say its words (at most one in ten wrong), starting and ending on its first and last
words. Alex chose the voice Heart (2026-11-12, #4964). Each phrase is kept in the cache by its
text, voice and pace, so a phrase said once is not said again.
"""
import hashlib
import html
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

VOICE = "af_heart"
MODEL = "prince-canuma/Kokoro-82M"
SR = 24000
PACE = 0.95  # Heart's own pace is quick for a tutorial
STYLES = {"calm": 1.0, "warm": 1.0, "bright": 1.04}
MOST_WRONG = 0.1
WHISPER = "mlx-community/whisper-small.en-mlx"

_model = None


def directed(line):
    """The line as SSML: a plain line is one phrase."""
    line = line.strip()
    return line if line.startswith("<speak") else f"<speak>{html.escape(line, quote=False)}</speak>"


def pieces(line):
    """The line's phrases and pauses, in order: ("say", text, rate) and ("pause", seconds)."""
    root = ET.fromstring(directed(line))
    out = []

    def walk(el, rate):
        if el.tag == "prosody":
            rate *= float(el.get("rate", "100%").rstrip("%")) / 100
        if el.tag == "break":
            out.append(("pause", float(re.sub(r"[^0-9.]", "", el.get("time", "300ms"))) / 1000))
        elif el.text and el.text.strip():
            out.append(("say", el.text, rate))
        for child in el:
            walk(child, rate)
            if child.tail and child.tail.strip():
                out.append(("say", child.tail, rate))

    walk(root, STYLES.get(root.get("style", "calm"), 1.0))
    merged = []  # text either side of an <emphasis> is one phrase
    for piece in out:
        if piece[0] == "say" and merged and merged[-1][0] == "say" and merged[-1][2] == piece[2]:
            merged[-1] = ("say", merged[-1][1] + " " + piece[1], piece[2])
        else:
            merged.append(piece)
    return [("say", re.sub(r"\s+([.,:;!?])", r"\1", " ".join(p[1].split())), p[2]) if p[0] == "say" else p
            for p in merged]


def plain(line):
    """The words of a line, for the captions, Whisper and the video's description."""
    return " ".join(p[1] for p in pieces(line) if p[0] == "say")


def words(text):
    text = text.lower().replace("’", "'").replace("-", " ")
    return re.findall(r"[a-z0-9']+", text)


def joined(heard, script):
    """Whisper writes some words as two ("work tree", "check out"): join a pair back when the
    script has them as one."""
    wanted, out, i = set(script), [], 0
    while i < len(heard):
        if i + 1 < len(heard) and heard[i] + heard[i + 1] in wanted:
            out.append(heard[i] + heard[i + 1])
            i += 2
        else:
            out.append(heard[i])
            i += 1
    return out


def wrong(script, heard):
    """Word error rate of `heard` against `script`."""
    a = words(script)
    b = joined(words(heard), a)
    row = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        previous, row[0] = row[0], i
        for j in range(1, len(b) + 1):
            current = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] != b[j - 1]))
            previous = current
    return row[len(b)] / max(1, len(a))


def good(script, heard):
    a = words(script)
    b = joined(words(heard), a)
    return bool(b) and a[0] == b[0] and a[-1] == b[-1] and wrong(script, heard) <= MOST_WRONG


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True).stdout
    return float(out.strip())


def generate(text, path, rate):
    """One phrase in the voice, at PACE × rate, with the silence off both ends."""
    global _model
    import numpy as np
    import soundfile
    if _model is None:
        from mlx_audio.tts.utils import load_model
        _model = load_model(MODEL)
    audio = np.concatenate([np.array(r.audio) for r in _model.generate(
        text=text, voice=VOICE, speed=PACE * rate, lang_code=VOICE[0])])
    loud = np.nonzero(np.abs(audio) > 0.01)[0]
    soundfile.write(str(path), audio[loud[0]:loud[-1] + 1] if len(loud) else audio, SR)


def silence(seconds, path):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"anullsrc=r={SR}:cl=mono",
                    "-t", f"{seconds:.3f}", str(path)], check=True)


def hear(path):
    import mlx_whisper
    return mlx_whisper.transcribe(str(path), path_or_hf_repo=WHISPER)["text"].strip()


def speak(scene, cache):
    """Returns {key: {"path", "duration", "text", "heard", "wrong"}} for every line of the scene;
    "text" is the line's words, without its directions."""
    cache.mkdir(parents=True, exist_ok=True)
    chosen = {}
    for key, line in scene.LINES.items():
        tag = hashlib.sha1(f"{line}|{VOICE}|{PACE}".encode()).hexdigest()[:16]
        path, check = cache / f"line-{tag}.wav", cache / f"line-{tag}.json"
        text = plain(line)
        if not path.exists():
            parts = []
            for n, piece in enumerate(pieces(line)):
                if piece[0] == "pause":
                    part = cache / f"pause-{piece[1]:.3f}.wav"
                    if not part.exists():
                        silence(piece[1], part)
                else:
                    said = hashlib.sha1(f"{piece[1]}|{VOICE}|{PACE * piece[2]:.4f}".encode()).hexdigest()[:16]
                    part = cache / f"said-{said}.wav"
                    if not part.exists():
                        generate(piece[1], part, piece[2])
                parts.append(part)
            listing = cache / f"line-{tag}.txt"
            listing.write_text("".join(f"file '{p}'\n" for p in parts))
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(listing),
                            "-ar", str(SR), "-ac", "1", str(path)], check=True)
            listing.unlink()
        if not check.exists():
            heard = hear(path)
            check.write_text(json.dumps({"heard": heard, "wrong": wrong(text, heard)}))
        result = json.loads(check.read_text())
        print(f"  {key}: {result['wrong']:.0%} wrong: {result['heard']}", flush=True)
        if not good(text, result["heard"]):
            raise RuntimeError(f"the line {key!r} does not say its script (Whisper heard {result['heard']!r}): {text}")
        chosen[key] = {"path": str(path), "duration": duration(path), "text": text, **result}
    return chosen


def self_test():
    line = ('<speak style="calm">Say it.<break time="500ms"/><prosody rate="90%">Click '
            '<emphasis>New Session</emphasis>.</prosody></speak>')
    assert pieces(line) == [("say", "Say it.", 1.0), ("pause", 0.5), ("say", "Click New Session.", 0.9)], pieces(line)
    assert plain(line) == "Say it. Click New Session.", plain(line)
    assert pieces("Fix it & run the tests.") == [("say", "Fix it & run the tests.", 1.0)]
    assert pieces('<speak style="bright">Go.</speak>') == [("say", "Go.", STYLES["bright"])]
    print("voice self-test passed")


if __name__ == "__main__":
    self_test()
