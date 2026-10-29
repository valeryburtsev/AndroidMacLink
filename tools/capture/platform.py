"""Decode the PLATFORM envelope carried in DCG fragments: version byte, header table, payload.

Layout: u8 version(=1), u32le header_bytes, u32le header_count, then per header u32le len + UTF-8 key
and u32le len + UTF-8 value, then u64le payload_len and the payload. Windows counts the 4-byte
header_count inside header_bytes; Android does not. Both are accepted.
"""
import struct


def decode(raw: bytes) -> dict:
    if len(raw) < 9 or raw[0] != 1:
        raise ValueError("not a version-1 PLATFORM envelope")
    header_bytes, count = struct.unpack_from("<II", raw, 1)
    if count > 64:
        raise ValueError("implausible header count")
    pos, headers = 9, {}
    for _ in range(count):
        pair = []
        for _ in range(2):
            (n,) = struct.unpack_from("<I", raw, pos); pos += 4
            if pos + n > len(raw): raise ValueError("header runs past end")
            pair.append(raw[pos:pos + n].decode("utf-8")); pos += n
        headers[pair[0]] = pair[1]
    consumed = pos - 5
    convention = "windows" if consumed == header_bytes else "android" if consumed - 4 == header_bytes else "unknown"
    (payload_len,) = struct.unpack_from("<Q", raw, pos); pos += 8
    if pos + payload_len != len(raw):
        raise ValueError(f"payload length {payload_len} does not match remaining {len(raw) - pos}")
    return {"headers": headers, "payload": raw[pos:], "convention": convention}
