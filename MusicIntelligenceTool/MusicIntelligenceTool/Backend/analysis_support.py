"""Shared result and audio-crop boundaries for local analysis modules."""
import math
import subprocess
import uuid


def mark(kind, start, end, source, label=None, metrics=None):
    return {
        "id": str(uuid.uuid4()), "kind": kind, "start": float(start), "end": float(end),
        "source": source, "startConfirmed": False, "endConfirmed": False,
        "fields": {"label": {"suggested": label}} if label else {},
        "metrics": {k: float(v) for k, v in (metrics or {}).items() if math.isfinite(v)},
    }


def cut(source, output, start, length, *, codec="pcm_f32le"):
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", str(start),
                    "-i", str(source), "-t", str(length), "-vn", "-c:a", codec, str(output)], check=True)


def spectrum(audio, sr=22050, hop=512, n_fft=4096):
    import librosa
    import numpy as np

    y, sr = librosa.load(audio, sr=sr, mono=False)
    if not y.size or not np.isfinite(y).all():
        raise ValueError("音频为空或包含无效采样。")
    power = np.abs(librosa.stft(y, n_fft=n_fft, hop_length=hop))**2
    if y.ndim == 2:
        power = power.mean(axis=0)
    return y, sr, power
