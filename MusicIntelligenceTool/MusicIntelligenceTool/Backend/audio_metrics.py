"""Original-gain measurements; inference resampling must not change these values."""
import math
import re
import subprocess


PCM_FORMATS = {
    "PCM_U8": ("pcm_u8", 8), "PCM_S8": ("pcm_u8", 8),
    "PCM_16": ("pcm_s16le", 16), "PCM_24": ("pcm_s24le", 24), "PCM_32": ("pcm_s32le", 32),
}


def measurement_codec(audio):
    import soundfile as sf

    try:
        subtype = sf.info(audio).subtype
    except sf.LibsndfileError:
        # Formats such as AAC are decoded by FFmpeg into float PCM.
        return "pcm_f32le"
    if subtype in PCM_FORMATS:
        return PCM_FORMATS[subtype][0]
    return "pcm_f64le" if subtype == "DOUBLE" else "pcm_f32le"


def measure_audio(audio):
    import numpy as np
    import soundfile as sf

    with sf.SoundFile(audio) as stream:
        channels, sample_rate = stream.channels, stream.samplerate
        bits = PCM_FORMATS.get(stream.subtype, (None, 0))[1]
        # Signed PCM has one more negative code than positive. Keep that
        # distinction through the crop instead of rounding integer rails.
        positive_full_scale = 1 - 2.0**(1 - bits) if bits else 1.0
        count, peak, full_scale, squares = 0, 0.0, 0, 0.0
        sums = np.zeros(channels)
        channel_squares = np.zeros(channels)
        cross = 0.0
        for block in stream.blocks(blocksize=65536, dtype="float64", always_2d=True):
            count += len(block)
            peak = max(peak, float(np.max(np.abs(block))))
            full_scale += int(np.count_nonzero((block <= -1) | (block >= positive_full_scale)))
            squares += float(np.sum(block**2))
            sums += block.sum(axis=0)
            channel_squares += (block**2).sum(axis=0)
            if channels == 2:
                cross += float(np.sum(block[:, 0] * block[:, 1]))
    if not count:
        return {}, []
    duration = count / sample_rate
    metrics = {"sample_rate_hz": sample_rate, "channels": channels,
               "measured_duration_s": duration, "full_scale_fraction": full_scale / (count * channels)}
    rms = math.sqrt(squares / (count * channels))
    if peak > 0:
        metrics.update(sample_peak_dbfs=20 * math.log10(peak), rms_dbfs=20 * math.log10(rms),
                       crest_db=20 * math.log10(peak / rms))
    if channels == 2:
        variances = np.maximum(0, channel_squares - sums**2 / count)
        denominator = math.sqrt(float(np.prod(variances)))
        if denominator > 1e-12:
            metrics["stereo_correlation"] = float(np.clip((cross - np.prod(sums) / count) / denominator, -1, 1))

    output = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-nostats", "-loglevel", "info", "-i", str(audio),
                             "-af", "ebur128=metadata=1:peak=true,ametadata=print:file=-", "-f", "null", "-"],
                            capture_output=True, text=True)
    if output.returncode:
        raise RuntimeError("FFmpeg 响度测量失败：" + output.stderr.strip().split("\n")[-1])
    values, short_levels = {}, []
    for line in output.stdout.splitlines():
        if not line.startswith("lavfi.r128."):
            continue
        key, value = line.removeprefix("lavfi.r128.").split("=", 1)
        value = float(value)
        values[key] = value
        if key == "S":
            # Short-term loudness needs a complete 3 s window. Its startup
            # sentinel is unavailable data, not a real musical crescendo.
            short_levels.append(value if len(short_levels) >= 29 and value > -119 else None)
    if values.get("I", -70) > -70 and duration >= .4:
        metrics["integrated_lufs"] = values["I"]
        if duration >= 3 and "LRA" in values:
            metrics["loudness_range_lu"] = values["LRA"]
    # The final summary includes the tail even when no complete 100 ms
    # metadata frame was emitted for it.
    match = re.search(r"True peak:\s*\n\s*Peak:\s+(\S+)\s+dBFS", output.stderr)
    if match and math.isfinite(peak_dbtp := float(match[1])):
        metrics["true_peak_dbtp"] = peak_dbtp
    return metrics, short_levels
