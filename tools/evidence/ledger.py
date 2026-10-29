#!/usr/bin/env python3
"""Evidence ledger: tie every protocol claim to the exact binary it came from.

  ledger.py register PATH [--kind apk|windows-package|capture|spec] [--version V] [--source S]
  ledger.py claim "text" --status observed|inferred|unknown --artifact SHA_PREFIX
                         [--where "Class.method / file:line / flows.jsonl seq 12"]
  ledger.py list [--status unknown]

`observed` means seen in a binary or a live capture; `inferred` means reasoned from
observations; `unknown` is an open question and names what would settle it.
Files live in evidence/ and contain no secrets, so they can be committed.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "evidence"
ARTIFACTS, CLAIMS = ROOT / "artifacts.jsonl", ROOT / "claims.jsonl"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def append(path: Path, record: dict):
    ROOT.mkdir(exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def cmd_register(args):
    target = Path(args.path)
    files = sorted(p for p in target.rglob("*") if p.is_file()) if target.is_dir() else [target]
    known = {a["sha256"] for a in read(ARTIFACTS)}
    added = 0
    for f in files:
        digest = sha256_file(f)
        if digest in known:
            continue
        known.add(digest)
        added += 1
        append(ARTIFACTS, {"sha256": digest, "name": f.name, "bytes": f.stat().st_size, "kind": args.kind,
                           "version": args.version, "source": args.source,
                           "registered": datetime.date.today().isoformat()})
        print(digest[:12], f.name)
    print(f"{added} new artifact(s), {len(files) - added} already known")


def cmd_claim(args):
    matches = [a for a in read(ARTIFACTS) if a["sha256"].startswith(args.artifact)] if args.artifact else []
    if args.status != "unknown" and len(matches) != 1:
        sys.exit(f"--artifact must match exactly one registered artifact (matched {len(matches)})")
    claims = read(CLAIMS)
    record = {"id": f"C{len(claims) + 1:04d}", "status": args.status, "claim": args.text,
              "artifact": matches[0]["sha256"] if matches else None, "where": args.where,
              "date": datetime.date.today().isoformat()}
    append(CLAIMS, record)
    print(record["id"], record["status"])


def cmd_list(args):
    for c in read(CLAIMS):
        if args.status in (None, c["status"]):
            art = (c["artifact"] or "-")[:12]
            print(f'{c["id"]} [{c["status"]:8}] {art}  {c["claim"]}' + (f'  @ {c["where"]}' if c.get("where") else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("register"); r.add_argument("path"); r.add_argument("--kind", default="file")
    r.add_argument("--version"); r.add_argument("--source"); r.set_defaults(fn=cmd_register)
    c = sub.add_parser("claim"); c.add_argument("text")
    c.add_argument("--status", required=True, choices=["observed", "inferred", "unknown"])
    c.add_argument("--artifact"); c.add_argument("--where"); c.set_defaults(fn=cmd_claim)
    l = sub.add_parser("list"); l.add_argument("--status", choices=["observed", "inferred", "unknown"])
    l.set_defaults(fn=cmd_list)
    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
