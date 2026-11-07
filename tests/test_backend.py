"""Run from the checkout with .venv/bin/python -m unittest discover -s tests."""
import asyncio
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
    def test_model_assets_preserve_verified_cache_and_checks_stay_offline(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp)/"remote.bin", Path(temp)/"cache/model.bin"
            source.write_bytes(b"complete fixture")
            environment.fetch(source.as_uri(), target, environment.digest(source))
            source.write_bytes(b"damaged")
            with self.assertRaisesRegex(ValueError, "校验失败"):
                environment.fetch(source.as_uri(), target, environment.digest(target))
            self.assertEqual(target.read_bytes(), b"complete fixture")
            self.assertEqual(list(target.parent.iterdir()), [target])
            with patch.dict("os.environ", XDG_CACHE_HOME=temp, MIT_WHISPER_MODEL="base"):
                with patch.object(environment, "fetch", side_effect=AssertionError("unexpected download")):
                    self.assertEqual(environment.whisper_weights(False)["state"], "missing")
                self.assertFalse((Path(temp)/"whisper").exists())

    def test_original_gain_stereo_and_loudness_startup(self):
        import numpy as np
        import soundfile as sf
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/"stereo.wav"
            sr = 48000
            tone = .5 * np.sin(2 * np.pi * 440 * np.arange(sr * 4) / sr)
            sf.write(path, np.column_stack((tone, -tone)), sr, subtype="FLOAT")
            result = worker.acoustic_or_harmony(path, "acoustics", 7, 4)
            summary = next(r for r in result["marks"] if r["kind"] == "loudness")
            metrics = summary["metrics"]
            self.assertEqual((summary["start"], summary["end"]), (7, 11))
            self.assertAlmostEqual(metrics["sample_peak_dbfs"], -6.0206, places=3)
            self.assertAlmostEqual(metrics["crest_db"], 3.0103, places=3)
            self.assertAlmostEqual(metrics["stereo_correlation"], -1, places=5)
            self.assertEqual(metrics["sample_rate_hz"], sr)
            self.assertEqual(metrics["channels"], 2)
            curve = [r for r in result["marks"] if r["kind"] == "acoustic"]
            self.assertEqual(len(curve), 4)
            self.assertGreater(curve[0]["metrics"]["rms"], .3)
            self.assertNotIn("short_lufs", curve[0]["metrics"])
            self.assertNotIn("short_lufs", curve[1]["metrics"])
            self.assertIn("short_lufs", curve[3]["metrics"])
            sf.write(path, np.column_stack((tone / 2, -tone / 2)), sr, subtype="FLOAT")
            quieter = worker.acoustic_or_harmony(path, "acoustics", 0, 4)
            quiet_metrics = next(r["metrics"] for r in quieter["marks"] if r["kind"] == "loudness")
            self.assertAlmostEqual(metrics["integrated_lufs"] - quiet_metrics["integrated_lufs"], 6.02, places=1)
            worker.cut(APP/"Study.wav", path, 2, 4)
            study = worker.acoustic_or_harmony(path, "acoustics", 2, 4)["marks"]
            self.assertTrue(any(row["kind"] == "onset" for row in study))
            curves = [row for row in study if row["kind"] == "acoustic"]
            self.assertEqual([row["start"] for row in curves], [2, 3, 4, 5])
            for row in curves:
                self.assertAlmostEqual(sum(row["metrics"][key+"_share"] for key in ("low", "mid", "high")), 1)
            sf.write(path, np.zeros(sr), sr)
            silent = worker.acoustic_or_harmony(path, "acoustics", 0, 1)["marks"]
            self.assertEqual([row["kind"] for row in silent], ["loudness"])
            self.assertNotIn("integrated_lufs", silent[0]["metrics"])

            record, output = Path(temp)/"input.json", Path(temp)/"output.json"
            record.write_text(json.dumps({"path": str(path), "duration": 1.05, "marks": []}))
            tail_frames = sr//20
            samples = np.zeros((sr + tail_frames, 2), dtype=np.int16)
            samples[-tail_frames:] = [32767, -32768]
            sf.write(path, samples, sr, subtype="PCM_16")
            command = [sys.executable, worker.__file__, "acoustics", str(record), str(output), temp, "0", "1.05"]
            subprocess.run(command, check=True)
            peak_metrics = json.loads(output.read_text())["marks"][0]["metrics"]
            self.assertAlmostEqual(peak_metrics["full_scale_fraction"], tail_frames/len(samples))
            self.assertAlmostEqual(peak_metrics["true_peak_dbtp"], 1.1, delta=.2)

            samples = np.full((sr + tail_frames, 2), 2147483646, dtype=np.int32)
            samples[:, 0] = 2147483647
            sf.write(path, samples, sr, subtype="PCM_32")
            subprocess.run(command, check=True)
            peak_metrics = json.loads(output.read_text())["marks"][0]["metrics"]
            self.assertEqual(peak_metrics["full_scale_fraction"], .5)


    def test_harmony_does_not_fill_silent_gaps_and_scores_are_not_probabilities(self):
        import numpy as np
        import soundfile as sf
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/"chords.wav"
            sr = 22050
            times = np.arange(sr * 7) / sr
            chord = sum(.12 * np.sin(2 * np.pi * f * times) for f in (220, 261.6256, 329.6276))
            chord[2*sr:5*sr] = 0
            sf.write(path, np.column_stack((chord, -chord)), sr, subtype="FLOAT")
            result = worker.acoustic_or_harmony(path, "harmony", 10, 7)
            chords = [r for r in result["marks"] if r["kind"] == "chord"]
            self.assertTrue(chords)
            self.assertTrue(any(r["fields"]["label"]["suggested"] == "Am" for r in chords))
            self.assertFalse(any(r["start"] < 15 and r["end"] > 12 for r in chords))
            self.assertTrue(all("template_similarity" in r["metrics"] and "template_margin" in r["metrics"] for r in chords))


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
            for state in ("stale", "rejected", "confirmed"):
                insight = worker.mark("insight", 13, 14, "fixture", "旧建议")
                field = insight["fields"]["label"]
                field["origin"] = {"runID":"fixture-run", "provider":"openRouter", "model":"fixture", "evidenceIDs":["audio"], "uncertainty":"待核对", "stale":state != "rejected"}
                if state == "confirmed":
                    field["confirmed"] = ""
                elif state == "rejected":
                    field["rejected"] = True
                song["marks"].append(insight)
            song["cloudRuns"] = [{"id":"fixture-run", "task":"interpretation", "provider":"openRouter", "model":"fixture", "range":{"start":13,"end":14}, "inputRevision":1, "inputFingerprint":"fixture", "promptVersion":"fixture", "createdAt":0, "status":"待更新"}]

            stale_emotion = worker.mark("emotion", 14, 15, "fixture", "过期情绪")
            stale_emotion["analysisStale"] = True
            reviewed_rhythm = worker.mark("rhythm_summary", 14, 15, "fixture", "过期速度")
            reviewed_rhythm["analysisStale"] = True
            reviewed_rhythm["fields"]["meter"] = {"confirmed": "4/4"}
            song["marks"].extend([stale_emotion, reviewed_rhythm])
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
                                         {"analyze_music","get_music_overview","get_music_timeline","get_music_record"})
                        request = asyncio.create_task(session.call_tool("analyze_music",{"path":str(APP/"Study.wav")}))
                        message = json.loads(await asyncio.wait_for(process.stdout.readline(), 5))
                        self.assertEqual(message["path"], str(APP/"Study.wav"))
                        process.stdin.write((json.dumps({"track_id":track,"status":"ready"})+"\n").encode())
                        await process.stdin.drain()
                        self.assertFalse((await request).isError)
                        overview = await session.call_tool("get_music_overview",{"track_id":track})
                        self.assertFalse(overview.isError, overview.content)
                        self.assertIsNotNone(overview.structuredContent, overview.content)
                        self.assertEqual(overview.structuredContent["revision"],1)
                        self.assertNotIn(stale_emotion["id"], [item["id"] for item in overview.structuredContent["emotions"]])
                        expected_meter = {"meter": {"value": "4/4", "source": "user"}}
                        self.assertEqual(overview.structuredContent["rhythm"][0]["fields"], expected_meter)
                        record = await session.call_tool("get_music_record", {"track_id": track})
                        self.assertEqual(record.structuredContent, song)
                        params = dict(track_id=track,start_s=0,end_s=12,confirmed_only=True)
                        timeline = (await session.call_tool("get_music_timeline",params)).structuredContent
                        self.assertEqual(len(timeline["items"]),1)
                        self.assertNotIn("hints",timeline["items"][0])
                        self.assertEqual(timeline["items"][0]["fields"]["label"]["source"],"user")
                        params.update(start_s=12,end_s=13,types=["beat"],confirmed_only=False)
                        beat_data = (await session.call_tool("get_music_timeline",params)).structuredContent
                        self.assertEqual(beat_data["items"][0]["start_s"],12)
                        visible = (await session.call_tool("get_music_timeline", dict(track_id=track, start_s=13, end_s=14, types=["insight"]))).structuredContent["items"]
                        self.assertEqual(len(visible), 1)
                        self.assertEqual(visible[0]["fields"]["label"]["value"], "")
                        self.assertEqual(visible[0]["fields"]["label"]["source"], "user")
                        reviewed = (await session.call_tool("get_music_timeline", dict(
                            track_id=track, start_s=14, end_s=15, types=["rhythm_summary"], confirmed_only=True
                        ))).structuredContent["items"]
                        self.assertEqual(reviewed[0]["fields"], expected_meter)

                        invalid = await session.call_tool("get_music_overview",{"track_id":"../secret"})
                        self.assertTrue(invalid.isError)
            finally:
                process.stdin.close()
                process.terminate()
                await asyncio.wait_for(process.wait(), 5)


if __name__ == "__main__":
    unittest.main()
