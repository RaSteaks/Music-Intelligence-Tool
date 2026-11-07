"""One job, one JSON result. Native model logs never share the result channel."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from analysis_support import cut, mark


def acoustic_or_harmony(audio, kind, offset, duration, record=None):
    if kind == "harmony":
        from harmony_analysis import analyze_harmony
        return analyze_harmony(audio, offset, duration, record)

    import librosa
    import numpy as np

    y, sr = librosa.load(audio, sr=22050, mono=False)
    rows = []
    if not y.size:
        return {"marks": rows}
    loudness = []
    if kind == "acoustics":
        from audio_metrics import measure_audio
        metrics, loudness = measure_audio(audio)
        summary = mark("loudness", offset, offset + duration, "FFmpeg EBU R128 / PCM", "响度与动态统计", metrics)
        summary["fields"]["content"] = {"suggested": "仅统计此区间，保留原始声道和增益。峰均比与响度范围不同；满幅采样不等同于已听出失真。静音或不足测量窗口的指标留空。"}
        rows.append(summary)
    if np.max(np.abs(y)) < 1e-5:
        return {"marks": rows}
    hop = 512
    n_fft = 2048
    spectrum = np.abs(librosa.stft(y, n_fft=n_fft, hop_length=hop))**2
    # Average power rather than waveforms so anti-phase stereo does not vanish.
    if y.ndim == 2:
        spectrum = spectrum.mean(axis=0)
    times = np.arange(0, duration, 1.0)
    onset_envelope = librosa.onset.onset_strength(S=librosa.power_to_db(spectrum), sr=sr, hop_length=hop)
    attacks = librosa.onset.onset_detect(onset_envelope=onset_envelope, sr=sr, hop_length=hop, units="time")
    rows.extend(mark("onset", offset+t, offset+t, "librosa") for t in attacks if t < duration)
    frequencies = librosa.fft_frequencies(sr=sr)
    for t in times:
        piece = spectrum[:, int(t*sr/hop):int((t+1)*sr/hop)]
        if not piece.size:
            continue
        power = piece.mean(axis=1, dtype=np.float64)
        total = max(power.sum(), 1e-12)
        metrics = {"rms": np.sqrt(np.mean(y[..., int(t*sr):int((t+1)*sr)]**2)),
                   "low_share": power[frequencies < 250].sum()/total,
                   "mid_share": power[(frequencies >= 250) & (frequencies < 4000)].sum()/total,
                   "high_share": power[frequencies >= 4000].sum()/total,
                   "centroid_hz": np.average(frequencies, weights=np.sqrt(piece).mean(axis=1)+1e-12),
                   "onsets_per_s": np.sum((attacks >= t) & (attacks < t+1)) / min(1, duration-t)}
        levels = loudness[int(t*10):int((t+1)*10)]
        levels = [x for x in levels if x is not None]
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
    parser.add_argument("job", choices=["structure", "acoustics", "harmony", "rhythm", "repetition", "melody", "lyrics", "emotion", "events", "alignment"])
    for name in ("record", "output", "runtime"):
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
        elif args.job == "events":
            from activity_analysis import analyze_activity
            result = analyze_activity(source, start, end, record.get("stems", {}), scratch, record.get("bpm"))
        else:
            clip = scratch/"clip.wav"
            if args.job in ("lyrics", "alignment", "melody"):
                source = Path(record.get("stems", {}).get("vocals", source))
            if args.job == "acoustics":
                from audio_metrics import measurement_codec
                cut(source, clip, start, end-start, codec=measurement_codec(source))
            else:
                cut(source, clip, start, end-start)
            if args.job == "lyrics":
                result = lyrics(clip, start, end-start)
            elif args.job == "alignment":
                result = align(clip, start, record, end)
            elif args.job == "rhythm":
                from rhythm_analysis import analyze_rhythm
                result = analyze_rhythm(clip, start, end-start, record)
            elif args.job == "repetition":
                from repetition_analysis import analyze_repetition
                result = analyze_repetition(clip, end-start, record)
            elif args.job == "melody":
                from melody_analysis import analyze_melody
                result = analyze_melody(clip, start, end-start, "vocals" in record.get("stems", {}))
            else:
                result = acoustic_or_harmony(clip, args.job, start, end-start, record)
        Path(args.output).write_text(json.dumps(result, allow_nan=False), encoding="utf-8")


if __name__ == "__main__":
    main()
