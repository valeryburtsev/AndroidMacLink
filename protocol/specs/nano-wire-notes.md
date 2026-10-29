# Nano wire layouts: working notes (first pass)

Working notes, not a spec. First static pass over the packet layouts that `nano-scoping.md`
left unknown, written so that a decoder can be started as soon as a UDP recording exists.
Nothing here has been checked against a packet. Revision 1, 2026-10-09, time-boxed (about 25
minutes of reading); items 1 to 4 are reasonably covered, 5 and 6 are partial.

Source: `lib/arm64-v8a/liblibnanoapi.so` from the Link to Windows 1.26082.130.0 `base.apk`
(extracted to a scratch directory only, never executed). Tools: `nm -D -C`, `objdump -d`
(Apple LLVM), `strings`, and a small script resolving `adrp/add` string references and PLT
names. The Windows `LibNanoAPI.dll` and the Java wrappers were not needed and not re-read.

Tags: **[native-symbols]** exported name or signature; **[native-disasm]** read from the
instructions of the named function; **[native-strings]** literal referenced by that function;
**[inferred]** deduced, reasoning given; **[recollection]** from memory of public documents
(RFCs, Microsoft open specifications, Xbox Nano notes), not verified against this library.
Addresses are virtual addresses in the arm64 library (`objdump -d --start-address=0x...`).
All multi-byte fields are little-endian unless marked BE; "raw store" means the code writes the
host integer without a byte swap.

## 0. What a decoder can already do, and what it cannot

| Step | Can do now | Cannot yet |
|---|---|---|
| Parse the outer header | Standard 12-byte RTP header, no CSRC, no extension on this path; payload type table complete (section 1) | Meaning of the RTP timestamp field |
| Route by SSRC | SSRC = two 16-bit halves; the low half is the multiplexer channel id (sections 1, 5) | Which side's connection id sits in the high half |
| Decrypt | AES-128-GCM, RFC 3711 key derivation, RFC 7714 style nonce, 12-byte AAD, 16-byte tag, plus a 2-byte encrypted trailer (section 2). Self-checking: the tag verifies or it does not | Cipher/mode enum values are inferred, not read by name; whether both directions share one key; SRTCP use |
| Keep-alive / MTU packets (PT 101) | Full layout and flag bits (section 3.1) | Cadence, whether the handshake gates the next layer |
| Rate-control handshake (PT 100) | SYN, SYNACK, ACKOFACK layouts and order (section 3.2) | Meaning of two SYN fields beyond their property names |
| Rate-control data header | Flag bits, field order and sizes, ack vector coding (section 4) | Time-stamp units, delayed-ack semantics, which controller type is negotiated |
| Multiplexer control (PT 97) | Message types and field order of create/open/close (section 5) | One u32 and one u64 field; the property-string grammar; id allocation |
| Sequencer header | 8 bytes, 48-bit number (section 5.3) | Flag byte values; when it is present; FEC header |
| Message channel | Packet types, common header, data packet field sizes (section 6.1) | Meaning of four of six u32 fields; where the scope path is carried; handshake semantics |
| Blob channel | Packet types and field order of all five packets (section 6.2) | Meaning of a few numeric fields; chunk size; flow-control numbers |

Expected shape of one decrypted data datagram **[inferred]** from the stack order in section 1.3
(each upper layer prepends at the front of the buffer; SRTP is the only layer that appends):

```
RTP header (12, clear, authenticated)
ciphertext:
  rate-control header   (2-byte flags + optional parts, max 47)      section 4
  sequencer header      (8, channel data only)                       section 5.3
  channel packet        (u32 type, u32, body)                        section 6
  trailer               (2, the upper layer's own 16-bit sequence)   section 2.4
GCM tag (16)
```

Keep-alive (PT 101) and rate-control handshake (PT 100) packets sit below the rate controller,
so their payload starts directly after the RTP header (plus trailer and tag) **[inferred]**.

---

## 1. Outermost framing

### 1.1 RTP header **[native-disasm]**

`Microsoft::Basix::Rtp::Header::Encode` (0xa112e4), `Header::Decode` (0xa117bc). Standard
RFC 3550 fixed header, 12 bytes:

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | `0x80`, `| 0x10` if an extension header object is attached, `| 0x20` if padding was added | Version 2; CSRC count always 0. Decode rejects anything but version 2 ("Invalid packet version received!") |
| 1 | 1 | marker bit (0x80) + payload type (7 bits) | `PayloadType::Encode` 0xa106f4 |
| 2 | 2 | sequence number, BE | |
| 4 | 4 | timestamp, BE | |
| 8 | 4 | SSRC, BE | |

- Padding (only when the caller asks for it): zero bytes up to a multiple of 4, last byte is
  the pad count, as in the RFC.
- Extension header (`ExtensionHeader::Encode` 0xa10ba8, `Decode` 0xa10eb8): a 16-bit id, a
  16-bit length, then the payload; looks like the RFC 3550 form. **Not emitted on the Direct IP
  path**: `IODescriptor::Serialize` (0x953d40) builds the header with a null extension. Byte
  order of the two 16-bit fields not read.
- `PayloadType::Put` (0xa1053c) rejects values above 127 and values 65 to 95 ("Payload type in
  the RTCP reserved range").
- RTP versus RTCP on receive (`SrtpContext::ProcessIncomingPacket` 0xaa1694): version 2 and
  second byte in 0xC1..0xDF is treated as RTCP, everything else as RTP.

Confidence: high.

### 1.2 What the header fields carry **[native-disasm]**

`IAsyncTransport::IODescriptor` is the in-memory form (`Serialize` 0x953d40, `DeserializeRTP`
0x953aa4). Its constructor signature is `(unsigned char payloadType, SequenceNumber<16>,
unsigned int, bool, ...)` **[native-symbols]**.

| RTP field | Descriptor member | Meaning |
|---|---|---|
| payload type | byte at +0 | Selects the consuming layer (table below) |
| marker | bool at +8 | Not traced |
| sequence | u16 at +2 | On the wire: the SRTP layer's own packet counter (section 2.4), not the upper layer's number |
| timestamp | u32 at +4 | Not traced |
| SSRC high 16 bits | u16 at +0xa | Connection id **[inferred]** from the u16 properties `Dct.ClientConnectionId` / `Dct.ServerConnectionId` and the packet-log field name `connectionId` |
| SSRC low 16 bits | u16 at +0xc | **Channel id**: `MuxDCTBase::OnDataReceived` (0x9e8bf0) looks the channel up by this u16; `MuxDCTChannel::InternalQueueWrite` (0x9f3ddc) stores the channel's id there |

A descriptor whose payload-type byte has the top bit set is serialised as RTCP instead
(`RtcpHeader`), not examined.

### 1.3 Payload types **[native-disasm]** + **[native-strings]**

From `Microsoft::Basix::Dct::operator<<(ostream&, PayloadTypes const&)` (0x9653ac), which
compares against each value and prints the name:

| Value | Name | Consumer |
|---|---|---|
| 35 (0x23) | `MuxDCTChannelRangeDefault` | Start of the range for channel data |
| 63 (0x3f) | `MuxDCTChannelRangeEnd` | End of that range |
| 96 (0x60) | `BaseLinkControl` | Not traced |
| 97 (0x61) | `MuxDCTControl` | Multiplexer create/open/close (section 5) |
| 98 (0x62) | `FECControl` | Not traced |
| 99 (0x63) | `SecurityLayerCtrl` | Not traced |
| 100 (0x64) | `URCPControl` | Rate-control handshake (section 3.2) |
| 101 (0x65) | `UDPKeepALive` | Keep-alive and MTU probing (section 3.1) |
| 102 (0x66) | `UDPConnectionProbing` | `UDPConnectionProber`; not part of this stack (below) |
| 104 (0x68) | `URCPDummyPacket` | Rate-control packet with no user data (acks); dropped after header processing |
| 127 (0x7f) | `MockUDPDctCtrl` | Test only |

Which value inside 35..63 a given channel uses was not found (the multiplexer routes by channel
id, not by payload type). Confidence in the table: high.

### 1.4 Layer order for Direct IP **[native-disasm]**

`UdpSrtpClientTransport::OpenInternal` (0x8a8428) asks for well-known stack 11 (`mov w0,#0xb`
at 0x8a87dc). `operator<<(ostream&, DCTFactory::Stack const&)` (0x954d18) names 11
**`EnhancedSrtp`** (4 `Udp`, 12 `EnhancedRtp`). `DCTFactory::GetWellKnownStackDescription`
(0x963428, jump table at 0x3da2d8) builds it recursively:

- stack 4 = base `udp`
- stack 6 = stack 4 + `SrtpFilter`
- stack 11 = stack 6 + `MTUProbe` + `KeepAlive`
- (stack 13 = base `ICEFilter` + `SrtpFilter` + `MTUProbe` + `KeepAlive`, the ICE variant)

`OpenInternal` then adds a layer named `OnWritable`, calls `Rcp::IUDPRateController::Create`,
and the multiplexer is opened on top. Bottom to top:

`udp` → `SrtpFilter` → `MTUProbe` → `KeepAlive` → `OnWritable` → rate controller
(`CUDPRateController` with `UDPRateControlInitializerClient`) → `ClientMuxDCT` → channels.

Consequences:

- **Every datagram is SRTP-protected**, including keep-alives and the rate-control handshake.
- `UDPConnectionProber` (PT 102) is **not** in this stack.
- Which class implements `MTUProbe` was not looked up.

Properties set by the client before building the stack **[native-strings]**:
`Dct.IsServerConnection`, `Dct.Udp.SendAddr`, `Dct.SRTP.KeystreamMode`,
`Dct.SRTP.AuthenticationMode`, `Dct.RateController.MinimumRTO`, `Dct.SRTP.MasterKeys` (one key
set, no separate incoming/outgoing).

Confidence: high for membership and order of the well-known stack; medium that "added later"
means "further from the socket".

---

## 2. SRTP

Class `Microsoft::Basix::Rtp::SrtpContext`, filter `Microsoft::Basix::Dct::SrtpFilter`
(constructor 0xaa469c). Source file per strings: `libbasix-network/dct/srtp.cpp`.

### 2.1 Keys in, modes

- Master key 16 bytes, master salt 14 bytes: `SrtpMasterKeys(16, 14, true)` **[native-symbols]**
  (scoping study 2.3). In the connection string they are **hex strings** (`security.key` 32 hex
  characters, `security.salt` 28) per the scoping study's parser error strings; not base64. Not
  re-verified here.
- Filter properties **[native-strings]**: `Dct.SRTP.MasterKeys`, `.IncomingMasterKeys`,
  `.OutgoingMasterKeys`, `.KeystreamMode`, `.AuthenticationMode`, `Dct.ServerConnectionId`.
- The filter creates two contexts, outgoing at filter+0x270 and incoming at filter+0x280
  **[native-disasm]** (0xaa4d84, 0xaa4e28). With only `MasterKeys` set, both come from the same
  master key **[inferred]**, so both directions would use the same session key and salt. Nonce
  separation then rests on the SSRC or sequence differing per direction. **Open; check first
  on a recording.**
- Keystream mode 3 (GCM), authentication mode 0 (none), per the scoping study. The context
  constructor (0xa9b70c) refuses "no encryption" and "no authentication unless GCM", and warns
  when GCM is combined with an auth tag ("RFC7714 recommends not using authentication tags...").

### 2.2 Session key derivation **[native-disasm]** `SrtpContext::DeriveSessionKeys` (0xa9c628)

Session key container: `SrtpSessionKeys(16, 20, 14)` (0xa9b65c called from the constructor):
encryption key 16 bytes, authentication key 20 bytes, salt 14 bytes.

For each label L the code builds a 16-byte block: the 14-byte master salt (right-aligned,
zero-padded on the left if shorter), **byte 7 XOR L**, then two zero bytes. It creates a block
cipher mode object keyed with the master key and that block as a 16-byte IV
(`Cryptography::CreateBlockCipherMode(1, 2, 1, key, keylen, iv, 16)`) and transforms a
zero-filled output buffer in place.

| Label | Output | Length |
|---|---|---|
| 0x00 | session encryption key | 16 |
| 0x01 | session authentication key (unused with mode 0) | 20 |
| 0x02 | session salt | 14 |

This is the RFC 3711 section 4.3.1 derivation with key derivation rate 0 (index term zero) and
AES in counter mode as the PRF **[recollection]** for the comparison. That enum values 1 and 2
mean AES and counter mode is **[inferred]**, not read from a name. A decoder should implement
`keystream = AES-128-CTR(master_key, counter_block = salt14^label || 0x0000)` and let the GCM
tag confirm it.

`DeriveSessionKeysRTCP` (0xa9cb00) exists and fills a second key set at context+0xe8; labels
not read (RFC 3711 uses 3, 4, 5 **[recollection]**).

Confidence: high for the structure, medium for the PRF identity.

### 2.3 Packet protection, GCM **[native-disasm]**

`SrtpContext::EncryptGCMMode` (0xa9f780), caller `ProcessOutgoingPacket` (0xaa0ce0); receive
side `ProcessIncomingPacketRTP` (0xaa3098) and `DecryptGCMMode` (0xaa035c).

- Key: session encryption key, 16 bytes, so AES-128-GCM.
- Nonce, 12 bytes: take the **last 12 bytes of the 14-byte session salt** (salt[2..13]), then
  XOR bytes 2..5 with the SSRC (BE) and bytes 4..11 with the 48-bit packet index as a 64-bit BE
  value (so effectively bytes 6..11). Equivalent to
  `00 00 | SSRC(4) | ROC(4) | SEQ(2)` XOR salt12, the RFC 7714 construction **[recollection]**.
  Departure from RFC 7714: the salt is derived as 14 bytes and truncated on the left, and the
  master salt is 14 bytes, not 12.
- Packet index: 48 bits, `ROC << 16 | SEQ`, where SEQ is the sequence number in the RTP header.
  The receiver estimates the roll-over counter from its highest index with the usual plus or
  minus 0x8000 window, starting from zero.
- AAD: exactly the first 12 bytes of the datagram (constant 12 passed at 0xaa0fe4 and
  0xaa38e0). An RTP extension would not be covered, but none is emitted.
- Ciphertext: everything after byte 12 except the last 16 bytes.
- Tag: 16 bytes at the end (the receive path trims 0x10 after a successful decrypt;
  `GetPacketOverheadBytes` 0xaa0c94 adds 16 for mode 3).
- Replay protection on receive: 64-packet bitmap, "Duplicate packet detected!".
- With authentication mode 1 (not used here) an HMAC is computed over the packet plus the
  32-bit ROC and truncated; details not needed.

### 2.4 Non-standard part: own sequence counter and a 2-byte trailer **[native-disasm]**

`SrtpFilter`'s constructor sets a flag byte at context+0x20 on both contexts (0xaa4e9c,
0xaa4eac). With it set, `ProcessOutgoingPacket`:

1. takes the next value of a 48-bit atomic counter kept in the context (context+0x28);
2. **appends 2 bytes to the end of the payload: the 16-bit sequence number the upper layer had
   put in the descriptor**, raw store (little-endian on the wire);
3. overwrites the descriptor's sequence number with the low 16 bits of its own counter;
4. serialises the RTP header, then encrypts (the trailer is inside the ciphertext).

`ProcessIncomingPacket` reverses it: after decryption and header parsing it removes the last
2 bytes of the payload when the flag is set (restoring the upper layer's number from them is
**[inferred]**; the store was not read).

So: the RTP sequence number on the wire is a strictly increasing per-direction SRTP counter,
and per-datagram overhead is 12 + 2 + 16 = 30 bytes (the filter stores 18 as its own overhead
at filter+0x290). Initial counter value (0 or 1) not determined; a decoder does not need it.

Confidence: high.

### 2.5 Recipe to decrypt one recorded datagram

1. Parse the 12-byte header; `seq` = bytes 2..3 BE, `ssrc` = bytes 8..11 BE.
2. Derive session key (label 0) and session salt (label 2) from the master key and salt (2.2).
3. `index = ROC << 16 | seq`, ROC = 0 until the header sequence wraps (per direction).
4. `nonce = salt[2..13] XOR (00 00 | ssrc BE | index as 6 bytes BE)`.
5. AES-128-GCM open: AAD = bytes 0..11, ciphertext = bytes 12..len-17, tag = last 16 bytes.
6. Drop the last 2 plaintext bytes (inner sequence number, LE) and hand the rest to the layer
   selected by the payload type.

If step 5 fails for every packet, vary in this order: PRF mode in step 2, salt truncation side
(first 12 instead of last 12), per-direction keys.

---

## 3. First exchange after UDP opens

Order **[inferred]** from the stack: keep-alive handshake (PT 101), then rate-control handshake
(PT 100), then multiplexer control (PT 97). Whether each waits for the previous one was not
traced.

### 3.1 Keep-alive and MTU probing, PT 101 **[native-disasm]**

`UDPKeepALiveFilter::SendKeepAlivePacket(unsigned int flags, unsigned long size)` (0xab3f84),
`OnKeepAliveReceived`, `OnOpened` (0xab2074), `TimerCallback` (0xab2fc4). Source file
`udpkeepalive.cpp`. Raw stores, so little-endian.

| Offset | Size | Field | Present |
|---|---|---|---|
| 0 | 4 | Largest datagram payload this side has received so far (reported MTU). The receiver compares it with its "highest known MTU" (`UpdateHighestKnownMtu`, log "Reported MTU changed") | always |
| 4 | 4 | flags | always |
| 8 | 8 | timer interval | flag bit 0 |
| 16 | 8 | disconnect timeout, milliseconds (a nanosecond value divided by 1,000,000) | flag bit 0 |
| 24 | 4 | MTU frequency | flag bits 0 and 3 |
| 28 | 4 | MTU probe frequency | flag bits 0 and 3 |
| 32 | 8 | MTU timeout, milliseconds | flag bits 0 and 3 |

Minimum length 8, 24 or 40 by flags; the packet is then extended to `size` when `size` is
larger (this is the MTU probe; fill content not read). Field names for offsets 8 to 39 come
from the two log format strings in `OnKeepAliveReceived` ("Timer Interval: [%d],
DisconnectTimeout: [%d]" and "MTU frequency: [%d], MTU probe frequency: [%d], MTU timeout:
[%d]") and the order is **[inferred]** from them. Unit of the interval at offset 8 not read.

Flag bits:

| Bit | Value | Meaning | Evidence |
|---|---|---|---|
| 0 | 1 | Handshake: carries this side's timing configuration | `OnOpened` and the timer send flags 9 |
| 1 | 2 | Handshake acknowledgement | sent in reply to bit 0; on receipt stops a timer |
| 2 | 4 | Close notification | "UDP Transport closed due to peer notification" |
| 3 | 8 | MTU configuration block present | parsed only when set |

Plain keep-alives and MTU probes are sent with flags 0 (`DeterminePacketsToSend`,
`DeterminePacketsToSendV2`, `TimerCallback`). Field 0 value 0xFFFFFFFF is special-cased on
receive (meaning not read). Related properties **[native-strings]**:
`Dct.KeepAlive.{Interval, Timeout, HandshakeEnabled, HandshakeInterval, HandshakeMaxAttempts,
GracePeriodDuration, GracePeriodTimeout, MTUFrequency, MTUProbeFrequency, MTUTimeout}`,
`Dct.UDP.MtuProbingIncreasedFactor`, `Dct.Udp.MtuMax`.

Confidence: high for sizes and flag bits, medium for the names of the timing fields.

### 3.2 Rate-control handshake, PT 100 **[native-disasm]**

`Rcp::UDPRateControlInitializer` and its `Client`/`Server` subclasses, source
`udpratecontrollerinitializer.cpp`. Every packet starts with a u16 type
(`DecodePacketFlags` 0xb6e32c accepts 0, 1, 2; "Invalid Packet : invalid flags field").

| Type | Name in logs | Sender | Body after the u16 |
|---|---|---|---|
| 0 | SYN | client first (`Client::OnOpened` 0xb6953c, retried by timer), then the server answers with its own SYN (`Server::OnHandshakePacketReceived` 0xb6c8f4, "Server receiving SYN, send ACK now") | 15 bytes, below |
| 1 | SYNACK | client (`Client::SendAckPacket` 0xb6ac30, "Client sending SYNACK") | u32 time stamp, u16 retry index |
| 2 | SYNACKOFACK | server (`Server::SendAckOfAckPacket` 0xb6d904) | nothing |

SYN body (`SendSynPacket(unsigned short)` 0xb69970); field names from the property each member
is loaded from in the constructor (0xb6dbec):

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | `UDPRateControlInitializer.Protocol.Version` |
| 2 | 1 | `UDPRateControlInitializer.LocalInitialReceiverLogSize` |
| 3 | 8 | `UDPRateControlInitializer.InitialSendSN` (scoping study: 100 on both sides) |
| 11 | 2 | `RateController.Type` |
| 13 | 2 | retry index (the method argument; error strings "retry index not previously received", "received index from SYNDataPacket is too big") |

Sequence: client SYN → server SYN → client SYNACK → server SYNACKOFACK → both
`CompleteHandshake`. The client is the side with `Dct.IsServerConnection` false, that is the
UDP initiator, the PC (and our Mac). Retransmission is timer-driven on the client
(`c_handshakeTimeoutInMs` 800 per the scoping study). The server's SYN lets the client learn
the rate-controller type ("Client receiving SYN from server (m_urcpType=%d)").

These packets carry no rate-control data header **[inferred]** (they are built and consumed by
the initializer itself). Confidence: high for layouts, medium for field meanings.

---

## 4. Rate-control and reliability header

`Rcp::UDPRateControlHeader::Encode` (0xb5e0bc), `Decode(FlexIBuffer&, unsigned long, unsigned
long)` (0xb5d538), source `udpratecontrollerheader.cpp`. `GetMaxHeaderSize` returns 47
(0xb5ef18). `CUDPRateController::OnDataReceived` (0xb535f8) decodes this header from every
packet that reaches it, processes it, discards the packet if its payload type is 104, and
otherwise forwards the rest upward **[native-disasm]**. So after the handshake every packet of
the layers above (PT 97, 104, 35..63) starts with it.

The header is a u16 flags word followed by optional parts in this fixed order:

| Flag bit | Mask | Part | Size | Content |
|---|---|---|---|---|
| 0 | 0x001 | Ack | 6 + 1 + n | u16 acknowledged sequence number; 24-bit time stamp (u16 low, u8 high); u8 time gap; one byte with n in the low nibble and a time scale in the high nibble; n bytes of delayed-ack time differences (n < 16, "8bit coding scheme for the timediff") |
| 6 | 0x040 | (one byte) | 1 | not identified |
| 8 | 0x100 | (delayed-ack parameters) | 3 | u8, u16 |
| 4 | 0x010 | Ack of acks | 2 | u16 sequence number |
| 2 | 0x004 | Data | 2 | u16 data sequence number; user data follows the header |
| 3 | 0x008 | Ack vector | up to 29 | section 4.1 |
| 9 | 0x200 | (64-bit value) | 8 | not identified |

- Sequence numbers are 64-bit inside the library and 16-bit on the wire; `Decode` extends each
  against a reference passed by the caller (current ack and data positions).
- "FlagAck and FlagAckVector can't be set simultaneousy" **[native-strings]**.
- The upper four bits of the flags word were not examined (a window-size field in the
  comparable public format **[recollection]**).
- This layout matches, bit for bit in the positions read, the packet layout of Microsoft's open
  specification MS-RDPEUDP2 (flags ACK 0x001, DATA 0x004, ACKVEC 0x008, AOA 0x010,
  OVERHEADSIZE 0x040, DELAYACKINFO 0x100, CORRELATIONID 0x200; same part order)
  **[recollection]**. Read that document before any further disassembly of this layer; then
  verify the points where this library may differ (bit 9 is 8 bytes here; the handshake of
  section 3.2 is this library's own).

### 4.1 Ack vector **[native-disasm]**

`UDPRateControlHeader::AckVector::Decode` (0xb5b930), `Encode` (0xb5c2d0), max size 29.

- u16 base sequence number.
- one byte: bit 7 = time stamp present, low 7 bits = number of coded bytes.
- if present: 24-bit time stamp (u16 + u8) and a u8 time gap.
- coded bytes: bit 7 set = run (bit 6 the state, low 6 bits the length); bit 7 clear = 7-bit
  bitmap. `TryRunLengthMode` **[native-symbols]** is the encoder's choice between the two.

Confidence: high for sizes and order, medium for the semantics borrowed from the public
document.

Unknown: which congestion controller (`CUdpURCP`, `CUdpURCPV2`, `C2CongestionController`,
`CUdpQControl`) the phone selects with `RateController.Type`; retransmission packet form
(`SendRetransmissionPackets` 0xb562a4 was not read); how strictly the peer checks pacing.

---

## 5. Channel multiplexer

`MuxDCTBase`, `ClientMuxDCT`, `ServerMuxDCT`, `MuxDCTChannel`, `MuxDCTSequencer`; sources
`muxdct.cpp`, `muxdctchannel.cpp`.

### 5.1 Routing **[native-disasm]** `MuxDCTBase::OnDataReceived` (0x9e8bf0)

- PT 104: handled specially (no channel).
- PT 97: control packet for the channel whose id is in the SSRC low half; a create request for
  an unknown id goes to `HandleChannelCreateRequest(unsigned short id, ...)`.
- Otherwise: looked up in a map keyed by the 16-bit channel id and handed to that channel.
  "Channel id duplicate detected." guards creation (`MuxDCTBase::CreateChannel` 0x9ec7a8). How
  ids are allocated was not read.

### 5.2 Control packets, PT 97 **[native-disasm]** `MuxDCTChannel::SendChannelControlPacket` (0x9f66f4)

Sent on the base link with the channel's id in the descriptor and send mode 2. Payload:

| Type (u32) | Name | Body |
|---|---|---|
| 2 | `ChannelCreateRequest` | u16 length + channel class name (no terminator; "Channel class name too big to be encoded."); u32 from a virtual call on the channel's FEC layer object, zero when there is none (FEC type **[inferred]**); then the same tail as type 3 |
| 3 | `ChannelOpenRequest` | u32 length + string (the channel's "local initialization info", `SetLocalInitializationInfo` **[native-symbols]**; the peer exposes it as `GetRemoteInitializationInfo`); u64 not identified |
| 4 | `ChannelCloseRequest` | u32 zero |

`SendChannelOpen` (0x9fc6a4): the creating side sends type 2 then type 3; the accepting side
sends only type 3. Class names are the five `Microsoft::Basix::Dct::Channel::Class::...`
strings of the scoping study (4.1); the property string of `CreateChannel(type, properties)`
most likely travels as the initialization info **[inferred]**.

Whether control packets also carry the sequencer header of 5.3 was not checked.

### 5.3 Sequencer header **[native-disasm]** `MuxDCTSequencer::Sender::AddPacketHeader`

For channel data the sequencer assigns a 48-bit per-channel number, writes its low 16 bits into
the descriptor's sequence field (the value that ends up in the SRTP trailer, section 2.4), and,
depending on the buffer's send mode (1, 2, 3; names `BestEffort`, `GuaranteedDelivery`,
`GuaranteedDeliveryFence` per the scoping study, mapping not confirmed), prepends 8 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | flag (0 or 1 seen in the code; meaning not read) |
| 1 | 1 | zero |
| 2 | 6 | 48-bit sequence number, little-endian (probably the "dependent" sequence of `Receiver::GetQueueDependentSeq` **[inferred]**) |

Whether the header is present in all three modes: not determined. FEC layer headers
(`MuxDCTChannelFECLayer::FECCommonHeader`) not read; whether FEC is active for Message and Blob
channels is still open.

Confidence for section 5: medium.

---

## 6. Channel payloads

Both channel protocols use the same outer shape **[native-disasm]**: `u32 type`, a second
`u32` (written from a call result in `MessagePacket::Encode` 0x8fd9d0; body length is the
likely meaning **[inferred]**), then the body. Strings inside bodies are `u32 length + bytes`.

### 6.1 Message channel

`Microsoft::Nano::Streaming::MessageChannel`, source `libnano/streaming/messagechannel.cpp`.
Constants **[native-symbols]**: `CurrentProtocolVersion` (0x3e5c88) = 1 and
`TargetPathMaxLength` (0x3e5c8c) = 512 per the scoping study.

Types (`MessagePacket::Decode` 0x905e58; "Unknown message packet type: %d"):

| Type | Packet | Body |
|---|---|---|
| 1 | `HandshakePacket` | u32 (protocol version **[inferred]**) (`InternalDecode` 0x906ddc) |
| 2 | `Message::DataPacket` | six u32, then u32 length + data (`InternalDecode` 0x900010) |
| 3 | `CancelRequestPacket` | u32 (message or transaction id **[inferred]**) (0x8fdf38); type number by elimination |

Data packet: the six u32 are stored into members at +0x28, +0x2c, +0x30 (32-bit) and +0x38,
+0x40, +0x48 (widened to 64-bit, so sizes, offsets or counts). `Message::Packetize` (0x8ff6e0)
splits a message into fragments of (maximum packet size minus 36) bytes, 36 being 8 bytes of
outer header plus 28 of this header, and fills +0x30, +0x38 and +0x48 per fragment. With
`SendMessageData(Flags, unsigned int id, string path, FlexIBuffer body)` **[native-symbols]**
the fields must include flags, the 32-bit message id, a total size and a fragment offset or
index; the exact assignment was not read.

Not found: where the scope path (`/workflow`, `/fileTransfer`) is carried. It is not a separate
field of the data packet, so it is probably serialised at the start of the message data
**[inferred]**.

### 6.2 Blob channel

`Microsoft::Nano::Streaming::BlobChannel`, source `libnano/streaming/blobchannel.cpp`.
`MinSupportedProtocolVersion` (0x3e4da4) 2, `MaxSupportedProtocolVersion` (0x3e4da8) 3.

Types (`BasePacket::Decode` 0x8f3f2c; "Unknown blob packet type: %d"):

| Type | Packet | Body, in order |
|---|---|---|
| 1 | `HandshakePacket` (0x8f88b8) | u32, u32 (the two protocol versions **[inferred]**) |
| 2 | `Blob::DataPacket` (0x8efa48) | u32 flags; u32; u64; u64; string name; u32; u32; u32 length + data |
| 3 | `CompletionPacket` (0x8eca60) | u32 completion type; string name |
| 4 | `StartPacket` (0x8f54cc) | u64 size; string name |
| 5 | `BlobWrittenPacket` (0x8f48f0) | u32 (peer write-queue length, per the scoping study); string name. The decoder branches on protocol version 3 here; what differs was not read |

For the data packet, `SendBlobData(Blob::Flags, string name, unsigned long long, unsigned long
long, FlexIBuffer)` **[native-symbols]** gives the two u64 as offset and total size in some
order; the three extra u32 (members +0x2c, +0x30, +0x38) are not identified.

Confidence for section 6: medium for type numbers and field sizes, low for meanings.

---

## 7. Differences from the scoping study

1. Stack 11 is the well-known stack named `EnhancedSrtp`. The study (4.1) lists `EnhancedSrtp`
   among stacks "the Phone Link client library does not construct"; it is the one it does.
2. The study's layer table (4.2) puts a possible connection prober at layer 2. It is not in
   this stack. The actual order has `MTUProbe` between SRTP and keep-alive and an `OnWritable`
   layer between keep-alive and the rate controller.
3. The SSRC split is no longer a recollection: high and low 16-bit halves are separate
   descriptor members and the low half is the channel id.
4. SRTP is close to the RFCs but not identical: the wire sequence number is SRTP's own counter,
   the upper layer's number travels as an encrypted 2-byte trailer, and the GCM salt is the
   last 12 of 14 derived bytes. Overhead is 30 bytes per datagram.
5. The rate-control header is the MS-RDPEUDP2 packet layout as far as read, which the study
   only suspected ("may describe part of this header").
6. Key and salt encodings: hex, as the study says (the task brief's "base64" example does not
   apply).

## 8. Next reading, in order of value

1. Record one session (scoping study, experiment 1) and run the recipe of 2.5. That single
   result validates sections 1 and 2 and settles the shared-key question.
2. Read MS-RDPEUDP2 sections on packet layout and compare with section 4.
3. `CUDPRateController::InternalQueueWriteCore` (0xb56e68) and `SendRetransmissionPackets`
   (0xb562a4): where the header is placed, payload type of ack-only packets, retransmission.
4. `MuxDCTSequencer::Receiver::ProcessReceiveBuffer` and `MuxDCTChannel::HandleChannelRequest`
   (0x9f5058): flag byte, header presence per mode, the unidentified u32/u64 of 5.2.
5. `MessageChannel::SendMessageData` (0x8fee8c), `Message::Packetize` (0x8ff6e0),
   `DispatchMessage` (0x901ecc): field assignment and the path encoding.
6. `BlobChannel::Blob::Packetize` (0x8ef164), `SendBlobWrittenPacket` (0x8f7f68): chunking and
   flow-control numbers.

---

## 9. Addendum, 2026-10-09 evening: first recording, sections 1 and 2 confirmed **[wire]**

Recording `captures/nano-udp-2.pcap` (tcpdump on the bridge member that carries the VM, 501 UDP
datagrams) taken while one file of about 64 KB was sent from the phone to the PC through Link
to Windows, with the relay proxy recording alongside. Read with
`winphone-probe nano-check <pcap> <flows.jsonl>`, which opens each datagram with
`app/Sources/WinPhoneCore/Nano/NanoPacket.swift` using the keys of the `cs_connection_info`
messages in the relay capture and prints counts and packet kinds only.

| Result | Meaning |
|---|---|
| 444 datagrams start like RTP version 2; **443 open and authenticate** | The header layout (1.1), the key derivation with AES counter mode (2.2), the nonce built from the last 12 salt bytes, the 12-byte AAD and the 16-byte tag (2.3) are all right. The "medium" confidence on the PRF is now settled. |
| The key and salt are hexadecimal text, 32 and 28 characters, in every one of 148 descriptions | 2.1 confirmed. |
| Both directions of a connection open with the **same** key set | The open risk of 2.1 is answered: one master key set serves both directions. Which party's description supplied it was not looked up. |
| Inner numbers rise by one from packet to packet on channels 1024, 1025 and 1026 | The 2-byte trailer is the upper layer's sequence number, low byte first (2.4). On channel 0 they do not, so channel 0 is not sequenced that way. |
| Packet kinds seen: 104 rate control without data (246), 35 channel data (125), 101 keep-alive (50), 97 multiplexer control (15), 100 rate control (4), 102 probing (3) | The payload type table (1.3) holds; **all channel data used type 35**. |
| The one datagram that did not open: type 102, 1,472 bytes, phone to PC | Probing packets at full size may not be protected, or are protected differently; `UDPConnectionProber` is in use after all (compare section 7). |
| Two UDP flows, each between the VM's NAT address and the phone's Wi-Fi address | The Direct IP path was used although Windows also offered ICE. A first connection (20 packets each way, keep-alives and control only) belongs to the session start; the second (173 out, 231 in) carried the file. |
| Keep-alive payloads of 8 bytes, and of 1,368 bytes | The 8-byte form of 3.1, and MTU probing. |
| Channels on the file connection: 0, 1024, 1025, 1026, all with connection id 0 | 1026 carried 65,351 bytes phone to PC in 51 packets (about 1,280 per packet) and 251 bytes back in 4: the file and its acknowledgements. 1024 and 1025 exchanged two and three packets each way of 100 to 200 bytes: the message channels. |

This was path B (`WEA`): the relay capture shows the phone's `/fileshare_android2cdeh_phase1`
request about the same time. What a decoder still cannot do is unchanged from section 0 below
the encryption: the rate-control header (4), the multiplexer control packets (5) and the
channel payloads (6). All of them can now be read in the clear from this recording.

---

## 10. Addendum, 2026-10-09 night: every layer read in the clear **[wire]**

With the encryption open (section 9) the rest of the recording was read directly. The whole
session now decodes: `winphone-probe nano-file captures/nano-udp-2.pcap
captures/vm-raw-2026-10-09/flows.jsonl` follows both connections, reports every channel and
message and reassembles the transferred file (a PDF of about 60 KB) at exactly its announced
size, with no packet left undecoded. Code: `app/Sources/WinPhoneCore/Nano/NanoLayers.swift`
and `NanoTrace.swift`; tests in `NanoLayerTests.swift`, one of which replays the recording
when it is present. What follows replaces the guesses of sections 3 to 6 where they differ.
All integers little-endian.

### 10.1 Probing, payload type 102

A u16 kind. Kind 1 is the probe: filler shaped like a STUN message (magic cookie, a SOFTWARE
attribute naming the library) padded to the size being tested. Kind 2 is the report: a u16
with the payload size of the probe that arrived. Both sides probe at the start; the one
datagram that did not decrypt in section 9 is the phone's full-size probe.

### 10.2 Start of a connection, in order

| # | From | Packet |
|---|---|---|
| 1 | PC | probe (type 102, kind 1), sequence 0 |
| 2 | both | probe reports (kind 2) |
| 3 | phone | keep-alive (type 101), 40 bytes, flags 9: interval 2000, disconnect timeout 15000, MTU frequency 10, MTU probe frequency 100, MTU timeout 90,000,000 |
| 4 | PC | rate-control SYN (type 100): version 3, receiver log size 14, first sequence 100, controller type 5, retry 0 |
| 5 | PC | keep-alive, 8 bytes: reported MTU 40, flags 0x12 (handshake acknowledgement, plus a bit 0x10 not in section 3.1) |
| 6 | phone | rate-control SYN, the same values |
| 7 | PC | SYN ACK: u32 time stamp, u16 retry |
| 8 | phone | SYN ACK of ACK (two bytes) |

The layouts of 3.1 and 3.2 hold exactly. The PC never sent a keep-alive handshake of its own
(flags 9) in this recording.

### 10.3 Rate-control header

As section 4, and as MS-RDPEUDP2: the low 12 bits of the first u16 are the flags, the top 4 the
log window size (13 from the PC, 12 from the phone). Seen and decoded: ACK (0x001), DATA
(0x004), ACK OF ACKS (0x010), the one-byte part 0x040, and the three-byte delayed-ack part
0x100 (u8 1, u16 20). Not seen: ack vector, the 8-byte part. Data sequence numbers start at
the handshake's first sequence (100) and the ack of acks stays at 100 here. Packets with
nothing but acknowledgements travel as type 104, or as type 35 on channel 0.

### 10.4 Multiplexer control, payload type 97

Follows the rate-control header directly (no sequencer header). u32 kind:

| Kind | Body |
|---|---|
| 2 create | u16 length + description; u32 (0); then as kind 3 |
| 3 open | u32 length + initialization string; f64 (1.0; the "u64 not identified" of 5.2 is a double) |
| 4 close | u32 (0) |

The description is the channel class name followed by `,<n>,<m>,<properties>`, and the creator
repeats it as its initialization string; the acceptor answers with kind 3 and an empty string.
Seen: `…::Class::Messaging,0,4,ScenarioId=DeviceConnection` (channel 1024, created by the
phone on every connection), `…::Messaging,1,4,ConsumerId=<id>&ScenarioId=<scenario>` (1025) and
`…::Blob,2,5,ConsumerId=<id>&ScenarioId=<scenario>` (1026). Channel numbers start at 1024 and
the phone, the UDP acceptor, creates all three.

### 10.5 Sequencer header

Eight bytes in front of every channel data packet: u8 mode (2 on a channel's first packet, 3
afterwards), u8 zero, 48-bit number of the packet this one follows (own number minus one;
zero on the first two). The packet's own number is the encrypted trailer of section 2.4.

### 10.6 Message channel

Packet: u32 kind, u32 length of the rest, the rest.

| Kind | Rest |
|---|---|
| 1 handshake | u32 version (1), sent by both sides as each one's first packet |
| 2 data | u32 flags (0); u32 message id (a random start per sender, rising by one); u32 (1); u32 path length; u32 body length; u32 offset of this piece (0); u32 length + bytes |

A message is its path immediately followed by its body; every message here fitted one packet.
The third u32 was 1 throughout (a piece count, or a version: not settled).

### 10.7 Blob channel

| Kind | Rest |
|---|---|
| 1 handshake | u32 lowest version (2), u32 highest (3), both sides |
| 4 start | u64 total size; string name |
| 2 data | u32 flags (0); u32 number of pieces in all; u64 (0); u64 total size; string name; u32 total size again; u32 offset of this piece; u32 length + bytes |
| 3 completion | u32 kind; string name. The sender ends with kind 1; the receiver answers with kind 4 |
| 5 written | u32 pieces still queued at the receiver; string name |

Strings are u32 length + bytes. The name is the file id of the offer. Pieces were 1,268 bytes;
48 of them made the file.

### 10.8 The exchange of a phone-to-PC share on the cross-device path

Relay first: the phone's resource request `/fileshare_android2cdeh_phase1` and the PC's answer.
Then, on a Nano connection the PC opens:

| # | From | Channel | Message |
|---|---|---|---|
| 1 | phone | control | creates channel 1024 (`ScenarioId=DeviceConnection`); both open it and exchange message handshakes |
| 2 | PC | 1024 | path `/Channel/ProtoCreatePlatformChannelRequest`: type `NAMED_STREAMS_CHANNEL`, scenario id `fileShare_` + the fixed GUID of `file-transfer.md` 3.2, a channel id, trace context |
| 3 | phone | 1024 | path `/Channel/ProtoPeerPlatformChannelCreationResult`: result success, reason success, the channel id |
| 4 | phone | control | creates 1025 (Messaging) and 1026 (Blob) for that scenario; handshakes on both |
| 5 | phone | 1025 | path `/<scenario id>/NamedStreams/fileTransfer/platform`: `FileShareMessage`, scenario `FileTransferToPc`, transfer id, try count 1, one item per file with id, name, size and status `IN_PROGRESS` (2, not the 1 the spec expected) |
| 6 | PC | 1025 | path `/<scenario id>/ManifestRequest`: a `ProtoManifest` whose entries are the files wanted (id and size), with a trace context. **This is how the PC asks for the files**; no `/Manifest` or `/ManifestAck` was exchanged |
| 7 | phone | 1026 | blob start, the data pieces, completion kind 1 |
| 8 | PC | 1026, 1025 | "written" reports; `FileShareMessage` scenario `FileTransferToPcCompleted` with sender name, received count 1 and the item at status `COMPLETED`; blob completion kind 4 |
| 9 | phone | 1025 | `FileTransferToPcCompleted` with only the transfer id and try count |
| 10 | both | control | close 1025 and 1026 |

### 10.9 What is still missing for a receiver

Decoding is complete for this flow. A receiver must also **send**: the context-source
signalling over the relay, the probe, keep-alive and rate-control handshakes, acknowledgements
with their timing fields (retransmission was not exercised by the recording), the channel
opens, the three messages of steps 2, 6 and 8 and the blob reports. All packet forms for those
are now known and have encoders; the sending side's timing behaviour (pacing, delayed
acknowledgements, when the phone retransmits or gives up) is the part still unobserved.

---

## 11. Addendum: what the sending side needed, also from the recording **[wire]**

Read from the same two files for the implementation in `app/Sources/WinPhoneCore/Nano/`
(`NanoSignalling.swift`, `NanoConnection.swift`, `NanoFileReceiver.swift`).

Signalling on the relay (`winphone-probe nano-signalling <flows.jsonl> [from]`):

- The exchange runs again for **each share**, right after the PC has answered the phone's
  `/fileshare_android2cdeh_phase1` request (`NanoDelegateInitResponse`, status OK, the same
  session id).
- `cs_initialize_message` goes on the bare route `/Context/Message`; its `context_source_id` is
  the **phone's** device id; transport preference 0.
- Every later message goes on `/Context/Message/<sender's own device id>`.
- Every request of this kind is answered with the JSON body `{"processStatus":"Success"}`
  (the PC adds content type `text/json`).
- The PC's direct description is exactly
  `{"connectioninformation":{},"connectionid":"<lower-case GUID>","connectiontype":0,"multipleconnections":true}`.
  Connection types 1, 2 and 3 are the ICE variants Windows also sends, each with its own key.
- The phone's direct description has `security.key` and `security.salt`, `ip` with `count` and
  numbered entries of `addr` and `iname` (one for mobile data, one for Wi-Fi here), `port` and
  `keepalive.warningtimeout` (5000), numbers written as text.
- **The key that protects the UDP connection is the one in the phone's direct description**, for
  both directions (`nano-check` now names the origin of each working key).

On the UDP connection:

- After the rate-control handshake **each side sends a burst of 123 packets of type 104**, each
  the rate header (data sequence 100 upward, the first and every sixteenth with the delayed-ack
  part 1 and 20) followed by 1,000 zero bytes: the link measurement of the rate controller.
  Real data then continues the same sequence numbers.
- Acknowledgement time stamps count **4 microseconds per unit**; an acknowledgement names one
  packet and covers as many before it as it carries time differences.
- Acknowledgements without data travel as type 35 on channel 0 with the ack-of-acks part at
  the first sequence number, 100.
- Keep-alives of 8 bytes go every 2 seconds from both sides; the PC's answer to the phone's
  keep-alive handshake has flags 0x12.
- The PC's size probe is its first packet (sequence 0), about 1.4 kB of STUN-shaped filler; the
  phone's own probe of 1,472 bytes does not authenticate with the session key and is answered
  with a report of 1,458.
- The transfer of about 60 kB took 0.4 s; the connection then stayed up on keep-alives.

Choices of this client that are **not** from the recording: its probe is 1,200 bytes of random
filler; a packet that is not acknowledged within 400 ms is sent again with the same data
sequence number; it acknowledges every packet singly; it closes the connection when the share
is over.

---

## 12. Addendum, 2026-10-09 21:00: first file received on the Mac, and two corrections **[wire, live]**

A file shared from the phone arrived on the Mac over this client's own connection
(`~/Library/Logs/WinPhone/winphone.log`, 20:58:40; 33,726 bytes, saved to Downloads). The phone
chose the **Phone Link client** as its target, so this was the exchange of `file-transfer.md`
3.1, which had never been captured: every step of it is now confirmed live.

| Step | Seen |
|---|---|
| Offer on `/legacy/phonecontent`, `contentType` `fileTransfer`, answered `{result 0}` | accepted; an answer of 1 leaves the phone on "preparing to send" |
| `/nanohandshake` with `workflow` `fileTransfer`, `sequenceNumber` Int64 file time, `handshake` = `{"contractVersion":{"versionMin":6,"versionMax":6},"settings":{"connectionType":0},"instanceId":"<guid>","multipleConnections":true}` | answered within 0.2 s with a `handshake` string that carries `ip`, `port` and `security` at its top level (not under `connectioninformation`) |
| UDP to the phone's `wlan0` address | first packet from the phone 16 ms after ours |
| Start sequence | complete 33 ms after the first packet |
| Channel 1024 `Messaging`, property `workflow=launcher`; `/workflow` JSON `{"workflow":"fileTransfer","workflowId":…}` | the phone then created 1025 `Messaging` and 1026 `Blob`, both `workflow=fileTransfer` |
| `/fileTransfer` JSON `FileTransferToPcFile` with the item at status 2 | the blob arrived 0.24 s later |
| `/fileTransfer` JSON `FileTransferToPcCompleted` with status 3 and `PcFolder` | the phone answered `FileTransferToPcCompleted` |

**Correction to 10.1 and 11 (probing).** The probe is a real exchange, and the phone will not go
on without it. Each side sends a probe (kind 1); the other answers with a report (kind 2)
carrying the probe's payload size. The phone starts at 1,458 and, while unanswered, sends six
smaller probes every 0.8 s, 16 bytes apart, searching for a size that gets through. Until one
of its probes is reported it ignores the rate-control SYN. The phone's probes are encrypted
like every other packet: the "probe that does not authenticate" of the recording was an IP
fragment, since 1,458 + 30 bytes exceeds what one unfragmented datagram carries and the
capture reader takes the first fragment only. Its payload is the kind, a u16 of 1, and zeros.
Our own probe of 1,200 random bytes was reported back by the phone without complaint.

**Order of the start on a direct Wi-Fi link**, as traced: our probe; the phone's probe; our
report and SYN; the phone's report, keep-alive handshake (flags 9) and SYN; our keep-alive
answer (0x12) and SYN ACK; the phone's SYN ACK of ACK.

Still not exercised: several files in one share, a large file, loss on a real network, a
share toward the cross-device client from this phone, and cancelling.


---

## 13. Acknowledgement vector and loss recovery

Static reading of `liblibnanoapi.so` (arm64, app manager 1.26082.130.0), 2026-10-09. Functions:
`UDPRateControlHeader::AckVector::Encode` (0xb5c2d0), `TryRunLengthMode` (0xb5c00c), `Decode`
(0xb5b930), `operator>` (0xb5cbe4); receiver half `UDPFlowCtlInbound::ProcessData` (0xb67734),
`SetupForSendingAcks` (0xb685a0), `ProcessAckOfAcks` (0xb69188); sender half
`UDPFlowCtlOutbound::ProcessAck` (0xb81968), `ProcessAckVector` (0xb82510), `TimerCallback`
(0xb7d780), `SetupForSendingAckOfAcks` (0xb81094); dispatch in
`CUDPRateController::OnDataReceived` (0xb535f8). Source file names from strings:
`udpratecontrollerinbound.cpp`, `udppacketqueue.h`.

### 13.0 The three facts that explain the live failures

1. **A plain ACK is cumulative at the sender.** `ProcessAck` walks from the acknowledged number
   S down to its lowest outstanding number and marks every packet still outstanding as
   acknowledged; the delayed-ack time differences only supply timing for the first n of them.
   An ACK that names the newest packet across a hole therefore tells the phone the hole
   arrived. That is why six lost packets were never sent again. **[native-disasm]**
2. **A retransmission is new data on the wire.** `SendRetransmissionPackets` hands the saved
   buffer back to `InternalQueueWriteCore`, the ordinary send path, which calls
   `SetupForSendingData` and so assigns the next data sequence number. A hole in the numbering
   is never filled; the receiver must not wait for it. **[native-disasm]** (call graph),
   agrees with the live observation.
3. **The ack of acks is how the sender tells the receiver to stop waiting.** After the sender
   gives a packet up as lost, its lowest outstanding number moves past it and it sends that
   number in the 0x010 part; the receiver then moves its "next expected" forward over the
   hole (13.4). A receiver that ignores the part stays stuck behind the hole, keeps repeating
   the same cumulative ACK (which the sender discards as "out of order ack, MinInUse: %d and
   ackSN: %d" **[native-strings]**), every later packet times out and is sent again: the slow
   trickle seen with the cumulative scheme. **[native-disasm]** + **[inferred]**

### 13.1 Ack vector, wire format **[native-disasm]**

| Field | Size | Meaning |
|---|---|---|
| base | u16 LE | Low 16 bits of the receiver's next expected sequence number, i.e. the **lowest missing** one. Element 0 of the vector describes this number and is always "not received". The decoder extends it to 64 bits against its own position. |
| count | u8 | Bit 7: time stamp present. Low 7 bits: number of coded bytes that follow (0..21; `c_ackVecBufferSize` = 21). |
| time stamp | u16 LE + u8 | Only if bit 7 set. Receive time of the **highest** received packet, 4 µs units, 24 bits (low 16, then high 8), same clock as the ACK part. |
| time gap | u8 | Only if bit 7 set. Milliseconds between receiving that packet and sending this vector, capped at 255. |
| coded bytes | count | See below. |

The vector is a bit string, element i describing sequence `base + i`, **ascending**; 1 =
received, 0 = not received. Its length is `highest received - base + 1`, so the last element is
always 1. Coded bytes are consumed in order:

| Byte | Meaning |
|---|---|
| bit 7 set (run) | bit 6 = the state of the run (**1 = received**, 0 = missing); low 6 bits = run length **itself** (1..63, not minus one; 0 adds nothing). |
| bit 7 clear (bitmap) | 7 elements, **bit 0 = lowest sequence number**, 1 = received. For the **last** coded byte only, if its value is below 0x40 the decoder stops at its highest set bit (value 1 gives 1 element, 2..3 give 2, 4..7 give 3, 8..15 give 4, 16..31 give 5, 32..63 give 6, 0 gives none), which is how a vector whose length is not a multiple of 7 ends. |

Encoder as built by the phone: at element 0 and after every completed bitmap byte it calls
`TryRunLengthMode`; that emits run bytes only when at least 8 equal elements follow (63 per
byte, repeated while 8 or more remain, then tries again for the opposite state), otherwise the
next 7 elements go into a bitmap byte. At most 21 coded bytes (147 packets as pure bitmap, 1,323
as pure runs). If everything fitted, the 7-byte header with time stamp is written (count byte
has bit 7 set); if the vector was cut short, the 3-byte header without time stamp. The decoder
accepts any mix, so a receiver may also emit bitmap bytes only for short vectors.

Flags: ACKVEC 0x008 **instead of** ACK 0x001; a header with both is rejected ("FlagAck and
FlagAckVector can't be set simultaneousy"). Part order stays as in section 4: the ack-of-acks
part precedes the vector.

### 13.2 When the receiver sends ACK and when the vector **[native-disasm]**

Receiver state: `next` (lowest number not yet received), `acked` (value of `next` when the
last ACK was built), `max` (highest number received), per-number state 1 = expected, not
arrived ("InFlight" in a string) or 2 = received, and a `gap` flag.

- A packet above `max`: every number between becomes state 1 and `gap` is set. A packet that
  fills `next`: `next` advances over received numbers; `gap` = holes remain. A number below
  `next` is passed up anyway and queued for a single plain ACK naming just it. A number in
  the window that is already received is dropped ("Received SN %d that was already ACKed").
- `ProcessData` asks for an immediate acknowledgement when `gap` is set, or when more than
  `maxDelayedAcks + 1` packets are unacknowledged; otherwise it arms a timer of
  max(10, `delayedAckTimeout` - age of the oldest unacknowledged packet) ms. Both values come
  from the peer's 0x100 part (u8 = `maxDelayedAcks`, u16 = `delayedAckTimeout`; 1 and 20 from
  the phone).
- `SetupForSendingAcks`, once per outgoing header:
  1. `next != acked`: plain **ACK** for `next - 1` (never across a hole), time differences for
     up to 15 packets below it down to `acked`; then `acked = next`.
  2. else if `gap` and `next < max`: **ACKVEC** with base `next`, covering `next..max`, time
     stamp of `max`. Nothing is updated, so the vector is repeated in every later header while
     the hole exists; with `gap` set that is at least one per packet received.
  3. else if a below-`next` packet is queued: plain ACK for that one number, no differences.
- The 0x040 byte is added to a plain ACK when its value changed or every 64th ACK; the value
  is the per-packet overhead the receiver saw (size below the rate header minus payload), and
  the sender only smooths it into its byte accounting.

### 13.3 What the sender does **[native-disasm]**

Sender packet states: 1 = in flight, 2 = acknowledged, 3 = lost.

- **ACK for S**: ignored if S is below the lowest outstanding number or below the highest S
  seen so far; rejected if above the highest number sent. Otherwise every in-flight packet
  from the lowest outstanding number up to S becomes acknowledged. No loss inference at all.
- **ACKVEC** (base, n elements, r of them received):
  - rejected with an exception if `base + n - 1` is beyond the highest number sent or if
    element 0 is "received" ("Invalid Packet: the last element of m_ackVector should not
    correspond to a sn beyond what we have sent. also the first element should not be an ACK");
    also an exception if an element says "not received" for a packet the sender already holds
    as acknowledged ("for the ACK node, the m_ackVector and node should be in sync"). Where
    these are caught was not read; treat both as fatal for the connection **[inferred]**. The
    second one means: **never report as missing a number that an earlier ACK or vector covered
    as received** (an ACK across a hole followed by an honest vector triggers it).
  - **Identical to the previous vector** (same base, same n, same r): every packet in its range
    that is still in flight is marked lost at once. A repeated vector is an explicit NACK.
  - Otherwise it must compare greater than the stored one (larger base, or same base with n
    and r not smaller; "Out of order ack vector" otherwise, ignored). Then, from the top
    element downwards: in-flight packets whose element is 1 become acknowledged; all in-flight
    packets **below the base** become acknowledged (the base is cumulative); an in-flight
    packet whose element is 0 becomes a loss candidate once the walk is more than
    `nackThreshold` positions below the highest acknowledged element. With the built-in
    default `c_nackMode` = 0x16 (mode 1 "reorder" in the high nibble, threshold 6 in the low
    nibble) that is: missing and at least **8 below the highest received number**. A candidate
    is not lost on the spot: the first sighting arms a 5 ms deadline, and the packet becomes
    lost when a later vector or the timer finds the deadline passed.
- **Timer**: every in-flight packet has a deadline (`GetPacketTimeout`: (attempt + 2) x a
  round-trip estimate, or 500 ms x (attempt + 1) before one exists; `GetRTO` clamps 10..2,000
  ms). When it passes, the packet is marked lost. So even with no vector the phone eventually
  resends, slowly.
- **Lost** packets go through `PrepareEventCallbacks` to `UdpReliabilityController`, which
  re-queues them (`c_maxRetransAttempts` = 50, not traced further); they leave with a **new
  data sequence number**. The lowest outstanding number then advances past the lost ones.

### 13.4 Ack of acks (0x010) **[native-disasm]**

- Sender side: the part is added only when the lowest outstanding number is greater than both
  (highest ACKed number + 1) and the base of the last vector received, and its value is that
  lowest outstanding number. In practice: after packets were given up as lost. (Windows sent
  the constant 100 in the short lossless recording; that is a different build.)
- Receiver side, value X, processed before the data of the same packet: `acked = max(acked,
  X)`; if `next < X` then `next` jumps to X and on over numbers already received, `max` is
  raised to `next - 1` if needed, and `gap` is recomputed. Everything below X is abandoned.
- Our own value: X only ever moves the phone's *receiving* half forward (max with its current
  position); acknowledgements and vectors are handled by its sending half. A constant 100 is a
  no-op and cannot make the phone ignore our acknowledgements. It matters only for data we
  send: because this client resends with the same sequence number it never needs to raise it.

### 13.5 Recipe: what a receiver must do when a packet is missing

1. Keep `next`, `acked`, `max` and a received set. Pass every new packet's payload up at once,
   whatever its number (ordering is the job of the sequencer header, section 5.3); also pass
   up a number below `next` and acknowledge it alone.
2. **Never send a plain ACK for a number above a hole.** The ACK names `next - 1` only.
3. While a hole exists (`next <= max`), answer every received data packet with an ACKVEC:
   base = `next`, elements `next..max`, time stamp and gap of `max`. First send the plain ACK
   for `next - 1` if that has not been acknowledged yet (one header carries one or the other).
4. If no further data arrives within about 20 ms, send the **same vector again unchanged**
   (same base, length and received count): the phone then marks every hole in it lost
   immediately, without waiting for 8 later packets or its timer. Do not repeat it more often
   than needed; each identical repeat is a NACK of whatever is still in flight in its range.
5. On every incoming header with 0x010, apply 13.4 before the data: move `next` up to X and
   over received numbers; drop the hole. This is what ends the vector for that hole. The lost
   payload arrives under new, higher numbers.
6. Once no hole remains, go back to plain ACKs (delayed as in 13.2).

Worked example: 100..103 arrive, then 106..110; 104 and 105 are missing. Flags word with
window 13 and our constant ack of acks 100; TT TT TT = 24-bit receive time of the newest
packet in 4 µs units, GG = ms since then.

| Event | Header bytes sent |
|---|---|
| 100..103 received | `11 D0` `67 00 TT TT TT GG 03 d1 d2 d3` `64 00` (ACK 103 with three time differences, as today) |
| 106 received | `18 D0` `64 00` `68 00 81 TT TT TT GG 04` |
| 107 received | `18 D0` `64 00` `68 00 81 TT TT TT GG 0C` |
| 108 received | `18 D0` `64 00` `68 00 81 TT TT TT GG 1C` |
| 109 received | `18 D0` `64 00` `68 00 81 TT TT TT GG 3C` |
| 110 received | `18 D0` `64 00` `68 00 81 TT TT TT GG 7C` |
| 20 ms without data | the last one again, base 104, 7 elements, 5 received (TT and GG may differ; they are not compared) |

`68 00` = base 104; `81` = time stamp present, one coded byte; `7C` = 0b1111100, bit 0 for 104
and bit 1 for 105 clear, bits 2..6 for 106..110 set. Without the ack-of-acks part the last
header is `08 D0 68 00 81 TT TT TT GG 7C`. The phone then resends the two payloads as, say,
111 and 112 with 0x010 = 106 or higher; `next` becomes 111 and plain ACKs resume. A longer
case, 104 and 105 missing and 106..200 received (97 elements): coded bytes `7C FF DB` (bitmap
for 104..110, run of 63 received, run of 27 received), count byte `83`.

### 13.6 Confidence

| Item | Confidence |
|---|---|
| Vector layout, ascending from base, 1 = received, run length in the low 6 bits, bit 6 = received, bitmap bit 0 = lowest, last-byte trimming | high; encoder and decoder read in full and agree |
| Base = lowest missing number, vector reaches the highest received, time stamp of the highest | high |
| ACK versus vector selection, immediate acknowledgement while a hole exists | high |
| Plain ACK cumulative at the sender; no loss inference from ACKs | high |
| Retransmission carries a new data sequence number | high (call graph), matches the live trace |
| Ack of acks moves the receiver past abandoned numbers; when the sender adds it | high for the arithmetic, medium for "only after loss" in practice |
| Identical vector = immediate loss of every in-flight packet in its range | high for the code path; not yet tried live |
| Reorder threshold 8 below the highest received, 5 ms confirmation | medium: the counting was read once, and the phone may be configured away from the default 0x16 |
| Timer values (500 ms steps, 10..2,000 ms clamp) | medium; the round-trip source was not traced |
| Exceptions on an inconsistent vector being fatal | low; the catch site was not read |
| Window nibble (stored per packet from the peer), 0x040 and 0x100 meaning | medium; none of them gates retransmission |

Relation to MS-RDPEUDP2 **[recollection]**: the code confirms the document's shape (base
sequence number, 7-bit count with a time-stamp flag, run and bitmap bytes, ACK and ACKVEC
mutually exclusive, ack of acks as the sender's lowest outstanding number). The polarity, the
bit order, the "run length itself" encoding, the trimmed last byte and the identical-vector
rule above are from the disassembly, not from memory of the document.

Not read: `UdpReliabilityController::OnPacketEvents` (0xb9b3c8) and what happens after 50
attempts; how the window nibble limits the sender; whether the Windows side follows the same
ack-of-acks rule.

## 14. Addendum, 2026-10-09 21:50: large files, live **[wire, live]**

Section 13 was built into the Mac client (`Nano/NanoReliability.swift`, `NanoConnection`) and
tried with the phone at once: a 25.9 MB video in 4.6 s and a 380 MB file in 47 s (about
8 MB/s), both complete. Before that, every large file stuck with a hole.

What the live runs confirm:

- **A plain ACK is cumulative.** With the old client (ACK names the newest packet, also across
  a gap) lost packets were never sent again. With ACKs held at the last packet below the gap
  they are.
- **The vector is accepted.** 8,611 vectors were sent during the 380 MB file and the
  connection stayed up; nothing suggests the phone took exception to any of them.
- **The ack of acks ends a gap.** The phone gave up 1,440 numbers in 23 steps during that
  file (465 in 8 steps during the 25.9 MB one); after each step the gap was gone and plain
  ACKs resumed. The largest gap seen at a two-second sample was 110 packets.
- The phone never sent a vector about the Mac's own packets (they are few).

Not separated by these runs: whether the phone resent on the vectors or on its own timer.
Both paths are covered by tests against a scripted phone, each alone.

Blob layout learned on the way (corrects section 6 and 10): the u64 after the piece count is
the **segment index**, not a byte offset. The phone cuts a file into segments of 100,000
bytes; a piece's place in the file is `segment x 100,000 + offset within the segment`, and
the u32 before the offset is that segment's own size. The channel's 16-bit packet number
comes round several times in a large file.

### 14.1 The same video sent to Windows (`nano-udp-3.pcap`) **[wire]**

25,163 of 25,164 datagrams open; 24,601 from the phone, 563 from the PC; the file took 3.7 s.

- Windows **never sends a vector**, and neither does the phone: every acknowledgement in
  the recording is a plain ACK.
- Windows acknowledges sparsely: 405 ACKs for 24,519 data packets, a median of 72 packets
  apart (as many as the phone's 0x100 part allows; the phone raises that value from 41 to
  184 during the transfer and sends the part on every 16th packet). Each ACK carries up to 15
  time differences. Only 5,212 packets were ever inside an ACK's own count; of the rest,
  15,500 were never sent again. That is the cumulative ACK seen on the wire.
- The phone still sent 3,802 packets twice, in three stretches (193, 74 and 3,535 packets),
  each starting right after an ACK for the packet just before the stretch, 20 to 620 ms after
  the first sending, with its ack of acks stepping forward as it went. Windows had gone on
  acknowledging later packets meanwhile. The recording does not show why the phone did not
  count those ACKs; it was taken on the VM's side, so what reached the phone is not known.
  Each stretch follows a pause of the phone or a 13 ms gap in Windows' ACKs.
- Windows sends real ack-of-acks values (its own lowest outstanding number, 233 to 361 here),
  and the constant 100 only while nothing of its own has been acknowledged yet. It also
  resends its own packets under new numbers.
- On the blob channel Windows sends one "written" packet per segment (281 here), then the
  completion.

## 15. Addendum, 2026-10-09 22:22: sending a blob to the phone **[live]**

The Mac sent two files to the phone as blobs (`NanoConnection.sendBlob`), accepted on the
first try. What this side does as the sender of bulk data:

- At most a window of packets unacknowledged: 32 at first, growing with each acknowledgement
  to 384, halved when a packet has to be sent again (at most once per 200 ms).
- The 0x100 part with (39, 20) on every sixteenth data packet while the blob goes out, so the
  phone acknowledges about every forty packets; (1, 20) again afterwards.
- A packet is sent again, under a new number, when a vector from the phone shows it missing
  with eight later packets arrived or 50 ms after it was sent, or after 400 ms without any
  acknowledgement. The ack of acks is the lowest number still outstanding.

Both files went out without a single packet sent again (2 MB in 0.4 s; the window had reached
233). The phone's vectors and the resend path have therefore not been exercised live yet; they
are covered by tests against a scripted phone that keeps its book of arrivals with the same
code as this client.
