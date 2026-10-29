#!/usr/bin/env python3
"""Extract the notification exchange from a raw capture as sanitized, byte-exact envelopes.

Keeps every APP envelope on `/legacy/phonecontent` and `/notifications` whose payload mentions
notifications, plus the responses to them. Personal strings are replaced by same-length
placeholders, so every length prefix stays valid and the bytes still decode:

  make_notification_fixtures.py captures/<session>/flows.jsonl \
      app/Tests/WinPhoneCoreTests/Fixtures/notifications.json [name=replacement ...]

Each `name=replacement` pair replaces the exact text `name`; the replacement is padded or cut to
the same byte length. `seqs=12,15,20` instead keeps every APP envelope of exactly those capture
records, whatever its route; use it to leave out messages that carry real notifications. UUIDs are always replaced by hash-derived fakes. Only use this on a capture
of test notifications: titles and bodies are kept as they are.
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

def find_packets(v):
    if isinstance(v, dict):
        if "Properties" in v and isinstance(v.get("Raw"), (bytes, bytearray)): yield v
        for x in v.values(): yield from find_packets(x)
    elif isinstance(v, list):
        for x in v: yield from find_packets(x)

def main():
    src, dest = sys.argv[1], Path(sys.argv[2])
    swaps, seqs = [], None
    for pair in sys.argv[3:]:
        name, _, replacement = pair.partition("=")
        if name == "seqs":
            seqs = {int(x) for x in replacement.split(",")}
            continue
        a, b = name.encode(), replacement.encode()
        swaps.append((a, (b + b"_" * len(a))[:len(a)]))
    entries, wanted = [], set()
    for line in open(src):
        r = json.loads(line)
        if r["type"] != "ws" or "raw_b64" not in r: continue
        if seqs is not None and int(r["seq"]) not in seqs: continue
        data = base64.b64decode(r["raw_b64"])
        if "handshake" in r: _, data = wire.split_handshake(data)
        for frame in wire.split_frames(data) if data else []:
            try: message = wire.unpack_msgpack(frame)
            except Exception: continue
            for packet in find_packets(message):
                if int(packet["Properties"].get("MessageType", -1)) != 0: continue  # APP only
                raw = bytes(packet["Raw"])
                try: envelope = P.decode(raw)
                except Exception: continue
                headers = dict(envelope["headers"])
                route = headers.get("_route", "")
                is_notification = route in ("/legacy/phonecontent", "/notifications") and b"notifications" in envelope["payload"]
                is_reply = route == "/internal/response" and headers.get("_originalRequestId") in wanted
                if seqs is None and not (is_notification or is_reply): continue
                if "_requestId" in headers: wanted.add(headers["_requestId"])
                clean = raw
                for a, b in swaps: clean = clean.replace(a, b)
                clean = UUID.sub(fake_uuid, clean)
                assert len(clean) == len(raw)
                entries.append({"dir": r["dir"], "route": route, "hex": clean.hex()})
    dest.write_text(json.dumps(entries, separators=(",", ":")))
    left = [a.decode() for a, _ in swaps if any(a in bytes.fromhex(e["hex"]) for e in entries)]
    print(f"{len(entries)} envelopes written to {dest} ({dest.stat().st_size} bytes); unreplaced names: {left or 'none'}")

if __name__ == "__main__":
    main()
