"""Real stdio MCP client and isolated loopback tests. No Claude or foreground App is launched."""
import asyncio
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import tempfile
import unittest

import httpx

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "MusicIntelligenceTool/MusicIntelligenceTool/Backend"


class ChannelClient:
    async def start(self, port):
        self.request_id = 0
        self.process = await asyncio.create_subprocess_exec(
            sys.executable, str(BACKEND / "music_channel.py"), "--port", str(port),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=4 * 1024 * 1024)
        initialized = await self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                   "clientInfo": {"name": "local-channel-test", "version": "1"}})
        self.capabilities = initialized["result"]["capabilities"]
        await self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        async with httpx.AsyncClient() as client:
            for _ in range(100):
                try:
                    await client.get(f"http://127.0.0.1:{port}/handoff/unknown")
                    return
                except httpx.ConnectError:
                    await asyncio.sleep(.05)
        raise TimeoutError("Channel HTTP bridge did not start")

    async def send(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        await self.process.stdin.drain()

    async def read(self, timeout=10):
        line = await asyncio.wait_for(self.process.stdout.readline(), timeout)
        if not line:
            raise RuntimeError((await self.process.stderr.read()).decode())
        return json.loads(line)

    async def call(self, method, params):
        self.request_id += 1
        await self.send({"jsonrpc": "2.0", "id": self.request_id, "method": method, "params": params})
        reply = await self.read()
        if reply.get("id") != self.request_id:
            raise AssertionError(f"Unexpected MCP message: {reply.get('method')}")
        return reply

    async def page(self, handoff_id, offset=0, limit=100):
        return await self.call("tools/call", {"name": "get_music_handoff", "arguments": {
            "handoff_id": handoff_id, "offset": offset, "limit": limit}})

    async def stop(self):
        self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), 5)
        except asyncio.TimeoutError:
            self.process.terminate()
            await asyncio.wait_for(self.process.wait(), 5)


class ChannelTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.url = f"http://127.0.0.1:{port}/handoff"
        self.channel = ChannelClient()
        self.addAsyncCleanup(self.channel.stop)
        await self.channel.start(port)
        self.http = httpx.AsyncClient()
        self.addAsyncCleanup(self.http.aclose)
        self.record = json.loads((BACKEND.parent / "Study.json").read_text())
        self.record.update(trackID="a" * 64, path="/fixture/练习.wav", stems={"人声": "/fixture/vocals.wav"})

    async def test_full_snapshot_pages_and_read_receipt(self):
        self.assertIn("claude/channel", self.channel.capabilities["experimental"])
        tools = (await self.channel.call("tools/list", {}))["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["get_music_handoff"])
        model_row = dict(self.record["marks"][0], source="model", startConfirmed=True,
                         fields={"label": {"suggested": "模型段名", "confirmed": "校对段名", "hint": "需试听\n入鼓"}},
                         metrics={"rms": .25})
        self.record["marks"] += [dict(model_row, id=f"model-{i}") for i in range(405)]
        self.record["futureMetadata"] = {"nested": [None, True, "保留未知字段"]}
        response = await self.http.post(self.url, json=self.record)
        self.assertEqual(response.status_code, 202)
        handoff_id = response.json()["handoff_id"]
        event = await self.channel.read()
        self.assertEqual(event["method"], "notifications/claude/channel")
        self.assertEqual(event["params"]["meta"]["handoff_id"], handoff_id)
        status_url = f"{self.url}/{handoff_id}"
        self.assertEqual((await self.http.get(status_url)).json()["status"], "queued")

        # Reading the last page first is not evidence that all earlier pages were consumed.
        last = (await self.channel.page(handoff_id, 400))["result"]["structuredContent"]
        self.assertIsNone(last["next_offset"])
        self.assertEqual((await self.http.get(status_url)).json()["status"], "reading")
        marks = []
        offset = 0
        while offset is not None:
            page = (await self.channel.page(handoff_id, offset))["result"]["structuredContent"]
            marks.extend(page["record"]["marks"])
            offset = page["next_offset"]
        assembled = dict(page["record"], marks=marks)
        self.assertEqual(assembled, self.record)
        self.assertEqual((await self.http.get(status_url)).json()["status"], "read")

        # A second send retains the first revision's exact model and editorial data.
        self.record["revision"] += 1
        self.record["marks"] = []
        await self.http.post(self.url, json=self.record)
        await self.channel.read()
        original = (await self.channel.page(handoff_id))["result"]["structuredContent"]
        self.assertEqual(original["record"]["revision"], self.record["revision"] - 1)
        self.assertEqual(original["record"]["marks"], assembled["marks"][:100])

    async def test_invalid_requests_and_empty_record(self):
        self.assertEqual((await self.http.post(self.url, json=self.record, headers={"Origin": "https://example.com"})).status_code, 403)
        self.assertEqual((await self.http.post(self.url, json={})).status_code, 400)
        self.assertEqual((await self.http.post(self.url, content="{", headers={"Content-Type": "application/json"})).status_code, 400)
        self.assertEqual((await self.http.post(self.url, json=self.record, headers={"Host": "example.com"})).status_code, 400)
        self.record["marks"] = []
        handoff_id = (await self.http.post(self.url, json=self.record)).json()["handoff_id"]
        await self.channel.read()
        for offset, limit in [(-1, 100), (0, 0), (0, 101), (1, 100)]:
            reply = await self.channel.page(handoff_id, offset, limit)
            self.assertTrue(reply["result"]["isError"])
        self.assertEqual((await self.http.get(f"{self.url}/{handoff_id}")).json()["status"], "queued")
        result = (await self.channel.page(handoff_id))["result"]["structuredContent"]
        self.assertEqual(result["record"], self.record)
        self.assertIsNone(result["next_offset"])
        self.assertEqual((await self.http.get(f"{self.url}/{handoff_id}")).json()["status"], "read")
        self.assertTrue((await self.channel.page("missing"))["result"]["isError"])

    @unittest.skipUnless(os.getenv("MIT_SWIFT_HANDOFF_CHECK"), "Run script/check_agent_handoff.sh for headless Swift integration")
    async def test_native_sender_and_clipboard_preserve_complete_record(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Path(temp) / "record.json"
            self.record["marks"][0]["fields"]["label"].update(suggested="模型原建议", hint="需试听")
            fixture.write_text(json.dumps(self.record))
            port = self.url.split(":")[-1].split("/")[0]
            sender = await asyncio.create_subprocess_exec(
                os.environ["MIT_SWIFT_HANDOFF_CHECK"], str(fixture),
                env=dict(os.environ, MIT_CHANNEL_PORT=port),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                event = await self.channel.read()
                handoff_id = event["params"]["meta"]["handoff_id"]
                page = (await self.channel.page(handoff_id))["result"]["structuredContent"]
                self.assertEqual(page["record"], self.record)
                stdout, stderr = await asyncio.wait_for(sender.communicate(), 10)
                self.assertEqual(sender.returncode, 0, stderr.decode())
                self.assertIn("Claude Code 已读取完整记录", stdout.decode())
            finally:
                if sender.returncode is None:
                    sender.terminate()
                    await sender.wait()

            offline = await asyncio.create_subprocess_exec(
                os.environ["MIT_SWIFT_HANDOFF_CHECK"], str(fixture), "offline",
                env=dict(os.environ, MIT_CHANNEL_PORT="0"),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            stdout, stderr = await asyncio.wait_for(offline.communicate(), 10)
            self.assertEqual(offline.returncode, 0, stderr.decode())
            self.assertIn("未确认发送", stdout.decode())


@unittest.skipUnless(os.getenv("MIT_SWIFT_HANDOFF_CHECK"), "Run script/check_agent_handoff.sh for headless Swift integration")
class NativeSenderSwitchTests(unittest.IsolatedAsyncioTestCase):
    async def test_late_responses_do_not_replace_the_current_song_handoff(self):
        # Real URLSession requests use a controlled HTTP peer to hold specific responses in flight.
        # The ChannelTests above cover the real service; this fixture isolates sender timing and errors.
        for phase in ("post", "receipt", "transport-error"):
            for roundtrip in (False, True):
                with self.subTest(phase=phase, roundtrip=roundtrip), tempfile.TemporaryDirectory() as temp:
                    directory = Path(temp)
                    for name in ("first.wav", "second.wav"):
                        shutil.copyfile(BACKEND.parent / "Study.wav", directory / name)
                    old_pending = asyncio.Event()
                    new_pending = asyncio.Event()
                    release_old = asyncio.Event()
                    release_new = asyncio.Event()
                    records = []

                    async def handle(reader, writer):
                        try:
                            headers = (await reader.readuntil(b"\r\n\r\n")).decode()
                            method, path, _ = headers.splitlines()[0].split()
                            code = 200
                            if method == "POST":
                                length = next(int(line.split(":", 1)[1]) for line in headers.splitlines()[1:]
                                              if line.lower().startswith("content-length:"))
                                records.append(json.loads(await reader.readexactly(length)))
                                handoff_id = "old" if len(records) == 1 else "new"
                                if handoff_id == "new":
                                    new_pending.set()
                                    await release_new.wait()
                                elif phase != "receipt":
                                    old_pending.set()
                                    await release_old.wait()
                                    if phase == "transport-error":
                                        # A malformed HTTP status line makes URLSession throw before decoding a receipt.
                                        writer.write(b"INVALID RESPONSE\r\n\r\n")
                                        await writer.drain()
                                        return
                                code = 202
                                payload = {"handoff_id": handoff_id, "status": "queued"}
                            else:
                                handoff_id = path.rsplit("/", 1)[-1]
                                if handoff_id == "old":
                                    old_pending.set()
                                    await release_old.wait()
                                payload = {"handoff_id": handoff_id, "status": "read"}
                            body = json.dumps(payload).encode()
                            writer.write(f"HTTP/1.1 {code} OK\r\nContent-Type: application/json\r\n"
                                         f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)
                            await writer.drain()
                        finally:
                            writer.close()
                            await writer.wait_closed()

                    server = await asyncio.start_server(handle, "127.0.0.1", 0)
                    async with server:
                        port = server.sockets[0].getsockname()[1]
                        sender = await asyncio.create_subprocess_exec(
                            os.environ["MIT_SWIFT_HANDOFF_CHECK"], str(directory), "switch",
                            "roundtrip" if roundtrip else "different",
                            env=dict(os.environ, MIT_CHANNEL_PORT=str(port)),
                            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                        try:
                            await asyncio.wait_for(old_pending.wait(), 5)
                            (directory / "switch").touch()
                            await asyncio.wait_for(new_pending.wait(), 5)
                            self.assertEqual(Path(records[0]["path"]).name, "first.wav")
                            self.assertEqual(Path(records[1]["path"]).name,
                                             "first.wav" if roundtrip else "second.wav")
                            release_old.set()
                            async def wait_for_old_completion():
                                while not (directory / "old-finished").exists():
                                    if sender.returncode is not None:
                                        stdout, stderr = await sender.communicate()
                                        self.fail(f"Swift sender exited early: {stdout.decode()}\n{stderr.decode()}")
                                    await asyncio.sleep(.01)
                            await asyncio.wait_for(wait_for_old_completion(), 5)
                            release_new.set()
                            stdout, stderr = await asyncio.wait_for(sender.communicate(), 5)
                            self.assertEqual(sender.returncode, 0, stderr.decode())
                            self.assertIn("Song switch handoff checks passed", stdout.decode())
                        finally:
                            release_old.set()
                            release_new.set()
                            if sender.returncode is None:
                                sender.terminate()
                                await sender.wait()


if __name__ == "__main__":
    unittest.main()
