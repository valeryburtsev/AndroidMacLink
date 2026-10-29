# Nano peer-to-peer transport: scoping study

Scoping study, not an implementation spec. It answers whether and how to build Microsoft's
"Nano" transport on macOS, which file transfer (both directions), phone-file content and
screen/app mirroring need. `file-transfer.md` sections 2.2 and 2.3 are the starting point and
are not repeated.

Revision 1, 2026-10-09. Static inspection only; nothing was executed, no device was touched.

## Sources and tags

| Tag | Meaning | Pointer style |
|---|---|---|
| **[code-android]** | Decompiled Link to Windows 1.26082.130.0 (jadx) | `A:` class; `agents` = `com.microsoft.mmx.agents`, `smsrc` = `com.microsoft.mmx.screenmirroringsrc`, `nano.jni` = `com.microsoft.nano.jni` |
| **[code-windows]** | Decompiled Phone Link 1.26072.257.0 | `W:` assembly :: class |
| **[native-strings]** | `strings`, `nm -D`, and string/constant references resolved from disassembly listings of `lib/arm64-v8a/liblibnanoapi.so` (inside the LTW `base.apk`) and `strings` of `LibNanoAPI.dll` | `N:` demangled symbol or literal; `Nw:` for the Windows DLL |
| **[wire]** | Seen in a capture, structure only | capture file |
| **[inferred]** | Deduced, reasoning given | |
| **[recollection]** | From memory of public reverse-engineering work on Xbox Nano. **Not verified here.** | |

How the native evidence was obtained: the Android library is stripped of debug data but
**exports about 7,700 C++ symbols** (`nm -D`), so class and method names, parameter types and
some constants are readable without a decompiler. String literals used by a given function were
recovered by resolving `adrp/add` pairs and inline immediates in `objdump -d` output for that
function's address range. The Windows DLL has no symbols; only its strings were used.

---

## 0. Summary

1. Nano is one native library built from one source tree for both platforms
   (`shared/nano/src/{libbasix,libbasix-network,libnano,clientlib}`), wrapped by a thin JNI layer
   on Android and a WinRT projection on Windows **[native-strings]**.
2. It is the same protocol family as Xbox game-streaming "Nano" (RTP framing, multiplexed
   channels with `...::Dct::Channel::Class::<name>` class names), in a later generation: UDP
   only, SRTP-protected, with the RDP-style URCP reliability layer underneath. Old public notes
   are a map, not a spec. Message and Blob channels are not in those notes at all.
3. On the same LAN the minimal path is: one relay request (`/nanohandshake`), then **the PC
   opens a plain UDP flow to an `ip`/`port` the phone returns, protected by SRTP whose master
   key and salt the phone also returns in that reply**. No ICE, STUN, TURN, DTLS or certificates.
4. Because the key travels in the relay reply, which our capture pipeline already decodes, any
   captured Nano session is decryptable offline. That turns the unknown part (byte-level
   framing of five thin layers) into a decoding exercise against named native code.
5. Recommendation: option (b), minimal same-LAN path with Message and Blob channels, built
   decoder-first, with a go/no-go gate after one capture. Rough size 4 to 5 weeks
   (range 3 to 7). First experiment: capture one real phone-to-PC transfer from the VM, relay
   and UDP together (section 7).

---

## 1. Where Nano lives

### 1.1 Android

| Layer | What | Evidence |
|---|---|---|
| Native library | `liblibnanoapi.so` (arm64 13.5 MB, armv7 8.8 MB). Statically contains OpenSSL 3 (`engines-3`, `ossl-modules` paths), Boost.Asio, Boost.PropertyTree, libopus | **[native-strings]** `unzip -l base.apk`; N: source paths `D:/a/_work/1/s/shared/nano/src/...` |
| Loader | `System.loadLibrary("libnanoapi")` in `com.microsoft.mmx.libnanoapi.LibNanoAPI`; natives `InitializeLogging`, `CheckException`, `StartPerfLog`, `StopPerfLog`, `FlushPerfLog` | **[code-android]** A: mmx.libnanoapi.LibNanoAPI; N: `Java_com_microsoft_mmx_libnanoapi_LibNanoAPI_*` |
| JNI package | `com.microsoft.nano.jni` with sub-packages `connect`, `client`, `channel`, `diagnostics`, `helpers` (41 files, about 850 lines, all thin) | **[code-android]** |
| Path A consumers ("apps stack") | `smsrc.connectionsvc.*` (ConnectionService, connect.ConnectionInstance, connect.ServerConnectAdapter, connect.ClientAdapter, workflow.*), entered from `agents.NanoHandshakeRequestHandler` through `agents.NanoHandshakeProvider`; file transfer in `agents.filetransfer.transport.nano.*` | **[code-android]** |
| Path B consumers ("platform") | `agents.ypp.ambientexperience.transport.nano.*` and `...transport.connect.DeviceConnection*` | **[code-android]** |
| Other native libs in the APK | `libwolfssl.so`, `libwolfssljni.so`, `libwolfcryptjni.so`, `libmscustomjni.so` (relay crypto, not Nano), `libOneAuth.so`, `libmaesdk.so` | **[native-strings]** |

JNI surface as jadx shows it (all `native`, every class also has `construct()` and `finalize()`)
**[code-android]**; each has a matching `Java_com_microsoft_nano_jni_*` export **[native-strings]**:

| Class | Native methods |
|---|---|
| `connect.ConnectFactory` | `construct(ITelemetryProvider)`, `IConnect CreateClientConnect(int)`, `IConnect CreateServerConnect(int)` |
| `connect.ClientConnect` (implements `IConnect`; used for both roles) | `void Initialize(String properties, IConnectDelegate)`, `void Open(String connectionInfo)`, `String GetProperty(String)`, `void Close()` |
| `connect.IConnectDelegate` (callback) | `OnSetupComplete(String connectionInfo)`, `OnOpened(IClient)`, `OnClosed(int reason, String error)` |
| `client.Client` | `void Initialize(IClientDelegate)`, `String CreateChannel(int type, String properties)`, `boolean IsConnected()`, `String GetConnectionMetrics()`, `String GetRealTimeConnectionMetrics()`, `void Close()` |
| `client.IClientDelegate` | `OnChannelCreated(IChannel)`, `OnClosed(int, String)`, `OnMissedPackets(int)`, `OnRecoveredPackets()` |
| `channel.MessageChannel` | `Initialize()`, `Open(IChannelDelegate)`, `RegisterHandler(String scope, IMessageHandler)`, `UnregisterHandler(String)`, `boolean Send(String scope, byte[])`, `Close()`, `GetChannelId()`, `GetChannelType()`, `GetProperties()`, `IsOpen()` |
| `channel.IMessageHandler` | `OnMessageReceived(String scope, byte[])` |
| `channel.BlobChannel` | `Initialize(IBlobChannelDelegate, String properties)`, `Open(IChannelDelegate)`, `boolean Send(String name, IBlobStream)`, `Cancel(String name)`, plus the common five |
| `channel.IBlobChannelDelegate` / `IBlobStream` | `IBlobStream RequestStream(String name, long size)`; stream: `long GetSize()`, `int GetData(byte[])`, `WriteData(byte[])`, `Close(String reason)` |
| `channel.VideoSourceChannel`, `AudioSourceChannel`, `InputTargetChannel` | media and input, not needed for file transfer |
| `diagnostics.NetworkDiagnosticsDetector(Factory)` | `RunNatDetection` |

Property bags cross JNI as one string, `key=value` pairs joined with `&`
(A: nano.jni.channel.Utils) **[code-android]**.

Enums **[code-android]**: `channel.ChannelType` VideoTarget 0, VideoSource 1, InputTarget 2,
InputSource 3, Message 4, Blob 5, AudioTarget 6, AudioSource 7 (eight values; `PLAN.md` 2.2 says
nine). `connect.ConnectionType` IpSrtp 0, IceSrtp 1, IpSrtpWifiP2p 2.
`connect.ConnectCloseReason` UNKNOWN 0, USER_CANCELED 1, TIMEOUT_EXCEEDED 2,
HOSTNAME_RESOLUTION_ERROR 3, NONE 4. `client.ClientCloseReason` UNKNOWN 0, USER_ENDED 1,
KEEP_ALIVE_TIMEOUT 2, PEER_ENDED 3.

### 1.2 Windows

| Layer | What | Evidence |
|---|---|---|
| Native | `LibNanoAPI.dll` (ARM64, 8.3 MB), same source tree, BCrypt instead of OpenSSL (`BCryptCipher`, `BCryptHasher`), libopus 1.5.2 | **[native-strings]** Nw: 158 distinct `shared\nano\...` source paths, `src\LibNanoAPI\{Channel,Client,Connect,Diagnostics,Helpers,Interop}\*.cpp` |
| Projection | `LibNanoAPI.Projection.dll`, namespaces `LibNanoAPI.Connect`, `.Client`, `.Channel`, `.Diagnostics`, `.Helpers`, `.Interop`, and `.DCT` (a raw channel-stack API: `ChannelFactory`, `ChannelStack`, `Descriptor`, `IDataReceiveDelegate`; no Android counterpart was seen) | **[code-windows]** W: LibNanoAPI.Projection |
| Path A managed | `YourPhone.ScreenMirroring.Managed` :: `AppProxyConnection.ConnectionSvc.*` (ConnectionService, Connect.ConnectAdapter, Connect.*ConnectionStrategy, Connection.ConnectionInstance, Connection.ClientAdapter, ConnectionTypes.*, CloudRelay.CloudRelayAdapter, Workflow.*), `ScreenMirroring.Managed.AppProxy.FetchConnectionHandler`, `AppProxyConnection.FileTransfer.*` | **[code-windows]** |
| Path B managed | `YourPhone.YPP.PlatformSdk` :: `Transport.Nano.*` (Connect.ClientConnectAdapter, Blob.BlobChannelAdapter, Channel.BaseChannelAdapter, ...), `YourPhone.YPP` :: `ConnectionManagement.NanoPlatformConnection`, `Nano.Transport.NanoFragmentTransport` | **[code-windows]** names only |

The managed surface mirrors the JNI one method for method (`IConnect.Initialize(IDictionary,
IConnectDelegate)`, `Open(string)`, `IClient.CreateChannel(ChannelType, IDictionary)`,
`IMessageChannel.Send(string scope, byte[])`, `IBlobChannel.Send(string, IBlobStream)`,
`IBlobChannelDelegate.RequestStream(string, ulong)`, `IBlobStream.GetData(ulong)`/`WriteData`)
**[code-windows]** W: LibNanoAPI.Projection :: Connect.IConnect, Client.IClient,
Channel.IMessageChannel, Channel.IBlobChannel.

Correction candidate for `PLAN.md` 2.2: `NanoFragmentTransport` sends and receives
`DCGFragmentMessage`/`DCGAckMessage` over a Nano "internal messaging channel", that is relay
fragments carried **over Nano**, not Nano carried over the relay **[code-windows]** (class
members and log names only, not traced further).

---

## 2. The handshake over the relay (path A)

### 2.1 Capture status

No `/nanohandshake` message exists in any of the four captures
(`vm-baseline`, `vm-pairing`, `vm-raw`, `vm-relay`, all 2026-10-09) **[wire]** (probe, route
filter, shape mode: no matching messages). Everything below is code and native strings.

### 2.2 Envelope

The relay request and reply value sets are in `file-transfer.md` 2.3 (`contentType`,
`workflow`, `handshake`, `sequenceNumber`, `correlationVector`, `isuserinitiated`; reply
`handshake` or `rejectReason`). There is **no follow-up route**: one request, one reply, then
UDP **[code-windows]** W: ...AppProxy.FetchConnectionHandler; **[code-android]** A:
agents.NanoHandshakeRequestHandler.

### 2.3 The `handshake` string

It is one JSON object: the native library's "connection string" with managed keys added
on top. The whole object is handed back to the peer's native `Open()` unchanged
**[code-windows]** W: ConnectionSvc.Connection.ConnectionInstance.AttemptConnectionAsync,
Connect.ConnectAdapter; **[code-android]** A: smsrc.connectionsvc.connect.ServerConnectAdapter,
ConnectionInstance, ConnectionService.

Managed keys:

| Key | Type | Set by | Meaning |
|---|---|---|---|
| `contractVersion` | object `versionMin` int, `versionMax` int | both | Both sides send 6 and 6; each takes min(peer max, 6). **[code-android]** A: smsrc.connectionsvc.ContractVersionService; **[code-windows]** W: ConnectionSvc.ConnectionContract |
| `settings` | object | PC | Phone reads `connectionType` (int, the phone's `TransportType`: 0 Ip, 1 Ice, 2 IceStun, 3 IceStunAndTurn; absent means Ip) and `audio` (bool). Windows also defines `remoteTaskTransfer`. **[code-android]** A: smsrc.remoteconfiguration.ExperimentFeature, ExperimentFeatureManager |
| `instanceId` | string | PC | Identifies the PC-side connection service. Used with `sequenceNumber` to drop stale requests (reject `laterRequestProcessing` when the number is not greater than the last one for that id) and to detect a new device. **[code-android]** A: smsrc.connectionsvc.ConnectionService |
| `multipleConnections` | bool | PC | True lets several connections coexist and skips the stale-request check |
| `diagnosticsServers` | JSON | PC, optional | Input to the phone's NAT detection |
| `tbst` | object | both, optional on PC | "Troubleshooter" payload; Windows names a `wifiIp` key inside it. Contents not examined |

Native keys, recovered from the four contract classes
(N: `ClientLib::Transport::{Udp,Ice}Srtp{Client,Server}ConnectionContract`, constructor from
string and `ToString()`) **[native-strings]**. Keys are Boost.PropertyTree paths, so a dotted
key is a nested JSON object **[inferred]** from `AnyPTreeFromJson`/`AnyPTreeToJson` being the
only (de)serialisers called there:

| Contract | Sent by | Keys |
|---|---|---|
| UdpSrtp client | PC, type Ip | Parser reads `random`. `ToString()` references no literal key at all, so the PC's native part is empty or nearly empty **[inferred]** |
| UdpSrtp server | phone, type Ip | `ip`, `port`, `security.key`, `security.salt`, `keepalive.warningtimeout` |
| IceSrtp client | PC, ICE types | `ice.candidates`, `security.key`, `security.salt`, `ice.stun.url`, `ice.turn.url`, `ice.turn.username`, `ice.turn.password` |
| IceSrtp server | phone, ICE types | `ice.candidates`, `keepalive.warningtimeout` |

`security.key` and `security.salt` are hex strings (the parser's errors are "Invalid hex string"
and "Hex string must contain even number of characters!") **[native-strings]**. They are
created by `Microsoft::Basix::Rtp::SrtpMasterKeys(16, 14, true)`, a 16-byte master key and
14-byte master salt, at exactly two call sites: `UdpSrtpServerTransport::Open` and
`IceSrtpClientTransport::Initialize` **[native-strings]**. So:

- **IP mode: the phone generates the SRTP key and returns it; the PC contributes nothing
  secret.**
- ICE mode: the PC generates the key and sends it with its candidates.

No certificate, fingerprint, DTLS parameter, ICE ufrag/password or cipher name appears as a
contract key. ICE credentials exist as stack properties
(`Microsoft::Basix::Dct.ICE.SessionDescription.Username`/`.Password`/`.Candidates`/`.Full`)
and presumably travel inside the `ice.candidates` value **[inferred]**; its format is unknown.

### 2.4 Who contributes what

| Item | Source |
|---|---|
| Phone IP and UDP port (IP mode) | Phone's native library picks an address (N: `ClientLib::Transport::SelectIpAddress`, `GetIpAddress`) and binds a UDP socket (`Microsoft::Basix::Dct.Udp.BoundAddr`) **[native-strings]** |
| SRTP key and salt | Section 2.3 |
| STUN URL | PC only. From relay `/CloudRelay/Relay` when a feature flag is set, else from remote configuration; passed to native as property `ice.stun.url` **[code-windows]** W: ConnectionTypes.ConnectionTypeRetriever, CloudRelay.CloudRelayAdapter (5 s timeout) |
| TURN URL, user name, password | PC only, from `/CloudRelay/Relay` (`TurnCredential`), properties `ice.turn.url`, `ice.turn.username`, `ice.turn.password`; they are then copied into the IceSrtp client contract for the phone **[code-windows]** + **[native-strings]** |
| Native properties, PC | `open.timeout` 7000 ms (Ip) or 10000 ms (ICE), `exp.iceFilterTransportClose` 1 **[code-windows]** W: Connect.ConnectAdapter |
| Native properties, phone | `keepalive.timeout` 30000, `keepalive.warningtimeout` 5000, `keepalive.mtutimeoutmultiplier` 1500 (2 on the internal ring), `relatedId`, `exp.iceFilterTransportClose` 1 **[code-android]** A: smsrc...ServerConnectAdapter |

### 2.5 Sequence and timeouts

1. PC: `CreateClientConnect(type)`, `Initialize(properties)`; native calls back
   `OnSetupComplete(localInfo)`.
2. PC adds the managed keys and sends `/nanohandshake`.
3. Phone: `CreateServerConnect(type from settings.connectionType)`, `Initialize`,
   `Open(peer JSON)`; native calls `OnSetupComplete(serverInfo)`; phone adds `contractVersion`
   and `tbst` and replies. Phone gives itself 30 s for this step
   (A: agents.NanoHandshakeProvider) and waits up to 5 s for its agent service
   (A: agents.NanoHandshakeRequestHandler).
4. PC: `Open(reply JSON)`; on success native calls `OnOpened(IClient)` on both sides.
5. Phone creates a Message channel with property `workflow=launcher` (section 5.1).

PC-side limits: 90 s for the whole connect, and the file-transfer waits already listed in
`file-transfer.md` 2.2 **[code-windows]**. Native constant
`UDPRateControlInitializer::c_handshakeTimeoutInMs` = 800 **[native-strings]** (what it bounds
is not established).

Reject and failure shapes: `file-transfer.md` 2.3, plus `laterRequestProcessing` (stale
`sequenceNumber`; the reply shape it produces was not traced) **[code-android]**.

---

## 3. Transports and connectivity

| Transport | Native class | Selected when | Needs |
|---|---|---|---|
| Direct IP ("IpSrtp") | N: `UdpSrtpClientTransport`, `UdpSrtpServerTransport` | PC sends `settings.connectionType` 0 or omits it | Phone and PC mutually routable; PC sends UDP to the phone's `ip`:`port` |
| ICE host / STUN / TURN ("IceSrtp") | N: `IceSrtpClientTransport`, `IceSrtpServerTransport`, `Dct::ICE::Agent`, `STUNMessage`, `MSTURN`, `RFC8656` | `connectionType` 1 to 3 | Full ICE agent on both sides |
| Wi-Fi Direct ("IpSrtpWifiP2p") | N: `UdpSrtpClientTransportWifiP2p`, `SelectP2pIpAddress` | Path B only as far as seen (`cs_wifi_p2p_info`) | Wi-Fi Direct group; macOS has no public API for it |
| Bluetooth | none | | N: `TransportFactory::CreateTransport` builds only the three above **[native-strings]** |

How Windows chooses (path A) **[code-windows]** W: ConnectionSvc.Connect.*ConnectionStrategy,
ConnectionTypes.ConnectionTypeRetriever:

- `DefaultConnectionStrategy`: Ip unless the ICE feature is on, in which case IceStun (or plain
  Ice when no STUN URL is available). One `/nanohandshake`.
- `FastestConnectionStrategy` and `FastestWithTurnConnectionStrategy`: start an Ip attempt and
  one or more ICE attempts in parallel (each its own `/nanohandshake` with
  `multipleConnections` true) and keep the first that connects.
- `IceTelemetryConnectionStrategy`: not examined.

Path B equivalents (`NanoTransportPreference` bit set IP 1, ICE_LOCAL 2, ICE_STUN 4, ICE_TURN 8,
IP_WIFI_P2P 16; `NanoTransportType` IP 0 to IP_WIFI_P2P 4) are in `file-transfer.md` 2.2.
`NanoServerConnectStatus` values were not extracted.

**Same Wi-Fi and nothing else: Direct IP works by design**, and it is what the phone defaults
to. A client that always sends `connectionType` 0 never needs ICE. It fails when client
isolation is on, when the two are on different subnets without routing, or when the Mac is on a
VPN that captures LAN traffic. macOS will show the Local Network permission prompt on the first
UDP send.

Minimal same-LAN case needs, in order: the relay request; a UDP socket (the Mac is the
initiator, so no listener and no firewall rule); the SRTP layer with the returned key; the
link handshake and keep-alive; the channel multiplexer; the Message channel; the Blob channel.

---

## 4. The wire protocol

### 4.1 Is it Xbox "Nano"?

Evidence for the same family:

- Namespaces `Microsoft::Nano::Streaming::{VideoChannel,AudioChannel,MessageChannel,BlobChannel}`,
  `Microsoft::Nano::Input::InputChannel`, source tree `shared/nano/src/libnano`
  **[native-strings]** (both libraries).
- Channel class names sent at channel creation:
  `Microsoft::Basix::Dct::Channel::Class::{Video,Audio,Input,Blob,Messaging}`
  (N: `ClientLib::Client::ChannelClassNameContract::DetermineChannelClassName`; same five
  strings in the DLL) **[native-strings]**. Public notes on Xbox Nano list
  `Microsoft::Rdp::Dct::Channel::Class::Video`, `...::Audio`, `...::Input`, `...::Control` and
  others **[recollection]**: the same scheme with `Rdp` renamed to `Basix`.
- RTP framing: N: `Microsoft::Basix::Rtp::Header`, `ExtensionHeader`, `RtcpHeader`,
  `PayloadType`; a packet log format with `payloadType`, `sequenceNo`, `timeStamp`,
  `cleanpoint`, `connectionId`, `channelId` **[native-strings]**. Xbox Nano used a 12-byte RTP
  header whose SSRC field is split into a connection id and a channel id **[recollection]**.
- Channel control by multiplexer messages: literals `ChannelCreateRequest`,
  `ChannelOpenRequest`, `ChannelCloseRequest`; N: `MuxDCTBase::HandleChannelCreateRequest`,
  `MuxDCTChannel::SendChannelOpen`, `SendChannelControlPacket` **[native-strings]**. Xbox Nano
  had channel-control create/open/close on a dedicated payload type **[recollection]**.
- Per-channel version handshakes: N: `VideoChannel::CurrentProtocolVersion` 6,
  `AudioChannel` 7, `InputChannel` 8 (with `FramePacketV3`, `FramePacketV4`,
  `ClientHandshakePacket`, `ServerHandshakePacket`), `MessageChannel` 1, `BlobChannel` min 2
  max 3 **[native-strings]** (values read from the exported constants).

Evidence that it is a different generation:

- No TCP control channel. The transports built by `TransportFactory` are UDP only; the library
  knows other stacks by name (`Tcp`, `TlsOverTcp`, `WebSocket`, `UdpTcpBridge`,
  `EnhancedRtp`, `EnhancedSrtp`) but the Phone Link client library does not construct them
  **[native-strings]**. Xbox Nano used a TCP control socket plus a UDP data socket
  **[recollection]**.
- Different payload-type vocabulary: `MuxDCTControl`, `MuxDCTChannelRangeDefault`..`RangeEnd`,
  `URCPControl`, `URCPDummyPacket`, `UDPKeepALive`, `FECControl`, `UDPConnectionProbing`,
  `SecurityLayerCtrl`, `BaseLinkControl` (N: `Dct::operator<<(PayloadTypes)`)
  **[native-strings]**. Numeric values not extracted. Xbox notes had Streamer, Control,
  ChannelControl and UDPHandshake **[recollection]**.
- A reliability and congestion layer from the RDP UDP lineage sits under the multiplexer:
  N: `Dct::Rcp::{UDPRateControlInitializer(Client|Server), UDPRateControlHeader::AckVector,
  CUdpURCP, CUdpURCPV2, UdpReliabilityController, UDPFlowCtlInbound/Outbound, UDPPathCapProber}`
  with `SendSynPacket`, `OnSynReceived`, `SendAckPacket`, `CompleteHandshake`; constants initial
  sequence number 100 on both sides, max retransmissions 50, RTO 10 to 2000 ms
  **[native-strings]**. Microsoft's open specification for RDP over UDP may describe part of
  this header **[recollection]**; worth an hour before any disassembly.
- Forward error correction per channel: N: `MuxDCTChannelFECLayer`,
  `...VariableBlockLength`, block size constant 5, property `Dct.FEC.Type` **[native-strings]**.
- Message and Blob channels do not appear in the Xbox notes **[recollection]**.

Verdict: same lineage, high confidence. Byte compatibility with the publicly documented Xbox
framing: unknown, and should be assumed absent until a capture says otherwise.

### 4.2 Layer stack for Direct IP

From `UdpSrtpClientTransport::OpenInternal`, which sets stack properties and builds a
"well-known stack" (enum value 11) through `DCTFactory` **[native-strings]**:

| # | Layer | Native class | Known | Unknown |
|---|---|---|---|---|
| 1 | UDP socket | `AsioUdpDCT` | PC sends to `Dct.Udp.SendAddr` = phone `ip`:`port` | Whether the phone accepts any source address |
| 2 | Connection probing (maybe) | `UDPConnectionProber` (`SendSynPackets`, `SendAckPacket`) | exists, has its own payload type | Whether the IP stack includes it |
| 3 | SRTP | `SrtpFilter`, `Rtp::SrtpContext` | `Dct.SRTP.KeystreamMode` set to 3 and `AuthenticationMode` to 0 by the client. Enum from the printer: 0 Null, 1 CounterMode, 2 F8, 3 Galois counter mode; authentication names `None`, `HMACSha1`. So **AES-GCM with a 16-byte master key and 14-byte salt, no separate auth tag** (string: "RFC7714 recommends not using authentication tags when using AES/GCM cipher in SRTP"; Windows: "BCrypt only supports 12 byte nonce values"). Session keys are derived (`DeriveSessionKeys`, `DeriveSessionKeysRTCP`); separate incoming and outgoing keys are supported | KDF details, nonce layout, tag length, which header fields are authenticated, rollover handling. One class of about ten methods to read |
| 4 | Keep-alive and MTU probing | `UDPKeepALiveFilter` | timeouts in 2.4; phone tells the PC `keepalive.warningtimeout` | packet layout, cadence |
| 5 | Rate control and reliability | `Rcp::*` (4.1) | Syn/Ack handshake, ack vectors, retransmission | header layout, which of URCP v1/v2 is selected, how much of the congestion logic a peer must honour |
| 6 | Multiplexer | `ClientMuxDCT`/`ServerMuxDCT`, `MuxDCTChannel`, `MuxDCTSequencer`, optional FEC layer | create/open/close requests carrying a class name, channel id and a property string; send modes `BestEffort`, `GuaranteedDelivery`, `GuaranteedDeliveryFence`; per-channel `Dct.Priority` | control packet layout, id allocation, whether FEC is on for Message/Blob |
| 7 | Channel protocols | `Nano::Streaming::MessageChannel`, `BlobChannel` | section 5 | field layouts |

All rows **[native-strings]**; the layer order is **[inferred]** from property names and class
relationships, not from a trace.

### 4.3 Crypto summary

- Direct IP: no DTLS, no TLS, no certificates. Confidentiality and peer authentication rest on
  the SRTP master key, and that key's secrecy rests on the relay's own end-to-end encryption of
  the `/nanohandshake` reply **[native-strings]** + **[inferred]**.
- The library contains TLS/DTLS-related properties (`Dct.Tls.UseSRTP`,
  `Dct.Tls.CertificateValidator`) and OpenSSL's DTLS-SRTP code, but nothing on the
  UdpSrtp or IceSrtp client path references them **[native-strings]**; treated as unused here
  **[inferred]**.

---

## 5. The channels file transfer needs

### 5.1 Channel creation and the workflow launcher

- The **phone** creates channels: `IClient.CreateChannel(type, properties)` returns a channel
  id; the PC learns of each through `IClientDelegate.OnChannelCreated(IChannel)` and then calls
  `Open(delegate)` on it **[code-android]** A: smsrc.connectionsvc.connect.ClientAdapter;
  **[code-windows]** W: ConnectionSvc.Connection.ClientAdapter.
- Every channel carries a `workflow` property; the PC routes new channels by it.
- First channel after connect: Message channel with `workflow=launcher`. The phone registers
  scopes `/workflow` and `/stopWorkflow` on it. The PC sends on `/workflow` a UTF-8 JSON object
  `workflow` (name, here `fileTransfer`) and `workflowId`; the phone starts that workflow and may
  later send the same object on `/stopWorkflow` **[code-android]** A:
  smsrc.connectionsvc.workflow.WorkflowLauncherInstance. **This answers open question 6 of
  `file-transfer.md`.**
- The `fileTransfer` workflow then creates one Message and one Blob channel
  (`workflow=fileTransfer`) **[code-android]** A:
  agents.filetransfer.transport.nano.FileTransferWorkflow.

### 5.2 Message channel

Managed/Java view **[code-android]** + **[code-windows]**: `Initialize()`,
`RegisterHandler(scope, handler)`, `Open(delegate)`, `Send(scope, bytes)` returning a bool,
handler receives `(scope, bytes)`. No acknowledgement, ordering or size limit is visible at this
level. File transfer uses the single scope `/fileTransfer` with UTF-8 JSON.

Native view **[native-strings]** N: `Nano::Streaming::MessageChannel::*`:

- Packet kinds: `HandshakePacket`, `Message::DataPacket`, `CancelRequestPacket`, under a common
  `MessagePacket` with a `Type`.
- Protocol version 1; target path (scope) limited to 512 (`TargetPathMaxLength`).
- Messages are fragmented and reassembled (`Message::Packetize`, `Merge`,
  `SafeInsertData(buffer, offset, data)`, `GetPartialMessage(id)`), each with a 32-bit id and
  `Flags`.
- The protocol has request/response transactions (`StartTransaction`, `CompleteTransaction(id,
  status, body)`, `MessageCompletion`, remote cancellation) that the Phone Link wrapper does not
  expose; `DispatchMessage(bool, id, path, body)` suggests a one-bit distinction between
  plain messages and transactions **[inferred]**.
- Handlers are matched by scoped path (`ScopedPathStore`), so a handler may cover a prefix
  **[inferred]**.

Unknown: every field layout, the handshake content, the delivery mode used.

### 5.3 Blob channel

Managed/Java view **[code-android]** + **[code-windows]**:

- Sender: `Send(name, stream)`; native pulls `GetSize()` once and `GetData(buffer)` repeatedly,
  then `Close(reason)`.
- Receiver: native calls `RequestStream(name, size)`; the returned stream gets `WriteData(bytes)`
  per chunk and `Close(reason)` at the end (an empty or null reason is success; this is where
  `file-transfer.md` renames the temporary file).
- `Cancel(name)` aborts one blob. Several blobs can be in flight by name.

Native view **[native-strings]** N: `Nano::Streaming::BlobChannel::*`:

- Packet kinds: `HandshakePacket`, `StartPacket` (name, 64-bit size), `Blob::DataPacket`
  (flags, name, two 64-bit numbers that fit offset and total, data), `BlobWrittenPacket`
  (name, 32-bit number), `CompletionPacket` (name, `CompletionType`).
- Versions 2 to 3 are accepted.
- **Flow control is application-level**: the receiver reports its write-queue length
  (`SendBlobWrittenPacket`, `SetPeerWriteQueueLength`), the sender throttles on it and on
  measured bandwidth (properties `Microsoft::Nano::Blob.QueueManagment.{QueueLimit,
  QueueMaxLength, PeerWriteQueueLengthLimit, BandwidthUtilizationRatio, RefreshRate}`,
  `Microsoft::Nano::Blob.MaxBlobSize`).
- Out-of-order data is tolerated (`GetPartialBlob`, `MarkPartialBlobCompleted`,
  `Blob::Merge`).
- Completion reasons probably include the literals `peerCanceled`, `peerCloseError`,
  `peerError`, `noStream`, `unexpectedClose`, `corrupted` (present in both libraries;
  attribution to this packet is **[inferred]**).

Unknown: field layouts, chunk size, default limits, the handshake, delivery mode.

---

## 6. Options for macOS

Code volume, measured as spacing between exported symbols in the arm64 library (an upper
bound, it includes unexported neighbours) **[native-strings]**:

| Component | Size | Needed for (b) |
|---|---|---|
| ICE, STUN, TURN, link switching | about 1,090 KB | no |
| Rate control and reliability (`Rcp`) | about 580 KB | wire format and minimal behaviour only |
| Client library glue (`ClientLib`) | about 430 KB | contracts and stack setup only |
| Video, audio, input channels | about 410 KB | no |
| Multiplexer, sequencer, FEC | about 210 KB | yes |
| Blob channel | about 96 KB | yes |
| UDP and stack base | about 78 KB | little |
| RTP and SRTP | about 62 KB | yes |
| Message channel | about 54 KB | yes |
| Keep-alive, connection prober | about 45 KB | yes |

### (a) Full reimplementation in Swift

Everything in the table: ICE with STUN and TURN, all channel types, FEC, congestion control.

- Reverse engineering: all of the above, about 3 MB of native code to read in part, including
  the ICE agent with Microsoft-specific TURN extensions and multi-link switching.
- Captures: LAN, cross-network (STUN) and relayed (TURN) sessions; mirroring sessions.
- Risks: ICE interoperability is the classic long tail; video needs codec and pacing work
  on top; vendor gating of screen features on the phone.
- Size: 40 to 60 working days before the first mirrored frame; consistent with the 6 to 10
  weeks in `PLAN.md`.
- First steps: identical to (b); (a) is (b) plus more. Do not start here.

### (b) Minimal same-LAN path with Message and Blob channels (recommended)

Direct IP only, `connectionType` 0, layers 1 to 7 of section 4.2, launcher workflow, the
`fileTransfer` workflow.

- Reverse engineering: packet layouts of SRTP, keep-alive, rate-control header and handshake,
  multiplexer control, Message and Blob packets. Roughly 30 to 40 `Encode`/`Decode`/
  `InternalEncode`/`InternalDecode` method pairs, all exported by name on Android. A
  decompiler (Ghidra) over the arm64 library is the practical tool; `objdump` suffices for
  constants. Estimated 8 to 12 days of reading, less if the capture is clean and the RDP-UDP
  open specification matches.
- Captures: one phone-to-PC and one PC-to-phone transfer from the Windows VM, relay and UDP
  recorded together. The VM runs in VMware Fusion on this Mac, so its packets always cross a
  host interface: with shared (NAT) networking capture on the VMware NAT interface
  (`bridge100` or the `vmenet`/`vmnet8` device), with bridged networking on the physical
  interface (`en0`). In both modes the PC is the UDP initiator, so NAT does not block Direct
  IP **[inferred]**. Filter `udp and host <phone address>`. The relay side uses the existing
  proxy pipeline; it yields the reply with `ip`, `port`, key and salt, which is what makes
  the UDP capture decryptable. Keys and addresses stay in the capture directory, never in
  documents.
- Risks, largest first:
  1. The reliability layer may require faithful congestion behaviour (the phone may stall or
     drop a peer that acknowledges incorrectly). Mitigation: file transfer tolerates a
     conservative sender; implement acks and retransmission exactly, pacing simply.
  2. FEC might be mandatory on guaranteed channels. Unknown until captured.
  3. SRTP details that differ from the RFCs (14-byte salt with GCM is already non-standard).
  4. The phone answers "device not supported" unless one of four capabilities holds: its own
     remoting capabilities `APPS_ON_WINDOWS_SUPPORTED` or `UNIFIED_STACK_SUPPORTED`, its files
     capability `FILES_THROUGH_APPS_STACK`, or `FILE_TRANSFER_SUPPORTED` in the file-transfer
     capabilities it holds **for the sender** (A: agents.NanoHandshakeRequestHandler.isRequestSupported)
     **[code-android]**. On a phone without the vendor remoting stack the last one decides, and
     what makes the phone record it for our client was not traced.
  5. Protocol drift with app updates; mitigated by per-channel version handshakes.
- Size: 19 to 28 working days. Contract, relay request and launcher 1 to 2; RTP and SRTP 2 to
  3; rate-control handshake, acks, retransmission 5 to 8; keep-alive and MTU 1 to 2;
  multiplexer 3 to 4; Message 1 to 2; Blob with flow control 3 to 4; file-transfer integration
  and tests 3.
- First three steps:
  1. Run the capture of section 7 and confirm the handshake shape and that the UDP flow
     matches `ip`/`port`.
  2. Write an offline decoder (Swift test target or script) that takes the pcap plus the key
     and salt and prints layer by layer; drive the disassembly from what the decoder cannot yet
     explain. Go/no-go gate: SRTP decrypts and the rate-control and multiplexer headers parse.
  3. Build the live client bottom-up against the phone, stopping at each layer's first
     observable success (phone answers the Syn; keep-alive holds 60 s; launcher channel
     appears; `/workflow` starts `fileTransfer`; one blob arrives).

### (c) Alternatives considered

- **Decoder-first as a deliverable in itself** (steps 1 and 2 of (b), 3 to 5 days). Produces a
  byte-level spec and a firm estimate before committing to the client. This is the recommended
  way to enter (b), not a separate destination.
- **Wrap Microsoft's native library.** The Android library is an arm64 ELF against bionic and
  the Windows one a PE; neither loads on macOS without an emulation shim, redistribution is not
  ours to grant, and the project rule is to inspect third-party binaries, not run or ship them.
  Rejected.
- **Target path B (platform connection, NamedStreams) first.** Same transport underneath plus
  context-source signalling, identity challenge and manifests. Strictly more work. Rejected as
  a first step; note that phone-file content needs it later.
- **Defer Nano; ship offers and browsing only** (`file-transfer.md` 7.3). Zero cost, no file
  bytes. The fallback if the gate in (b) fails.

---

## 7. What can be learned cheaply first

Largest uncertainty: the byte-level framing between the first UDP packet and the first
channel message (layers 2 to 6). Everything above and below it is already named.

**Experiment 1 (about half a day, uses only the existing VM setup).** With the relay proxy
recording, start `tcpdump` on the Mac for UDP between the VM and the phone, then send one small
file from the phone to the PC through Phone Link. Outcome checks, none needing new code:

1. A `/nanohandshake` request and reply appear in the relay capture; their shape confirms or
   corrects section 2.3 (read with the probe in shape mode).
2. The UDP flow goes from the VM to the address and port in the reply, and starts within
   `open.timeout`.
3. First bytes of each datagram look like RTP version 2 with a small set of payload types.
4. Packet count and sizes for a file of known length bound the chunk size and the overhead.

If check 2 or 3 fails, the model in section 4.2 is wrong and the estimate in 6(b) does not
hold; if they pass, the remaining work is decoding with the key in hand.

**Experiment 0 (an hour, optional, no Windows involved).** From the macOS client, which already
speaks the relay, send `/nanohandshake` with `workflow` `fileTransfer` and a minimal `handshake`
object (`contractVersion` 6/6, `settings.connectionType` 0, a fresh `instanceId`,
`multipleConnections` false). The reply shows whether the phone accepts our client for this
request at all (risk 4 of option (b)) and returns the UdpSrtp server contract. The phone then waits for a
client that never arrives and times out; no state is left behind **[inferred]**.

**Free, before either:** the existing captures contain PLATFORM `/Context/Message` records
(path B signalling) **[wire]** (`vm-raw`, shape mode; `file-transfer.md` 2.2 counts them). If
any is a `cs_connection_info`, its connection string has the same native contract and would
show the key set without a new capture. Not decoded for this study.

---

## 8. Known and unknown, in one place

Known from code and symbols:

- Library identity, JNI and WinRT surface, enums (section 1).
- Handshake envelope, managed keys, native contract key names, who generates the SRTP key,
  key and salt sizes, timeouts (section 2).
- Transport selection and that Direct IP is the default and sufficient on one LAN (section 3).
- Layer inventory, SRTP mode, per-channel protocol versions, launcher workflow, packet kinds of
  Message and Blob channels, Blob flow-control mechanism (sections 4 and 5).

Unknown until a capture or disassembly:

- Exact JSON of both connection strings (nesting, value encodings, the role of `random`).
- Whether the phone accepts `/nanohandshake` from our client type.
- Every packet layout below the JNI line; payload-type numbers; SRTP KDF and nonce.
- Whether connection probing and FEC are active on this stack.
- How strictly the phone enforces rate-control behaviour.
- ICE candidate encoding (only matters for option (a)).
- `NanoServerConnectStatus` values, the `tbst` payload, `IceTelemetryConnectionStrategy`.

---

## 9. Addendum, 2026-10-09: what the existing relay capture already shows **[wire]**

Read after the study above was written, with `winphone-probe app-messages
captures/vm-raw-2026-10-09/flows.jsonl --shape`, which now names the kind of each
`ContextSourceMessage` and, for a connection description, the names of its keys (never a value:
the description carries key material). Records: `vm-raw`, first exchange 33 to 70; the same
pattern repeats 34 times over about seven hours, at each start of the cross-device (`WEA`)
session. No other capture has these messages.

The exchange on PLATFORM `/Context/Message` (first message) and `/Context/Message/<id>` (the rest):

| # | From | Message | Keys of `connectioninformation` |
|---|---|---|---|
| 1 | PC | `cs_initialize_message`, source id of 36 characters, `transport_preference` 0 | |
| 2 | phone | `cs_initialize_ack_message`, status success | |
| 3 | PC | `cs_connection_info`, 128 characters | none (empty object) |
| 4 | PC | `cs_connection_info`, about 1,580 characters | `ice{candidates, stun{url}, turn{url, username, password}}`, `security{key, salt}` |
| 5 | phone | `cs_connection_info`, 383 characters | `ip{count, 0{addr, iname}, 1{addr, iname}}`, `port`, `security{key, salt}`, `keepalive{warningtimeout}` |
| 6 | PC | `cs_connection_info` again, twice, growing to about 2,800 characters | as in 4, with more candidates |
| 7 | phone | `cs_connection_info`, about 1,600 characters | `ice{candidates}`, `keepalive{warningtimeout}` |

Every description has the top-level keys `connectionid`, `connectiontype`, `multipleconnections`
and `connectioninformation`.

What this settles, and what it does not:

- **The Direct IP contract of section 2.3 and 4.2 is on the wire**, with exactly the predicted
  parts: the phone's addresses by interface, a port, an SRTP key and salt, and a keep-alive
  warning timeout (message 5). It is no longer code-only.
- **Windows offers ICE as well, in the same exchange**, with STUN and TURN servers and its own
  key and salt (messages 4 and 6), and the phone answers with ICE candidates too (message 7).
  Which of the two the native library then uses was not observable here.
- **A Nano connection is attempted at every session start, without any file transfer.** The
  recording of experiment 1 therefore does not need a file to be sent: restarting Phone Link on
  the VM while `tcpdump` runs should already yield the UDP flow, and its key is in message 4 or 5
  of the relay capture taken at the same time.
- This is path B signalling (`WEA`, `ContextSourceMessage`). Path A's `/nanohandshake` remains
  uncaptured; section 2.3 expects the same native contract inside it **[inferred]**.
- Our own client receives none of this today: the Mac's `WEA` session never sends
  `cs_initialize_message`.

