#!/bin/sh
set -eu
case "$1" in
  */model_environment.py)
    printf '%s:%s\n' "$2" "$3" >> "$4/calls"
    if [ "$2" = download ]; then touch "$4/model-ready"; fi
    if [ -f "$4/model-ready" ]; then
      printf '%s\n' '{"state":"ready","detail":"测试模型已就绪"}'
    else
      printf '%s\n' '{"state":"missing","detail":"需要测试模型","action":"下载测试模型"}'
    fi
    ;;
  */analysis_worker.py)
    printf 'analysis:%s\n' "$2" >> "$5/calls"
    cat > "$4" <<'JSON'
{"marks":[
  {"id":"verse-1","kind":"lyric","start":2,"end":4,"source":"fixture","startConfirmed":false,"endConfirmed":false,"fields":{"label":{"suggested":"First verse"}},"metrics":{}},
  {"id":"verse-2","kind":"lyric","start":4,"end":6,"source":"fixture","startConfirmed":false,"endConfirmed":false,"fields":{"label":{"confirmed":"Second verse"}},"metrics":{}},
  {"id":"verse-3","kind":"lyric","start":6,"end":8,"source":"fixture","startConfirmed":false,"endConfirmed":false,"fields":{"label":{"suggested":"Third verse"}},"metrics":{}}
]}
JSON
    ;;
  *) exit 1 ;;
esac
