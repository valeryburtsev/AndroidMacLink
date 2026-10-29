# Nano away from the local network: candidates, checks and the relay

Status on 2026-10-10: built, checked byte for byte against the recording of 2026-10-09, run on a
simulated internet, and **run live against Microsoft's real servers from the Mac alone** (two
local sockets through the relay: 40 of 40 datagrams of 1,100 bytes each way). **Not yet tried
with the phone on another network.**

When the phone and the PC are not on one network, the Nano connection (`nano-wire-notes.md`) is
made the way voice calls are: ICE, with STUN to learn one's address as the internet sees it and
TURN as the relay of last resort. All three are the public standards (RFC 8445 / 5245, 5389,
5766 / 8656), with the few additions listed here. Nothing above the path changes: the same Nano
start sequence, channels and SRTP run over whatever pair is chosen.

Tags: **[capture]** `captures/nano-udp-4.pcap` with the keys of `captures/vm-raw-2026-10-09`
(the mirroring session; Windows tried the direct way and three ICE variants side by side and
the phone answered all), **[live]** this Mac against the real servers, **[built]** the Mac
client.

## 1. Servers and account

DCG `GET /CloudRelay/Relay?api-version=1.0.0&isOnlyStun=false` with the device token answers

    {"stunInfo":{"urls":["relay.communication.microsoft.com:3478"]},
     "turnCredential":{"urls":["relay.communication.microsoft.com:3478"],
                       "username":"<100 characters>","credential":"<28 characters>","turnExpireTime":<seconds>}}

**[capture]**. Bare `host:port`, the same host for both; the account lasts about a week.

## 2. Signalling

The same APP request as the direct way, `/nanohandshake` (`nano-scoping.md` 2.3), with another
`handshake` text. The PC's, keys in this order **[capture]**:

    {"security":{"key":"<32 hex, lower case>","salt":"<28 hex>"},
     "ice":{"candidates":"<the description of section 3, as one string>",
            "stun":{"url":"relay.communication.microsoft.com:3478"},
            "turn":{"url":"...:3478","username":"...","password":"..."}},
     "contractVersion":{"versionMin":6,"versionMax":6},
     "settings":{"remoteTaskTransfer":true,"connectionType":3,"audio":true},
     "instanceId":"<lower-case GUID>","multipleConnections":true}

- `connectionType` 1: candidates of the device only, `stun.url` and the `turn` values empty;
  2: with the address server; 3: with the relay too. Windows sent one request of each kind
  beside the direct one (type 0) and kept the first connection that opened.
- **On this way the PC makes the SRTP key** and both directions use it (the three ICE
  connections of the recording open with the key of their own request).
- The PC hands the relay account to the phone, which gets an address on the relay for itself.

The phone's answer: `{"ice":{"candidates":"..."},"keepalive":{"warningtimeout":"5000"},
"contractVersion":{...},"tbst":{...}}`.

## 3. The description (`ice.candidates`)

JSON, every value a string, slashes escaped as `\/` **[capture]**:

    {"Full":"1","PacingMs":"50","Version":"1",
     "Candidates":{"count":"3","0":{...},"1":{...},"2":{...}},
     "Username":"<12 characters, base64 of 9 bytes>","Password":"<44 characters, base64 of 32 bytes>",
     "StunTimeoutMs":"200","StunRetryCount":"4"}

A candidate, keys in this order:

| Key | Meaning |
|---|---|
| `transportAddress` | `a.b.c.d:port` or `[v6]:port` |
| `baseAddress` | the device's own address it is reached through |
| `natAddress` | for a relay candidate: the device as the server saw it; else empty |
| `serverAddress` | the server that gave a reflexive or relay candidate; else empty |
| `ipv6` | `0` or `1` |
| `type` | `0` host, `1` server-reflexive, `3` relay (2 would be peer-reflexive) |
| `addressType` | of the base: `3` private IPv4, `4` link-local IPv6, `0` anything else |
| `priority` | the standard's: type preference 126 / 100 / 0 in the top byte, an order among one's own in the middle, 255 |
| `foundation` | a number |
| `transport` | `udp` |
| `relayStandard` | `0`, on relay candidates only |

The phone on Wi-Fi sent: two global IPv6 hosts, its Wi-Fi address, its mobile-data address
(carrier range, as a host candidate), and for types 2 and 3 a reflexive and a relay candidate
based on the Wi-Fi address.

## 4. The messages

STUN with the fixed cookie, no FINGERPRINT. Additions to the standard's attributes
**[capture]**:

- `0x8022` SOFTWARE `libnano` in every request of the library (not in answers).
- `0x8025`, four bytes `00 00 <n> 00`: which send of this request this is, from 1 (RFC 7982's
  transmit counter). A resend keeps the transaction and changes only this, and with it the
  signature. Answers repeat the request's value.
- `0x8094`, in Allocate: the text `00000000-0000-0000-0000-000000000000`.

**Address question.** Binding request with SOFTWARE and the counter; the answer has the
counter and XOR-MAPPED-ADDRESS.

**Relay** (long-term credentials, key = MD5 of `username:realm:password`, realm `rtcmedia`):

1. Allocate without account: SOFTWARE, REQUESTED-TRANSPORT `11 00 00 00`, LIFETIME 3600,
   DONT-FRAGMENT, `0x0017` = `00 00 00 01`, `0x8094`, counter.
2. The server refuses with **300 Try Alternate**: NONCE (16 bytes), REALM, SOFTWARE,
   ALTERNATE-SERVER.
3. The same request to that server, now with USERNAME, REALM, NONCE after SOFTWARE and signed.
   Success: LIFETIME 600, XOR-MAPPED-ADDRESS, XOR-RELAYED-ADDRESS, signed.
4. CreatePermission per peer address (port 0): SOFTWARE, USERNAME, REALM, NONCE,
   XOR-PEER-ADDRESS, counter. **403 Forbidden for private and carrier-range peers**, success for
   public ones.
5. Checks through the relay travel in Send indications (DATA, XOR-PEER-ADDRESS, DONT-FRAGMENT)
   and arrive in Data indications (XOR-PEER-ADDRESS, DATA).
6. Once a relayed pair has answered: ChannelBind (CHANNEL-NUMBER `40 00 00 00`, then `40 01`,
   ...; XOR-PEER-ADDRESS), after which data may use the four-byte channel framing.

**Checks.** Binding request: SOFTWARE, USERNAME `<receiver's name>:<sender's name>`,
ICE-CONTROLLING (PC) or ICE-CONTROLLED (phone) with eight random bytes, PRIORITY, optionally
USE-CANDIDATE, the counter, MESSAGE-INTEGRITY keyed with the **receiver's password as text**.
The answer: MAPPED-ADDRESS, XOR-MAPPED-ADDRESS (where the request came from), the counter,
MESSAGE-INTEGRITY with the same key. PRIORITY carried the sender's reflexive candidate's
priority on direct checks and the relay candidate's on relayed ones.

Timing as recorded: checks start 50 ms apart; resends after about 0.2, 0.4, 0.8 s; about one
second after the first pair answered, the PC sends the check with USE-CANDIDATE on the best
pair, and the Nano start sequence follows its answer within 10 ms. The first Nano packet, the
size probe, is 1,196 bytes on these paths (1,468 on the direct one).

Every recorded message reads with the Mac client's code, every recorded signature verifies
with the keys from the recorded handshakes, and each message written again comes out byte for
byte (`IceRecordingTests`, skipped where the recording is absent).

## 5. The Mac client [built]

- `Nano/Ice/Stun.swift`: the messages, addresses, signatures, channel framing.
- `Nano/Ice/IceDescription.swift`: the description of section 3; `NanoRelayServers`.
- `Nano/Ice/IceSocket.swift`: one IPv4 UDP socket for all addresses.
- `Nano/Ice/IceAgent.swift`: gathers (own address, reflexive, relay with the two-step
  sign-in), checks every IPv4 candidate of the phone directly and every public one through the
  relay, answers the phone's checks and learns unannounced addresses from them, nominates
  about a second after the first success, then carries the connection's datagrams; keeps a
  relay in use alive (Refresh, permission, channel every four minutes) and gives it back when
  closing.
- `Nano/NanoConnector.swift`: one direct request first; the phone's addresses that lie in one
  of the Mac's own networks are tried as before; if there is none, or none answers, a second
  request of type 3 and the procedure above. Used by the phone screen and by file transfer in
  both directions on the Phone Link session. Shares the phone announces on the cross-device
  session (`NanoSignalling`) still use the direct way only.
- `Nano/Ice/IceSelfTest.swift` and the default `ice.selftest`: the procedure against the real
  servers with two local sockets, one of them allowed only the relay.
- Tests: `IceTests` on `IceTestNetwork` (routers of the plain and the strict kind, a server
  that answers and relays with the two-step sign-in): same network, two home routers, a strict
  carrier, no way at all, and a phone on mobile data from the request to the files.

## 6. Limits and open questions

1. IPv4 only: the phone's IPv6 candidates are ignored, and the Mac offers none.
2. With the phone: does the phone accept a single request of type 3 without the others
   Windows sends beside it? Does a path open across a real carrier, and which kind?
3. The phone refuses the request while "sync over mobile data" is off and it is on mobile data
   (`device-controls.md` 3.7).
4. Mirroring over mobile data costs the phone's data plan: the phone sends up to 8 Mbit/s.
5. All datagrams pass one actor; fine for a relayed path's speeds, to be measured.
