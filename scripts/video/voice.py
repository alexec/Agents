"""The narration: Chatterbox's default voice, two takes a line, each checked by Whisper (#1078).

The takes are exaggeration 0.65 and 0.85 (cfg 0.35 and 0.3), as Alex chose. A take is kept
only when Whisper hears the script's words in it (at most one word in ten wrong), starting and
ending on the script's own first and last words, so a swallowed word at either end fails it. A marketing
scene prefers the livelier take and a usage scene the calmer one, when both pass. A line with
no good take is tried again with new seeds, and the scene stops if none passes.

Takes are kept in the cache by their text and settings, so a line said once is not said again.
"""
import hashlib
import json
import re
import subprocess
from pathlib import Path

TAKES = [(0.65, 0.35), (0.85, 0.3)]
TRIES = 4
MOST_WRONG = 0.1
WHISPER = "mlx-community/whisper-small.en-mlx"

_model = None


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


def generate(text, path, exaggeration, cfg, seed):
    global _model
    import torch
    import torchaudio
    from chatterbox.tts import ChatterboxTTS
    if _model is None:
        _model = ChatterboxTTS.from_pretrained(device="mps" if torch.backends.mps.is_available() else "cpu")
    torch.manual_seed(seed)
    wav = _model.generate(text, exaggeration=exaggeration, cfg_weight=cfg, temperature=0.8)
    raw = path.with_suffix(".raw.wav")
    torchaudio.save(str(raw), wav, _model.sr)
    # Silence off both ends, so a line starts on its marker.
    trim = "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(raw), "-af", trim, str(path)], check=True)
    raw.unlink()


def hear(path):
    import mlx_whisper
    return mlx_whisper.transcribe(str(path), path_or_hf_repo=WHISPER)["text"].strip()


def speak(scene, cache):
    """Returns {key: {"path", "duration", "text", "heard", "wrong"}} for every line of the scene."""
    cache.mkdir(parents=True, exist_ok=True)
    lively = getattr(scene, "GROUP", "usage") == "marketing"
    chosen = {}
    for key, text in scene.LINES.items():
        passed = []
        for attempt in range(TRIES):
            for n, (exaggeration, cfg) in enumerate(TAKES):
                seed = 1 + n + 2 * attempt
                tag = hashlib.sha1(f"{text}|{exaggeration}|{cfg}|{seed}".encode()).hexdigest()[:16]
                path = cache / f"{tag}.wav"
                check = cache / f"{tag}.json"
                if not path.exists():
                    generate(text, path, exaggeration, cfg, seed)
                if not check.exists():
                    heard = hear(path)
                    check.write_text(json.dumps({"heard": heard, "wrong": wrong(text, heard)}))
                result = json.loads(check.read_text())
                take = {"path": str(path), "duration": duration(path), "text": text,
                        "exaggeration": exaggeration, **result}
                print(f"  {key} take {n + 1} (exaggeration {exaggeration}): {result['wrong']:.0%} wrong: {result['heard']}", flush=True)
                if good(text, result["heard"]):
                    passed.append(take)
            if passed:
                break
        if not passed:
            raise RuntimeError(f"no take of {key!r} says its script: {text}")
        passed.sort(key=lambda t: -t["exaggeration"] if lively else t["exaggeration"])
        chosen[key] = passed[0]
    return chosen
