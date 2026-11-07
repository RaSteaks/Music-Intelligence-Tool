"""Time-ordered segment similarity using chroma and timbral DTW."""
from analysis_support import mark, spectrum


def analyze_repetition(audio, duration, record):
    import librosa
    import numpy as np
    from scipy.ndimage import zoom
    from scipy.spatial.distance import cdist

    hop = 512
    _, sr, power = spectrum(audio, hop=hop)
    chroma = librosa.feature.chroma_stft(S=power, sr=sr, n_fft=4096, hop_length=hop)
    mel = librosa.feature.melspectrogram(S=power, sr=sr, n_fft=4096, hop_length=hop)
    mfcc = librosa.feature.mfcc(S=librosa.power_to_db(mel), n_mfcc=13)[1:]
    mfcc = (mfcc - mfcc.mean(axis=1, keepdims=True)) / np.maximum(mfcc.std(axis=1, keepdims=True), 1)
    sections = sorted([row for row in record.get("marks", []) if row["kind"] == "section" and row["end"]-row["start"] >= 2], key=lambda row: row["start"])
    warnings = []
    if len(sections) < 2:
        window = max(min(8, max(2, duration/2)), duration/50)
        sections = [{"start": float(t), "end": float(min(duration, t + window))} for t in np.arange(0, max(0, duration-window/2+.01), window/2)]
        warnings.append(f"尚无多个段落，使用约 {window:.1f} 秒、半重叠窗口查找片段重复；这不等于功能段落划分。")
    if len(sections) > 100:
        raise ValueError("超过 100 个段落，请先合并过细的分段再分析重复关系。")
    features = []
    for section in sections:
        a, b = int(section["start"]*sr/hop), min(chroma.shape[1], int(section["end"]*sr/hop))
        c, m = chroma[:, a:b], mfcc[:, a:b]
        if c.shape[1] < 2 or np.max(power[:, a:b]) < 1e-7:
            features.append(None); continue
        flatness = float(np.mean(librosa.feature.spectral_flatness(S=np.sqrt(power[:, a:b]))))
        energy = np.sqrt(power[:, a:b].sum(axis=0))
        if flatness > .15 and np.std(energy) / max(np.mean(energy), 1e-9) < .2:
            features.append(None); continue
        bins = min(128, max(8, int((section["end"]-section["start"])*4)))
        c = zoom(c, (1, bins/c.shape[1]), order=1)
        m = zoom(m, (1, bins/m.shape[1]), order=1)
        c /= np.maximum(np.linalg.norm(c, axis=0), 1e-9)
        # A stationary drone should not become a confident repeated melody.
        variation = float(np.mean(np.std(c, axis=1)))
        features.append((c, m, variation))
    rows, groups = [], {}
    for index, current in enumerate(sections):
        if features[index] is None or features[index][2] < .025:
            continue
        best = None
        for previous in range(index):
            reference = sections[previous]
            if reference["end"] > current["start"] or features[previous] is None:
                continue
            ratio = (current["end"]-current["start"])/(reference["end"]-reference["start"])
            if not .65 <= ratio <= 1.55:
                continue
            a, am, _ = features[previous]; b, bm, _ = features[index]
            timbre_cost = np.minimum(cdist(am.T, bm.T, metric="euclidean") / 10, 1)
            for shift in range(-5, 7):
                tonal_cost = np.clip(1 - np.roll(a, shift, axis=0).T @ b, 0, 1)
                cost = .85 * tonal_cost + .15 * timbre_cost
                _, path = librosa.sequence.dtw(C=cost, global_constraints=True, band_rad=.25)
                similarity = float(1 - np.mean(cost[path[:, 0], path[:, 1]]))
                if best is None or similarity > best[0]:
                    best = similarity, previous, shift, ratio
        if best is None or best[0] < .84:
            continue
        similarity, previous, shift, ratio = best
        reference = sections[previous]
        number = len(set(groups.values()))
        group = groups.setdefault(previous, chr(65 + number % 26) + (str(number//26+1) if number >= 26 else ""))
        groups[index] = group
        variant = shift != 0 or abs(ratio - 1) > .06 or similarity < .96
        row = mark("repetition", current["start"], current["end"], "librosa Chroma/MFCC DTW",
                   group + ("′" if variant else "") + " · 重复候选",
                   {"similarity": similarity, "transpose_semitones": shift, "duration_ratio": ratio,
                    "reference_start_s": reference["start"], "reference_end_s": reference["end"]})
        row["fields"]["content"] = {"suggested": f"与 {reference['start']:.2f}–{reference['end']:.2f} 秒的片段相似；允许速度变化和移调。相同和弦伴奏也可能产生相似度，须试听主题与配器。"}
        row["relatedIDs"] = [section["id"] for section in (reference, current) if "id" in section]
        rows.append(row)
    return {"marks": rows, "warnings": warnings}
