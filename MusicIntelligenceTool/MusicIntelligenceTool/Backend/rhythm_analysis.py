"""Multi-beat tempo statistics, metrical alternatives and onset-phase evidence."""
from analysis_support import mark, spectrum


def analyze_rhythm(audio, offset, duration, record):
    import librosa
    import numpy as np

    hop = 256
    _, sr, power = spectrum(audio, hop=hop, n_fft=2048)
    onset = librosa.onset.onset_strength(S=librosa.power_to_db(power), sr=sr, hop_length=hop)
    attacks = librosa.onset.onset_detect(onset_envelope=onset, sr=sr, hop_length=hop, units="time")
    saved = record.get("marks", [])
    beats = np.array(sorted({row["start"] for row in saved if row["kind"] == "beat" and offset <= row["start"] < offset + duration}))
    rows, warnings = [], []
    source = "All-In-One beats / interval statistics"
    if len(beats) < 5:
        if len(attacks) < 5 or np.max(onset) < 1e-6:
            return {"marks": [], "warnings": ["未检出足够的稳定起音，节奏结果留空。"]}
        tempo = librosa.feature.tempo(onset_envelope=onset, sr=sr, hop_length=hop, ac_size=4, aggregate=None)
        _, local = librosa.beat.beat_track(onset_envelope=onset, sr=sr, hop_length=hop, bpm=tempo, units="time")
        beats = offset + np.asarray(local)
        source = "librosa dynamic beat tracking"
        rows += [mark("rhythm_beat", t, t, source) for t in beats if t < offset + duration]
        warnings.append("使用本地动态节拍候选；自由节奏、切分和弱起可能导致半速／倍速歧义。")
    if len(beats) < 5:
        return {"marks": [], "warnings": ["有效拍点不足五个，速度统计留空。"]}
    intervals = np.diff(beats)
    median = float(np.median(intervals))
    bpm = 60 / median
    variation = float(np.median(np.abs(intervals - median)) / median)
    metrics = {"tempo_bpm": bpm, "half_tempo_bpm": bpm / 2, "double_tempo_bpm": bpm * 2,
               "beat_interval_mad": variation, "beat_count": len(beats)}
    summary = mark("rhythm_summary", offset, offset + duration, source, f"参考速度 {bpm:.1f} BPM", metrics)
    summary["fields"]["content"] = {"suggested": "速度由连续多拍统计。半速与倍速是节拍层级候选，不自动替换全曲 BPM；拍间变异不是识别准确率。"}

    absolute_attacks = attacks + offset
    phases = []
    offbeats, covered_attacks = 0, 0
    for attack in absolute_attacks:
        index = int(np.searchsorted(beats, attack, side="right")) - 1
        if index < 0 or index >= len(intervals):
            continue
        covered_attacks += 1
        phase = float((attack - beats[index]) / intervals[index])
        if .15 < phase < .85:
            phases.append(phase); offbeats += 1
    if covered_attacks:
        metrics["offbeat_onset_fraction"] = offbeats / covered_attacks
        metrics["onset_phase_coverage"] = covered_attacks / len(absolute_attacks)
    if len(phases) >= 4:
        phase = float(np.median(phases))
        spread = float(np.median(np.abs(np.asarray(phases) - phase)))
        metrics.update(offbeat_phase=phase, offbeat_phase_mad=spread)
        if spread < .08 and .58 <= phase <= .75:
            metrics["swing_ratio"] = phase / (1 - phase)
            summary["fields"]["groove"] = {"suggested": "存在长短拍摇摆线索；需结合重音与风格试听确认。"}
    # mark() copies metrics, so publish phase statistics explicitly.
    summary["metrics"].update(metrics)

    downbeats = sorted(row["start"] for row in saved if row["kind"] == "downbeat" and offset <= row["start"] <= offset + duration)
    counts = [int(np.count_nonzero((beats >= lo - .03) & (beats < hi - .03))) for lo, hi in zip(downbeats, downbeats[1:])]
    counts = [value for value in counts if 2 <= value <= 12]
    meter_source = "小节第一拍间的拍点计数"
    if len(counts) >= 2:
        per_bar = max(set(counts), key=counts.count)
        support = counts.count(per_bar) / len(counts)
    else:
        # Infer periodic accent organization only when several bars are present.
        strength = np.array([np.max(onset[max(0, int((t-offset)*sr/hop)-2):int((t-offset)*sr/hop)+3]) for t in beats])
        centered = strength - strength.mean()
        candidates = []
        for lag in range(2, 8):
            if len(strength) >= lag * 4 and np.std(centered[:-lag]) > 1e-6 and np.std(centered[lag:]) > 1e-6:
                candidates.append((float(np.corrcoef(centered[:-lag], centered[lag:])[0, 1]), lag))
        candidates.sort(reverse=True)
        support, per_bar = candidates[0] if candidates else (0, 0)
        # Prefer the smallest equally supported period rather than its multiples.
        if candidates:
            per_bar = min(lag for value, lag in candidates if value >= support - .05)
        meter_source = "拍点附近起音强度的周期性"
    if support >= .7 and per_bar:
        summary["metrics"].update(beats_per_bar=per_bar, meter_support=support)
        alternatives = {2: "2/4、2/2，或 6/8 的复合二拍", 3: "3/4、3/8，或 9/8 的复合三拍",
                        4: "4/4、4/8，或 12/8 的复合四拍", 6: "6/8 或 6/4"}
        summary["fields"]["meter"] = {"suggested": f"每小节约 {per_bar} 个检测拍；候选：" + alternatives.get(per_bar, f"{per_bar} 拍组织，分母未知")}
        summary["fields"]["content"]["suggested"] += f" 拍号线索来自{meter_source}，不能单凭拍点计数确定记谱分母。"
    for index in range(0, len(beats)-4, 4):
        piece = intervals[index:index+8]
        if len(piece) < 4:
            continue
        local_bpm = float(60 / np.median(piece))
        rows.append(mark("tempo", float(beats[index]), float(beats[min(index+4, len(beats)-1)]), source,
                         f"{local_bpm:.1f} BPM", {"tempo_bpm": local_bpm, "interval_count": len(piece)}))
    rows.append(summary)
    return {"marks": rows, "warnings": warnings}
