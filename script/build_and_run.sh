#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=${MIT_BUILD_DIR:-"${TMPDIR:-/tmp}/MusicIntelligenceTool-build"}
name=MusicIntelligenceTool
app="$build_dir/Build/Products/Debug/$name.app"
xcodebuild -project "$name/$name.xcodeproj" -scheme "$name" -destination 'platform=macOS' -derivedDataPath "$build_dir" build
case "${1:-run}" in
  --debug) exec lldb "$app/Contents/MacOS/$name" ;;
  --verify) open -n "$app"; sleep 2; pgrep -x "$name" >/dev/null ;;
  --logs|--telemetry) open "$app"; /usr/bin/log stream --predicate 'process == "MusicIntelligenceTool"' ;;
  run) open "$app" ;;
  *) echo "usage: $0 [--verify|--logs|--debug|--telemetry]" >&2; exit 2 ;;
esac
