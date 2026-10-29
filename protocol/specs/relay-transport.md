# Relay transport specification (Hub Relay, DCG fragments, PLATFORM and APP envelopes)

Status: derived from primary sources on 2026-10-09. Facts only; no decompiled code is reproduced.
Audience: the developer writing the Swift client that plays the PC role toward Link to Windows.

## 0. Sources, notation, caveats

| Tag | Meaning |
|---|---|
| `W:YPP` | Windows assembly `YourPhone.YPP` (Phone Link 1.26072.257.0), namespace prefix `YourPhone.YPP.` omitted |
| `W:Common` | `YourPhone.YPP.Common` |
| `W:SDK` | `YourPhone.YPP.PlatformSdk` |
| `W:ConnYPP` | `YourPhone.Connectivity.YPP.Managed` |
| `W:ConnMgd` | `YourPhone.Connectivity.Managed` |
| `W:Util` | `YourPhone.Utilities` |
| `A:` | Android Link to Windows 1.26082.130.0, class under `com.microsoft.mmx.agents.ypp.` unless a full name is given |
| `cap:relay#N` | `captures/vm-relay-2026-10-09/flows.jsonl`, record `seq` N |
| `cap:raw#N` | `captures/vm-raw-2026-10-09/flows.jsonl` (keeps raw WebSocket bytes, so exact MessagePack type codes are known) |
| `cap:pair#N` | `captures/vm-pairing-2026-10-09/flows.jsonl` |

Each section is split into **Observed in code**, **Observed on the wire** and **Inferred / uncertain**.

Caveats that apply to the whole document:

1. Every capture was produced by the Windows package `MicrosoftWindows.CrossDevice_cw5n1h2txyewy` version
   `1.26082.74.0` (request header `dcg-appid`, cap:relay#1), not by the decompiled Phone Link package.
   Both ship the same YPP platform code as far as the wire shows, but configuration values differ
   (for example heartbeat 30 s on the wire versus the 15 s code default).
2. Many numeric settings are remote-configurable. "Default" below means the value compiled into the code.
3. Server-to-client frames are re-encoded by the hub service (section 5.4). They show what a receiver gets,
   not the bytes the phone produced.
4. Captured identifiers, tokens and payload contents are deliberately not reproduced here.

## 1. Layering and identifiers

```
feature payload (protobuf, PBValueSet, JSON)
  -> binary envelope v1 (headers + payload)            sections 8, 9
  -> DCG fragment(s) + DCG ack                          sections 5, 6
  -> HubRelayMultiplexPacket (MessagePack map)          section 5
  -> SignalR hub invocation, MessagePack hub protocol   sections 3, 4
  -> WebSocket binary message to Azure SignalR Service  section 2
```

| Identifier | Scope and lifetime | Where it appears |
|---|---|---|
| DCG client ID (UUID string) | One per enrolled device identity | Hub invocation target/sender argument, `DCG-PartnerId` header, wake `deviceId` |
| SignalR invocation ID | Per WebSocket connection, decimal string counter from `"1"` | Invocation element 2, Completion element 2 |
| DCG `SessionId` (UUID string) | Chosen by the *sender*, one per target, constant for the sender's process lifetime | `Properties.SessionId` of fragments; echoed in acks |
| DCG `SequenceNumber` (int) | Sender-side counter per target, starts at 1, process lifetime | Fragment and ack properties |
| DCG `MessageId` (int) | Sender-side counter, global across targets, starts at 1 | Fragment properties |
| `FragmentId` / `FragmentCount` | Per message, 1-based | Fragment properties |
| Envelope `_requestId` | Per request | Envelope headers; answered with `_originalRequestId` |
| Hub `connectionSessionId` | Supplied by a session-based sender (section 11) | 4th argument of the session-based hub methods |

Sources: `W:YPP Transport.Messaging.IdManager`, `W:YPP Transport.Chunking.OutgoingSequenceNumberProvider`,
`A:transport.messaging.IdManager`, `A:transport.chunking.FragmentSender` (static `SequenceNumberMap`).

## 2. Negotiate and WebSocket connect

### 2.1 Observed in code

* Hub URL is `<services base><HubEndpoint>` with base `https://dcg.microsoft.com/` (also `dcg-df`, `dcg-beta`)
  and `HubEndpoint = "relayhub/"`. Windows: `W:Common Configuration.PlatformConfiguration`
  (`ServicesBaseProd`, `HubEndpoint`), `W:YPP SignalR.Transport.Connection.SignalRConnectionFactory.GetHubUriFromEnvironment`.
  Android: `A:configuration.PlatformConfiguration` (`baseServiceUrlProd`, `hubEndpoint`),
  `A:signalr.transport.connection.SignalRConnectionFactory`.
* Both clients use the stock Microsoft SignalR client (ASP.NET Core SignalR .NET client on Windows,
  `com.microsoft.signalr` Java client on Android) with the MessagePack hub protocol and an access token provider.
  Negotiation, redirect following and `id` handling are therefore standard SignalR behavior.
* Access token: Windows asks `IServicesAccessTokenProvider.GetAccessTokenAsync` with scope `"general"`
  (assembly `YourPhone.YPP.Auth`, `ServicesClient.ScopedServicesAccessTokenProvider`); this is the DCG service token obtained from
  the Auth API (out of scope here). It is presented as `Authorization: Bearer <token>`.
* Custom headers added to *every* HTTP request of the connection (both negotiates and the WebSocket upgrade),
  `W:Common Context.CustomHeadersBuilder.CreateCustomHeadersForConnection`:

| Header | Value derivation (Windows) |
|---|---|
| `DCG-LogicalDeviceId` | Base64 of SHA-256 of the Windows publisher system ID (`AppInformationProvider.LogicalDeviceId`); empty string if unavailable |
| `DCG-AppVersion` | Package version `major.minor.build.revision` |
| `DCG-AppId` | Package family name |
| `DCG-SessionId` | Random GUID generated once per process (`AppInformationProvider.SessionIdValue`) |
| `DCG-RingName` | Current ring name from remote configuration (`PlatformOptions.RingName`) |
| `DCG-OS` | `ClientOsName` enum name; Windows sends `Windows` (enum: `Unknown, Windows, Android, iOS`) |
| `DCG-OSVersion` | `major.minor.build` from `RtlGetVersion` |
| `DCG-PartnerId` | DCG client ID of the partner the connection was first created for; omitted for account-level ("peerless") connections |
| `DCG-HubRegion` | Only when a hub region was requested (shard selection); omitted otherwise |
| `traceparent` | `00-<TraceId 32 hex>-<CorrelationId 16 hex>-<TraceFlags as 2 hex digits>` (`TraceContext.FormattedTraceParent`) |
| `tracestate` | `k=v` pairs of the trace state joined by `,`, then `,yppHttpParent=<CorrelationId>` (`AzureFormattedTraceState`) |
| `DCG-TraceState` | Same string as `tracestate` |
| `DCG-HeartBeatFrequency` | `HeartBeatFrequency.TotalSeconds` formatted invariant; default `15` |

* Android adds `DCG-PartnerId` (only when the request is "with partner"), the telemetry header map from
  `TelemetryContextHeaderProvider`, `DCG-HeartBeatFrequency` (int seconds, feature `YPPHeartBeatFrequencyInSeconds`,
  default 15), `DCG-HubRegion` when known, and `DCG-UserId` only when the `IsRelayHubV4Enabled` feature is on
  (default off). `A:signalr.transport.connection.SignalRConnectionFactory`.
* Android SignalR client specifics (`com.microsoft.signalr.HubConnection`): negotiate version constant 1;
  on a negotiate response that carries `accessToken` it sets `Authorization: Bearer <accessToken>` for all later
  requests; follows `url` redirects up to 100 times; final URL is `<url>` plus query `id=<connectionToken>` when
  `negotiateVersion > 0`, otherwise `id=<connectionId>`.

### 2.2 Observed on the wire (cap:relay#1-3, cap:raw#1-3, cap:pair#1-3 and #235-239)

Step 1, DCG negotiate:

```
POST https://dcg.microsoft.com/relayhub/negotiate?negotiateVersion=1      (empty body, content-length: 0)
```

Request headers, in captured order: `accept: */*`, `dcg-logicaldeviceid`, `dcg-appversion`, `dcg-appid`,
`dcg-sessionid`, `dcg-ringname` (`Public`), `dcg-os` (`Windows`), `dcg-osversion` (`10.0.26200`),
`dcg-partnerid`, `traceparent`, `tracestate`, `dcg-tracestate`, `dcg-heartbeatfrequency` (`30`),
`user-agent` (`Microsoft SignalR/10.0 (<version+commit>; Windows NT; .NET; .NET 10.0.12)`),
`x-requested-with: XMLHttpRequest`, `authorization` (redacted, 848 bytes including `Bearer `),
`baggage` (`ypScenarioId = StartSession, ypTriggerId = CDEH.ProcessSessionChanges`), `content-length: 0`.

`x-requested-with`, `user-agent` and `accept` come from the SignalR .NET client library, `baggage` from .NET
activity propagation; none is set by YPP code. The `authorization` value has the same length and hash prefix as
the one sent to `Dispatcher/Wake` in the same session (cap:relay#10), i.e. it is the ordinary DCG bearer token.

Response `200 application/json`:

| Field | Value |
|---|---|
| `negotiateVersion` | `0` |
| `url` | `https://signalrp2-relayhub-prod-<shard>.service.signalr.net/client/?hub=dcgrelayhub_relayhub&asrs.op=%2Frelayhub&negotiateVersion=1&asrs_request_id=<id>` |
| `accessToken` | JWT for Azure SignalR Service (redacted, about 934 characters) |
| `availableTransports` | `[]` |

Shards seen: `eu02-3` (later reported as region `NorthEurope`) and `eu01-1` (`WestEurope`).

Step 2, Azure SignalR negotiate. The client inserts `negotiate` after the path of `url`, keeps the query string
unchanged, and repeats all custom headers, but `authorization` is now `Bearer <accessToken from step 1>`
(941 bytes = 7 + token length):

```
POST https://<shard host>/client/negotiate?hub=dcgrelayhub_relayhub&asrs.op=%2Frelayhub&negotiateVersion=1&asrs_request_id=<id>
```

Response: `negotiateVersion: 1`, `connectionId` (31 characters), `connectionToken` (redacted),
`availableTransports`: `WebSockets` (`Text`, `Binary`), `ServerSentEvents` (`Text`), `LongPolling` (`Text`, `Binary`).

Step 3, WebSocket upgrade:

```
GET wss://<shard host>/client/?hub=dcgrelayhub_relayhub&asrs.op=%2Frelayhub&negotiateVersion=1&asrs_request_id=<id>&id=<connectionToken>
```

with the same custom headers and `Authorization: Bearer <accessToken>` as a header. The access token is not put
in the query string (`access_token` never appears). Response `101`.

Timing: about 0.2 s per step; WebSocket open about 0.4 s after the first POST.

### 2.3 Inferred / uncertain

* `DCG-HeartBeatFrequency` most likely tells the hub how often to deliver `OnPartnerHeartBeat` to this client.
  Evidence: the PC sent `30` and received partner heartbeats exactly every 30.0 s (cap:raw, 22 samples) while
  both code bases default to 15. The phone's own header value was not captured, so the direction is not proven.
* `DCG-PartnerId` is assumed to let the hub pre-associate the two connections; the hub's use of it is not visible.
* Lifetime and claims of the Azure SignalR `accessToken` are unknown (value redacted).
* Whether the hub accepts a connection without `DCG-LogicalDeviceId`, `DCG-AppId` etc. is untested.

## 3. SignalR protocol details

### 3.1 Observed in code

* Hub protocol name `messagepack`. Windows replaces the stock protocol with
  `W:YPP SignalR.Protocol.AotMessagePackHubProtocol` (same wire format, static formatters). It declares
  protocol version 2 and can parse message types 1-9, but see 3.2 for the version actually sent.
  Android uses `com.microsoft.signalr.messagepack.MessagePackHubProtocol` (Jackson + msgpack).
* Framing: each hub message is prefixed with its length as a little-endian base-128 varint (1-5 bytes);
  several hub messages may be concatenated in one WebSocket message
  (`W:YPP SignalR.Protocol.AotBinaryMessageFormatter`, `AotBinaryMessageParser`).
* Message shapes written by the Windows client (`AotMessagePackHubProtocol.Write*`):

| Type | Array |
|---|---|
| 1 Invocation | `[1, headers map, invocationId or nil, target, [args...], [streamIds...]]` (6 elements) |
| 3 Completion | `[3, headers, invocationId, resultKind, (error string or result)]`; resultKind 1 error, 2 void, 3 non-void |
| 6 Ping | `[6]` |
| 7 Close | `[7, error or nil, allowReconnect bool]` |

  Types 2, 4, 5 (streaming) and 8, 9 (stateful reconnect) are implemented by the parser but no YPP code uses them.
* Invocations are blocking on both platforms: Windows calls `HubConnection.InvokeAsync` and awaits the
  Completion (`W:YPP SignalR.HubConnectionWrapper.InvokeAsync`); Android calls `hubConnection.invoke(...)` and
  `blockingAwait()` (`A:signalr.transport.HubRelayProxy.sendDataInternal`). A failed invocation surfaces as
  `HubSendException`.
* Keep-alive: `KeepAliveInterval` 15 s, `ServerTimeout` 30 s on both platforms, applied only when timeout >
  keep-alive (`W:Common PlatformOptions.HubConnectionKeepAlive/HubConnectionServiceTimeout`; Android features
  `YPPHubConnectionKeepAliveMillis` 15000, `YPPHubConnectionServiceTimeoutMillis` 30000).
  Android handshake response timeout 15 s, tick rate 1 s (`com.microsoft.signalr.HubConnection`).

### 3.2 Observed on the wire

* Handshake request, sent as a *binary* WebSocket message of 39 bytes:
  `{"protocol":"messagepack","version":1}` followed by `0x1E` (cap:raw#4). Response: `{}` + `0x1E`, 3 bytes,
  binary (cap:raw#5).
* First hub message after the handshake is a client Ping, bytes `02 91 06` (cap:raw#6).
* Server pings arrive every 15-16 s; client pings go out about 15 s after the last client send
  (cap:raw: server pings at 15.6, 31.6, 46.6 ...; client pings at 24.4, 39.4, 54.4 ...).
* Client invocation IDs are decimal strings `"1"`, `"2"`, ... per WebSocket connection (cap:relay: 66 invocations
  numbered 1-66). Server-to-client invocations carry `nil` as invocation ID.
* Every client invocation is answered by a Completion `[3, {}, "<id>", 3, nil]` (result kind 3 with a nil
  result), typically 50-70 ms later (cap:raw#9, #31). No error completion was captured.
* The Windows client puts a headers map on its invocations: `traceparent` and sometimes `baggage`
  (cap:raw#8, #13, #39). The hub does not forward them (server invocations have an empty headers map).
  They originate from the .NET SignalR client, not from YPP code.
* Coalescing: one WebSocket message carried four invocations (cap:raw#24) or two completions (cap:raw#27).
* Graceful close: the client sent `[7, nil, false]` right after a `/PlatformDisconnectRequest` (cap:pair#184-187).
  No server-initiated Close was captured.

### 3.3 Inferred / uncertain

* The .NET client sends handshake version 1 although the protocol object reports 2, because stateful reconnect
  is not enabled; this is library behavior, consistent with the capture, not visible in YPP code.
* A client that omits the invocation headers map content (sends `{}`) should be fine: Android sends none.
* Behavior on Completion with error (result kind 1) was never observed; in code it becomes a send failure that
  is retried up to twice immediately (section 6).

## 4. Hub API

### 4.1 Client-to-server methods

Sources: `W:YPP SignalR.Transport.HubConstants`, `HubRelayProxy.SendDataAsync`,
`SignalR.Transport.Connection.SignalRConnection.SendConnectedInternalAsync`; `A:signalr.transport.HubRelayProxy`,
`A:signalr.transport.connection.SignalRConnectionV2.sendConnected`.

| Method | Arguments (in order) | Used for |
|---|---|---|
| `SendMessageAsync` | `trace` (trace-context map), `targetDcgClientId` (string), `packet` (HubRelayMultiplexPacket map) | Every DCG fragment and ack between PC and phone |
| `SendSessionBasedMessageAsync` | `trace`, `targetDcgClientId`, `packet`, `connectionSessionId` (string) | Windows only, replies to session-based senders (section 11) |
| `SendConnectedAsync` | `trace`, `targetDcgClientId`, `payload` | Presence announcement to one partner. Windows sends an empty map `{}` as payload, Android sends the empty string `""` |

No other client-to-server method exists in either code base. There is no client heartbeat method.

### 4.2 Server-to-client callbacks

Sources: `W:YPP SignalR.Transport.Connection.HubPartnerChangeHandler.SetupHandlers`,
`SignalRConnection` constructor, `SignalRConnectionProxy`, `HubRelayProxy.SetupListeners`;
`A:signalr.transport.connection.HubPartnerChangeHandler`, `SignalRConnectionProxy`, `A:signalr.transport.HubRelayProxy`,
`A:signalr.transport.utils.MessagePackTypes`.

| Callback | Arguments | Notes |
|---|---|---|
| `OnConnected` | `payload` map `{RegionName: string, Partners: [string]}` | Pushed once after the connection is up, independent of `SendConnectedAsync`. `Partners` lists partner DCG IDs currently on the hub |
| `OnPartnerConnected` | `partnerId` string, `trace` map or nil, `info` | `info` is `{RegionName: string}` when the hub itself announces the partner, or the third argument the partner passed to `SendConnectedAsync` (`""` from Android, `{}` from Windows). Windows types it as `object` and only uses it when it is a string; Android types it as the `OnConnected` payload class |
| `OnPartnerDisconnected` | `partnerId` string | |
| `OnPartnerHeartBeat` | `partnerId` string, `connectionId` string, `sentTime` integer | Windows types `sentTime` as `object`, Android as `BigInteger`. Windows matches `partnerId` against known partners with a suffix comparison (`EndsWith`) and ignores heartbeats from unknown partners |
| `OnReceiveMessage` | `senderId` string, `trace` map, `packet` map | Note the order differs from `SendMessageAsync` (sender first) |
| `OnReceiveSessionBasedMessage` | `senderId`, `trace`, `packet`, `connectionSessionId` string | Android registers it only to track that the sender exists; it does not deliver the packet (section 11) |

On the wire (cap:raw#7, #11, #16, #22): `OnConnected [{RegionName:"WestEurope", Partners:[]}]`;
`OnPartnerConnected [<id>, nil, {RegionName:"WestEurope"}]` followed by two
`OnPartnerConnected [<id>, <trace>, ""]`; `OnPartnerHeartBeat [<id>, <6-character string>, <uint64 Unix ms>]`.

### 4.3 Trace-context object (`HubRelayTraceContextPacket`)

A MessagePack **map** with exactly these string keys, written in this order by Windows
(`W:YPP Transport.Protocol.HubRelayTraceContextPacket`, formatter in `W:YPP SignalR.YppMessagePackResolver`;
Android `A:signalr.HubRelayTraceContextPacket` with Jackson property names):

| Key | Type | Value |
|---|---|---|
| `TraceId` | string | 32 lowercase hex characters (16 random bytes, never all zero) |
| `ParentId` | string or nil | Set to the sender's *correlation ID*: 16 lowercase hex characters (8 random bytes). May be nil in frames originating from Android |
| `TraceFlags` | integer 0-255 | 0 or 1 seen; Windows declares `byte` |
| `TraceState` | map string to string | Telemetry tags such as `ypScenarioId`, `ypTriggerId`; may be empty but not nil |

Generation (`W:Common Context.TraceContextUtils`): IDs come from a cryptographic RNG and are regenerated if all
bytes are zero. For `SendConnectedAsync` Windows builds a fresh context with `TraceFlags = 0` and
`TraceState = {ypScenarioId: "SendConnectedMessage", ypTriggerId: "ConnectingWithPartner"}`. For fragments the
context of the message being sent is used; for acks the context of the fragment being acknowledged.

Validation on receipt:

* Windows converts the packet with `new TraceContext(...)`, which throws unless `TraceId` is exactly 32
  letters-or-digits and not all `'0'` (`W:Common Context.TraceContext` constructor). In
  `SignalRFragmentTransport.ProcessInboundDataAsync` that exception causes the packet to be logged and dropped.
  A nil trace object is tolerated by Windows (a fresh context is generated).
* Android calls `context.toTraceContext()` unconditionally in `HubRelayProxy` before queuing the packet; its
  `TraceContext` constructor dereferences `TraceId` and `TraceState`, so a nil trace object, nil `TraceId` or nil
  `TraceState` makes the delivery fail (no ack will ever be sent).

## 5. The packet object and DCG properties

### 5.1 `HubRelayMultiplexPacket`

MessagePack **map** (not array) with three string keys. Windows class
`W:YPP Transport.Protocol.HubRelayMultiplexPacket` is annotated `MessagePackObject(keyAsPropertyName: true)`;
its generated formatter writes `Properties`, `Type`, `Raw` in that order and ignores unknown keys when reading.
Android class `A:transport.protocol.HubRelayMultiplexPacket` uses Jackson names `Properties`, `Raw`, `Type`.

| Key | Type | Value |
|---|---|---|
| `Properties` | map string to any | DCG metadata, see below |
| `Type` | string | Handler type, always `ms-dcg` (`DCGProtocolConstants.HandlerTypeName`) |
| `Raw` | bin or nil | Fragment bytes; nil for acks |

### 5.2 Fragment properties (`Properties.Type = 2`)

Sources: `W:YPP Transport.Protocol.DCGFragmentMessage`, `DCGMessage.CreateMultiplexPacketPropertiesBase`,
`DCGProtocolConstants`; `A:transport.protocol.DCGFragmentMessage`, `DCGMessage`.

| Key | Meaning | Windows writes (cap:raw#13) | Arrives from Android as (cap:raw#19) |
|---|---|---|---|
| `Version` | DCG version, `1.0` | float64 | float64 |
| `Type` | DCG message type, `2` = Fragment | int32 (`0xD2`) | unsigned int, smallest width |
| `SessionId` | Sender's DCG session UUID | string | string |
| `SequenceNumber` | Sender's per-target counter | int32 | unsigned int |
| `MessageId` | Sender's message counter | int32 | unsigned int |
| `MessageType` | Transport message type, `0` App / `1` Platform | int32 | unsigned int |
| `FragmentId` | 1-based index | int32 | unsigned int |
| `FragmentCount` | Total fragments, at least 1 | int32 | unsigned int |

Windows key order: `Version, Type, SessionId, SequenceNumber, MessageId, MessageType, FragmentId, FragmentCount`.
Android builds a `HashMap` (order not significant; seen: `Type, Version, SequenceNumber, SessionId, FragmentId,
FragmentCount, MessageType, MessageId`).

### 5.3 Ack properties (`Properties.Type = 1`), `Raw = nil`

Sources: `W:YPP Transport.Protocol.DCGAckMessage`; `A:transport.protocol.DCGAckMessage`.

| Key | Meaning | Windows writes (cap:raw#39) | Arrives from Android as (cap:raw#18) |
|---|---|---|---|
| `Version` | `1.0` | float64 | float64 |
| `Type` | `1` = Acknowledgement | int32 | unsigned int |
| `SessionId` | Copied from the fragment being acknowledged (the *fragment sender's* session ID) | string | string |
| `SequenceNumber` | Copied from the fragment | int32 | **float64** (Android stores `Double`) |
| `Success` | bool | true/false | true/false |
| `ErrorNo` | 0 success, 1 unsupported version, 2 invalid handler | int32 | **float64** |
| `ErrorMessage` | Only on Windows-built failure acks: the result enum name | string, optional | never written by Android |

Reading rules, which define what a sender may emit:

* Windows (`DCGHubMultiplexPacketProcessor.CheckPacket`) unboxes `Version` with a direct cast to `double`.
  With the primitive-object MessagePack resolver this only succeeds for a float64 on the wire; an integer or
  float32 `Version` raises an exception and the packet is dropped. All other numeric properties go through
  `Convert.ToInt32`, so integer or floating encodings are both accepted. `SessionId` and `Success` are direct
  casts to string / bool. `MessageType`: value 1 means Platform, anything else or a missing key means App.
* Android (`A:signalr.transport.SerializationHelperUtility.castInt/castDouble`) accepts `Integer` or `Double`
  for every numeric property, including `Version`. A missing `MessageType` means App.

### 5.4 Observed re-encoding by the hub (Inferred from wire evidence)

Frames received from the hub are not byte-identical to what the sender wrote: the invocation headers map is
emptied, and integer properties arrive as `uint8`-coded values (`0xCC nn`) even for small numbers such as 1,
which neither client library would emit itself, while float64 values stay float64 (cap:raw#18, #19 versus #13).
Conclusion: the hub deserializes and re-serializes arguments, preserving the integer-versus-float distinction
but not integer width. Implementation consequence: decode numbers generically (any integer width, or float64),
and always encode `Version` as float64.

## 6. DCG reliability

### 6.1 Observed in code, Windows sender

Classes: `W:YPP Transport.Messaging.OutgoingMessageClient`, `SendOperation`, `OutgoingMessageQueueManager`,
`Transport.Chunking.FragmentSender`, `OutgoingMessageFragmenter`, `StreamFragmenter`,
`SignalR.Transport.SignalRFragmentTransport`, `SignalRFragmentSenderPolicy`, `SignalR.SignalRResiliencyPolicyFactory`,
`Transport.Chunking.SignalRFragmentSenderCircuitBreakerProvider`.

* **Fragment size**: `FragmentSizeInBytes`, default `536870912` (512 MiB), overridable by remote feature
  `YPPFragmentSizeInBytes` (`W:Common PlatformOptions`, `W:ConnYPP Utilities.YppPlatformOptionsBuilder`).
  The serialized envelope (section 8) is cut into consecutive chunks of that size;
  `FragmentCount = ceil(length / size)`.
* **Queueing**: one unbounded priority queue per target; order is ascending `Priority`, then ascending
  `MessageId`. A multi-fragment message is re-queued after each fragment, so higher-priority messages can
  interleave between its fragments.
* **Assignment**: `MessageId` when the message is created (before queueing); `SessionId` =
  GUID stored per target on first use; `SequenceNumber` when the fragment is taken for sending, once, and kept
  for all retries of that fragment; `FragmentId` counts from 1.
* **Stop-and-wait**: one send loop per target; the next fragment is taken only after the current one is
  acknowledged, failed or timed out.
* **Before sending** the transport opens the hub connection if needed; if the partner is not in the connected
  set it wakes the partner and waits (section 10), unless the message was sent with `SkipWakeIfNotConnected`
  (all responses), in which case the send fails with `PartnerNotConnected`.
* **Hub send retry**: if the invocation fails or the hub is not connected, the whole open-and-send step is
  retried up to 2 more times with no delay.
* **Ack wait**: `SignalRFragmentSendWithAckTimeout`, default 15 s (feature `YPPSignalRFragmentAckTimeoutMillis`).
  Acks are matched on source DCG ID and `SequenceNumber` only. An ack for `SequenceNumber - 1` is logged as late
  and ignored; other mismatches are ignored.
* **Ack timeout retry**: the fragment is re-sent with the same `SequenceNumber` up to
  `SignalRFragmentSendWithAckRetryCount` (default 2) more times, i.e. 3 transmissions, then the message fails
  with `AckTimedOut`.
* **Negative ack** (`Success = false`): no retry. `ErrorNo` 1 maps to `RemoteTransportTooOld`, 2 to
  `InvalidHandler` (reported as `RemoteTransportSentError`); the message fails.
* **Ack from an untrusted source**: fails the fragment with `LostTrustWithPartner`.
* **SkipPartnerAck** option: the fragment completes as soon as the hub invocation completes.
* A per-target circuit breaker with threshold `SignalRConsecutiveAckTimeoutsForPartnerDisconnect` (default 5)
  removes the partner from the connected set (`PartnerDisconnectReason.TooManyAckTimeouts`) so that the next
  send wakes the phone again.

### 6.2 Observed in code, Windows receiver

Classes: `W:YPP SignalR.Transport.SignalRFragmentTransport` (inbound loop),
`Transport.Protocol.DCGHubMultiplexPacketProcessor`, `Transport.Chunking.FragmentReceiver`, `FragmentAssembler`,
`FragmentPendingMessageAssembler`, `FragmentMetadata`, `Transport.Messaging.IncomingMessageClient`.

* Packet check: `Type` must be `ms-dcg` and `Version` must not exceed 1.0; otherwise the packet is dropped
  without a negative ack (exception: an ack with a higher version is treated as a failed ack,
  `RemoteTransportTooNew`). DCG types 3-5 (presence) are ignored.
* Trust: a fragment whose sender is not a trusted DCG client is dropped, no ack. Acks are passed on with a
  "trust validated" flag.
* Every accepted fragment is acknowledged immediately with `Success = true`, on a separate task, before and
  independently of reassembly. Acks can therefore leave out of order.
* The ack is sent on the same hub connection family and with the same `connectionSessionId` as the fragment.
  Ack send failures caused by a cancelled invocation are retried twice.
* Reassembly key: (source DCG client, `MessageId`, `SessionId`). Slots are indexed by `FragmentId`; fragments
  may arrive in any order. Dropped silently: `FragmentId` outside `1...FragmentCount`, a `FragmentCount` larger
  than the first one seen for that message, a slot already filled. `FragmentCount <= 0` raises an error.
* When all slots are filled the envelope is parsed and the message is raised once, then the entry is removed.
* No duplicate suppression across completed messages, no size limit and no expiry of incomplete messages exist
  in this code.

### 6.3 Observed in code, Android

Classes: `A:transport.chunking.FragmentSender`, `FragmentReceiver`, `FragmentAssembler`,
`FragmentPendingMessageAssembler`, `BinaryStreamFragmenter`, `A:signalr.transport.SignalRFragmentTransport`,
`SignalRFragmentSenderPolicy`, `A:configuration.PlatformConfiguration`.

* Fragment size: feature `YppFragmentSizeInBytes`, default `0x20000000` (512 MiB); the policy rejects sizes
  outside 1...512 MiB.
* Sender is windowed, not stop-and-wait: up to `fragmentSenderConcurrentSends = 100` fragments per target may be
  unacknowledged. Hub sends themselves are serialized, so fragments leave in `SequenceNumber` order.
* `SequenceNumber`: static per-target counter starting at 1; `MessageId`: global counter starting at 1;
  `SessionId`: random UUID per target, kept in memory.
* Pending acks are keyed by `sessionId#sequenceNumber#target`, so an ack must echo both the session ID and the
  sequence number exactly. Ack wait 15 s (`fragmentSenderAckTimeoutInSeconds`), up to 2 re-sends with the same
  sequence number (`fragmentSenderAckTimeoutRetryCount`), hub send retried up to 2 times with zero delay
  (`signalRTransportSendFragmentRetryCount`).
* Android ignores the `Success` flag of an incoming ack: any ack with a matching key completes the fragment as
  success (`SignalRFragmentTransport.handleIncomingAck`, `FragmentSender.onAcknowledgement`).
* Receiver: fragments and acks from an untrusted device are dropped. A fragment that fails the packet check
  (`Type` not `ms-dcg`, `Version > 1.0`, unknown DCG type) is answered with a negative ack: `Success = false`,
  `ErrorNo` 1 (unsupported version) or 2 (invalid handler).
* Every received fragment is acknowledged (single-thread executor, so acks stay ordered), then checked against
  a duplicate cache keyed `"<SequenceNumber>-<SessionId>"` with a passive expiry of 5 minutes
  (`getSeenSequenceNumberCacheDuration`). A duplicate is acknowledged again but not delivered.
* Reassembly key: (`MessageId`, `SessionId`, sender). Same slot rules as Windows. No expiry of incomplete messages.

### 6.4 Observed on the wire

* All 600+ captured fragments have `FragmentId = 1`, `FragmentCount = 1`. Largest single fragment: 1,971,142
  bytes (cap:pair), another of 330,081 bytes (cap:relay#88). Multi-fragment messages were never observed.
* Windows is stop-and-wait: each new fragment follows the ack of the previous one (cap:relay#22-#91). Its
  `MessageId` values are not monotonic on the wire because responses overtake queued requests
  (cap:relay: sequence 37 carries message 42, sequence 38 carries message 37).
* Android sends fragments back to back without waiting: sequences 129, 130, 131 arrived within 0.2 s while the
  PC acknowledged none of them until 1.2 s later (cap:raw#19-#24).
* Counters survive reconnects: a fresh WebSocket started with Windows sequence 34 / Android sequence 31
  (cap:relay#13, #23), and with 173 / 129 in a later session (cap:raw). After the phone was re-paired under a
  new DCG client ID, Windows restarted at sequence 1 for that target while `MessageId` continued at 105
  (cap:pair#249).
* Each direction uses its own constant `SessionId`; acks carry the other side's session ID (cap:relay, one
  session ID per direction per capture).
* Windows acks can be late and out of order: acks for sequences 131, 130, 129 left in that order in one
  WebSocket message 1.2 s after the fragments arrived (cap:raw#24).
* Ack latency from Android is 100-250 ms; hub Completion precedes the peer ack.
* No negative ack, retry or duplicate sequence number within a session was captured.

### 6.5 Inferred / uncertain

* Because Android suppresses duplicates by (`SequenceNumber`, `SessionId`) for 5 minutes, a client that
  restarts and reuses an old `SessionId` with a counter reset to 1 would have its fragments acknowledged but
  silently discarded. Generate a new `SessionId` on every process start (as both official clients do) or
  persist both values together.
* Whether the hub or Azure SignalR imposes a maximum message size is unknown; 1.97 MB passed. Fragmenting at a
  much smaller size than the official default is permitted by the protocol but has not been exercised live.
* The Windows ack-timeout circuit breaker is wired to count `AckTimedOut` results, but the ack-timeout path
  raises a timeout exception instead; whether the breaker ever opens through that path is unclear from the
  decompiled code.
* Message delivery order on the receiver is completion order of reassembly; there is no cross-message ordering
  guarantee beyond what stop-and-wait (Windows) or serialized sends (Android) give.

## 7. Message type values and routing

### 7.1 Observed in code

Three different enumerations exist; only the first two appear on the hub.

| Enumeration | Values | Where |
|---|---|---|
| DCG message type, `Properties.Type` | 0 Unknown, 1 Acknowledgement, 2 Fragment, 3 PresenceAnnouncement, 4 PresenceRequest, 5 PresenceResponse | `W:YPP Transport.Protocol.DCGMessageType`; Android defines only 0-2 |
| Transport message type, `Properties.MessageType` | **0 App, 1 Platform, 2 Unknown** | `W:YPP Transport.Protocol.TransportMessageType`, `A:transport.protocol.TransportMessageType` |
| Protobuf `ProtoTransportMessageType` | 0 Unspecified, **1 App, 2 Platform** | `platform_sdk/v1/dcg_fragment_message.proto`; used only when DCG messages travel inside protobuf (Nano transport), mapped by `W:YPP Transport.Protocol.DcgProtoExtensions` |
| Protobuf `ProtoDcgMessageType` | 0 Unspecified, 1 Acknowledgement, 2 Fragment, 3-5 presence | `dcg_base_message.proto` |

Routing of a reassembled message:

* Windows `IncomingMessageClient` dispatches by transport message type to subscribers.
  * Platform: `Transport.PlatformMessaging.PlatformMessageManager` looks up the `_route` header in its route
    table; no handler means a rejection response (section 8.4).
  * App: several subscribers each filter by header. `PlatformMessageManager` consumes only responses
    (`_route == /internal/response`); `ConnectionManagement.PlatformConnection` raises non-response messages
    from its partner to the application (`W:ConnYPP Services.IncomingDataApplicationService`, then the
    application message router); `Transport.DeviceProxyMessaging.DeviceProxyMessageReceiver` takes
    `_route == /DeviceProxyClient/TransportMiddleware`; `SignalR.SignalRTransport` forwards everything except
    that route to the app hand-off handler.
* Android `IncomingMessageClient` notifies all listeners; `platformmessaging.PlatformMessageManager` handles
  only Platform, `signalr.transport.MessageReceiver` only App (then
  `com.microsoft.mmx.agents.transport.MessageRouter` by `_route`).

### 7.2 Observed on the wire

`MessageType` 1 dominates (routes `/DeviceResourceManager`, `/Context/Publish`, `/Context/Message[/<id>]`,
`/SessionValidation`, `/PlatformDisconnectRequest`, `/internal/response`). `MessageType` 0 carries
`/connect/v1`, `/legacy/phonecontent` and their `/internal/response` replies (cap:pair, cap:raw).

## 8. Binary envelope and PLATFORM messages

### 8.1 Byte layout (shared by APP and PLATFORM)

All integers little-endian. Sources: `W:YPP Transport.Chunking.BinaryMessageSerializationStrategy` and
`BinaryMessageDeserializationStrategy`; `A:transport.chunking.BinaryMessageSerializationStrategy`,
`BinaryMessageDeserializationStrategy`, `BinaryReader`.

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | Version, value 1 (readers skip it without checking) |
| 1 | 4 | `headerLength` (int32) |
| 5 | 4 | `headerCount` (int32) |
| 9 | ... | `headerCount` times: int32 key length, key UTF-8 bytes, int32 value length, value UTF-8 bytes |
| ... | 8 | `payloadLength` (int64) |
| ... | `payloadLength` | Payload |

The Windows versus Android difference:

* Windows writes `headerLength = 4 + sum(4 + keyLen + 4 + valueLen)`, i.e. it **includes** the 4-byte count.
* Android writes `headerLength = sum(4 + keyLen + 4 + valueLen)`, **excluding** the count.

Both readers use `headerLength` only as "bytes that must be buffered before parsing headers" and then parse
`headerCount` entries, so each accepts the other's convention. Windows additionally requires `headerLength > 0`
and `headerCount > 0` (a message with zero headers is rejected). Android reads the 8-byte payload length but
keeps only its low 32 bits.

Wire check (cap:relay#13, #23): the same four headers give `headerLength` 129 from Windows and, with a 36-byte
request ID instead of a 2-byte one, 159 from Android; both match the formulas above.

### 8.2 Headers

Constants: `W:YPP Transport.PlatformMessaging.PlatformConstants`, `W:Util Connectivity.CommunicationConstants`.

| Header | Semantics |
|---|---|
| `_route` | Route string, selects the handler. `/internal/response` marks a response |
| `_requestId` | Request identity chosen by the requester. Windows PLATFORM requests: decimal string from a process-wide counter (`IdManager.GenerateRequestId`). Windows APP requests: GUID string. Android: UUID-style correlation ID string |
| `_originalRequestId` | In a response, the `_requestId` being answered |
| `_rejectionVersion` | Version of the rejection mechanism the sender understands. Windows adds `"1"` to every outgoing message, requests and responses alike (`PlatformMessageToOutgoingMessageAdapter`). Android adds `"1"` to binary requests built without explicit options and to key-value messages, `"0"` to one-way requests, and nothing to binary responses (`A:platformmessaging.OutgoingPlatformMessage`, `OutgoingPlatformKvpMessage`) |
| `_rejectedReason` | In a response: enum *name* `Unspecified, None, NotAllowed, VersionTooLow, VersionTooHigh, AllSyncDisabled, MeteredSyncDisabled, NotSubscribedToRoute` (`W:YPP Transport.Protocol.RejectionReason`, `A:platformmessaging.protocol.RejectionReason`) |
| `ms-content-type` | `application/x-binary` (payload is opaque bytes, usually protobuf) or `text/json` (payload is a UTF-8 JSON object). PLATFORM only. Android treats a missing header or `text/json` as JSON key-value, anything else as binary |

Observed header sets (cap:relay, cap:pair):

| Sender, kind | Headers |
|---|---|
| Windows PLATFORM request | `_route`, `ms-content-type`, `_requestId`, `_rejectionVersion` |
| Windows PLATFORM binary response | `_originalRequestId`, `_route`, `ms-content-type`, `_rejectionVersion` |
| Windows PLATFORM key-value response | same, `ms-content-type: text/json`, payload `{}` (2 bytes) |
| Android PLATFORM request | `ms-content-type`, `_route`, `_rejectionVersion`, `_requestId` |
| Android PLATFORM response | `ms-content-type`, `_route`, `_originalRequestId` |

### 8.3 Request / response correlation and timeouts (Observed in code)

Windows `PlatformMessageManager.SendRequestAsync`:

1. Take `_requestId` from the message headers if present, else generate the next counter value.
2. Register a pending request under that ID, send the message, then wait for a response.
3. Timeout `PlatformRequestTimeout`, default 120 s, covering send and wait; result `ResponseTimedOut`.
4. `OneWay` requests complete as soon as the send completes (they still carry `_requestId`).
5. A response is any message with `_route = /internal/response`, PLATFORM or APP; it is matched purely by
   `_originalRequestId` (`Handle_Response`, `PendingRequestManager`). The DCG ack is not a response.
6. Response without `_rejectedReason`, or with `None`, is success. Other names map to
   `RemoteSyncNotAllowed`, `RemoteVersionTooLow`, `RemoteVersionTooHigh`, `RemoteAllSyncDisabled`,
   `RemoteMeteredSyncDisabled`, `RemoteNotSubscribedToRoute`; an unparsable value maps to `RemoteVersionTooHigh`.

Windows `SendResponseAsync`: requires `_originalRequestId`, forces `_route = /internal/response`, keeps the
request's transport message type, and sends with "ignore device disabled" and "skip wake if not connected".

Android `platformmessaging.PlatformMessageManager`: request timeout `platformRequestTimeoutInSeconds = 60`;
responses are matched by `_originalRequestId`; `_rejectedReason` `VersionTooLow`/`VersionTooHigh` mean
incompatible, `NotSubscribedToRoute` means unsubscribed, any other non-`None` value means rejected.
`IncomingPlatformMessageRequest.sendResponseAsync` sets `_route` and `_originalRequestId`.

### 8.4 Rejection rules (Observed in code)

* Windows: an incoming PLATFORM message whose `_route` has no handler is answered, if the request carries
  `_rejectionVersion >= 1`, with a `text/json` response `{}` plus `_originalRequestId` and
  `_rejectedReason: NotSubscribedToRoute`. Otherwise nothing is sent.
* Android, in this order for every incoming PLATFORM message except `/internal/response`:
  1. If the application-level transfer status is not `ALLOWED`, reject with the mapped reason
     (`NotAllowed`, `AllSyncDisabled`, `MeteredSyncDisabled`, `VersionTooHigh`, `VersionTooLow`) and stop.
     Source of the status: `com.microsoft.mmx.agents.transport.TransferStatusChecker` over
     `AgentConnectivityManager.getSyncAllowed()`.
  2. Missing or empty `_route`, or no handler: reject with `NotSubscribedToRoute`.
  A rejection is only sent when feature `PlatformManagedMessageRejection` is on (default true), the request has
  a `_requestId`, and its `_rejectionVersion >= 1`. The rejection is a key-value response (`text/json`, empty
  object) with `_route`, `_originalRequestId`, `_rejectedReason` (`OutgoingPlatformRejectionResponse`).

### 8.5 PLATFORM routes relevant to transport

| Route | Direction | Payload | Purpose |
|---|---|---|---|
| `/internal/response` | both | per request | Response |
| `/SessionValidation` | PC to phone | protobuf `ProtoPlatformSessionValidationRequest` / `...Response` | Capability exchange (section 10.4) |
| `/PlatformActivateSessionRequest` | PC to phone | key-value, empty; one-way | Ask the phone to (re)start its session for this PC |
| `/PlatformDisconnectRequest` | both | Windows: key-value, empty, one-way. Android: protobuf `PlatformDisconnectRequest {trace_context, reason}`, one-way, no partner ack | Session goodbye |
| `/DeviceResourceManager`, `/Context/Publish`, `/Context/Message`, `/Context/Message/<id>`, `/Channel/...`, `/CryptoTrustKeyRotation`, `/CryptoTrustKeyRotationCheck` | both | protobuf | Platform features, specified elsewhere |

## 9. APP messages (`MessageType = 0`)

### 9.1 Observed in code

* Same binary envelope as section 8.1. No `ms-content-type` header.
* Payload: a serialized `pbvalueset.ValueSet` protobuf (`value_set/valueset.proto`): `map<string, DataVariant>`
  where each `DataVariant` carries `value_type` (enum `DataValueType`) and exactly one typed field (scalars,
  strings, GUID strings, nested `ValueSet`, typed arrays, date/time as int64). Android:
  `A:valueset.PayloadHelper`, `ValueSetSerializerUtility`; Windows: `W:ConnMgd ValueSetContent`,
  `W:ConnYPP Utilities.YppIncomingMessageToIncomingRequestAdapter`.
* Optional gzip: when header `_isGzippedCompressed` parses as boolean true, the payload is a gzip stream of the
  `ValueSet` bytes (both platforms read it; `A:transport.messaging.IncomingMessage.getPayloadAsKvp`).
* Requests from Windows are built by `W:ConnMgd RemoteAppClient.SendKvpRequestImplAsync` and sent through the
  same `PlatformMessageManager.SendRequestAsync` path as PLATFORM requests, with transport type App
  (`W:ConnYPP Communication.OutgoingRequestAsOutgoingPlatformMessage`, `YppRequestSender`). Consequences:
  * headers: `_route`, `_requestId` (a new GUID per request, `W:Util Connectivity.OutgoingRequest`),
    `_rejectionVersion: "1"`, plus any caller-supplied headers;
  * the following keys are always added to the payload: `displayName`, `appVersion`, `installationId`,
    `contractVersion` (double). Legacy requests also add `isuserinitiated` (bool), `ignoreResponse` (bool),
    `transportType` (int 0);
  * default timeout 120 s (`RequestOptions`), default priority 100, user-initiated requests priority 0.
* Contract version constant on both sides: `3.99` (`CommunicationConstants.ContractVersionValue`,
  `com.microsoft.mmx.agents.AppServiceProviderHelpers`). Android accepts a request only if
  `floor(request.contractVersion) == floor(3.99)` (`VersionChecking.areContractVersionsCompatible`).
* Android request handling (`com.microsoft.mmx.agents.ScenarioRequestHandlerBase.handleAsync`):
  1. If sync is not allowed: when the connectivity manager is uninitialised, send nothing; otherwise respond
     with a "sync not allowed" payload and then force-terminate the session.
  2. If the contract version is incompatible: respond `result = 3`.
  3. Otherwise run the route handler and respond with its map, or `result = 1` on exception, `result = 2`
     when the handler returned nothing.
* Android responses (`com.microsoft.mmx.agents.transport.OutgoingResponse`, `Responder`): headers `_route =
  /internal/response` and `_originalRequestId`; payload `ValueSet` containing at least `result` (int32) and
  `contractVersion` (double). Result codes built by `AppServiceProviderHelpers`: 0 success, 1 failure,
  3 incompatible contract, 4 accepted, 5 denied, 6 permanently denied, 7 needs permission, 10 cancelled or
  disconnected (optional `rejectReason`), 18 device not supported, 20 app launched.
* Android requests to the PC (`com.microsoft.mmx.agents.transport.OutgoingRequest`, `RequestSender`):
  `_requestId` is a generated correlation ID; default response timeout 2 minutes; a response is accepted only
  from the DCG client the request was sent to (`ResponseMessageHandler`).
* Windows responses to phone requests (`W:Util Connectivity.OutgoingResponse`, `OutgoingResponseHeaders`,
  `W:ConnYPP Services.IncomingDataApplicationService`): headers `_originalRequestId`, `_route =
  /internal/response`, `result` (decimal string), optional `contractVersion`, `correlationVector`; priority 50.
* When reading, Windows copies `result`, `_requestId`, `_route`, `correlationVector`, `contractVersion` and
  `contentType` from the payload into its header view if the envelope header is absent
  (`IncomingResponseHeaders`, `YppIncomingMessageRequestHeaders`).
* Android APP route table (26 routes, `DaggerMainApplication_HiltComponents_SingletonC`): `/connect/v1`,
  `/internal/response`, `/ping`, `/chat/v1`, `/media/v1`, `/contacts/v2`, `/calling`, `/calling/dial`,
  `/notifications`, `/settings`, `/clipboard`, `/devicestatus`, `/command/devicestatus`, `/command/audio`,
  `/permission`, `/permission/status`, `/applications`, `/files`, `/wallpaper`, `/nanohandshake`,
  `/btwakeenablerequest`, `/ypcringupdatenotificationrequest`, `/command/platform/a2dmigration`,
  `/newhomepagenotificationrequest`, `/hotspotsetupnotificationrequest`, `/hotspotdevicedatasyncrequest`.
  The phone sends its own content to the PC on `/legacy/phonecontent`.
* `/DeviceProxyClient/TransportMiddleware` is a separate APP route handled only on Windows
  (`W:YPP Transport.DeviceProxyMessaging.*`): headers `RequestId`, `ChunkSize`, `ContentType`
  (also `ChunkCount`, `ChunkId`, `FileSize`), JSON payload `{name, parameters: {commandContent}}`; it requires a
  `connectionSessionId` (section 11). Not used by the Android phone app.

### 9.2 Observed on the wire (cap:pair#409-#464, cap:raw)

| Message | Envelope headers | Payload |
|---|---|---|
| PC `/connect/v1` request | `_requestId` (36 chars), `_route`, `_rejectionVersion: 1`; Windows header-length convention | `ValueSet`, 1917 bytes; top-level keys include `contentType`, `correlationVector`, `contractVersion`, `sequenceNumbers` (object), `configuration` (object), `attributes` (object: `flightRing`, `displayName`, `appVersion`), sampling fields |
| Phone response | `_originalRequestId`, `_route: /internal/response`; Android convention | `ValueSet`, about 3 kB: `permissions`, `settings`, `mediaSettings`, `yppVersion`, device status values, per-content sequence numbers and more |
| Phone `/legacy/phonecontent` request | `_requestId` (36 chars), `_route` | `ValueSet` with `contentType`, `contractVersion`, `sequenceNumber`, `correlationVector`, `dedupeID`, `installationId`, `displayName` plus content |
| PC response | `_originalRequestId`, `_route: /internal/response`, `result: 0`, `_rejectionVersion: 1` | `ValueSet` with `result` (int32), sometimes more |

The `/connect/v1` response arrived 1.5 s after the request, after several unrelated messages.

### 9.3 Inferred / uncertain

* The semantic meaning of individual `ValueSet` keys belongs to the feature specifications.
* Date/time units inside `DataVariant` are not verified here.

## 10. Presence and session start

### 10.1 Observed in code, Windows (PC role)

Classes: `W:YPP ConnectionManagement.SignalRPlatformConnectionWorker`, `SignalRPartnerConnection`,
`SignalR.Transport.Connection.SignalRPartnerConnectionService`, `SignalRConnection`, `SignalRConnectionProxy`,
`HubPartnerChangeHandler`, `Wake.WakeParams`, `Wake.WakeProvider`, `Wake.DispatcherManager`.

1. Open the hub connection (section 2). Initial open is retried `SignalRInitialConnectionRetryAttempts` (3)
   times with 1 s sleep; on the first retry after an HTTP 401 the DCG token is force-refreshed.
2. The hub pushes `OnConnected`; the client stores `RegionName` and `Partners`. Windows does **not** mark the
   listed partners as connected.
3. If the partner is not in the connected set: call `SendConnectedAsync(partner)` ("flush"), wait up to 10 s for
   the `OnConnected` payload, then call `POST /Dispatcher/Wake` with wake data that includes
   `DCG-HubRegion = RegionName` (plus `DCG-Environment`, `IgnoreDeviceDisabledStatus`, `DCG-RequestNewSession`,
   `DCG-CryptoWakeJwt`), `collapseKey = "YPPWake"`, priority `normal` on the first attempt and `high` on
   retries, `ttl` in seconds (default 20).
4. Wait for the partner to enter the connected set for `max(ttl, 10 s)`. Up to `WakeRetryAttempts` (2) more
   wakes on "device unreachable"; the worker alternates the TTL between 20 s and 45 min on such failures.
5. The partner enters the connected set on `OnPartnerConnected`, `OnReceiveMessage` or
   `OnReceiveSessionBasedMessage` from it. `OnPartnerHeartBeat` only refreshes partners already in the set.
6. Every `OnPartnerConnected` is answered with `SendConnectedAsync(sender)` (handler registered in the
   `SignalRConnection` constructor). When asked to connect while hub and partner are already connected, the
   worker also sends `SendConnectedAsync(partner)`.
7. Once the partner is connected, queued fragments flow. There is no transport-level handshake beyond this.
8. Heartbeat supervision: for each connected partner a timer of `HeartBeatFrequency + 2 s` is re-armed on every
   message, heartbeat or presence event from it; each expiry increments a miss counter and reaching
   `MissedHeartBeatsThreshold` (3) removes the partner (`ExceededMissedHeartbeats`); see 10.6 for a caveat.
   Supervision is off when `HeartBeatFrequency` is zero.
9. The connected set is cleared when the hub connection closes or starts reconnecting, on power resume and on
   session unlock.

### 10.2 Observed in code, Android (phone role)

Classes: `A:signalr.transport.connection.SignalRConnectionV2` / `SignalRConnection`, `HubPartnerChangeHandler`,
`A:signalr.transport.SignalRUserSessionTracker`, `A:wake.WakeNotificationHandler`.

1. A wake push carries `DCG-SourceId`, `DCG-HubRegion`, `DCG-Environment`, `DCG-RequestNewSession`,
   `DCG-CryptoWakeJwt`, `DCG-TraceParent`, `DCG-TraceState`; the phone opens a hub connection with
   `DCG-PartnerId` and `DCG-HubRegion` headers.
2. After the hub connection starts, the phone waits for the `OnConnected` payload (up to 30 s), then sends
   `SendConnectedAsync(target, "")` to every ID in `Partners` plus the wake source, then arms its idle timer.
3. A partner becomes "connected" on `OnPartnerConnected`, `OnReceiveMessage`, `OnPartnerHeartBeat`
   (managed partnership) or `OnReceiveSessionBasedMessage` (session-based, not wake-able).
4. A user session for the PC starts when the partner connects **and** the PC's DCG client ID maps to a known
   remote app (`SessionStartStatus.NO_APP_ID_MAPPING` otherwise). After a session ended because the partner
   left, only an `OnPartnerConnected` event or a `/PlatformActivateSessionRequest` can start a new one; plain
   incoming data or heartbeats are ignored for that purpose (`PartnerConnectedSource.canBeginSessionForTerminatedApp`).
5. Heartbeat supervision mirrors Windows: interval `heartBeatFrequency + 2 s`, threshold 3, timer re-armed after
   each miss.
6. Idle timer 30 min; it only closes the hub connection when no managed partner is connected.

### 10.3 Observed on the wire: full start sequence (cap:raw#1-#24, cap:pair#235-#300, cap:relay#1-#22)

| t (s) | Dir | Event |
|---|---|---|
| 0.00-0.37 | | Two negotiates, WebSocket upgrade |
| 0.37 | c2s | Handshake; 0.42 s2c handshake response |
| 0.43 | c2s | Ping; `SendConnectedAsync(trace, partner, {})` invocation `"1"` |
| 0.43 | s2c | `OnConnected {RegionName, Partners: []}` (may precede or follow the client's `SendConnectedAsync`) |
| 0.48 | s2c | Completion `"1"` |
| 0.71 | HTTP | `POST dcg.microsoft.com/Dispatcher/Wake?api-version=1.5.0`, body keys `collapseKey`, `data`, `deviceId`, `priority`, `ttl` |
| 1.96 | s2c | `OnPartnerConnected [partner, nil, {RegionName}]` (hub-generated when the phone connects) |
| 1.98 | c2s | `SendConnectedAsync` (reply), immediately followed by the first queued fragment |
| 2.08, 2.19 | s2c | Two `OnPartnerConnected [partner, trace, ""]` (relays of the phone's `SendConnectedAsync`; their `TraceId` equals the trace ID in the `traceparent` of the wake request, checked in cap:relay#10 and #16) |
| 2.24 | s2c | First DCG ack from the phone, then the phone's own requests |
| 2.61 | s2c | First `OnPartnerHeartBeat`, then one every 30.0 s |

The PC answers each `OnPartnerConnected` with another `SendConnectedAsync` (cap:relay#12, #17, #20).

### 10.4 `/SessionValidation` (capability exchange)

Observed in code:

* Windows sends it only when the context-source optimization is enabled (`IsContextSourceOptimizationEnabled`,
  remote feature `YPPUseSharedConnection`) and only as part of obtaining a context source
  (`W:YPP ConnectionManagement.Session.PlatformConnectionSessionValidator`). It is a normal PLATFORM request,
  `application/x-binary`, payload `ProtoPlatformSessionValidationRequest { repeated platform_capabilities = 1 }`.
  Local capabilities: always `SESSION_VALIDATION (1)`; plus `PERSISTENT_MESSAGE_CHANNEL (2)` when
  `EnableNanoOffloadPhase1`, plus `NANO_TRANSPORT_PREFERENCE (3)` when `EnableNanoTransportPreference`
  (`W:SDK Utils.PlatformCapabilitiesProvider`).
* Response `ProtoPlatformSessionValidationResponse { repeated platform_capabilities = 1;
  int32 persistent_messaging_channel_version = 2; int32 nano_transport_preference_version = 3 }`.
  Windows requires `SESSION_VALIDATION` in the response, else "not supported"; minimum versions it accepts:
  persistent messaging channel 14, nano transport preference 3. A rejection, missing route, empty or
  unparsable payload all mean "session validation not supported".
* Android answers on route `/SessionValidation`
  (`A:ambientexperience.contextmanagement.PlatformConnectionSessionResponder`) with its capabilities and the
  constants 14 and 3, and creates a context source for the requesting PC.

Observed on the wire: request payload `0A 01 01` (capabilities `[1]`), response `0A 03 01 02 03 10 0E 18 03`
(capabilities `[1, 2, 3]`, versions 14 and 3), 0.2-0.35 s round trip (cap:relay#158/#162, cap:pair#12/#19).
In cap:pair it was the first fragment of the session; in cap:relay it came 10 s into the session, after
28 other PLATFORM exchanges had already succeeded.

### 10.5 What gates feature traffic

Observed in code and on the wire:

* Transport level: the peer must be a trusted DCG client on both sides (untrusted fragments are dropped without
  an ack), and the trace object must be well formed (section 4.3). Nothing else is required before fragments are
  accepted; `/SessionValidation` is **not** a precondition (cap:relay shows traffic before it).
* Android PLATFORM handlers additionally require transfer status `ALLOWED` (section 8.4), and Android APP
  handlers require sync allowed plus a compatible `contractVersion` (section 9.1).
* The phone must consider a user session active for most features; that needs `OnPartnerConnected` from the PC
  (i.e. the PC's `SendConnectedAsync`) or `/PlatformActivateSessionRequest`, and the PC must be a known linked
  device.

`/connect/v1` (Observed): an APP request sent by the PC application layer whenever the platform connection
becomes connected (`W:ConnMgd Services.EstablishConnectionManager`, content type `connect`, timeout 10 min when
not user-initiated). It exchanges configuration, capabilities, permissions and sync sequence numbers
(Android `com.microsoft.mmx.agents.ConnectionRequestHandler`, response keys `deviceConfiguration`,
`attributes`, `capabilities`, `permissions`, `userAttributes`, `settings`, `mediaSettings`, `yppCapabilities`,
`yppVersion = 8`, `cameraStreamConfiguration`, ...). On the wire it was sent 6.4 s after the partner connected,
after PLATFORM traffic had started (cap:pair#409).

### 10.6 Inferred / uncertain

* Whether individual Android feature handlers refuse to work before a successful `/connect/v1` is not
  established here; the transport and platform layers do not depend on it.
* The two relayed `OnPartnerConnected` events per session are taken to be the phone announcing itself once for
  the `Partners` list or wake source and once more from a second code path; the reason for exactly two is not
  identified.
* Windows starts its per-partner heartbeat timer as a one-shot and the expiry handler does not re-arm it, so
  how three consecutive misses can accumulate is unclear from the decompiled code
  (`HubPartnerChangeHandler.Timer_OnHeartBeatTimerElapsed`, `W:Common Timer`). Android re-arms explicitly, so
  there a silent partner is dropped after roughly `3 x (frequency + 2 s)`.
* The hub-generated `OnPartnerConnected [partner, nil, {RegionName}]` is assumed to be triggered by the
  partner's hub connection carrying `DCG-PartnerId`; this is not visible in client code.

## 11. Session-based messages and `connectionSessionId`

### 11.1 Observed in code

* Windows chooses the hub method per packet: `SendSessionBasedMessageAsync` when the outgoing message has a
  non-null `ConnectionSessionId`, else `SendMessageAsync` (`W:YPP SignalR.Transport.HubRelayProxy.SendDataAsync`).
* Windows never originates a `connectionSessionId`. It is non-null only (a) on acks for fragments that arrived
  through `OnReceiveSessionBasedMessage` (`SignalRFragmentTransport.SendAcknowledgementAsync`), and (b) on
  device-proxy responses, which copy it from the incoming request
  (`W:YPP Transport.DeviceProxyMessaging.OutgoingDeviceProxyMessage`). PLATFORM messages always use null
  (`PlatformMessageToOutgoingMessageAdapter.ConnectionSessionId`), as do ordinary APP messages
  (`SignalR.SignalRTransport`).
* The connection manager keys partner connections by (partner ID, environment, `connectionSessionId`)
  (`SignalRConnectionPartnerKey`), and a partner seen only through session-based messages is not put under
  heartbeat supervision.
* Android never calls `SendSessionBasedMessageAsync`. It registers `OnReceiveSessionBasedMessage` only to note
  the sender as a session-based, non-wake-able partner; the packet content is not processed
  (`A:signalr.transport.connection.HubPartnerChangeHandler`, `A:signalr.transport.HubRelayProxy`).

### 11.2 Observed on the wire

Neither session-based method appears in any capture.

### 11.3 Inferred / uncertain

Session-based messaging serves a third kind of client (web or "device proxy" clients, see route
`/DeviceProxyClient/TransportMiddleware`) that addresses one specific hub connection of the PC. A PC-role
client talking to the Android app can ignore both methods, but should register a no-op handler for
`OnReceiveSessionBasedMessage` so that an unexpected invocation is not a protocol error.

## 12. Reconnect and resilience

### 12.1 Observed in code, Windows

| Mechanism | Behavior | Source |
|---|---|---|
| SignalR automatic reconnect | Delays `0 s, 2 s, 10 s, 30 s, 1 min, 3 min, 5 min`, then give up (connection closed). On HTTP 429 the delay is `15 s + random(0...29) s` | `W:YPP SignalR.HubReconnectionRetryPolicy`, `W:Common PlatformConfiguration.SignalRReconnectionInterval`, `TooManyRequests*` |
| Initial open | 3 retries, 1 s apart; force token refresh on first retry after 401; a 429 opens a circuit breaker for `15 s + random(0...29) s` | `W:YPP SignalR.SignalRResiliencyPolicyFactory.CreateHubConnectionPolicy` |
| Platform connection worker | After a non-fatal open or partner failure the delay doubles before each new attempt: 2 s, 4 s, 8 s ... ; when it reaches 6 h the failure becomes fatal. Reset to 1 s on success | `W:YPP ConnectionManagement.Utils.PlatformConnectionNextTryPolicyManager`, `SignalRConnectionWorkerBase.DelayNextAttemptAsync` |
| Fatal open results | Crypto failure, non-transient auth failure, user interaction required | `SignalRPlatformConnectionResiliencyUtils` |
| Partner loss | On hub close or reconnecting, all partners are marked disconnected; reconnect is automatic unless the disconnect was intentional (`/PlatformDisconnectRequest`) | `HubPartnerChangeHandler`, `SignalRPlatformConnectionWorker.Handle_Partner_Disconnected` |
| Idle close | `SignalRMaximumIdleTime` 60 min, but the idle timer is disabled whenever peerless connection management is enabled, which the Phone Link options builder hard-codes to true | `SignalRConnection`, `W:ConnYPP Utilities.YppPlatformOptionsBuilder` |
| Token on reconnect | Every (re)negotiate calls the access token provider again, so a fresh DCG token and a fresh Azure SignalR access token are used | `SignalRConnectionFactory.CreateHubConnection` |
| Hub throttling | A hub error whose message contains `Throttled` maps to a `Throttled` send status when the feature is on | `HubRelayProxy.ProcessResult` |

State kept across reconnects within one process: per-target `SessionId` and `SequenceNumber`, global `MessageId`
and request-ID counters, queued and in-flight send operations (they re-open the connection and re-wake the
partner as needed), pending requests (until their own timeout), partially reassembled messages. Nothing of
this is persisted to disk. The connected-partner set and the stored `OnConnected` payload are **not** kept.

### 12.2 Observed in code, Android

* Open retry: `YPPRetryAttemptsForSignalRConnection` (3) attempts, 2 s apart, token refresh when needed
  (`A:utils.Resiliency.getSignalROpenStrategy`). The V2 connection class (feature `YppSignalRConnectionV2`,
  default off) also abandons an open attempt after 20 s.
* Reconnect after an unexpected close only when feature `YppIsLtwDrivenReconnectsEnabled` is on (default off):
  delays `1, 2, 3, 5, 7, 10, 30 s, 1 min, 3 min` (`getSignalRReconnectAfterDisconnectDelayOptions`). Otherwise
  the phone waits to be woken again.
* A circuit breaker per PC ends the phone's session after repeated ack timeouts or unreachable results
  (`A:signalr.transport.MessageSender.evaluateSessionState`).

### 12.3 Observed on the wire

Each capture starts with a brand-new negotiate; sequence numbers continue from the previous connection
(section 6.4). The phone connected 1.2-1.6 s after the wake request in all sessions. No token-expiry event,
server Close or automatic reconnect was captured.

### 12.4 Inferred / uncertain

* What the hub does when the Azure SignalR access token expires on a live connection is unknown.
* After any reconnect the PC must expect `OnConnected` again and must re-establish presence
  (`SendConnectedAsync`, wake if the partner does not appear), because the phone restarts its session only on a
  presence event.

## 13. Constants

| Setting | Windows default (key or remote feature) | Android default |
|---|---|---|
| Hub path | `relayhub/` | `relayhub/` |
| SignalR keep-alive / server timeout | 15 s / 30 s (`YPPHubConnectionKeepAliveMillis`, `YPPHubConnectionServiceTimeoutMillis`) | 15 s / 30 s |
| Heartbeat frequency header | 15 s (`YPPHeartBeatFrequencyInSeconds`); 30 seen on the wire | 15 s |
| Missed heartbeats threshold, timer | 3, frequency + 2 s (`YPPMissedHeartBeatsThreshold`) | 3, frequency + 2 s |
| Fragment size | 536870912 bytes (`YPPFragmentSizeInBytes`) | 536870912 bytes (`YppFragmentSizeInBytes`) |
| Fragment ack timeout | 15 s (`YPPSignalRFragmentAckTimeoutMillis`) | 15 s |
| Fragment re-sends on ack timeout | 2 (`YPPSignalRFragmentSendWithAckRetryCount`) | 2 |
| Hub send retries | 2, no delay | 2, no delay |
| Unacked fragments in flight per target | 1 | up to 100 |
| Duplicate cache | none | 5 min, key `(SequenceNumber, SessionId)` |
| Consecutive ack timeouts before partner drop | 5 | circuit breaker (see code) |
| PLATFORM request timeout | 120 s (`PlatformRequestTimeout`) | 60 s |
| APP request timeout | 120 s default, 600 s for background `/connect/v1` | 120 s |
| Wait for `OnConnected` payload | 10 s | 30 s |
| Wake TTL / long TTL / min wait for partner | 20 s / 45 min / 10 s | n/a |
| Wake retries | 2 | n/a |
| Initial hub open retries | 3 x 1 s | 3 x 2 s |
| Platform connect timeout before feedback | 70 s (`YPPConnectApiWaitForConnectionDefault`) | n/a |
| Message priorities (lower is sent first on Windows) | 0 high, 50 medium, 100 low; PLATFORM binary default 100, key-value 0, APP responses 50 | PLATFORM binary 25, key-value 50, APP default 50 |

## 14. Implementation checklist for a PC-role client (derived from the facts above)

1. Negotiate at `https://dcg.microsoft.com/relayhub/negotiate?negotiateVersion=1` with the DCG bearer token and
   the `DCG-*` headers; follow `url` + `accessToken`; negotiate again; open the WebSocket with
   `id=<connectionToken>` and `Authorization: Bearer <accessToken>`; repeat the `DCG-*` headers on all three.
2. Send the JSON handshake with `version: 1`, expect `{}`; run pings every 15 s and a 30 s server timeout.
3. Split and join hub messages by varint length prefix; allow several per WebSocket message.
4. Use string invocation IDs and wait for the Completion of every invocation.
5. Register handlers for all six callbacks. Reply to every `OnPartnerConnected` with `SendConnectedAsync`.
6. Always send a full trace object: 32-hex `TraceId`, 16-hex `ParentId`, integer `TraceFlags`, non-nil
   `TraceState` map.
7. Encode packets as maps with keys `Properties`, `Type`, `Raw`; `Version` as float64 `1.0`; other numbers as
   integers. Decode numbers leniently (any integer width or float64).
8. Use a fresh random `SessionId` per target per process start, sequence numbers from 1, and echo the peer's
   `SessionId` and `SequenceNumber` in acks. Ack every fragment, including duplicates.
9. Expect several unacknowledged fragments from the phone at once and acks in any order.
10. Wait for the phone's ack (15 s, re-send twice with the same sequence number) before sending the next
    fragment to it.
11. Build envelopes with at least one header; accept both header-length conventions.
12. Answer unknown PLATFORM routes that carry `_rejectionVersion >= 1` with a rejection response.
13. Correlate responses by `_originalRequestId` across both message types.

## 15. Open questions

1. Exact hub semantics of `DCG-HeartBeatFrequency` and `DCG-PartnerId`; whether heartbeats are generated by the
   hub from connection liveness or relayed from something the partner sends.
2. Lifetime of the Azure SignalR access token and hub behavior at expiry; server-initiated Close contents.
3. Maximum hub message size, and whether multi-fragment messages work end to end (never observed).
4. The exact bytes Android puts on the wire (only hub-re-encoded frames are visible); in particular whether the
   hub would also re-encode a float32 `Version` as float64.
5. Whether the hub validates `DCG-LogicalDeviceId`, `DCG-AppId`, `DCG-OS` or accepts arbitrary values.
6. Hub behavior for `SendMessageAsync` to a partner that is not connected (queued, dropped, or error
   completion); Windows avoids the case by waking first.
7. The CrossDevice package that produced the captures may differ from Phone Link 1.26072 in details not
   visible on the wire.
