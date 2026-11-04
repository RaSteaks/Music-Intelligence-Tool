"""Run from the checkout with .venv/bin/python -m unittest discover -s tests."""
import asyncio
import contextlib
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "MusicIntelligenceTool/MusicIntelligenceTool"
sys.path.insert(0, str(APP / "Backend"))
import analysis_worker as worker
import model_environment as environment
import music_mcp as api


class AnalysisTests(unittest.TestCase):
    def test_model_download_rejects_partial_or_wrong_weights(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "remote.bin"
            target = Path(temp) / "cache/model.bin"
            source.write_bytes(b"complete fixture")
            environment.fetch(source.as_uri(), target, environment.digest(source))
            source.write_bytes(b"damaged")
            with self.assertRaisesRegex(ValueError, "校验失败"):
                environment.fetch(source.as_uri(), target, environment.digest(target))
            self.assertEqual(target.read_bytes(), b"complete fixture")
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_whisper_check_does_not_download_missing_weights(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict("os.environ", XDG_CACHE_HOME=temp, MIT_WHISPER_MODEL="base"):
            with patch.object(environment, "fetch", side_effect=AssertionError("unexpected download")):
                result = environment.whisper_weights(False)
            self.assertEqual(result["state"], "missing")
            self.assertFalse((Path(temp) / "whisper").exists())

    def test_acoustic_measurement_and_chords_use_original_time(self):
        with tempfile.TemporaryDirectory() as temp:
            clip = Path(temp)/"clip.wav"
            worker.cut(APP/"Study.wav", clip, 2, 4)
            features = worker.acoustic_or_harmony(clip, "acoustics", 2, 4)
            curve = [r for r in features["marks"] if r["kind"] == "acoustic"]
            self.assertEqual([r["start"] for r in curve], [2, 3, 4, 5])
            self.assertTrue(any(-70 < r["metrics"].get("short_lufs", -100) < 0 for r in curve))
            self.assertTrue(any(r["kind"] == "onset" for r in features["marks"]))
            for row in curve:
                self.assertAlmostEqual(sum(row["metrics"][k+"_share"] for k in ("low","mid","high")), 1)
            harmony = worker.acoustic_or_harmony(clip, "harmony", 2, 4)
            self.assertTrue(harmony["marks"])
            self.assertTrue(any(r["fields"]["label"]["suggested"] == "Am" for r in harmony["marks"]))
            worker.cut(APP/"Study.wav", clip, 0, 1)
            self.assertEqual(worker.acoustic_or_harmony(clip, "acoustics", 0, 1)["marks"], [])


class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_http_discovery_import_overview_and_filtered_timeline(self):
        import os
        import httpx
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            track = "a"*64
            song = json.loads((APP/"Study.json").read_text())
            song.update(trackID=track,path=str(APP/"Study.wav"))
            beat = worker.mark("beat", 12, 12, "All-In-One")
            song["marks"].append(beat)
            song["marks"][0]["fields"]["mood"]["hint"] = "需试听"
            (root/track).mkdir()
            (root/track/"analysis.json").write_text(json.dumps(song))
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
            process = await asyncio.create_subprocess_exec(
                sys.executable, str(APP/"Backend/music_mcp.py"), str(root),
                env=dict(os.environ, MIT_MCP_PORT=str(port)), stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL)
            try:
                for _ in range(200):
                    try:
                        reader, writer = await asyncio.open_connection("127.0.0.1",port)
                        writer.close(); await writer.wait_closed(); break
                    except OSError:
                        await asyncio.sleep(.05)
                async with streamablehttp_client(f"http://127.0.0.1:{port}/mcp") as (read,write,_):
                    async with ClientSession(read,write) as session:
                        await session.initialize()
                        self.assertEqual({t.name for t in (await session.list_tools()).tools},
                                         {"analyze_music","get_music_overview","get_music_timeline"})
                        request = asyncio.create_task(session.call_tool("analyze_music",{"path":str(APP/"Study.wav")}))
                        message = json.loads(await asyncio.wait_for(process.stdout.readline(), 5))
                        self.assertEqual(message["path"], str(APP/"Study.wav"))
                        process.stdin.write((json.dumps({"track_id":track,"status":"ready"})+"\n").encode())
                        await process.stdin.drain()
                        self.assertFalse((await request).isError)
                        overview = await session.call_tool("get_music_overview",{"track_id":track})
                        self.assertEqual(overview.structuredContent["revision"],1)
                        params = dict(track_id=track,start_s=0,end_s=12,confirmed_only=True)
                        timeline = (await session.call_tool("get_music_timeline",params)).structuredContent
                        self.assertEqual(len(timeline["items"]),1)
                        self.assertNotIn("hints",timeline["items"][0])
                        self.assertEqual(timeline["items"][0]["fields"]["label"]["source"],"user")
                        params.update(start_s=12,end_s=13,types=["beat"],confirmed_only=False)
                        beat_data = (await session.call_tool("get_music_timeline",params)).structuredContent
                        self.assertEqual(beat_data["items"][0]["start_s"],12)
                        invalid = await session.call_tool("get_music_overview",{"track_id":"../secret"})
                        self.assertTrue(invalid.isError)
            finally:
                process.terminate()
                await process.wait()


if __name__ == "__main__":
    unittest.main()
