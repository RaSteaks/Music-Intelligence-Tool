"""Inspect the selected interpreter offline; only an explicit download may access the network."""
import argparse
import contextlib
import hashlib
import importlib.metadata as metadata
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from urllib.request import urlopen


def emit(**event):
    print(json.dumps(event, ensure_ascii=False), file=sys.__stdout__, flush=True)


def digest(path):
    if not path.is_file():
        return None
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def fetch(url, target, expected=None):
    """Publish complete files atomically so interrupted downloads aren't picked up by analysis."""
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, suffix=".part", delete=False) as temp:
        partial = Path(temp.name)
    try:
        with urlopen(url, timeout=60) as source, partial.open("wb") as output:
            total = int(source.headers.get("Content-Length") or 0)
            last = -1
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                output.write(chunk)
                percent = 100 * output.tell() // total if total else -1
                if percent != last:
                    emit(progress=f"{target.name} · {percent}%")
                    last = percent
            if output.tell() == 0 or (total and output.tell() != total):
                raise ValueError("下载不完整，请重试")
        if expected and digest(partial) != expected:
            raise ValueError(f"{target.name} 校验失败，请重试")
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)


def weight(name, size, source, url=None):
    return {"name": name, "bytes": size, "source": source, "url": url}


def cached(ready, detail, action="下载模型", *, weights=()):
    return {"state": "ready" if ready else "missing", "detail": detail,
            "action": None if ready else action, "weights": weights}


def blocked(detail):
    return {"state": "blocked", "detail": detail, "action": None}


# Publisher Content-Length by checkpoint filename. Use the resolved URL to handle aliases
# such as "large" and "turbo" without duplicating the installed Whisper registry.
WHISPER_BYTES = {
    "tiny.pt": 75_572_083, "tiny.en.pt": 75_571_315,
    "base.pt": 145_262_807, "base.en.pt": 145_261_783,
    "small.pt": 483_617_219, "small.en.pt": 483_615_683,
    "medium.pt": 1_528_008_539, "medium.en.pt": 1_528_006_491,
    "large-v1.pt": 3_086_999_982, "large-v2.pt": 3_086_999_982,
    "large-v3.pt": 3_087_371_615, "large-v3-turbo.pt": 1_617_941_637,
}


def whisper_weights(download):
    import whisper

    name = os.getenv("MIT_WHISPER_MODEL", "base")
    if name not in whisper._MODELS:
        path = Path(name)
        if path.is_file() and path.stat().st_size:
            return cached(True, str(path), weights=[weight(path.name, path.stat().st_size, "本地文件")])
        return blocked(f"MIT_WHISPER_MODEL 指定的模型不存在：{name}")
    url = whisper._MODELS[name]
    directory = Path(os.getenv("XDG_CACHE_HOME", Path.home() / ".cache")) / "whisper"
    path = directory / url.split("/")[-1]
    sha = url.split("/")[-2]
    ready = digest(path) == sha
    if download and not ready:
        fetch(url, path, sha)
        ready = True
    size = path.stat().st_size if ready else WHISPER_BYTES.get(path.name)
    return cached(ready, f"Whisper {name} · {path}", weights=[
        weight(path.name, size, "OpenAI · Whisper", "https://github.com/openai/whisper#available-models-and-languages")
    ])


def structure_weights(download):
    from allin1_mlx.models import loaders_mlx as loader

    folds = loader.ENSEMBLE_MODELS["harmonix-all"]
    ready = 0
    for index, fold in enumerate(folds, 1):
        for filename, sha in loader._FALLBACK_FILES[fold]:
            path = loader._FALLBACK_CACHE_DIR / filename
            if digest(path) != sha:
                if not download:
                    break
                emit(progress=f"结构模型 {index}/{len(folds)} · {filename}")
                loader._download_verified_file(filename, sha, loader._FALLBACK_CACHE_DIR)
        else:
            ready += 1
    # Sum of the eight .npz blobs at this loader revision (excludes YAML configs).
    revision = loader._FALLBACK_REVISION
    size = 10_107_176 if revision == "da5f3474503fde41860b454a48bc9e7899cd5dfa" else None
    return cached(ready == len(folds), f"harmonix-all · {ready}/{len(folds)} 组权重已校验", weights=[
        weight(f"harmonix-all（{len(folds)} 组 NPZ）", size, "GitHub · all-in-one-mlx",
               f"https://github.com/ssmall256/all-in-one-mlx/tree/{revision}/mlx-weights")
    ])


def stem_weights(download):
    from demucs_mlx.model_converter import get_mlx_cache_dir, get_mlx_model

    weights = [weight("HTDemucs · 955717e8-8726e21a.th", 84_141_911, "Meta · Demucs",
                      "https://github.com/facebookresearch/demucs/blob/main/demucs/remote/files.txt")]
    directory = get_mlx_cache_dir()
    config = directory / "htdemucs_config.json"
    if config.is_file():
        try:
            expected = json.loads(config.read_text()).get("safetensors_sha256")
        except (UnicodeError, json.JSONDecodeError):
            expected = None
        if expected and digest(directory / "htdemucs.safetensors") == expected:
            return cached(True, f"HTDemucs · {directory}", weights=weights)
    from packaging.version import Version
    needs_converter = (importlib.util.find_spec("demucs") is None
                       or importlib.util.find_spec("torch") is None
                       or Version(metadata.version("torch")) < Version("2.6"))
    if download:
        if needs_converter:
            emit(progress="正在安装 MLX 转换依赖…")
            requirement = f"demucs-mlx[convert]=={metadata.version('demucs-mlx')}"
            subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", requirement],
                           stdout=sys.stderr, check=True)
            importlib.invalidate_caches()
        emit(progress="正在下载 HTDemucs 并转换为 MLX 权重…")
        get_mlx_model("htdemucs")
        return stem_weights(False)
    if needs_converter:
        return cached(False, "首次转换还需下载 Python 依赖，大小随环境而定。", "安装转换依赖并下载", weights=weights)
    return cached(False, "HTDemucs · 需要下载并转换权重", weights=weights)


def hub_files(repo, files, download, weight_bytes):
    from huggingface_hub import hf_hub_download, try_to_load_from_cache
    from huggingface_hub.constants import ENDPOINT
    from transformers.utils.hub import TRANSFORMERS_CACHE

    present = 0
    for index, name in enumerate(files, 1):
        local = try_to_load_from_cache(repo, name, cache_dir=TRANSFORMERS_CACHE)
        path = Path(local) if isinstance(local, str) else None
        valid = path is not None and path.is_file() and path.stat().st_size > 0
        if valid:
            # The HF cache links LFS weights to blobs named by their SHA-256.
            blob = path.resolve().name
            if len(blob) == 64 and all(char in "0123456789abcdef" for char in blob):
                valid = digest(path) == blob
        if valid:
            present += 1
        elif download:
            emit(progress=f"{repo} · {index}/{len(files)} · {name}")
            hf_hub_download(repo, name, cache_dir=TRANSFORMERS_CACHE, force_download=path is not None)
            present += 1
    return cached(present == len(files), f"{repo} · {present}/{len(files)} 个文件已缓存", weights=[
        weight(f"{repo.split('/')[-1]} · pytorch_model.bin", weight_bytes, "Hugging Face",
               f"{ENDPOINT}/{repo}/blob/main/pytorch_model.bin")
    ])


def emotion_weights(root, download):
    repo = root / ".models/Music2Emotion"
    if not (repo/"music2emo.py").is_file():
        return blocked("缺少 Music2Emo 推理代码")
    # The pinned upstream checkout also contains these two small heads. MERT lives in the HF cache.
    revision = "c5f7984f78d9928b841f25bd05a47377c12c58ca"
    heads = {"saved_models/J_all.ckpt": "deaceb291f7974deb688167d3639b7f6eb66eb0715824668618393777d1e07a5",
             "inference/data/btc_model_large_voca.pt": "1673d23f8f9a55ae7f9e8b80a51da616debb22675b8d8b67ea6ce0ef37b0ab51"}
    present = 0
    for name, sha in heads.items():
        if digest(repo/name) == sha:
            present += 1
        elif download:
            fetch(f"https://raw.githubusercontent.com/AMAAI-Lab/Music2Emotion/{revision}/{name}", repo/name, sha)
            present += 1
    mert = hub_files("m-a-p/MERT-v1-95M", ["config.json", "preprocessor_config.json", "configuration_MERT.py",
                                            "modeling_MERT.py", "pytorch_model.bin"], download, 377_552_987)
    return cached(present == len(heads) and mert["state"] == "ready",
                  f"Music2Emo {present}/2 · {mert['detail']}", weights=[
                      weight("J_all.ckpt + btc_model_large_voca.pt", 12_958_092 + 12_229_576, "GitHub · Music2Emotion",
                             f"https://github.com/AMAAI-Lab/Music2Emotion/tree/{revision}"),
                      *mert["weights"],
                  ])


def alignment_weights(language, download):
    if language == "en":
        import torch
        import torchaudio
        name = torchaudio.pipelines.WAV2VEC2_ASR_BASE_960H._path
        path = Path(torch.hub.get_dir()) / "checkpoints" / Path(name).name
        if download and not (path.is_file() and path.stat().st_size):
            fetch(f"https://download.pytorch.org/torchaudio/models/{name}", path)
        return cached(path.is_file() and path.stat().st_size > 0, f"Wav2Vec2 English · {path.name}", weights=[
            weight(path.name, 377_664_473 if name == "wav2vec2_fairseq_base_ls960_asr_ls960.pth" else None,
                   "PyTorch · torchaudio", "https://docs.pytorch.org/audio/stable/pipelines.html#torchaudio.pipelines.WAV2VEC2_ASR_BASE_960H")
        ])
    return hub_files("jonatasgrosman/wav2vec2-large-xlsr-53-chinese-zh-cn",
                     ["config.json", "preprocessor_config.json", "vocab.json", "special_tokens_map.json",
                      "pytorch_model.bin"], download, 1_276_296_151)


PACKAGES = {"base": ("mcp", "numpy", "librosa"), "structure": ("all-in-one-mlx", "mlx", "natten-mlx"),
            "stems": ("demucs-mlx", "mlx"), "lyrics": ("openai-whisper", "torch"),
            "emotion": ("torch", "torchaudio", "transformers", "music21", "pytorch-lightning", "gradio"),
            "align-zh": ("whisperx", "torch", "torchaudio", "transformers"),
            "align-en": ("whisperx", "torch", "torchaudio", "transformers")}


def inspect_feature(feature, root, download=False):
    if feature in ("structure", "stems") and platform.machine() != "arm64":
        return blocked("MLX 需要 Apple Silicon 和原生 arm64 Python")
    missing = []
    for package in PACKAGES[feature]:
        try:
            metadata.version(package)
        except metadata.PackageNotFoundError:
            missing.append(package)
    if missing:
        return blocked("缺少 Python 依赖：" + "、".join(missing))
    if feature == "base":
        return cached(True, "声学分析、和声与 MCP 依赖已安装")
    if feature == "structure":
        return structure_weights(download)
    if feature == "stems":
        return stem_weights(download)
    if feature == "lyrics":
        return whisper_weights(download)
    if feature == "emotion":
        return emotion_weights(root, download)
    return alignment_weights(feature.removeprefix("align-"), download)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["check", "download"])
    parser.add_argument("feature", choices=PACKAGES)
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args()
    if args.operation == "check":
        os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            result = inspect_feature(args.feature, args.runtime, args.operation == "download")
            if args.operation == "download" and result["state"] == "ready":
                emit(progress="正在复核本机缓存…")
                result = inspect_feature(args.feature, args.runtime)
        emit(**result, python=platform.python_version())
    except Exception as exc:
        emit(error=str(exc) or type(exc).__name__)
        sys.exit(1)
