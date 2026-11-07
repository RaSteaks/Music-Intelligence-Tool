#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
base=${PYTHON:-python3.10}
modern=${PYTHON_MODERN:-python3.12}
mode=${1:-base}
command -v ffmpeg >/dev/null || { echo '请先安装 FFmpeg (brew install ffmpeg)' >&2; exit 1; }
if [[ "$mode" != music ]]; then
  "$base" -m venv .venv
  .venv/bin/python -m pip install 'mcp>=1.12,<2' 'numpy<2' 'librosa==0.11.0' 'openai-whisper==20250625' 'torch==2.5.1'
fi
if [[ "$mode" == music || "$mode" == all ]]; then
  # Essentia's native melody algorithms use their own NumPy ABI/runtime.
  "$modern" -m venv .venv-music
  .venv-music/bin/python -m pip install 'numpy==1.26.4' 'essentia==2.1b6.dev1389' 'soundfile==0.12.1'
fi
if [[ "$mode" == models || "$mode" == all ]]; then
  "$modern" -m venv .venv-structure
  .venv-structure/bin/python -m pip install all-in-one-mlx==1.0.14 'demucs-mlx[convert]>=1.4.11,<1.5'
  if [[ ! -d .models/Music2Emotion ]]; then
    git clone https://github.com/AMAAI-Lab/Music2Emotion.git .models/Music2Emotion
    git -C .models/Music2Emotion checkout --detach c5f7984f78d9928b841f25bd05a47377c12c58ca
  fi
  "$base" -m venv .venv-emotion
  .venv-emotion/bin/python -m pip install -r .models/Music2Emotion/requirements.txt
fi
if [[ "$mode" == align || "$mode" == all ]]; then
  "$modern" -m venv .venv-align
  .venv-align/bin/python -m pip install 'whisperx>=3.4,<4'
fi
echo '环境已安装。在 App 的「运行环境」中选择本仓库目录。'
