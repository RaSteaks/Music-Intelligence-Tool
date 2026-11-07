"""Beat-synchronous chord candidates and profile-based regional tonality."""
import math

from analysis_support import mark, spectrum

NAMES = "C C# D Eb E F F# G Ab A Bb B".split()
QUALITIES = [("", [0, 4, 7]), ("m", [0, 3, 7]), ("7", [0, 4, 7, 10]),
             ("maj7", [0, 4, 7, 11]), ("m7", [0, 3, 7, 10]), ("dim", [0, 3, 6]),
             ("aug", [0, 4, 8]), ("sus2", [0, 2, 7]), ("sus4", [0, 5, 7])]


def key_candidate(chroma):
    import numpy as np
    profiles = np.array([[6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
                         [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]])
    if not chroma.size or np.std(chroma) < 1e-6:
        return None
    scores = sorted([(float(np.corrcoef(np.roll(profile, root), chroma)[0, 1]), root, mode)
                     for mode, profile in enumerate(profiles) for root in range(12)], reverse=True)
    best = scores[0]
    if not math.isfinite(best[0]) or best[0] < .5 or best[0] - scores[1][0] < .03:
        return None
    return best[1], best[2], best[0], best[0] - scores[1][0]


def analyze_harmony(audio, offset, duration, record=None):
    import librosa
    import numpy as np
    from scipy.signal import find_peaks

    hop, n_fft = 512, 4096
    y, sr, power = spectrum(audio, hop=hop, n_fft=n_fft)
    if np.max(np.abs(y)) < 1e-5:
        return {"marks": [], "key": None}
    chroma = librosa.feature.chroma_stft(S=power, sr=sr, n_fft=n_fft, hop_length=hop)
    rms = librosa.feature.rms(S=np.sqrt(power), frame_length=n_fft, hop_length=hop)[0]
    active = rms >= max(1e-4, float(rms.max()) * .001)
    global_key = key_candidate(chroma[:, active].mean(axis=1)) if np.any(active) else None
    saved = (record or {}).get("marks", [])
    beats = sorted({row["start"] - offset for row in saved if row["kind"] == "beat" and offset < row["start"] < offset + duration})
    if len(beats) < 2:
        beats = sorted({row["start"] - offset for row in saved if row["kind"] == "rhythm_beat" and offset < row["start"] < offset + duration})
    synchronized = len(beats) >= 2
    boundaries = [0] + (beats if synchronized else list(np.arange(.5, duration, .5))) + [duration]
    templates, metadata = [], []
    for root in range(12):
        for quality, intervals in QUALITIES:
            notes = [(root + step) % 12 for step in intervals]
            vector = np.zeros(12); vector[notes] = 1 / np.sqrt(len(notes))
            templates.append(vector); metadata.append((root, quality, notes))
    templates = np.array(templates)
    windows, scores, basses = [], [], []
    frequencies = librosa.fft_frequencies(sr=sr, n_fft=n_fft)
    for lo, hi in zip(boundaries, boundaries[1:]):
        a, b = int(lo * sr / hop), min(chroma.shape[1], max(int(hi * sr / hop), int(lo * sr / hop) + 1))
        if hi - lo < .08 or a >= b or np.mean(active[a:b]) < .5:
            windows.append((lo, hi)); scores.append(np.zeros(len(templates))); basses.append(None); continue
        energy = chroma[:, a:b].mean(axis=1)
        similarities = templates @ (energy / max(np.linalg.norm(energy), 1e-12))
        average = power[:, a:b].mean(axis=1)
        peaks, _ = find_peaks(average)
        low = [p for p in peaks if 50 <= frequencies[p] <= 350 and average[p] > average.max() * .06]
        bass = int(round(librosa.hz_to_midi(frequencies[min(low)]))) % 12 if low else None
        # A small bass prior resolves suspended-chord root ambiguities; it is
        # too small to turn a poor pitch-class match into a valid chord.
        similarities += np.array([.035 if bass == root else 0 for root, _, _ in metadata])
        windows.append((lo, hi)); scores.append(similarities); basses.append(bass)
    scores = np.array(scores)
    if not len(scores):
        return {"marks": [], "key": None}
    # Uniform transition penalty can be evaluated without an N x N matrix.
    previous = scores[0].copy(); back = []
    for emission in scores[1:]:
        best = int(np.argmax(previous))
        change = previous[best] - .08
        parents = np.where(previous >= change, np.arange(len(previous)), best)
        previous = emission + np.maximum(previous, change)
        back.append(parents)
    state = int(np.argmax(previous)); path = [state]
    for parents in reversed(back):
        state = int(parents[state]); path.append(state)
    path.reverse()
    rows = []
    for index, ((lo, hi), state) in enumerate(zip(windows, path)):
        ranked = np.argsort(scores[index])[::-1]
        score = float(scores[index, state])
        margin = score - float(np.max(np.delete(scores[index], state)))
        if score < .72 or state != ranked[0] or margin < .018:
            continue
        root, quality, notes = metadata[state]
        bass = basses[index]
        label = NAMES[root] + quality
        if bass is not None and bass in notes and bass != root:
            label += "/" + NAMES[bass]
        metrics = {"template_similarity": min(1, score), "template_margin": margin,
                   "root_pc": root, "beat_synchronized": float(synchronized)}
        if rows and rows[-1]["fields"]["label"]["suggested"] == label and abs(rows[-1]["end"] - (offset + lo)) < 1e-6:
            rows[-1]["end"] = offset + hi
            for key in ("template_similarity", "template_margin"):
                rows[-1]["metrics"][key] = min(rows[-1]["metrics"][key], metrics[key])
        else:
            row = mark("chord", offset + lo, offset + hi, "librosa Chroma / temporal decoding", label, metrics)
            if global_key:
                tonic, mode, _, _ = global_key
                major = ["I", "♭II", "II", "♭III", "III", "IV", "♯IV", "V", "♭VI", "VI", "♭VII", "VII"]
                minor = ["I", "♭II", "II", "III", "♯III", "IV", "♯IV", "V", "VI", "♯VI", "VII", "♯VII"]
                degree = (minor if mode else major)[(root - tonic) % 12]
                if quality in ("m", "m7", "dim"): degree = degree.lower()
                row["fields"]["degree"] = {"suggested": degree + ("°" if quality == "dim" else "7" if "7" in quality else "")}
            row["fields"]["content"] = {"suggested": "大小三和弦、七和弦、减／增三和弦及挂留候选；低音用于转位线索。匹配分数不是准确率，和声功能依赖调性候选。"}
            rows.append(row)
    key_label = None
    if global_key:
        root, mode, score, margin = global_key
        key_label = NAMES[root] + (" minor" if mode else " major")
        full = record is None or (offset == 0 and duration >= record.get("duration", duration))
        rows.append(mark("key" if full else "key_region", offset, offset + duration, "librosa key profile", key_label,
                         {"profile_correlation": score, "profile_margin": margin}))
    regions = [(max(offset, row["start"]), min(offset + duration, row["end"])) for row in saved if row["kind"] == "section"]
    regions = [(lo, hi) for lo, hi in regions if hi - lo >= 4]
    if len(regions) < 2:
        regions = [(offset + t, offset + min(duration, t + 8)) for t in np.arange(0, duration, 8) if min(duration, t + 8) - t >= 4]
    previous_region = None
    for lo, hi in regions:
        a, b = int((lo - offset) * sr / hop), min(chroma.shape[1], int((hi - offset) * sr / hop))
        valid = active[a:b]
        estimate = key_candidate(chroma[:, a:b][:, valid].mean(axis=1)) if np.any(valid) else None
        if not estimate: previous_region = None; continue
        root, mode, score, margin = estimate
        label = NAMES[root] + (" minor" if mode else " major")
        region = mark("key_region", lo, hi, "librosa key profile", label, {"profile_correlation": score, "profile_margin": margin})
        rows.append(region)
        if previous_region and abs(previous_region["end"] - lo) < .1 and previous_region["fields"]["label"]["suggested"] != label and min(previous_region["metrics"]["profile_margin"], margin) >= .08:
            change = mark("modulation", lo, hi, "regional key comparison", "调性变化候选", {"resolution_s": hi - lo})
            change["fields"]["content"] = {"suggested": previous_region["fields"]["label"]["suggested"] + " → " + label + "；变化可能位于此窗口内，须试听核对，不能视为精确转调落点。"}
            rows.append(change)
        previous_region = region
    return {"marks": rows, "key": key_label}
