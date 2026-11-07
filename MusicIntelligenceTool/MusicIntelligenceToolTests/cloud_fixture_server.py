"""Bundled, isolated HTTP fixture for app tests; never contacts a model provider."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.reply(200, {"data": [{"id": "fixture/audio", "architecture": {"input_modalities": ["text", "audio"]},
                                  "supported_parameters": ["structured_outputs"]}]})

    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer fixture-key" or "/deny/" in self.path:
            self.reply(401, {"error": {"message": "fixture failure"}})
            return
        if "/redirect/" in self.path:
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/unexpected")
            self.end_headers()
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        (root / "last-request.json").write_text(json.dumps(body))
        with (root / "requests.log").open("a") as log:
            log.write(self.path + "\n")
        if "/slow/" in self.path:
            time.sleep(3)
        responses = self.path.endswith("/responses")
        parts = body["input"][0]["content"] if responses else body["messages"][-1]["content"]
        context = json.loads(parts[0]["text"])
        if "/gate-second/" in self.path and context["range"]["start"] == 1:
            deadline = time.monotonic() + 5
            while not (root / "release-second").exists() and time.monotonic() < deadline:
                time.sleep(.02)
        with (root / "contexts.jsonl").open("a") as log:
            log.write(json.dumps(context) + "\n")
        if "/fail-once/" in self.path and context["range"]["start"] >= 1 and not (root/"failed-once").exists():
            (root/"failed-once").touch()
            self.reply(503, {"error": {"message": "temporary fixture failure"}})
            return
        has_audio = any(part["type"] == "input_audio" for part in parts)
        references = context.get("audioReferences") or [{"id": "audio"}]
        evidence = [references[0]["id"]] if has_audio else [context["items"][0]["id"]]
        if "/invalid/" in self.path:
            evidence = ["invented-id"]
        result = {"findings": [{"category": "summary", "start": context["range"]["start"],
                                 "end": context["range"]["end"], "label": "测试分析候选 · " + body["model"], "content": "固定测试响应，供校对流程验证。",
                                 "uncertainty": "非真实音乐判断", "evidenceIDs": evidence}]}
        usage = {"input_tokens": 100, "output_tokens": 20, "total_tokens": 120, "cost": 0.001}
        if responses:
            self.reply(200, {"status": "completed", "model": body["model"] + "-v1", "provider": "fixture",
                             "usage": usage, "output": [{"type": "message", "content": [{"type": "output_text", "text": json.dumps(result)}]}]})
        else:
            self.reply(200, {"model": body["model"] + "-v1", "provider": "fixture", "usage": usage,
                             "choices": [{"finish_reason": "length" if "/truncated/" in self.path else "stop",
                                          "message": {"content": json.dumps(result)}}]})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
