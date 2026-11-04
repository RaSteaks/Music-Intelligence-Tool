"""One job, one JSON result. Native model logs never share the result channel."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


def mark(kind, start, end, source, label=None, metrics=None):
    return {
        "id": str(uuid.uuid4()), "kind": kind, "start": float(start), "end": float(end),
        "source": source, "startConfirmed": False, "endConfirmed": False,
        "fields": {"label": {"suggested": label}} if label else {},
        "metrics": {k: float(v) for k, v in (metrics or {}).items() if math.isfinite(v)},
    }


def cut(source, output, start, length):
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", str(start),
                    "-i", str(source), "-t", str(length), "-vn", "-c:a", "pcm_f32le", str(output)], check=True)


def acoustic_or_harmony(audio, kind, offset, duration):
    import librosa
    import numpy as np

    y, sr = librosa.load(audio, sr=22050)
    rows = []
    if not len(y) or np.max(np.abs(y)) < 1e-5:
        return {"marks": rows}
    hop = 512
    times = np.arange(0, duration, 1.0)
    if kind == "harmony":
        chroma = librosa.feature.chroma_stft(y=y, sr=sr, hop_length=hop)
        names = "C C# D Eb E F F# G Ab A Bb B".split()
        profiles = np.array([[6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
                             [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]])
        key_scores = [(np.corrcoef(np.roll(profile, i), chroma.mean(axis=1))[0, 1],
                       names[i] + (" minor" if mode else " major"))
                      for mode, profile in enumerate(profiles) for i in range(12)]
        templates = []
        for i, name in enumerate(names):
            for third, suffix in ((4, ""), (3, "m")):
                vector = np.zeros(12)
                vector[[i, (i + third) % 12, (i + 7) % 12]] = 1 / np.sqrt(3)
                templates.append((vector, name + suffix))
        for t in times:
            frame = chroma[:, int(t*sr/hop):max(int((t+1)*sr/hop), int(t*sr/hop)+1)]
            if not frame.size:
                continue
            energy = frame.mean(axis=1)
            scores = sorted([(np.dot(energy, v) / max(np.linalg.norm(energy), 1e-9), n)
                             for v, n in templates], reverse=True)
            if scores[0][0] < .65 or scores[0][0] - scores[1][0] < .025:
                continue
            end = offset + min(duration, t + 1)
            if rows and rows[-1]["fields"]["label"]["suggested"] == scores[0][1] and rows[-1]["end"] == offset+t:
                rows[-1]["end"] = end
            else:
                rows.append(mark("chord", offset+t, end, "librosa", scores[0][1]))
        valid = [pair for pair in key_scores if math.isfinite(pair[0])]
        return {"marks": rows, "key": max(valid)[1] if valid and max(valid)[0] > .4 else None}

    # EBU R128 on the original channels; do not normalize or downmix before measuring loudness.
    output = subprocess.check_output(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(audio),
                                      "-af", "ebur128=metadata=1,ametadata=print:key=lavfi.r128.S:file=-",
                                      "-f", "null", "-"], text=True)
    loudness = [float(line.split("=")[1]) for line in output.splitlines() if line.startswith("lavfi.r128.S=")]
    attacks = librosa.onset.onset_detect(y=y, sr=sr, hop_length=hop, units="time")
    rows.extend(mark("onset", offset+t, offset+t, "librosa") for t in attacks if t < duration)
    frequencies = librosa.fft_frequencies(sr=sr)
    spectrum = np.abs(librosa.stft(y, hop_length=hop))
    for t in times:
        piece = spectrum[:, int(t*sr/hop):int((t+1)*sr/hop)]
        if not piece.size:
            continue
        power = (piece**2).mean(axis=1)
        total = max(power.sum(), 1e-12)
        metrics = {"rms": np.sqrt(np.mean(y[int(t*sr):int((t+1)*sr)]**2)),
                   "low_share": power[frequencies < 250].sum()/total,
                   "mid_share": power[(frequencies >= 250) & (frequencies < 4000)].sum()/total,
                   "high_share": power[frequencies >= 4000].sum()/total,
                   "centroid_hz": np.average(frequencies, weights=piece.mean(axis=1)+1e-12),
                   "onsets_per_s": np.sum((attacks >= t) & (attacks < t+1)) / min(1, duration-t)}
        levels = loudness[int(t*10):int((t+1)*10)]
        levels = [x for x in levels if x > -119]
        if levels:
            metrics["short_lufs"] = np.mean(levels)
        rows.append(mark("acoustic", offset+t, offset+min(duration, t+1), "FFmpeg/librosa", metrics=metrics))
    return {"marks": rows}


def structure(source, cache, runtime, duration):
    cli = runtime / ".venv-structure/bin/allin1-mlx"
    if not cli.is_file():
        raise RuntimeError("请先运行 script/setup.sh models 安装结构分析模型")
    demix = cache / "demix"
    out = cache / "structure"
    subprocess.run([str(cli), str(source), "--out-dir", str(out), "--demix-dir", str(demix),
                    "--spec-dir", str(cache/"spec"), "--keep-byproducts", "--no-multiprocess",
                    "--no-mlx-in-memory"], cwd=cache, check=True)
    data = json.loads((out / (source.stem + ".json")).read_text())
    rows = [mark("section", s["start"], min(s["end"], duration), "All-In-One", s["label"])
            for s in data["segments"] if 0 <= s["start"] < min(s["end"], duration)]
    for kind, key in (("beat", "beats"), ("downbeat", "downbeats")):
        previous = None
        for t in data[key]:
            if 0 <= t < duration:
                metrics = {"local_bpm": 60/(t-previous)} if kind == "beat" and previous is not None and t > previous else {}
                rows.append(mark(kind, t, t, "All-In-One", metrics=metrics))
                previous = t
    stems = {p.stem: str(p) for p in demix.rglob("*.wav") if p.stem in ("vocals", "bass", "drums", "other")}
    return {"marks": rows, "bpm": data.get("bpm") or None, "stems": stems}


def lyrics(audio, start, duration):
    import whisper
    result = whisper.load_model(os.getenv("MIT_WHISPER_MODEL", "base"), device="cpu").transcribe(
        str(audio), fp16=False, verbose=False, condition_on_previous_text=False)
    rows = []
    for line in result["segments"]:
        text = line["text"].strip()
        if text and line.get("no_speech_prob", 0) < .6 and line["start"] < min(line["end"], duration):
            rows.append(mark("lyric", start + line["start"], start + min(duration, line["end"]), "Whisper", text))
    return {"marks": rows}


def align(audio, start, record, end):
    import whisperx
    rows = []
    lines = []
    for row in record["marks"]:
        if row["kind"] != "lyric" or row["start"] < start or row["end"] > end:
            continue
        field = row["fields"].get("label", {})
        text = field.get("confirmed", field.get("suggested", "")).strip()
        if text:
            lines.append({"start": row["start"]-start, "end": row["end"]-start, "text": text})
    if not lines:
        return {"marks": []}
    text = "".join(x["text"] for x in lines)
    language = os.getenv("MIT_LYRIC_LANGUAGE") or ("zh" if any("\u4e00" <= c <= "\u9fff" for c in text) else "en")
    model, meta = whisperx.load_align_model(language_code=language, device="cpu")
    result = whisperx.align(lines, model, meta, whisperx.load_audio(str(audio)), "cpu")
    for word in result["word_segments"]:
        if "start" in word and "end" in word:
            rows.append(mark("word", start + word["start"], start + word["end"], "WhisperX", word["word"]))
    return {"marks": rows}


def emotions(source, start, end, runtime, scratch, sections):
    repo = runtime / ".models/Music2Emotion"
    if not repo.is_dir():
        raise RuntimeError("请先运行 script/setup.sh models 安装 Music2Emo")
    # Upstream cleans ./temp_out and ./output. Run it only in our private temporary directory.
    for name in ("inference", "saved_models"):
        (scratch/name).symlink_to(repo/name, target_is_directory=True)
    os.chdir(scratch)
    sys.path.insert(0, str(repo))
    from music2emo import Music2emo
    model = Music2emo()
    rows = []
    for lo, hi in sections or [(start, end)]:
        t, hi = max(lo, start), min(hi, end)
        while t < hi:
            stop = min(t + 30, hi)
            if stop-t < 1:
                break
            clip = scratch/"window.wav"
            cut(source, clip, t, stop-t)
            values = model.predict(str(clip))
            label = "、".join(values["predicted_moods"][:2])
            rows.append(mark("emotion", t, stop, "Music2Emo", label,
                             {"valence": values["valence"], "arousal": values["arousal"]}))
            t = stop
    return {"marks": rows}


def main():
    parser = argparse.ArgumentParser()
    for name in ("job", "record", "output", "runtime"):
        parser.add_argument(name)
    parser.add_argument("start", type=float)
    parser.add_argument("end", type=float)
    args = parser.parse_args()
    record = json.loads(Path(args.record).read_text())
    cache = Path(args.record).parent
    source = Path(record["path"])
    runtime = Path(args.runtime).resolve()
    start, end = args.start, args.end
    with tempfile.TemporaryDirectory(dir=cache) as temp:
        scratch = Path(temp)
        if args.job == "structure":
            result = structure(source, cache, runtime, record["duration"])
        elif args.job == "emotion":
            sections = [(r["start"], r["end"]) for r in record["marks"] if r["kind"] == "section"]
            result = emotions(source, start, end, runtime, scratch, sections)
        else:
            clip = scratch/"clip.wav"
            if args.job in ("lyrics", "alignment"):
                source = Path(record.get("stems", {}).get("vocals", source))
            cut(source, clip, start, end-start)
            if args.job == "lyrics":
                result = lyrics(clip, start, end-start)
            elif args.job == "alignment":
                result = align(clip, start, record, end)
            else:
                result = acoustic_or_harmony(clip, args.job, start, end-start)
        Path(args.output).write_text(json.dumps(result, allow_nan=False), encoding="utf-8")


if __name__ == "__main__":
    main()
