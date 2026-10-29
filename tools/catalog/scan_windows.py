#!/usr/bin/env python3
"""Scan decompiled Phone Link C# for protocol facts: hosts, routes, hub methods, GUIDs, protobuf files.

Reads source as text only. Usage: scan_windows.py corpus/windows/decompiled [section]
"""
import collections, re, sys
from pathlib import Path

root = Path(sys.argv[1]); only = sys.argv[2] if len(sys.argv) > 2 else None
STR = re.compile(r'"((?:[^"\\\n]|\\.){2,300})"')
URL = re.compile(r"^(https?|wss?)://[A-Za-z0-9.{}-]+")
ROUTE = re.compile(r"^/[A-Za-z][A-Za-z0-9_/{}.-]{2,80}$")
GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
HOSTLIKE = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)*\.(microsoft|live|microsoftonline|windows|office|msn|bing|azure|skype|azureedge|trafficmanager)\.(com|net)(/.*)?$")
buckets = {k: collections.defaultdict(set) for k in ("urls", "routes", "guids", "hosts", "protos", "hubs", "apiver", "scopes")}
SKIP = ("/WinRT/", "XamlTypeInfo", "/Properties/")
for f in root.rglob("*.cs"):
    rel = f.relative_to(root).as_posix()
    if any(s in "/" + rel for s in SKIP): continue
    asm = rel.split("/")[0]
    text = f.read_text(encoding="utf-8", errors="replace")
    if "FileDescriptor.FromGeneratedCode" in text: buckets["protos"][asm].add(rel)
    for m in STR.finditer(text):
        s = m.group(1)
        if URL.match(s): buckets["urls"][s].add(asm)
        elif HOSTLIKE.match(s): buckets["hosts"][s].add(asm)
        elif GUID.match(s): buckets["guids"][s.lower()].add(asm + ":" + f.stem)
        elif ROUTE.match(s) and not s.startswith(("/Assets", "/Styles", "/Themes", "/Controls", "/Views", "/Microsoft.")) and not s.endswith((".xaml", ".png", ".svg", ".json", ".gif", ".ico", ".xbf")): buckets["routes"][s].add(asm)
        elif "api-version" in s.lower() or s.startswith("{+baseurl}/"): buckets["apiver"][s].add(asm)
        elif "offline_access" in s or "::" in s and "MBI" in s or s.startswith("service::"): buckets["scopes"][s].add(asm)
    for m in re.finditer(r'\.(?:InvokeAsync|SendAsync|InvokeCoreAsync|SendCoreAsync|On)(?:<[^>]+>)?\(\s*"([A-Za-z]\w+)"', text):
        buckets["hubs"][m.group(1)].add(asm)
for name, b in buckets.items():
    if only and only != name: continue
    print(f"\n=== {name} ({len(b)})")
    for k in sorted(b, key=lambda k: (k.lower())):
        v = sorted(b[k]); print(f"  {k}   <- {', '.join(v[:3])}{' ...' if len(v) > 3 else ''}")
