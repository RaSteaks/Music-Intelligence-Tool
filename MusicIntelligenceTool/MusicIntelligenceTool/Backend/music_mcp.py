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
    has_confirmation = row["startConfirmed"] or row["endConfirmed"]
    for name, values in row["fields"].items():
        if values.get("hint"):
            hints[name] = values["hint"]
        if "confirmed" in values:
            fields[name] = {"value": values["confirmed"], "source": "user"}
            has_confirmation = True
        elif not confirmed_only and "suggested" in values and not row.get("analysisStale") and not values.get("rejected") and not (values.get("origin") or {}).get("stale"):
            origin = values.get("origin")
            fields[name] = {"value": values["suggested"], "source":
                            f"{origin['provider']}/{origin['model']}" if origin else row["source"]}
        if name in fields and values.get("origin"):
            fields[name]["origin"] = values["origin"]
    if (confirmed_only or row.get("analysisStale")) and not has_confirmation:
        return None
    if row["kind"] == "insight" and not has_confirmation and not any(name in fields for name in ("label", "content", "mood")):
        return None
    item = {"id": row["id"], "type": row["kind"], "start_s": row["start"], "end_s": row["end"],
            "start_source": "user" if row["startConfirmed"] else row["source"],
            "end_source": "user" if row["endConfirmed"] else row["source"], "fields": fields}
    if not confirmed_only:
        item.update(hints=hints, metrics={} if row.get("analysisStale") else row["metrics"])
    if row.get("analysisStale"):
        item["analysis_stale"] = True
    if row.get("relatedIDs"):
        item["related_ids"] = row["relatedIDs"]
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
    """Return revision, statuses, coverage and section, mood, loudness, rhythm, melody and repetition
    summaries. Include current activity/insight candidates and cloud task metadata."""
    song = read_song(track_id)
    return {"track_id": track_id, "revision": song["revision"], "duration_s": song["duration"],
            "bpm": song.get("bpm"), "key": song.get("key"), "status": song["status"],
            "sections": [item for m in sorted(song["marks"], key=lambda r: r["start"]) if m["kind"] == "section" and (item := effective(m)) is not None],
            "emotions": [item for m in song["marks"] if m["kind"] == "emotion" and (item := effective(m)) is not None],
            "insights": [item for m in song["marks"] if m["kind"] == "insight" and (item := effective(m)) is not None],
            "cloud_runs": [{key: value for key, value in run.items() if key != "context"}
                           for run in song.get("cloudRuns") or []],
            "cloud_batches": song.get("cloudBatches") or [], "warnings": song.get("warnings") or {},
            "coverage": song.get("coverage") or {},
            "events": [item for m in song["marks"] if m["kind"] == "event" and (item := effective(m)) is not None],
            "rhythm": [item for m in song["marks"] if m["kind"] == "rhythm_summary" and (item := effective(m)) is not None],
            "melody": [item for m in song["marks"] if m["kind"] == "melody_summary" and (item := effective(m)) is not None],
            "loudness": [item for m in song["marks"] if m["kind"] == "loudness" and (item := effective(m)) is not None],
            "tonality_regions": [item for m in song["marks"] if m["kind"] in ("key_region", "modulation") and (item := effective(m)) is not None],
            "repetitions": [item for m in song["marks"] if m["kind"] == "repetition" and (item := effective(m)) is not None]}


@server.tool()
def get_music_record(track_id: str) -> dict[str, object]:
    """Return the complete saved analysis record, including original model suggestions, user confirmations,
    hints, metrics, module status and local audio/stem paths. Audio file contents are not included."""
    return read_song(track_id)


@server.tool()
def get_music_timeline(track_id: str, start_s: float, end_s: float, types: list[str] | None = None,
                       confirmed_only: bool = False) -> dict[str, object]:
    """Query [start_s,end_s) in original audio seconds. Types: section, beat, downbeat, onset, acoustic,
    emotion, chord, key, key_region, modulation, lyric, word, note, insight, loudness, event,
    rhythm_beat, tempo, rhythm_summary, repetition, pitch, melody_note, melody_summary, melody_phrase, melody_motif. Stale or rejected suggestions are
    excluded unless the field has a human confirmation. Hints are separate from confirmed values."""
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
