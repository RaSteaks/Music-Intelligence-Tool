#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="${MIT_CHECK_DIR:-$PWD/tmp/agent-handoff-checks}"
mkdir -p "$check_dir"
xcrun swiftc -parse-as-library -swift-version 5 \
  MusicIntelligenceTool/MusicIntelligenceTool/SongRecord.swift \
  MusicIntelligenceTool/MusicIntelligenceTool/CloudRecord.swift \
  MusicIntelligenceTool/MusicIntelligenceTool/CloudPlanning.swift \
  MusicIntelligenceTool/MusicIntelligenceTool/CloudClient.swift \
  MusicIntelligenceTool/MusicIntelligenceTool/ExternalModels.swift \
  MusicIntelligenceTool/MusicIntelligenceTool/Studio.swift \
  MusicIntelligenceTool/MusicIntelligenceTool/ModelEnvironment.swift \
  MusicIntelligenceTool/MusicIntelligenceTool/ShortcutSettings.swift \
  tests/check_agent_handoff.swift -o "$check_dir/check-agent-handoff"
MIT_SWIFT_HANDOFF_CHECK="$check_dir/check-agent-handoff" \
  .venv/bin/python -m unittest discover -s tests -p test_channel.py -v
.venv/bin/python -m unittest discover -s tests -p test_backend.py -k MCPTests -v
