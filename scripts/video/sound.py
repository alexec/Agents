"""The sound test (#4855): make.py fails a take whose track is wrong, and says which check failed.

1. **The words:** Whisper hears the tape's `speech.wav`, and its words agree with the sentences
   the app said (the tape's marks, and the walk's `{"cmd":"voice"}` → `said`): at most one word
   in ten different, after case and punctuation are taken out.
2. **The sounds at their marks:** the mixed track is louder than the floor in the 100 ms after
   each sound's mark, and quiet in the 100 ms before it (when nothing else plays there).
3. **Nothing else:** where no speech, no sound and no narration is, the track is silent.
4. **The length:** the video's track is as long as its frames, within one frame.

`frame.compose` writes `sound.json` (where each sentence, sound and narration line is in the
video's time); this reads it and the mixed track, `scene.mov`. A failed test keeps the video
in the take's folder, with `sound-test.json`, for a person to look at.

    scripts/video/make.sh --sound-self-test    a made-up track, right and then wrong
"""
import json
import subprocess
import tempfile
from pathlib import Path

FLOOR_DB = -50.0  # below it is silence
WINDOW = 0.1  # seconds after (and before) a sound's mark
BLOCK = 0.01  # the track is measured in blocks of this many seconds
RATE = 16000
EDGE = 0.03  # each span is this much wider at both ends, for the blocks it starts and ends in
THINK = "Let me think."  # the tape's sentence with no `said` (#3565)


class SoundTestFailed(RuntimeError):
    pass


def levels(path):
    """The track's level in dBFS, a value for each BLOCK (the loudest channel's RMS)."""
    import numpy
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-vn", "-ac", "1", "-ar", str(RATE),
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    samples = numpy.frombuffer(raw, dtype=numpy.float32)
    size = int(RATE * BLOCK)
    blocks = samples[:len(samples) // size * size].reshape(-1, size)
    rms = numpy.sqrt(numpy.mean(blocks.astype(numpy.float64) ** 2, axis=1))
    return 20 * numpy.log10(numpy.maximum(rms, 1e-10))


def loudest(db, start, end):
    a, b = max(0, int(start / BLOCK)), min(len(db), int(end / BLOCK + 0.999))
    return float(db[a:b].max()) if b > a else None


def stream_lengths(mp4):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,duration",
                          "-of", "json", str(mp4)], capture_output=True, text=True, check=True).stdout
    return {s["codec_type"]: float(s["duration"]) for s in json.loads(out)["streams"] if "duration" in s}


def words_check(work, failures):
    """Check 1: Whisper hears speech.wav and agrees with what the app said."""
    import voice
    tape = work / "voice/marks.json"
    speech = work / "voice/speech.wav"
    if not tape.exists():
        return None
    spoken = [m for m in json.loads(tape.read_text())["marks"] if "seconds" in m]
    sentences = [m["said"] or THINK for m in spoken]
    walk = work / "voice/said.json"
    if walk.exists():
        for line in json.loads(walk.read_text()):
            if line not in sentences:
                failures.append(f"words: the walk says the app said {line!r}, but the tape has no such sentence")
    if not sentences:
        return None
    script = " ".join(sentences)
    heard = voice.hear(sentences_only(speech, spoken, work / "voice/heard.wav")) if speech.exists() else ""
    off = voice.wrong(script, heard)
    if off > voice.MOST_WRONG:
        failures.append(f"words: Whisper hears {off:.0%} of the speech wrong (at most {voice.MOST_WRONG:.0%}): "
                        f"heard {heard!r}, the app said {script!r}")
    return {"said": script, "heard": heard, "wrong": off}


def sentences_only(speech, spoken, out):
    """speech.wav with only its sentences, a short gap between them: on the long silences
    between them Whisper hears words that are not there."""
    parts = [f"[0:a]atrim=start={m['t']:.4f}:duration={m['seconds']:.4f},asetpts=PTS-STARTPTS,apad=pad_dur=0.4[s{i}]"
             for i, m in enumerate(spoken)]
    parts.append("".join(f"[s{i}]" for i in range(len(spoken))) + f"concat=n={len(spoken)}:v=0:a=1[out]")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(speech), "-filter_complex", ";".join(parts),
                    "-map", "[out]", str(out)], check=True)
    return out


def test(work, mp4, fps, hear=True):
    """Runs the four checks on a composed take. Raises SoundTestFailed with each failure."""
    plan = json.loads((work / "sound.json").read_text())
    spans = plan["spans"]  # [{"kind": "narration"|"speech"|"sound", "from", "to", "name"}]
    db = levels(work / "scene.mov")
    failures, report = [], {"spans": spans}

    # 1. The words.
    if hear:
        report["words"] = words_check(work, failures)

    # 2. The sounds at their marks.
    def busy(start, end, but=None):
        return any(s is not but and s["from"] - EDGE < end and s["to"] + EDGE > start for s in spans)

    for span in (s for s in spans if s["kind"] == "sound"):
        t = span["from"]
        after = loudest(db, t, t + WINDOW)
        if after is None or after <= FLOOR_DB:
            failures.append(f"sound {span['name']} at {t:.2f}s: not heard in the {WINDOW * 1000:.0f} ms after its mark "
                            f"({after if after is None else round(after, 1)} dBFS)")
        if t >= WINDOW and not busy(t - WINDOW, t, but=span):
            before = loudest(db, t - WINDOW, t - EDGE)
            if before is not None and before > FLOOR_DB:
                failures.append(f"sound {span['name']} at {t:.2f}s: the track is not quiet in the {WINDOW * 1000:.0f} ms "
                                f"before its mark ({before:.1f} dBFS): it plays early, or something else does")

    # 3. Nothing else.
    loud = [i * BLOCK for i, level in enumerate(db) if level > FLOOR_DB and not busy(i * BLOCK, (i + 1) * BLOCK)]
    if loud:
        runs, first = [], loud[0]
        for a, b in zip(loud, loud[1:] + [None]):
            if b is None or b - a > BLOCK * 1.5:
                runs.append((first, a + BLOCK))
                first = b
        shown = ", ".join(f"{a:.2f}–{b:.2f}s" for a, b in runs[:5])
        failures.append(f"nothing else: the track is louder than {FLOOR_DB:.0f} dBFS where nothing should play: {shown}"
                        + (f" and {len(runs) - 5} more" if len(runs) > 5 else ""))
    report["unexpected"] = loud[:200]

    # 4. The length.
    lengths = stream_lengths(mp4)
    report["lengths"] = lengths
    if "audio" not in lengths or "video" not in lengths:
        failures.append(f"length: {mp4.name} has {', '.join(sorted(lengths)) or 'no'} streams with a length")
    elif abs(lengths["audio"] - lengths["video"]) > 1 / fps:
        failures.append(f"length: the track is {lengths['audio']:.3f}s and the frames {lengths['video']:.3f}s "
                        f"(more than one frame, {1 / fps:.3f}s, apart)")

    report["failures"] = failures
    (work / "sound-test.json").write_text(json.dumps(report, indent=1))
    if failures:
        raise SoundTestFailed("the sound test failed:\n  " + "\n  ".join(failures))
    return report


def self_test():
    """A made-up take: a track with a sound and a line, then the same with each fault in turn."""
    import frame
    import voice
    with tempfile.TemporaryDirectory(prefix="agents-sound-test-") as folder:
        work = Path(folder)
        pop = "/System/Library/Sounds/Pop.aiff"
        pop_length = voice.duration(pop)

        def take(sound_at, mark_at, noise_at=None, video=6.0, audio=6.0):
            parts = [f"[0:a]aformat=sample_rates=48000:channel_layouts=stereo,adelay={int(sound_at * 1000)}:all=1[s]"]
            inputs = ["-i", pop]
            mixed = "[s]"
            if noise_at is not None:
                inputs += ["-f", "lavfi", "-i", "sine=f=440:d=0.3:sample_rate=48000"]
                parts.append(f"[1:a]aformat=channel_layouts=stereo,adelay={int(noise_at * 1000)}:all=1[n]")
                parts.append("[s][n]amix=inputs=2:normalize=0[m]")
                mixed = "[m]"
            parts.append(f"{mixed}apad,atrim=0:{audio}[a]")
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", ";".join(parts),
                            "-map", "[a]", "-c:a", "pcm_s16le", str(work / "scene.mov")], check=True)
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"color=black:s=64x64:r=30:d={video}",
                            "-i", str(work / "scene.mov"), "-c:v", "libx264", "-c:a", "aac", str(work / "take.mp4")],
                           check=True)
            (work / "sound.json").write_text(json.dumps({"spans": [
                {"kind": "sound", "name": "Pop", "from": mark_at, "to": mark_at + pop_length}]}))

        def fails(what, **args):
            take(**args)
            try:
                test(work, work / "take.mp4", frame.FPS, hear=False)
            except SoundTestFailed as error:
                assert what in str(error), f"the test failed, but not for {what!r}: {error}"
                return next(line.strip() for line in str(error).splitlines() if what in line)
            raise AssertionError(f"the test did not catch {what!r}")

        take(sound_at=2.0, mark_at=2.0)
        test(work, work / "take.mp4", frame.FPS, hear=False)
        print("sound self-test: a right track passes")
        print("  caught:", fails("before its mark", sound_at=1.93, mark_at=2.0))
        print("  caught:", fails("not heard", sound_at=3.5, mark_at=2.0))
        print("  caught:", fails("nothing else", sound_at=2.0, mark_at=2.0, noise_at=4.5))
        print("  caught:", fails("length", sound_at=2.0, mark_at=2.0, video=6.0, audio=4.0))


if __name__ == "__main__":
    self_test()
