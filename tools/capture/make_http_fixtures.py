#!/usr/bin/env python3
"""Build sanitized HTTP fixtures for the Swift tests from the redacted captures.

Writes two files:
  dcg-requests.json   one entry per distinct DCG call: method, path, query, header names in wire
                      order, and the request body with every leaf value replaced by its type.
  pairing-qr.json     the pairing service's responses for one QR pairing, with identifiers, PINs
                      and the link's variable parts replaced by fakes of the same shape.
"""
import hashlib, json, re, sys
from pathlib import Path
from urllib.parse import urlsplit, parse_qsl

UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
def fake_uuid(m):
    h = hashlib.sha256(b"winphone-fixture" + m.group(0).lower().encode()).hexdigest()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"
SKIP_HEADERS = {"host", "accept-encoding", "connection", "content-length", "user-agent", "baggage"}

def types(v):
    if isinstance(v, dict):
        if v.get("redacted") is True: return "string"
        return {k: types(x) for k, x in v.items()}
    if isinstance(v, list): return [types(v[0])] if v else []
    return {str: "string", bool: "bool", int: "int", float: "double", type(None): "null"}[type(v)]

def main():
    dest = Path(sys.argv[1]); captures = sys.argv[2:]
    requests, pairing, seen = [], [], set()
    for path in captures:
        for line in open(path):
            r = json.loads(line)
            if r["type"] != "http": continue
            u = urlsplit(r["url"])
            if u.hostname != "dcg.microsoft.com": continue
            headers = {h[0].lower(): h[1] for h in r["request_headers"]}
            app = "PL" if headers.get("dcg-appid") == "Microsoft.YourPhone_8wekyb3d8bbwe" else "WEA"
            p = UUID.sub("{id}", u.path)
            if "PairingSessions" in p and r["response_body"].get("kind") == "json" and r["status"] == 200:
                body = json.loads(UUID.sub(fake_uuid, json.dumps(r["response_body"]["json"])))
                if body.get("challengePIN"): body["challengePIN"] = "ABCDEF"
                if body.get("partnerDeviceKey"): body["partnerDeviceKey"] = "PartnerDeviceKey~" + "0" * 64
                if body.get("pairingLink"):
                    body["pairingLink"] = re.sub(r"ti=[0-9a-f]+", "ti=" + "0" * 32, re.sub(r"mvc=\d+", "mvc=1000000", body["pairingLink"]))
                pairing.append(body)
            key = (r["method"], p, app if p.startswith(("/Auth", "/Registration", "/DeviceAuthProxy/Enroll", "/DeviceAuthProxy/SetDeviceInfo")) else "")
            if key in seen or (app != "PL" and any(k[:2] == key[:2] and k[2] == "PL" for k in seen)): continue
            if app != "PL" and p.startswith(("/Auth", "/Registration", "/DeviceAuthProxy/Enroll", "/DeviceAuthProxy/SetDeviceInfo")): continue
            seen.add(key)
            requests.append({
                "client": app, "method": r["method"], "path": p,
                "query": [[k, "{id}" if UUID.fullmatch(v) else v] for k, v in parse_qsl(u.query, keep_blank_values=True)],
                "headers": [h[0] for h in r["request_headers"] if h[0].lower() not in SKIP_HEADERS],
                "body": types(r["request_body"]["json"]) if r["request_body"].get("kind") == "json" else None,
                "status": r["status"],
            })
    (dest / "dcg-requests.json").write_text(json.dumps(requests, indent=1))
    (dest / "pairing-qr.json").write_text(json.dumps(pairing, indent=1))
    print(len(requests), "requests;", len(pairing), "pairing responses")
    for q in requests: print(f"  {q['client']:3} {q['method']:4} {q['path']}")

if __name__ == "__main__":
    main()
