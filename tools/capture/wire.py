"""Pure helpers for Phone Link traffic capture: secret redaction and SignalR framing.

No mitmproxy imports here, so this module is unit-testable on its own.
Secrets are replaced at capture time, so they never reach disk. Each redacted
value keeps its length and a short SHA-256 prefix, which is enough to tell
"same token as before" from "new token" without being able to recover it.
"""
from __future__ import annotations

import base64
import hashlib
import json
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

SENSITIVE_HEADERS = {
    "authorization", "proxy-authorization", "cookie", "set-cookie",
    "useridentitytoken", "dcg-token", "dcg-cryptowakejwt", "x-ms-token",
}
SENSITIVE_KEYS = {
    "access_token", "refresh_token", "id_token", "device_code", "code", "token",
    "accesstoken", "refreshtoken", "connectiontoken", "certificatejwt",
    "client_secret", "password", "assertion", "user_code", "id",
}
# "id" is only sensitive as a URL query parameter (the SignalR connection token),
# so JSON bodies use this narrower set.
SENSITIVE_JSON_KEYS = (SENSITIVE_KEYS - {"id", "code"}) | {
    # account details returned by enrollment, and short-lived TURN credentials
    "signinname", "firstname", "lastname", "accountkey", "credential", "username",
}
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")
RECORD_SEPARATOR = 0x1E


def redacted(value: str | bytes) -> dict:
    raw = value.encode("utf-8", "replace") if isinstance(value, str) else bytes(value)
    return {"redacted": True, "len": len(raw), "sha256_12": hashlib.sha256(raw).hexdigest()[:12]}


def redact_headers(pairs) -> list[list]:
    out = []
    for name, value in pairs:
        out.append([name, redacted(value) if name.lower() in SENSITIVE_HEADERS else scrub_text(value)])
    return out


def redact_url(url: str) -> str:
    parts = urlsplit(url)
    query = [
        (k, "REDACTED" if k.lower() in SENSITIVE_KEYS else v)
        for k, v in parse_qsl(parts.query, keep_blank_values=True)
    ]
    netloc = parts.hostname or ""
    if parts.port:
        netloc += f":{parts.port}"
    return urlunsplit((parts.scheme, netloc, parts.path, urlencode(query), ""))


def scrub_text(text: str) -> str:
    """Replace anything shaped like a JWT inside free text."""
    return JWT_RE.sub(lambda m: f"<jwt sha256_12={hashlib.sha256(m.group(0).encode()).hexdigest()[:12]}>", text)


def redact_json(value, keys=SENSITIVE_JSON_KEYS):
    if isinstance(value, dict):
        return {
            k: (redacted(json.dumps(v)) if str(k).lower() in keys and v not in (None, "") else redact_json(v, keys))
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [redact_json(v, keys) for v in value]
    if isinstance(value, str):
        return scrub_text(value)
    return value


def describe_body(content: bytes | None, content_type: str, inline_limit: int = 65536) -> dict:
    """Return a JSON-safe, redacted description of an HTTP body."""
    if not content:
        return {"kind": "empty"}
    info = {"len": len(content), "sha256": hashlib.sha256(content).hexdigest()}
    ctype = (content_type or "").split(";")[0].strip().lower()
    if ctype.endswith("json") or content[:1] in (b"{", b"["):
        try:
            return {**info, "kind": "json", "json": redact_json(json.loads(content))}
        except ValueError:
            pass
    if ctype == "application/x-www-form-urlencoded":
        try:
            form = parse_qsl(content.decode("utf-8"), keep_blank_values=True)
            return {**info, "kind": "form", "form": [
                [k, redacted(v) if k.lower() in SENSITIVE_KEYS and v else scrub_text(v)] for k, v in form
            ]}
        except UnicodeDecodeError:
            pass
    if len(content) > inline_limit:
        return {**info, "kind": "blob"}  # caller stores the bytes by digest
    try:
        return {**info, "kind": "text", "text": scrub_text(content.decode("utf-8"))}
    except UnicodeDecodeError:
        return {**info, "kind": "binary", "b64": base64.b64encode(content).decode()}


# ---- Minimal MessagePack decoder --------------------------------------------------------
# mitmproxy's bundled Python ships no msgpack module, so the addon decodes with this.

import struct


def unpack_msgpack(buf: bytes):
    """Decode exactly one MessagePack value; raise ValueError on trailing or missing bytes."""
    value, pos = _unpack(memoryview(buf), 0, 0)
    if pos != len(buf):
        raise ValueError(f"{len(buf) - pos} trailing byte(s) after MessagePack value")
    return value


def _take(buf, pos, n):
    if pos + n > len(buf):
        raise ValueError("truncated MessagePack value")
    return bytes(buf[pos:pos + n]), pos + n


def _unpack(buf, pos, depth):
    if depth > 64:
        raise ValueError("MessagePack nesting too deep")
    head, pos = _take(buf, pos, 1)
    b = head[0]
    if b <= 0x7F:
        return b, pos
    if b >= 0xE0:
        return b - 0x100, pos
    if 0x80 <= b <= 0x8F:
        return _map(buf, pos, b & 0x0F, depth)
    if 0x90 <= b <= 0x9F:
        return _array(buf, pos, b & 0x0F, depth)
    if 0xA0 <= b <= 0xBF:
        raw, pos = _take(buf, pos, b & 0x1F)
        return raw.decode("utf-8", "replace"), pos
    if b == 0xC0:
        return None, pos
    if b in (0xC2, 0xC3):
        return b == 0xC3, pos
    if b in (0xC4, 0xC5, 0xC6, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF):
        width = {0xC4: 1, 0xC5: 2, 0xC6: 4, 0xD9: 1, 0xDA: 2, 0xDB: 4, 0xDC: 2, 0xDD: 4, 0xDE: 2, 0xDF: 4}[b]
        raw, pos = _take(buf, pos, width)
        n = int.from_bytes(raw, "big")
        if b in (0xDC, 0xDD):
            return _array(buf, pos, n, depth)
        if b in (0xDE, 0xDF):
            return _map(buf, pos, n, depth)
        raw, pos = _take(buf, pos, n)
        return (raw if b <= 0xC6 else raw.decode("utf-8", "replace")), pos
    if b in (0xCA, 0xCB):
        raw, pos = _take(buf, pos, 4 if b == 0xCA else 8)
        return struct.unpack(">f" if b == 0xCA else ">d", raw)[0], pos
    if 0xCC <= b <= 0xD3:
        width = 1 << ((b - 0xCC) & 3)
        raw, pos = _take(buf, pos, width)
        return int.from_bytes(raw, "big", signed=b >= 0xD0), pos
    if b in (0xC7, 0xC8, 0xC9) or 0xD4 <= b <= 0xD8:  # ext types
        if b <= 0xC9:
            raw, pos = _take(buf, pos, 1 << (b - 0xC7))
            n = int.from_bytes(raw, "big")
        else:
            n = 1 << (b - 0xD4)
        kind, pos = _take(buf, pos, 1)
        raw, pos = _take(buf, pos, n)
        return {"ext_type": int.from_bytes(kind, "big", signed=True), "data": raw}, pos
    raise ValueError(f"invalid MessagePack byte 0x{b:02x}")


def _array(buf, pos, n, depth):
    if n > len(buf) - pos:
        raise ValueError("MessagePack array length exceeds remaining bytes")
    out = []
    for _ in range(n):
        item, pos = _unpack(buf, pos, depth + 1)
        out.append(item)
    return out, pos


def _map(buf, pos, n, depth):
    if 2 * n > len(buf) - pos:
        raise ValueError("MessagePack map length exceeds remaining bytes")
    out = {}
    for _ in range(n):
        key, pos = _unpack(buf, pos, depth + 1)
        out[key if isinstance(key, (str, int)) else repr(key)], pos = _unpack(buf, pos, depth + 1)
    return out, pos


# ---- SignalR (MessagePack hub protocol) -------------------------------------------------

def read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    """SignalR length prefix: little-endian base-128, at most 5 bytes."""
    value = shift = 0
    for i in range(5):
        if pos + i >= len(buf):
            raise ValueError("truncated length prefix")
        byte = buf[pos + i]
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos + i + 1
        shift += 7
    raise ValueError("length prefix longer than 5 bytes")


def split_frames(buf: bytes) -> list[bytes]:
    frames, pos = [], 0
    while pos < len(buf):
        size, pos = read_varint(buf, pos)
        if pos + size > len(buf):
            raise ValueError("frame runs past end of WebSocket message")
        frames.append(buf[pos:pos + size])
        pos += size
    return frames


def split_handshake(buf: bytes) -> tuple[bytes, bytes]:
    """Return (handshake_json, trailing_bytes). The handshake ends at 0x1e."""
    end = buf.find(bytes([RECORD_SEPARATOR]))
    if end < 0:
        raise ValueError("no record separator in handshake")
    return buf[:end], buf[end + 1:]


HUB_TYPES = {1: "Invocation", 2: "StreamItem", 3: "Completion", 4: "StreamInvocation",
             5: "CancelInvocation", 6: "Ping", 7: "Close"}


def jsonable(value):
    """Make a decoded MessagePack value JSON-safe; payload bytes are kept (base64) for decoding later."""
    if isinstance(value, (bytes, bytearray)):
        return {"bytes_b64": base64.b64encode(bytes(value)).decode(), "len": len(value)}
    if isinstance(value, dict):
        return {str(k): jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    if isinstance(value, str):
        return scrub_text(value)
    return value


def describe_hub_frame(frame: bytes) -> dict:
    """Decode one hub message: [type, headers, invocationId, target, arguments, streamIds]."""
    msg = unpack_msgpack(frame)
    out = {"hub_type": HUB_TYPES.get(msg[0], msg[0]) if isinstance(msg, list) and msg else None}
    if isinstance(msg, list) and msg and msg[0] in (1, 4) and len(msg) >= 5:
        out.update(invocation_id=msg[2], target=msg[3], arguments=jsonable(msg[4]))
    else:
        out["message"] = jsonable(msg)
    return out
