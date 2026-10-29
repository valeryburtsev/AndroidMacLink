"""Run with: tools/.venv/bin/python -m unittest discover -s tools/capture -v"""
import json
import unittest

import msgpack

import wire

JWT = "eyJhbGciOiJFUzM4NCJ9.eyJpc3MiOiJkZXZpY2UifQ.c2lnbmF0dXJlLWJ5dGVzLWhlcmU"


def frame(obj) -> bytes:
    body = msgpack.packb(obj, use_bin_type=True)
    out, n = bytearray(), len(body)
    while True:
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out) + body


class Redaction(unittest.TestCase):
    def test_sensitive_headers_never_survive(self):
        out = wire.redact_headers([("Authorization", "Bearer " + JWT), ("Dcg-Token", "abc"), ("Accept", "*/*")])
        dumped = json.dumps(out)
        self.assertNotIn(JWT, dumped)
        self.assertNotIn('"abc"', dumped)
        self.assertEqual(out[2], ["Accept", "*/*"])
        self.assertEqual(out[0][1]["len"], len("Bearer " + JWT))

    def test_same_secret_same_fingerprint(self):
        self.assertEqual(wire.redacted("tok")["sha256_12"], wire.redacted(b"tok")["sha256_12"])
        self.assertNotEqual(wire.redacted("tok")["sha256_12"], wire.redacted("tok2")["sha256_12"])

    def test_url_connection_token_removed(self):
        url = wire.redact_url("wss://user:pw@dcg.microsoft.com/relayhub/?id=SECRETCONN&api-version=1.5.0#frag")
        self.assertNotIn("SECRETCONN", url)
        self.assertNotIn("user:pw", url)
        self.assertIn("api-version=1.5.0", url)

    def test_json_body_tokens_and_embedded_jwt(self):
        body = json.dumps({"certificateJWT": JWT, "deviceId": "d-1", "nested": {"refresh_token": "r", "note": "x " + JWT}})
        info = wire.describe_body(body.encode(), "application/json")
        dumped = json.dumps(info)
        self.assertNotIn(JWT, dumped)
        self.assertEqual(info["json"]["deviceId"], "d-1")
        self.assertTrue(info["json"]["nested"]["refresh_token"]["redacted"])

    def test_account_details_and_turn_credentials_are_redacted(self):
        body = json.dumps({"accountInfo": {"signInName": "someone@example.com", "firstName": "Ada", "lastName": "Lovelace",
                                           "accountKey": "QUJD"},
                           "turnCredential": {"urls": ["relay.example:3478"], "username": "turn-user", "credential": "turn-pass"}})
        dumped = json.dumps(wire.describe_body(body.encode(), "application/json"))
        for secret in ("someone@example.com", "Ada", "Lovelace", "QUJD", "turn-user", "turn-pass"):
            self.assertNotIn(secret, dumped)
        self.assertIn("relay.example:3478", dumped)

    def test_form_body(self):
        info = wire.describe_body(b"client_id=8CF5&device_code=DEVSECRET&grant_type=x", "application/x-www-form-urlencoded")
        self.assertNotIn("DEVSECRET", json.dumps(info))
        self.assertIn(["client_id", "8CF5"], info["form"])

    def test_large_binary_becomes_blob(self):
        info = wire.describe_body(b"\xff" * 70000, "application/octet-stream")
        self.assertEqual(info["kind"], "blob")
        self.assertEqual(info["len"], 70000)


class SignalR(unittest.TestCase):
    def test_varint_multibyte(self):
        self.assertEqual(wire.read_varint(bytes([0xAC, 0x02]), 0), (300, 2))
        with self.assertRaises(ValueError):
            wire.read_varint(bytes([0x80]), 0)

    def test_handshake_with_coalesced_frame(self):
        ping = frame([6])
        hs, rest = wire.split_handshake(b'{"protocol":"messagepack","version":1}\x1e' + ping)
        self.assertEqual(json.loads(hs)["protocol"], "messagepack")
        self.assertEqual(wire.split_frames(rest), [ping[1:]])

    def test_multiple_frames_and_invocation_decode(self):
        trace = {"TraceId": "0" * 32, "ParentId": "1" * 16, "TraceFlags": 0, "TraceState": {}}
        packet = {"Properties": {"Type": "2", "MessageType": "1"}, "Raw": b"\x08\x01" * 200, "Type": "ms-dcg"}
        inv = frame([1, {}, "7", "SendMessageAsync", [trace, "target-id", packet], []])
        frames = wire.split_frames(inv + frame([6]))
        self.assertEqual(len(frames), 2)
        d = wire.describe_hub_frame(frames[0])
        self.assertEqual((d["hub_type"], d["target"], d["invocation_id"]), ("Invocation", "SendMessageAsync", "7"))
        self.assertEqual(d["arguments"][2]["Raw"]["len"], 400)
        json.dumps(d)  # must be JSON-safe
        self.assertEqual(wire.describe_hub_frame(frames[1])["hub_type"], "Ping")

    def test_truncated_frame_rejected(self):
        with self.assertRaises(ValueError):
            wire.split_frames(frame([6])[:-1] if len(frame([6])) > 2 else b"\x05\x01")


class MessagePack(unittest.TestCase):
    """Our decoder must agree with the reference msgpack library."""

    SAMPLES = [
        None, True, False, 0, 127, 128, 255, 256, 65535, 65536, 2**32, 2**63 - 1, -1, -32, -33, -129, -32769, -2**31 - 1,
        1.5, -0.25, "", "a" * 31, "b" * 32, "c" * 300, "d" * 70000, "ключ ✓", b"", b"\x00" * 255, b"\x01" * 256,
        b"\x02" * 70000, [], list(range(15)), list(range(16)), list(range(70000)), {}, {"k": [1, {"n": b"x"}]},
        {str(i): i for i in range(20)}, {1: "int key"},
        [1, {}, "7", "OnReceiveMessage", [{"TraceId": "0" * 32, "TraceState": {}}, "id", {"Raw": b"\x08\x01"}], []],
    ]

    def test_matches_reference(self):
        for sample in self.SAMPLES:
            packed = msgpack.packb(sample, use_bin_type=True)
            self.assertEqual(wire.unpack_msgpack(packed), msgpack.unpackb(packed, raw=False, strict_map_key=False))

    def test_float32_and_ext(self):
        self.assertEqual(wire.unpack_msgpack(msgpack.packb(1.5, use_single_float=True)), 1.5)
        ext = wire.unpack_msgpack(msgpack.packb(msgpack.ExtType(5, b"abcd")))
        self.assertEqual(ext, {"ext_type": 5, "data": b"abcd"})

    def test_malformed_input_rejected(self):
        good = msgpack.packb({"a": [1, 2, b"xyz"]}, use_bin_type=True)
        for bad in (good[:-1], good + b"\x00", b"\xc1", b"\xdd\xff\xff\xff\xff", b"\x91" * 200):
            with self.assertRaises(ValueError):
                wire.unpack_msgpack(bad)


if __name__ == "__main__":
    unittest.main()
