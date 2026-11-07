"""Predominant melody extraction using Essentia's polyphonic Melodia algorithm."""
import math

from analysis_support import mark


def note_name(midi):
    names = "C C# D Eb E F F# G Ab A Bb B".split()
    return names[int(round(midi)) % 12] + str(int(round(midi)) // 12 - 1)


def analyze_melody(audio, offset, duration, vocal_stem=False):
    import numpy as np
    import soundfile as sf
    from essentia_runtime import vector_algorithm

    channels, original_sr = sf.read(audio, dtype="float32", always_2d=True)
    if not len(channels) or not np.isfinite(channels).all():
        raise ValueError("音频为空或包含无效采样。")
    y = channels.mean(axis=1)
    warnings = []
    if np.mean(y**2) < .1 * np.mean(channels**2):
        y = channels[:, int(np.argmax(np.mean(channels**2, axis=0)))]
        warnings.append("声道混合存在明显抵消，旋律分析采用能量最高的声道。")
    if original_sr != 44100:
        # Essentia quality=1 is sinc resampling; 4 is linear and can distort the
        # salience of short high notes before equal-loudness filtering.
        y = vector_algorithm("Resample", inputSampleRate=original_sr, outputSampleRate=44100, quality=1)(y)
    # A 256-sample analysis hop retains short-note contours in the pinned build;
    # the published curve is still explicitly sampled at 50 ms.
    sr, hop, step = 44100, 256, .05
    source = "Essentia Melodia / " + ("vocals" if vocal_stem else "mix")
    if not vocal_stem:
        warnings.append("分析原混音中的主导旋律候选；伴奏、低音和多条旋律可能造成误选。有人声分轨时优先使用人声轨。")
    rows, points = [], []
    actual_duration = min(duration, len(y)/sr)
    if actual_duration < duration - .05:
        warnings.append(f"源音轨只覆盖到原曲 {offset+actual_duration:.2f} 秒，后续区间未分析。")
    # Context overlaps protect contours at job-window seams. Only each core
    # interval is published, so repeated frames cannot double-count coverage.
    for core in np.arange(0, actual_duration, 30):
        stop = min(core+30, actual_duration)
        lo, hi = max(0, core-1), min(actual_duration, stop+1)
        original = y[int(lo*sr):int(hi*sr)]
        if len(original) < 2048 or np.max(np.abs(original)) < 1e-5:
            continue
        filtered = vector_algorithm("EqualLoudness", sampleRate=sr)(original)
        pitch, salience = vector_algorithm("PredominantPitchMelodia", sampleRate=sr, frameSize=2048, hopSize=hop,
                                           minFrequency=65, maxFrequency=2093,
                                           guessUnvoiced=False, voiceVibrato=True)(filtered)
        times = lo + np.arange(len(pitch))*hop/sr
        for frame_index in range(int(math.ceil((stop-core)/step))):
            t = core + frame_index*step
            end = min(stop, core+(frame_index+1)*step)
            window = (times >= t) & (times < end)
            valid = window & (pitch > 0) & (salience > 0)
            original_piece = y[int(t*sr):int(end*sr)]
            if not np.any(window) or np.count_nonzero(valid) < .5 * np.count_nonzero(window) or not original_piece.size or np.sqrt(np.mean(original_piece**2)) < 1e-4:
                continue
            hz = float(np.median(pitch[valid]))
            piece = filtered[max(0, int((t-lo)*sr)):int((end-lo)*sr)]
            correlations = []
            for lag in {max(1, int(sr/hz)), max(1, int(sr/hz)+1)}:
                if lag < len(piece):
                    left, right = piece[:-lag], piece[lag:]
                    correlations.append(float(np.dot(left, right) / max(np.linalg.norm(left)*np.linalg.norm(right), 1e-12)))
            periodicity = max(correlations, default=0)
            # A salient random spectral ridge is not enough: require periodic
            # support at the estimated F0 in the perceptually weighted signal.
            if periodicity < .3:
                continue
            midi = 69 + 12*math.log2(hz/440)
            strength = float(np.median(salience[valid]))
            rows.append(mark("pitch", offset+t, offset+end, source, note_name(midi),
                             {"frequency_hz": hz, "midi_pitch": midi, "pitch_salience": strength, "periodicity": periodicity, "resolution_s": step}))
            points.append((float(t), float(end), midi, strength))
    if not points:
        return {"marks": [], "warnings": warnings + ["未检出可靠的主导音高，旋律结果留空。"],
                "coverage": [{"source": "vocals" if vocal_stem else "original", "start": offset, "end": offset+actual_duration}]}
    notes = []
    for t, end, midi, strength in points:
        quantized = int(round(midi))
        if notes and quantized == notes[-1]["metrics"]["midi_note"] and abs(notes[-1]["end"] - (offset+t)) < .001:
            notes[-1]["end"] = offset+end
        else:
            notes.append(mark("melody_note", offset+t, offset+end, source, note_name(quantized), {"midi_note": quantized}))
    notes = [note for note in notes if note["end"] - note["start"] >= .12]
    rows.extend(notes)
    groups = []
    for note in notes:
        if not groups or note["start"] - groups[-1][-1]["end"] >= .35:
            groups.append([note])
        else:
            groups[-1].append(note)
    phrases, contours = [], []
    for index, group in enumerate(groups):
        phrase = mark("melody_phrase", group[0]["start"], group[-1]["end"], source, f"乐句 {index+1}（候选）",
                      {"note_count": len(group), "phrase_span_semitones": max(n["metrics"]["midi_note"] for n in group)-min(n["metrics"]["midi_note"] for n in group)})
        phrase["fields"]["content"] = {"suggested": "按检测旋律中至少 0.35 秒的空隙分组，可能受分轨串音和漏检影响；不是已确认的音乐乐句边界。"}
        phrases.append(phrase)
        values = np.array([n["metrics"]["midi_note"] for n in group])
        contour = np.interp(np.linspace(0, len(values)-1, 32), np.arange(len(values)), values-values[0]) if len(values) >= 4 else None
        contours.append(contour)
        candidates = []
        for previous in range(index):
            if contour is None or contours[previous] is None:
                continue
            ratio = (phrase["end"]-phrase["start"])/(phrases[previous]["end"]-phrases[previous]["start"])
            if .65 <= ratio <= 1.55:
                candidates.append((float(np.mean(np.abs(contour-contours[previous]))), previous))
        if candidates:
            distance, previous = min(candidates)
            if distance <= .75:
                reference = phrases[previous]
                motif = mark("melody_motif", phrase["start"], phrase["end"], source, "相似旋律动机（候选）",
                             {"interval_distance_semitones": distance, "reference_start_s": reference["start"], "reference_end_s": reference["end"],
                              "transpose_semitones": group[0]["metrics"]["midi_note"]-groups[previous][0]["metrics"]["midi_note"]})
                motif["relatedIDs"] = [reference["id"], phrase["id"]]
                motif["fields"]["content"] = {"suggested": "比较相对起音的音程轮廓，允许移调和时长变化；相似轮廓不证明主题相同，请交替试听。"}
                rows.append(motif)
    rows.extend(phrases)
    pitches = np.array([point[2] for point in points])
    low, high = np.percentile(pitches, [5, 95])
    voiced_duration = sum(end-t for t, end, _, _ in points)
    summary = mark("melody_summary", offset, offset+actual_duration, source, f"检测音域 {note_name(low)}–{note_name(high)}",
                   {"pitch_low_midi": low, "pitch_high_midi": high, "pitch_span_semitones": high-low,
                    "pitched_fraction": voiced_duration / actual_duration,
                    "pitch_salience": float(np.median([point[3] for point in points]))})
    summary["fields"]["content"] = {"suggested": "音域取检测到的音高 5–95 百分位，仅描述此区间，不代表歌手的全部音域。音符是主导旋律候选，未检测段不补音；显著度不是准确率。"}
    # Vibrato is a measured periodic pitch modulation on sustained notes; no
    # identity, vocal technique or singing-quality judgement is inferred.
    vibrato = []
    for note in notes:
        if note["end"] - note["start"] < 1:
            continue
        cents = np.array([(midi-note["metrics"]["midi_note"])*100 for t, end, midi, _ in points
                          if offset+t >= note["start"]-.001 and offset+end <= note["end"]+.001])
        if len(cents) < 20 or np.ptp(cents) < 15:
            continue
        trend = np.polyval(np.polyfit(np.arange(len(cents)), cents, 1), np.arange(len(cents)))
        energy = np.abs(np.fft.rfft((cents-trend)*np.hanning(len(cents))))**2
        frequencies = np.fft.rfftfreq(len(cents), step)
        band = (frequencies >= 4) & (frequencies <= 8)
        total = energy[(frequencies >= 2) & (frequencies <= 9)].sum()
        if total > 0 and energy[band].sum()/total > .6:
            vibrato.append(float(frequencies[np.flatnonzero(band)[np.argmax(energy[band])]]))
    if vibrato:
        summary["metrics"]["vibrato_hz"] = float(np.median(vibrato))
        summary["fields"]["content"]["suggested"] += " 持续音内存在 4–8 Hz 音高调制线索，需试听区分颤音、乐器调制或提取误差。"
    rows.append(summary)
    for row in rows:
        row["fields"]["audio_source"] = {"suggested": "vocals" if vocal_stem else "original"}
    return {"marks": rows, "warnings": warnings,
            "coverage": [{"source": "vocals" if vocal_stem else "original", "start": offset, "end": offset+actual_duration}]}
