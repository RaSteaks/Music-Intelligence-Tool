"""Energy-based activity candidates, never definitive instrument recognition."""
import math
from pathlib import Path
import subprocess

from analysis_support import cut, mark


def activity_intervals(audio, kind, bpm=None):
    import numpy as np
    import soundfile as sf

    levels = []
    with sf.SoundFile(audio) as stream:
        step = max(1, round(stream.samplerate * .1))
        resolution = step / stream.samplerate
        duration = len(stream) / stream.samplerate
        for block in stream.blocks(blocksize=step, dtype="float64", always_2d=True):
            rms = math.sqrt(float(np.mean(block**2)))
            levels.append(20 * math.log10(max(rms, 1e-12)))
    if not levels:
        return [], {"resolution_s": resolution}, duration
    silence = kind == "silence"
    threshold = -60.0 if silence else max(-50.0, max(levels) - 30)
    gap = .3
    if kind == "drums":
        # Sparse beats contain genuine silence between hits. Bridge a bounded
        # beat-sized gap, without merging long instrumental breaks.
        gap = min(1.5, max(.3, 120 / bpm)) if bpm and bpm > 0 else .8
    intervals, beginning, active_frames = [], None, 0
    for index, level in enumerate(levels):
        active = level < threshold if silence else level >= threshold - (6 if beginning is not None else 0)
        if active:
            if beginning is None:
                beginning = index * resolution
                active_frames = 0
            active_frames += 1
        elif beginning is not None:
            intervals.append((beginning, index * resolution, active_frames))
            beginning = None
    if beginning is not None:
        intervals.append((beginning, duration, active_frames))
    merged = []
    for start, end, frames in intervals:
        if not silence and merged and start - merged[-1][1] <= gap + 1e-9:
            previous = merged[-1]
            merged[-1] = (previous[0], end, previous[2] + frames)
        else:
            merged.append((start, end, frames))
    minimum = .5 if silence else .4
    result = [(start, end) for start, end, frames in merged
              if end - start >= minimum - 1e-9 and (silence or frames * resolution >= .2 - 1e-9)]
    return result, {"threshold_dbfs": threshold, "resolution_s": resolution, "bridged_gap_s": 0 if silence else gap}, duration


def analyze_activity(source, start, end, stems, scratch, bpm=None):
    rows, warnings, coverage = [], [], []
    inputs = [("silence", "近静音", Path(source))]
    for name, title in (("vocals", "人声轨"), ("drums", "鼓轨"), ("bass", "贝斯轨")):
        path = stems.get(name)
        if not path or not Path(path).is_file():
            warnings.append(f"缺少{title}，未分析该声部；请先运行结构 · 节拍 · 分轨。")
            continue
        inputs.append((name, title + "活动（候选）", Path(path)))
    for name, title, path in inputs:
        clip = scratch / (name + ".wav")
        try:
            cut(path, clip, start, end - start)
            intervals, metrics, duration = activity_intervals(clip, name, bpm)
        except (subprocess.CalledProcessError, RuntimeError) as error:
            if name == "silence":
                raise RuntimeError("无法读取原曲，请检查音频文件。") from error
            warnings.append(f"无法解码{title}，已保留其他可用结果。")
            continue
        if duration <= 0:
            warnings.append(f"{title}在此选区没有可分析的采样。")
            continue
        stop = min(end, start + duration)
        coverage.append({"source": name, "start": start, "end": stop})
        if stop < end - .05:
            warnings.append(f"{title}只覆盖到原曲 {stop:.2f} 秒。")
        for lo, hi in intervals:
            row = mark("event", start + lo, min(end, start + hi), "PCM 能量阈值", title, metrics)
            row["fields"]["event_type"] = {"suggested": name}
            row["fields"]["content"] = {"suggested": (
                "原曲各声道的 100 ms RMS 低于 −60 dBFS，持续至少 0.5 秒；很轻的音乐也可能被包含。"
                if name == "silence" else
                "根据分轨能量推测活动区间，串音和残响可能误报。区间边缘若与选区重合，不代表真实进入或退出；请切换对应音轨试听核对。")}
            rows.append(row)
    return {"marks": sorted(rows, key=lambda row: (row["start"], row["end"])), "warnings": warnings, "coverage": coverage}
