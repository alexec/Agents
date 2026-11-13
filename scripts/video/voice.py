"""The narration: Qwen3-TTS's built-in speaker Aiden, said from a directed script (#1078, #4964, #5079).

A scene's line is plain words, or a directed line: a small part of W3C SSML,

    <speak style="calm">Say what you want done.<break time="500ms"/>
      <prosody rate="92%">Here: fix the Celsius conversion,</prosody></speak>

- `<break time="…ms"/>`: a pause of that length, as silence between phrases said apart.
- `<prosody rate="…%">`: slower or faster. A slow rate tells the voice "a little slower".
- `<emphasis>`: a stressed word. The voice is told to stress it.
- `style` on `<speak>` (not SSML): the tone, `calm`, `warm` or `bright`. The voice is told it.

Each phrase between pauses is said on its own by Qwen3-TTS CustomVoice 1.7B (Apache-2.0,
through mlx-audio) as the speaker Aiden, with an instruction made from the marks (`instruct`).
Alex chose Aiden (2026-11-12, spike #5062). The model samples, so each phrase is said with a
seed from its text, and Whisper (`mlx-whisper`) hears it: a phrase that does not say its words
is said again with the next seed, at most TRIES times in all, and then the take fails. Whisper
then hears each whole line, which must say its words (at most one in ten wrong), starting and
ending on its first and last words. Each phrase is kept in the cache by its text, speaker and
instruction, so a phrase said once is not said again.
"""
import hashlib
import html
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"  # about 4 GB, Apache-2.0
SPEAKER = "aiden"
SR = 24000
TEMPERATURE = 0.7
TRIES = 3
TONES = {
    "calm": "Calm, clear and friendly, like a patient teacher.",
    "warm": "Warm and welcoming, smiling as you speak.",
    "bright": "Bright, upbeat and lively.",
}
SLOW = 0.97  # a rate under this is "a little slower"
MOST_WRONG = 0.1
WHISPER = "mlx-community/whisper-small.en-mlx"

_model = None


def directed(line):
    """The line as SSML: a plain line is one phrase."""
    line = line.strip()
    return line if line.startswith("<speak") else f"<speak>{html.escape(line, quote=False)}</speak>"


def tidy(text):
    return re.sub(r"\s+([.,:;!?])", r"\1", " ".join(text.split()))


def pieces(line):
    """The line's phrases and pauses, in order: ("say", text, instruction) and ("pause", seconds)."""
    root = ET.fromstring(directed(line))
    tone = root.get("style", "calm")
    if tone not in TONES:
        raise ValueError(f"unknown style {tone!r} (one of {', '.join(TONES)}): {line}")
    out = []  # ("say", text, rate, [stressed]) before the merge

    def walk(el, rate):
        if el.tag == "prosody":
            rate *= float(el.get("rate", "100%").rstrip("%")) / 100
        if el.tag == "break":
            out.append(("pause", float(re.sub(r"[^0-9.]", "", el.get("time", "300ms"))) / 1000))
        elif el.text and el.text.strip():
            out.append(("say", el.text, rate, [tidy(el.text)] if el.tag == "emphasis" else []))
        for child in el:
            walk(child, rate)
            if child.tail and child.tail.strip():
                out.append(("say", child.tail, rate, []))

    walk(root, 1.0)
    merged = []  # text either side of an <emphasis> is one phrase
    for piece in out:
        if piece[0] == "say" and merged and merged[-1][0] == "say" and merged[-1][2] == piece[2]:
            merged[-1] = ("say", merged[-1][1] + " " + piece[1], piece[2], merged[-1][3] + piece[3])
        else:
            merged.append(piece)
    return [("say", tidy(p[1]), instruct(tone, p[2], p[3])) if p[0] == "say" else p for p in merged]


def instruct(tone, rate, stressed):
    """What the voice is told for one phrase: its tone, its pace and its stressed words."""
    out = TONES[tone]
    if rate < SLOW:
        out += " A little slower than usual."
    if stressed:
        out += " Stress the words " + ", ".join(f"'{w}'" for w in stressed) + "."
    return out


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


def missing():
    """Why the voice cannot speak on this Mac yet, or None: its weights are not in the
    Hugging Face cache (`fetch` gets them)."""
    from huggingface_hub import snapshot_download
    try:
        snapshot_download(MODEL, local_files_only=True)
    except Exception:
        return f"the voice's weights ({MODEL}, about 4 GB) are not in the cache: scripts/video/make.sh fetches them"
    return None


def fetch():
    """The voice's weights into the Hugging Face cache, once."""
    if missing():
        from huggingface_hub import snapshot_download
        print(f"fetching the voice's weights ({MODEL}, about 4 GB), once", flush=True)
        snapshot_download(MODEL)


def generate(text, instruction, path, seed):
    """One phrase as Aiden, with the silence off both ends."""
    global _model
    import mlx.core as mx
    import numpy as np
    import soundfile
    if _model is None:
        from mlx_audio.tts.utils import load_model
        _model = load_model(MODEL)
    mx.random.seed(seed)
    audio = np.concatenate([np.array(r.audio) for r in _model.generate_custom_voice(
        text=text, speaker=SPEAKER, language="English", instruct=instruction, temperature=TEMPERATURE)])
    loud = np.nonzero(np.abs(audio) > 0.01)[0]
    soundfile.write(str(path), (audio[loud[0]:loud[-1] + 1] if len(loud) else audio).astype(np.float32), SR)


def said(text, instruction, path):
    """The phrase in `path`, said again with the next seed while Whisper does not hear its
    words, at most TRIES times."""
    base = int(hashlib.sha1(f"{text}|{instruction}".encode()).hexdigest()[:8], 16)
    heard = ""
    for attempt in range(TRIES):
        generate(text, instruction, path, base + attempt)
        heard = hear(path)
        if good(text, heard):
            return
        print(f"    said again ({attempt + 1} of {TRIES} heard {heard!r}): {text}", flush=True)
    path.unlink()
    raise RuntimeError(f"the phrase {text!r} was not heard in {TRIES} tries (last heard {heard!r})")


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
    voice = f"{MODEL}|{SPEAKER}|{TEMPERATURE}"
    chosen = {}
    for key, line in scene.LINES.items():
        tag = hashlib.sha1(f"{line}|{voice}".encode()).hexdigest()[:16]
        path, check = cache / f"line-{tag}.wav", cache / f"line-{tag}.json"
        text = plain(line)
        if not path.exists():
            parts = []
            for piece in pieces(line):
                if piece[0] == "pause":
                    part = cache / f"pause-{piece[1]:.3f}.wav"
                    if not part.exists():
                        silence(piece[1], part)
                else:
                    name = hashlib.sha1(f"{piece[1]}|{piece[2]}|{voice}".encode()).hexdigest()[:16]
                    part = cache / f"said-{name}.wav"
                    if not part.exists():
                        said(piece[1], piece[2], part)
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
    calm = TONES["calm"]
    line = ('<speak style="calm">Say it.<break time="500ms"/><prosody rate="90%">Click '
            '<emphasis>New Session</emphasis>.</prosody></speak>')
    assert pieces(line) == [
        ("say", "Say it.", calm), ("pause", 0.5),
        ("say", "Click New Session.", calm + " A little slower than usual. Stress the words 'New Session'."),
    ], pieces(line)
    assert plain(line) == "Say it. Click New Session.", plain(line)
    assert pieces("Fix it & run the tests.") == [("say", "Fix it & run the tests.", calm)]
    assert pieces('<speak style="bright">Go.</speak>') == [("say", "Go.", TONES["bright"])]
    assert pieces('<speak style="warm">Your <emphasis>first</emphasis> agent.</speak>') == [
        ("say", "Your first agent.", TONES["warm"] + " Stress the words 'first'.")]
    try:
        pieces('<speak style="angry">No.</speak>')
    except ValueError:
        pass
    else:
        raise AssertionError("an unknown style must fail")
    assert good("Send it,", "Send it.") and not good("Send it,", "Ascend it.")
    print("voice self-test passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--fetch"]:
        fetch()
    else:
        self_test()
