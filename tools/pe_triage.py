#!/usr/bin/env python3
"""Classify PE files as managed (.NET IL), ReadyToRun (IL + precompiled) or native. Reads headers only."""
import struct, sys
from pathlib import Path

def classify(path: Path) -> str:
    d = path.read_bytes()[:4096] if path.stat().st_size >= 4096 else path.read_bytes()
    if d[:2] != b"MZ": return "not-pe"
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0": return "not-pe"
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    optsz = struct.unpack_from("<H", d, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", d, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96)
    rva, size = struct.unpack_from("<II", d, dd + 14 * 8)
    if not rva: return "native"
    full = path.read_bytes()
    sec = opt + optsz
    for i in range(nsec):
        vsz, va, rsz, raw = struct.unpack_from("<IIII", full, sec + i * 40 + 8)
        if va <= rva < va + max(vsz, rsz):
            cor = raw + (rva - va)
            r2r_rva = struct.unpack_from("<I", full, cor + 64)[0]  # ManagedNativeHeader
            flags = struct.unpack_from("<I", full, cor + 16)[0]
            return "managed-r2r" if (r2r_rva or not flags & 1) else "managed-il"
    return "managed?"

if __name__ == "__main__":
    for p in sorted(Path(sys.argv[1]).glob("*.dll")) + sorted(Path(sys.argv[1]).glob("*.exe")):
        print(f"{classify(p):12} {p.stat().st_size:>10} {p.name}")
