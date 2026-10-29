#!/usr/bin/env python3
"""Summarize a capture session: one line per HTTP exchange and per WebSocket hub frame. Values stay redacted."""
import json, sys, collections
from urllib.parse import urlsplit

def keys(body, depth=0):
    if body.get("kind") == "json":
        j = body["json"]
        if isinstance(j, dict): return "{" + ", ".join(list(j)[:14]) + ("…" if len(j) > 14 else "") + "}"
        if isinstance(j, list): return f"[{len(j)} items" + (": {" + ", ".join(list(j[0])[:10]) + "}" if j and isinstance(j[0], dict) else "") + "]"
        return repr(j)[:60]
    return body.get("kind", "?") + (f" {body['len']}b" if "len" in body else "")

path = sys.argv[1]; verbose = len(sys.argv) > 2
t0 = None
for line in open(path):
    r = json.loads(line); t0 = t0 or r["ts"]; t = f"{r['ts'] - t0:7.2f}s"
    if r["type"] == "http":
        u = urlsplit(r["url"])
        hdrs = [h[0] for h in r["request_headers"] if h[0].lower() not in ("host", "accept", "accept-encoding", "user-agent", "connection", "content-length", "content-type", "traceparent", "tracestate", "request-id")]
        print(f"{t} {r['method']:5} {u.hostname}{u.path}{'?' + u.query if u.query else ''}  -> {r['status']}")
        print(f"          req headers: {', '.join(hdrs)}")
        if r["request_body"].get("kind") != "empty": print(f"          req body:  {keys(r['request_body'])}")
        print(f"          resp body: {keys(r['response_body'])}")
    else:
        for f in r.get("frames", []):
            args = f.get("arguments")
            extra = ""
            if isinstance(args, list):
                for a in args:
                    if isinstance(a, dict) and "Properties" in a:
                        p = a["Properties"]; raw = a.get("Raw") or {}
                        extra = f" props={ {k: p[k] for k in p if k not in ('SessionId',)} } raw={raw.get('len') if isinstance(raw, dict) else None}b"
            print(f"{t} WS {r['dir']} {f.get('hub_type')} {f.get('target') or ''}{extra}")
        if "handshake" in r: print(f"{t} WS {r['dir']} handshake {r['handshake']}")
        if "decode_error" in r: print(f"{t} WS {r['dir']} DECODE ERROR {r['decode_error']}")
