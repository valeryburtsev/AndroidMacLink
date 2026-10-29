"""mitmproxy addon: record Phone Link cloud traffic as redacted JSON lines.

Usage (proxy the Windows VM or the Android phone through this Mac):

    mitmdump -s tools/capture/mitm_addon.py --set phonelink_out=captures/session1

Only hosts matching `phonelink_hosts` are recorded; everything else passes through
untouched and unlogged. Tokens, cookies and JWTs are redacted before anything is
written (see wire.py). SignalR WebSocket messages are split into hub frames and
MessagePack-decoded so DCG packets are readable.
"""
from __future__ import annotations

import base64
import json
import re
import sys
import time
from pathlib import Path

from mitmproxy import ctx, http

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wire  # noqa: E402

DEFAULT_HOSTS = r"(^|\.)dcg\.microsoft\.com$|^login\.(microsoftonline|live|microsoft)\.com$"


class PhoneLinkCapture:
    def __init__(self):
        self.out: Path | None = None
        self.hosts = re.compile(DEFAULT_HOSTS)
        self.seq = 0
        self.handshaken: dict[str, set[bool]] = {}

    def load(self, loader):
        loader.add_option("phonelink_out", str, "captures/session", "Output directory for this capture session")
        loader.add_option("phonelink_hosts", str, DEFAULT_HOSTS, "Regex of hostnames to record")
        loader.add_option("phonelink_raw_ws", bool, False, "Also store the raw bytes of each WebSocket message")

    def configure(self, updates):
        self.hosts = re.compile(ctx.options.phonelink_hosts)
        self.out = Path(ctx.options.phonelink_out)
        (self.out / "blobs").mkdir(parents=True, exist_ok=True)

    def _wanted(self, flow: http.HTTPFlow) -> bool:
        return bool(self.hosts.search(flow.request.pretty_host))

    def _write(self, record: dict):
        self.seq += 1
        record = {"seq": self.seq, "ts": round(time.time(), 3), **record}
        with open(self.out / "flows.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")

    def _body(self, message) -> dict:
        content = message.content
        info = wire.describe_body(content, message.headers.get("content-type", ""))
        if info.get("kind") == "blob":
            (self.out / "blobs" / info["sha256"]).write_bytes(content)
        return info

    def http_connect(self, flow: http.HTTPFlow):
        """Log only the host and port of every tunnel, so we learn which hosts the client uses."""
        with open(self.out / "hosts.log", "a", encoding="utf-8") as fh:
            fh.write(f"{round(time.time(), 3)} {flow.request.pretty_host}:{flow.request.port}\n")

    def response(self, flow: http.HTTPFlow):
        if not self._wanted(flow):
            return
        self._write({
            "type": "http", "flow": flow.id,
            "method": flow.request.method, "url": wire.redact_url(flow.request.pretty_url),
            "request_headers": wire.redact_headers(flow.request.headers.items(multi=True)),
            "request_body": self._body(flow.request),
            "status": flow.response.status_code,
            "response_headers": wire.redact_headers(flow.response.headers.items(multi=True)),
            "response_body": self._body(flow.response),
        })

    def websocket_message(self, flow: http.HTTPFlow):
        if not self._wanted(flow):
            return
        msg = flow.websocket.messages[-1]
        record = {"type": "ws", "flow": flow.id, "url": wire.redact_url(flow.request.pretty_url),
                  "dir": "c2s" if msg.from_client else "s2c", "text": msg.is_text, "len": len(msg.content)}
        if ctx.options.phonelink_raw_ws:
            # Exact bytes of the WebSocket message, for byte-level codec tests. Hub frames carry
            # no credentials (the connection token is in the URL), but they do carry payloads.
            record["raw_b64"] = base64.b64encode(msg.content).decode()
        done = self.handshaken.setdefault(flow.id, set())
        data = msg.content
        try:
            if msg.from_client not in done:  # first message each way is the JSON handshake
                handshake, data = wire.split_handshake(data)
                done.add(msg.from_client)
                record["handshake"] = json.loads(handshake or b"{}")
            if data:
                record["frames"] = [wire.describe_hub_frame(f) for f in wire.split_frames(data)]
        except Exception as exc:  # never drop a message because decoding failed
            record["decode_error"] = repr(exc)
            record["raw"] = wire.jsonable(msg.content)
        self._write(record)


addons = [PhoneLinkCapture()]
