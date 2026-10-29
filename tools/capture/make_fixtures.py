#!/usr/bin/env python3
"""Turn a raw capture into sanitized, byte-exact hub frames for the Swift codec tests.

Every byte the real clients produced is kept except: (1) PLATFORM payload bytes are zeroed in
place, since they hold user content, and (2) UUIDs are replaced by same-length fakes derived from
a hash. Lengths and all encoding choices are untouched, so decoders and encoders can be checked
against real frames.

  make_fixtures.py captures/<session>/flows.jsonl app/Tests/WinPhoneCoreTests/Fixtures/relay-frames.json
"""
import base64, hashlib, importlib.util, json, re, sys
from pathlib import Path
here = Path(__file__).parent
sys.path.insert(0, str(here)); import wire
spec = importlib.util.spec_from_file_location("wp_platform", here / "platform.py"); P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)

UUID = re.compile(rb"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
def fake_uuid(m):
    h = hashlib.sha256(b"winphone-fixture" + m.group(0).lower()).hexdigest()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}".encode()

def find_raws(v):
    if isinstance(v, dict):
        if "Properties" in v and isinstance(v.get("Raw"), (bytes, bytearray)): yield bytes(v["Raw"])
        for x in v.values(): yield from find_raws(x)
    elif isinstance(v, list):
        for x in v: yield from find_raws(x)

def sanitize(frame: bytes) -> bytes:
    out = bytearray(frame)
    for raw in find_raws(wire.unpack_msgpack(frame)):
        at = frame.find(raw)
        if at < 0: raise ValueError("payload not found in frame")
        try:
            n = len(P.decode(raw)["payload"])
        except Exception:
            n = len(raw)  # not an envelope we understand: blank the whole thing
        out[at + len(raw) - n: at + len(raw)] = bytes(n)
    return UUID.sub(fake_uuid, bytes(out))

def main():
    src, dest = sys.argv[1], Path(sys.argv[2]); limit = 16384
    frames, skipped = [], 0
    for line in open(src):
        r = json.loads(line)
        if r["type"] != "ws" or "raw_b64" not in r: continue
        data = base64.b64decode(r["raw_b64"])
        if "handshake" in r: _, data = wire.split_handshake(data)
        for f in wire.split_frames(data) if data else []:
            if len(f) > limit: skipped += 1; continue
            s = sanitize(f)
            assert len(s) == len(f)
            frames.append({"dir": r["dir"], "hex": s.hex()})
    dest.write_text(json.dumps(frames, separators=(",", ":")))
    print(f"{len(frames)} frames written, {skipped} oversized skipped, {dest.stat().st_size} bytes")

if __name__ == "__main__":
    main()
