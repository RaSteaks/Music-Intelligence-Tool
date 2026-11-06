"""Local MCP tools. Swift owns the writer; all reads see atomic snapshots."""
import json
import math
import os
from pathlib import Path
import re
import sys
import threading

from mcp.server.fastmcp import FastMCP

ROOT = Path(sys.argv[1]) if __name__ == "__main__" else Path(".")
server = FastMCP("Music Intelligence Tool", host="127.0.0.1", port=int(os.getenv("MIT_MCP_PORT", "18765")))
bridge = threading.Lock()


def read_song(track_id):
    if not re.fullmatch(r"[a-f0-9]{64}", track_id):
        raise ValueError("无效的 track_id")
    return json.loads((ROOT / track_id / "analysis.json").read_text())


def effective(row, confirmed_only=False):
    fields = {}
    hints = {}
    for name, values in row["fields"].items():
        if values.get("hint"):
            hints[name] = values["hint"]
        if "confirmed" in values:
            fields[name] = {"value": values["confirmed"], "source": "user"}
        elif not confirmed_only and "suggested" in values:
            fields[name] = {"value": values["suggested"], "source": row["source"]}
    if confirmed_only and not (fields or row["startConfirmed"] or row["endConfirmed"]):
        return None
    item = {"id": row["id"], "type": row["kind"], "start_s": row["start"], "end_s": row["end"],
            "start_source": "user" if row["startConfirmed"] else row["source"],
            "end_source": "user" if row["endConfirmed"] else row["source"], "fields": fields}
    if not confirmed_only:
        item.update(hints=hints, metrics=row["metrics"])
    return item


@server.tool()
def analyze_music(path: str) -> dict[str, object]:
    """Open a local audio file in the running App and schedule missing analyses. Returns track_id and status."""
    source = Path(path).expanduser().resolve(strict=True)
    if source.suffix.lower() not in (".wav", ".mp3", ".flac", ".m4a") or not source.is_file():
        raise ValueError("请选择 WAV、MP3、FLAC 或 M4A 文件")
    # Serialize command/reply pairs; stdout is a pipe to the owning App, not the HTTP transport.
    with bridge:
        print(json.dumps({"path": str(source)}), flush=True)
        line = sys.stdin.readline()
        if not line:
            raise RuntimeError("App 连接已关闭")
        reply = json.loads(line)
    if "error" in reply:
        raise ValueError(reply["error"])
    return reply


@server.tool()
def get_music_overview(track_id: str) -> dict[str, object]:
    """Return the latest saved revision, module status, duration, tempo, key, sections and emotion windows."""
    song = read_song(track_id)
    return {"track_id": track_id, "revision": song["revision"], "duration_s": song["duration"],
            "bpm": song.get("bpm"), "key": song.get("key"), "status": song["status"],
            "sections": [effective(m) for m in sorted(song["marks"], key=lambda r: r["start"]) if m["kind"]=="section"],
            "emotions": [effective(m) for m in song["marks"] if m["kind"]=="emotion"]}


@server.tool()
def get_music_record(track_id: str) -> dict[str, object]:
    """Return the complete saved analysis record, including original model suggestions, user confirmations,
    hints, metrics, module status and local audio/stem paths. Audio file contents are not included."""
    return read_song(track_id)


@server.tool()
def get_music_timeline(track_id: str, start_s: float, end_s: float, types: list[str] | None = None,
                       confirmed_only: bool = False) -> dict[str, object]:
    """Query [start_s,end_s) in original audio seconds. Types: section, beat, downbeat, onset, acoustic,
    emotion, chord, lyric, word, note. Hints are separate from confirmed values."""
    if not (math.isfinite(start_s) and math.isfinite(end_s) and 0 <= start_s < end_s):
        raise ValueError("无效的时间范围")
    song = read_song(track_id)
    items = []
    for row in sorted(song["marks"], key=lambda r: r["start"]):
        if types is not None and row["kind"] not in types:
            continue
        if row["start"] >= end_s or (row["end"] <= start_s and row["start"] < start_s):
            continue
        item = effective(row, confirmed_only)
        if item is not None:
            items.append(item)
    return {"track_id": track_id, "revision": song["revision"], "status": song["status"], "items": items}


if __name__ == "__main__":
    import asyncio
    import uvicorn

    # stdout is the Swift command pipe. HTTP access logs must never be parsed as App requests.
    app = server.streamable_http_app()
    config = uvicorn.Config(app, host=server.settings.host, port=server.settings.port,
                            log_level=server.settings.log_level.lower(), access_log=False)
    asyncio.run(uvicorn.Server(config).serve())
