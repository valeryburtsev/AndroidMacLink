# Session start, clipboard sync and notification sync

Implementation-grade specification for a PC-side client that an Android phone running
Link to Windows (LTW) treats like Windows. Scope: what happens above the DCG fragment layer
once the hub relay is connected, plus the first two features (clipboard, notifications).

Revision 1, 2026-10-09.

Sources and how they are cited

| Tag | Source |
|---|---|
| `W:` | Decompiled Phone Link 1.26072.257.0, `corpus/windows/decompiled/`. Cited as assembly :: class.method. |
| `A:` | Decompiled Link to Windows 1.26082.130.0 (jadx), package prefix `com.microsoft.mmx.agents` abbreviated to `agents`. |
| `P:` | Recovered proto sources, `protocol/recovered/android/`. Cited as file :: message. |
| `C-relay:` | `captures/vm-relay-2026-10-09/flows.jsonl`, record `seq`. |
| `C-pair:` | `captures/vm-pairing-2026-10-09/flows.jsonl`, record `seq`. |
| `X:` | Third-party cross-check only (`third_party/linkmyphone/docs/...`). Never a primary source. |

Every statement is labelled by evidence class: **[code]** observed in code, **[wire]** observed
in a capture, **[inferred]** deduced and not directly confirmed. Captured payloads were read for
structure only; no user content is reproduced here.

Three limits of the evidence, stated once

1. The Windows process that owns the relay connection in both captures is Cross Device
   Experience Host (`MicrosoftWindows.CrossDevice`, client type `WEA`, called CDEH below). It is
   **not decompiled** (only a stub exists under `corpus/windows/stub/`). Everything CDEH does is
   known from the wire and from the Android peer code, never from Windows code.
2. Notification pushes were captured on 2026-10-09 after the user granted notification access
   (`captures/vm-raw-2026-10-09`, seq 2219 to 2253; sanitized copy in
   `app/Tests/WinPhoneCoreTests/Fixtures/notifications.json`). They confirm section 7.2 and 7.3
   for operation 1 and add two facts **[wire]**: Windows repeats the scenario result as an
   envelope header `result` on its reply (headers `_originalRequestId`, `_route`, `result`,
   `_rejectionVersion`), and the push carries `incremental` Int32 1, `dedupeID` String and
   `retryCount` Int32 next to the status keys. A second capture the same day (seq 2375 to 2435;
   `Fixtures/notification-commands.json`) covers the PC side **[wire]**: the `/permission`
   question (type 64, answered with result 4 once granted) and the `permissions` push,
   reconcile (operation 3), dismiss (operation 2) and Clear all (operation 4, listing every key
   the PC holds), each with `isuserinitiated` false, and the phone's removal pushes (operation 2,
   empty document). PC APP requests order their headers `_requestId`, `_route`,
   `_rejectionVersion`. Launch, action buttons and inline reply (operation 5) are still
   **[code]** only.
3. Image types **[code]** + **[live 2026-10-09]**: the phone announces a copy only when the clip
   description lists one of `image/bmp`, `image/gif`, `image/jpeg`, `image/png`, `image/svg+xml`,
   `image/tiff`, `image/webp`, `image/x-ms-bmp`, `text/plain`, `text/html`, `text/css`, `text/csv`,
   `text/richtext`, `text/sgml`, `text/yaml` (A: agents.clipboard.ClipboardConstants.SUPPORTED_MIME_TYPES;
   ClipboardEventSubscriber rejects others as `MimeTypeNotSupport`). A Samsung photo copied as
   `image/heif` produced no publication to either the Mac or the VM.
4. No clipboard *content* exchange exists in any capture: the PC had the feature off. The
   STATUS and FEATURE_OFF exchanges are on the wire; CONTENT and CLIPBOARD_CHANGE are **[code]**.

---

## 1. Model: two clients on one connection

Windows runs two DCG identities for the same machine **[wire]** (C-pair: 192, 194, 202, 213;
evidence/claims.jsonl C0038):

| | Phone Link | Cross Device Experience Host |
|---|---|---|
| Package | `Microsoft.YourPhone` 1.26072.257.0 | `MicrosoftWindows.CrossDevice` 1.26082.74.0 |
| DCG `clientType` | `PL` | `WEA` |
| Registered `capabilities` | `FILE_TRANSFER_ONEDRIVE`, `UNLINKABLE_V1`, `UNLINKABLE_V2` | `DEVICE_STATUS`, `UNLINKABLE_V1`, `FILE_TRANSFER`, `FILE_TRANSFER_ONEDRIVE`, `FILE_TRANSFER_ONEDRIVE_WNS_PUSH`, `CLIPBOARD`, `REMOTE_CONTROL`, `REMOTE_CONTROL_V2`, `HOTSPOT` |
| Speaks | APP messages (`/connect/v1`, `/notifications`, `/legacy/phonecontent` ...) | PLATFORM messages (`/DeviceResourceManager`, `/Context/Publish` ...) |

The phone registers as `clientType` `LTW` with capabilities `PHONE_APPS`, `DEVICE_STATUS`,
`HOTSPOT_ACCOUNT_SECRET`, `CONTINUITY`, `CAMERA_STREAMING`, `PHONE_FILES`, `FILE_TRANSFER`,
`CLIPBOARD`, `RINGER_MODE`, `HOTSPOT`, `SEND_MESSAGE`, `REMOTE_CONTROL` **[wire]** (C-pair: 162).

Both capability lists travel in `metadata.capabilities` of `POST /DeviceAuthProxy/SetDeviceInfo`
and `EnrollDevice`, and come back from `GetDeviceInfoList` **[wire]** (C-pair: 192, 213, 162).

Connection sharing **[wire] + [code]**

- In both captures every hub WebSocket was opened with `DCG-AppId`
  `MicrosoftWindows.CrossDevice_...`, yet the same socket and the same DCG session carried
  `/connect/v1` whose payload has `appVersion` = `1.26072.257.0`, i.e. Phone Link's
  (C-pair: 239 open, 409 and 549 connect).
- Android calls this "connection sharing" (experiment `ENABLE_SHARING_CONNECTION`). When a WEA
  remote app is connected for a device, sends addressed to the PL remote app of the same
  `distinguishedDeviceId` are redirected to the WEA DCG client id
  (A: agents.remotedevice.ConnectionSharingManager; RemoteDeviceManager.getConnectionSharingRemoteApp,
  isActiveConsideringConnectionSharing; agents.remoteapp.RemoteAppClient).
- Phone Link's own code confirms the other half: when it has no handler for an incoming
  resource path it logs that the request is "handled by the connection owner under connection
  sharing" and stays silent (W: YourPhone.YPP :: DeviceResourceManager.ProcessIncomingRequestAsync).
- Several PC answers to one phone request appear twice on the wire with different trace state
  (C-relay: 41 and 142 for the same `_originalRequestId`). **[inferred]** both Windows processes
  answer the same `/Context/Publish`. The phone tolerates it.

Consequence for our client: the phone decides which features to offer per remote app by
`clientType` and by the capability strings stored in DCG. Clipboard is a WEA feature gated on
the string `CLIPBOARD`; notification push is a PL feature (sections 6.6 and 7.8).

---

## 2. Message envelopes

### 2.1 Hub properties **[wire]**

Each DCG fragment in the hub invocation carries `Properties`: `Version` 1.0, `Type` (2 =
fragment, 1 = ACK), `SessionId`, `SequenceNumber`, `MessageId`, `FragmentId`, `FragmentCount`,
`MessageType` (C-relay: 13, 21).

`MessageType` on the hub is **0 = APP, 1 = PLATFORM** (C-pair: 409 is APP with 0; C-relay: 13 is
PLATFORM with 1). This matches W: YourPhone.YPP :: Transport.Protocol.TransportMessageType
(`App`, `Platform`, `Unknown`) and is **not** the numbering in
P: platform_sdk/v1/dcg_fragment_message.proto :: ProtoTransportMessageType (APP = 1, PLATFORM = 2).

Session ids are per direction: PC to phone and phone to PC fragments carry different
`SessionId` values, each with its own `SequenceNumber` space (C-pair: 249 versus 262).

### 2.2 Binary envelope (same for APP and PLATFORM) **[wire]**

`u8 version = 1`, `u32le header_bytes`, `u32le header_count`, then per header
`u32le len + UTF-8 key`, `u32le len + UTF-8 value`, then `u64le payload_len`, then payload.
Windows counts the 4-byte `header_count` inside `header_bytes`; Android does not; accept both
(`tools/capture/platform.py`; claims C0029). All 357 fragments in C-pair and all 58 in C-relay
decode this way, APP ones included.

### 2.3 Headers

| Header | Used on | Value |
|---|---|---|
| `_route` | all | Route. Every reply uses `/internal/response`. |
| `_requestId` | requests | Windows PLATFORM: incrementing unsigned integer as decimal string (`"20"`, `"21"` ...). Windows APP and all Android: GUID, lowercase with hyphens. **[wire]** (C-relay: 13, 23; C-pair: 409). **[code]** W: PlatformMessageManager.SendRequestAsync uses `idManager.GenerateRequestId()` when the header is absent. |
| `_originalRequestId` | replies | Copy of the request's `_requestId`. A reply without it is dropped (W: PlatformMessageManager.Handle_Response). |
| `ms-content-type` | PLATFORM only | `application/x-binary` (protobuf payload) or `text/json`. Absent on APP messages **[wire]**. Constants: W: YourPhone.YPP :: PlatformConstants. |
| `_rejectionVersion` | every message Windows sends; Android requests | `"1"`. |
| `_rejectedReason` | rejection replies | Name from `RejectionReason`: `Unspecified`, `None`, `NotAllowed`, `VersionTooLow`, `VersionTooHigh`, `AllSyncDisabled`, `MeteredSyncDisabled`, `NotSubscribedToRoute` (W: YourPhone.YPP :: Transport.Protocol.RejectionReason; same on Android, A: agents.ypp.platformmessaging.PlatformMessageManager). |
| `result` | APP replies sent by the PC | Decimal string of the Int32 `result` in the value set **[wire]** (C-pair: 431). The phone's replies do not carry it (C-pair: 459). |
| `_isGzippedCompressed` | incoming APP | `"true"` means the payload is gzip around the value set (W: YourPhone.Connectivity.YPP.Managed :: YppIncomingMessageToIncomingRequestAdapter). Not seen on the wire. |

Rejection **[code]**: a PLATFORM request on a route nobody subscribed to is answered with
`/internal/response`, `_originalRequestId`, `_rejectedReason: NotSubscribedToRoute`, content
type `text/json`, empty map, but only if the request carried `_rejectionVersion` >= 1
(W: PlatformMessageManager.SendRejectionResponseAsync). An unparseable reason reads as
`VersionTooHigh` (W: PlatformRequestResultUtils.CreateFromIncomingMessage).

Timeouts **[code]**: platform reply timeout 120 s (W: YourPhone.YPP.Common :: PlatformConfiguration.PlatformRequestTimeout);
platform connection timeout 70 s (PlatformOptions.PlatformConnectionTimeout).

### 2.4 Payload kinds

- PLATFORM `application/x-binary`: one protobuf message, type fixed by route (section 3).
- PLATFORM `text/json`: a UTF-8 JSON object of string to string. `{}` is the usual empty answer.
- APP: one `pbvalueset.ValueSet` (P: value_set/valueset.proto). A map of string to `DataVariant`;
  the variant's `value_type` selects exactly one value field. Readers on both sides test exact
  types, so Int32 versus Int64 versus arrays must match the tables below
  (W: YourPhone.Connectivity.Managed :: ValueSetContentSerializer; A: agents.ypp.valueset.ValueSetSerializerUtility).
  A Bool `false` or a zero number is encoded with `value_type` set and the value field omitted
  (proto3 default) **[wire]** (C-pair: 409, key `IsSampled`).

---

## 3. PLATFORM routes

| Route | Direction seen | Payload | Reply |
|---|---|---|---|
| `/SessionValidation` | PC to phone | `ProtoPlatformSessionValidationRequest` | `ProtoPlatformSessionValidationResponse` |
| `/DeviceResourceManager` | both | `DeviceResourceManagerMessage` | `DeviceResourceManagerResponseMessage` |
| `/Context/Publish` | phone to PC on the wire; PC to phone in code | `MsaepMessage` | JSON `{}` from Windows; none from Android |
| `/Context/Message`, `/Context/Message/<contextSourceId>` | both | `ContextSourceMessage` | JSON `{"processStatus":"Success"}` |
| `/PlatformDisconnectRequest` | PC to phone | JSON `{}` on the wire (C-pair: 184) | not examined |
| `/internal/response` | both | reply to any of the above | none |

Routes the phone subscribes to **[code]**: `/DeviceResourceManager`, `/Context/Publish`,
`/Context/Message`, `/SessionValidation`, `/PlatformDisconnectRequest`,
`/PlatformActivateSessionRequest`, `/CryptoTrustKeyRotation`, `/CryptoTrustKeyRotationCheck`,
`/internal/response` (A: agents.ypp.ambientexperience.deviceresource.signalr.SignalRDeviceResourceManager,
providers.signalr.SignalRContextProvider, contextmanagement.PlatformConnectionSessionResponder,
agents.ypp.signalr.transport.SignalRUserSessionTracker, agents.ypp.authclient.trust.CryptoTrustKeyRotationHandler).

---

## 4. Session start as captured

### 4.1 Reconnect of an already paired pair (C-relay), first 20 seconds

Time is seconds from capture start. `PC>` is PC to phone, `PH>` phone to PC. The hub reported
the partner connected at 2.47 s (C-relay: 11). The DCG session was a continuation: the first
fragment has `SequenceNumber` 34 and `_requestId` "20".

| seq | t | Dir | Route | Correlation | Payload type | Meaning |
|---|---|---|---|---|---|---|
| 13 | 2.47 | PC> | /DeviceResourceManager | req 20 | DRM{type 4, GET, path `/devicestatus`, no payload} | Ask phone status. |
| 22 | 3.11 | PC> | /DeviceResourceManager | req 21 | DRM{type 4, GET, `/clipboard`, `ClipboardRequestMessage{request_type 3 FEATURE_OFF}`} | Tell the phone clipboard sync is off on this PC. |
| 23 | 3.16 | PH> | /DeviceResourceManager | req A (GUID) | DRM{type 4, GET, `/remotedevicestatus`, no payload} | Phone asks for the PC's status. |
| 28 | 3.30 | PH> | /internal/response | orig 20 | DRMResp{`DeviceStatusResponseMessage{status 1 OK, info{...}}`, response_type 1} | Phone status (battery, bluetooth, DND, operator, signal, ringer, wifi, network data type, DND rule). |
| 32 | 3.42 | PC> | /DeviceResourceManager | req 22 | same as seq 22 | Repeated FEATURE_OFF. |
| 33 | 3.44 | PH> | /Context/Publish | req B | `MsaepMessage{tag 4, payload = PubSubPayload{additional = FilesResponsePayload{file_configuration}}}` | Phone files configuration and thumbnail prefetch folders. |
| 37 | 3.52 | PH> | /internal/response | orig 21 | DRMResp{`ClipboardResponseMessage{status 1 OK}`, 1} | Ack of FEATURE_OFF. |
| 41 | 3.79 | PC> | /internal/response | orig B | `text/json` `{}` | Publish acknowledged. |
| 43 | 3.89 | PH> | /internal/response | orig 22 | DRMResp{Clipboard OK, 1} | Ack. |
| 47 | 4.00 | PC> | /DeviceResourceManager | req 23 | DRM{type 2 CAMERA_METADATA, request 4 SYNC, `/camerametadata`, no payload} | Ask phone to publish camera streaming config. |
| 50 | 4.15 | PC> | /DeviceResourceManager | req 24 | DRM{type 4, GET, `/phoneapps?since=2`} | Phone apps delta since sequence 2. |
| 52 | 4.21 | PH> | /Context/Publish | req C | `MsaepMessage{tag 2, payload = PubSubPayload{data = {1:1, 2:1, 3:1}}, versions 1.1}` | Camera streaming configuration (three small integers; P: streaming/v1 `StreamingConfigurationMessage`, **[inferred]** type). |
| 54 | 4.27 | PH> | /internal/response | orig 23 | DRMResp{payload = 13 ASCII bytes `CannotBeEmpty`, 1} | Placeholder body. |
| 59 | 4.37 | PC> | /internal/response | orig C | `{}` | Publish acknowledged. |
| 60 | 4.41 | PH> | /internal/response | orig 24 | DRMResp{`PhoneAppsResponseMessage{status 1, sync metadata "phoneApps" seq 2}`, 1} | Nothing new. |
| 65 | 4.54 | PC> | /DeviceResourceManager | req 25 | DRM{type 5 WALLPAPER, GET, `/wallpaper`, `WallpaperRequestMessage{current_wallpapers[{id 9, type 1}, {id -1, type 2}]}`} | Wallpaper sync with known ids. |
| 68 | 4.69 | PC> | /DeviceResourceManager | req 26 | DRM{type 4, GET, `/appcontext?since=0`} | Task continuity contexts. |
| 71 | 4.83 | PC> | /internal/response | orig A | DRMResp{`DeviceStatusResponseMessage{status 1, info{battery_percent -1, network_type 2}}`, 1} | PC status for the phone UI (no battery, Ethernet). |
| 73 | 4.90 | PH> | /internal/response | orig 26 | DRMResp{`AppContextResponseMessage{status 1, metadata "continuityAppContext"}`, 1} | |
| 77 | 5.15 | PH> | /internal/response | orig 25 | DRMResp{`WallpaperResponseMessage{wallpapers[{id 9, type 1}], status 1}`, 1} | Unchanged, no bytes. |
| 80 | 5.22 | PH> | /DeviceResourceManager | req D | DRM{type 4, GET, `/wallpaper`, no payload} | Phone asks for the PC wallpaper. |
| 82 | 5.32 | PH> | /DeviceResourceManager | req E | DRM{type 4, GET, `/clipboard`, `ClipboardRequestMessage{request_type 5 STATUS, correlation_id 16 hex}`} | Phone asks whether clipboard sync is on. |
| 84 | 5.32 | PC> | /internal/response | orig E | DRMResp{`ClipboardResponseMessage{status 9 FEATURE_OFF, correlation_id echoed}`, 1} | It is off. |
| 88 | 5.49 | PC> | /internal/response | orig D | DRMResp{`WallpaperResponseMessage{wallpapers[{type 1, payload JPEG 329,883 bytes}], status 1}`, 1} | One 330 kB message in a single fragment. |
| 91, 97, 107, 167 | 6.70 ... | PC> | /DeviceResourceManager | req 27 ... | DRM{type 1 FILES_METADATA, request 2 UPDATE, `/filesmetadata`, `FilesUpdateRequest{create_folder_request}`} | Phone-files housekeeping, repeated. |
| 94, 100, 110, 178 | 6.97 ... | PH> | /internal/response | orig 27 ... | DRMResp{files update response with one `FileMetadata`, 1} | |
| 103 | 8.75 | PH> | /Context/Publish | req F | `MsaepMessage{tag 4, PubSubPayload{additional = FilesResponsePayload{file_sync_update{type 2, seq 4}}}}` | Files changed. |
| 104 | 8.76 | PC> | /internal/response | orig F | `{}` | |
| 113, 116 | 9.5 | PH> | /Context/Publish | req G, H | `MsaepMessage{tag 4, ...{storage_info{available, total}}}` | Storage numbers. |
| 114, 119 | 9.5 | PC> | /internal/response | orig G, H | `{}` | |
| 123 to 155 | 10.6 to 12.2 | PC> | /internal/response | orig of earlier and unseen publishes | `{}`, empty trace state | Second acknowledgement of publishes, including five already acknowledged above. **[inferred]** the Phone Link process answering through the shared connection. |
| 158 | 12.31 | PC> | /SessionValidation | req 30 | `ProtoPlatformSessionValidationRequest{platform_capabilities [1]}` | Capability probe (section 5.1). |
| 161 | 12.46 | PC> | /DeviceResourceManager | req 31 | DRM{type 4, GET, `/phone-mirroring/trigger-publish`, no payload} | Ask phone to publish its mirroring context. |
| 162 | 12.53 | PH> | /internal/response | orig 30 | `ProtoPlatformSessionValidationResponse{platform_capabilities [1,2,3], persistent_messaging_channel_version 14, nano_transport_preference_version 3}` | |
| 169 | 12.82 | PH> | /Context/Publish | req I | `MsaepMessage{tag 10, PubSubPayload{additional = ASCII "phone_mirroring_publish_for_context_handle"}}` | Mirroring context handle. |
| 173, 181 | 12.9, 13.1 | PC> | /internal/response | orig I | `{}` twice | |
| 174 | 12.96 | PH> | /internal/response | orig 31 | DRMResp{no payload, response_type 1} | |

### 4.2 First session after a fresh pairing (C-pair: 239 onward)

Same pattern with these additions:

- First message is PC> DRM{type 9 FILE_SHARE, GET, `/fileshare`, payload `{1:1}`} (249), answered `{1:1}` (262).
- PC> DRM{type 6 MEDIA, GET, `/media`, `{1:1}`} (282), answered with three small fields (292).
- PC> DRM{type 1, request 4 SYNC, `/filesmetadata`, `FilesSyncRequest{config_sync_request{}}`} (349).
- A context-source handshake for a peer-to-peer (Nano) connection, scenario
  `CDEH.PhoneFiles.FullSyncToLocalDB`: PC> `/Context/Message` `ContextSourceMessage{cs_initialize_message{context_source_id = phone DCG id, trace_context}}` (279);
  PH> `/Context/Message/<phone DCG id>` `{cs_initialize_ack_message{status 1}}` (284) plus a JSON reply
  `{"processStatus":"Success"}` to the request (285); then `cs_connection_info` messages in both
  directions on `/Context/Message/<sender's own DCG id>` (297, 308 ...).
- APP traffic starts 6.4 s after the first PLATFORM message: PC> `/connect/v1` (409), phone
  pushes `/legacy/phonecontent` items (421 ...), phone answers the connect (459). Section 8.
- `/SessionValidation` appears at +7 s (424), again immediately followed by
  `/phone-mirroring/trigger-publish` (470).
- The phone publishes tag 4 and tag 2 (269, 270) **before** any `/SessionValidation` in that
  session, and the PC sends clipboard FEATURE_OFF 13 times over the capture (340, 374 ...).
- Tag 8 (`DeviceStatus`) publishes appear twice with a 42-byte `additional` body.

### 4.3 What a minimal client must do

**MUST (otherwise requests hang or the peer retries)**

| Item | Why | Evidence |
|---|---|---|
| Send the hub connected call and ACK every DCG fragment | Transport level, outside this document. | claims C0028 |
| Answer every request that carries `_requestId` | The phone waits on a pending-request table per `_requestId`. | A: PlatformMessageManager; W: same |
| For an unknown PLATFORM route, reply `_rejectedReason: NotSubscribedToRoute` | That is what both real clients do. | [code] section 2.3 |
| For `/DeviceResourceManager` with a path we do not serve, reply `DeviceResourceManagerResponseMessage{response_type 2}` with empty payload | Android does exactly this; the requester maps it to `UNSUPPORTED_RESOURCE_TYPE`. | A: SignalRDeviceResourceManager.respondWithNoCallbackErrorAsync |
| Reply `{}` (`text/json`) to each `/Context/Publish` | The phone sends publishes as requests and records the result. | [wire] 41; W: SignalRContextProvider.ProcessIncomingPublishAsync |

**Nothing at PLATFORM level is required for the phone to treat the PC as connected.**
**[code]** The phone starts a user session for a remote DCG client when the hub reports the
partner connected and the id is known in its remote-app store; otherwise the result is
`NO_APP_ID_MAPPING` (A: agents.ypp.signalr.transport.SignalRUserSessionTracker.beginSession).
**[wire]** The phone issued its own first request 0.7 s after the partner-connected event
(C-relay: 11, 23), and in the fresh session it published before any `/SessionValidation`
(C-pair: 269, 424).

**SHOULD**

| Item | Effect if skipped |
|---|---|
| Answer `/remotedevicestatus` with `DeviceStatusResponseMessage{status 1, info{...}}` | **[code]** the LTW home screen asks for clipboard STATUS only after this round trip returns success (A: com.microsoft.appmanager.homepage.viewmodel.HomepageViewModel; homepage.domain.SyncRemoteDeviceStatusUseCase; agents.remotedevicestatus.RemoteDeviceStatusSyncManager). The phone still learns the state from a FEATURE_ON request, so this is not strictly required. |
| Answer `/wallpaper` from the phone | Cosmetic. `response_type 2` is acceptable. |

**Optional features (each independent)**

| Messages | Feature |
|---|---|
| `/SessionValidation` | Only needed by a client that itself opens context sources or publishes through Microsoft's SDK rules (section 5.1). The phone answers it but never demands it. |
| `/devicestatus` | Phone status tiles. |
| `/clipboard` + publish tag 9 | Clipboard, section 6. |
| `/connect/v1`, `/legacy/phonecontent`, `/notifications` | Phone Link content, notifications. Sections 7 and 8. |
| `/phoneapps`, `/appcontext`, `/wallpaper`, `/media`, `/filesmetadata`, `/fileshare`, `/camerametadata`, `/phone-mirroring/trigger-publish`, `/Context/Message` | Apps list, task continuity, wallpaper, media, phone files, file share, camera, mirroring, Nano. Not needed for clipboard or notifications. |

---

## 5. Platform building blocks

### 5.1 Session validation

P: platform_sdk/v1/session_validation.proto.

| Message | Fields |
|---|---|
| `ProtoPlatformSessionValidationRequest` | 1 `platform_capabilities` repeated enum (packed) |
| `ProtoPlatformSessionValidationResponse` | 1 `platform_capabilities`, 2 `persistent_messaging_channel_version` int32, 3 `nano_transport_preference_version` int32 |

`ProtoPlatformCapabilities`: 0 UNSPECIFIED, 1 SESSION_VALIDATION, 2 PERSISTENT_MESSAGE_CHANNEL, 3 NANO_TRANSPORT_PREFERENCE.

- **[wire]** Windows sent `[1]` only; phone answered `[1,2,3]`, 14, 3 (C-relay: 158, 162).
- **[code]** Windows always lists SESSION_VALIDATION and adds 3 or 2 when the local settings
  `EnableNanoTransportPreference` or `EnableNanoOffloadPhase1` are on
  (W: YourPhone.YPP.PlatformSdk :: Utils.PlatformCapabilitiesProvider.LocalCapabilities).
- **[code]** The phone answers with constants 14 and 3 and its own capability list; an empty or
  non-binary request gets an empty payload (A: ...contextmanagement.PlatformConnectionSessionResponder).
- **[code]** Windows treats a missing SESSION_VALIDATION in the answer, an empty answer, a
  timeout mapped to `NoResponse`, `RemoteVersionTooLow` or `RemoteNotSubscribedToRoute` as
  "session validation not supported". Minimum versions it accepts: persistent channel 14, nano
  preference 3 (W: YourPhone.YPP :: ConnectionManagement.Session.PlatformConnectionSessionValidator).
- **[code]** In Phone Link's SDK a successful validation is the precondition for creating the
  "context source" of a connection, and a context source is required both before it publishes
  and before it delivers an incoming publish to subscribers
  (W: YourPhone.YPP :: SignalR.Context.SignalRContextProvider.TryPublishToCandidateAsync, ProcessIncomingPublishAsync; SignalRContextSourceManager).
  This is a rule inside the Windows SDK, not something the phone enforces.

### 5.2 DeviceResourceManager (DRM)

P: platform_sdk/v1/device_resource_manager.proto.

Request `DeviceResourceManagerMessage`

| # | Field | Type | Notes |
|---|---|---|---|
| 1 | `resource_type` | enum `ProtoDeviceResourceType` | Deprecated selector. 4 (`UNKNOWN`) whenever the path selects the handler. |
| 2 | `request_type` | enum `ProtoDeviceResourceRequestType` | 1 GET, 2 UPDATE, 3 DELETE, 4 SYNC (0 unspecified). |
| 3 | `payload` | bytes | Resource-specific protobuf; may be absent. |
| 4 | `resource_path` | string | Relative URI, optional query (`/phoneapps?since=2`). |

`ProtoDeviceResourceType`: 0 UNSPECIFIED, 1 FILES_METADATA, 2 CAMERA_METADATA, 3 PERMISSIONS,
4 UNKNOWN, 5 WALLPAPER, 6 MEDIA, 7 RING_MY_PHONE, 8 LOCK_MY_PC, 9 FILE_SHARE, 10 REMOTE_CONTROL.

Response `DeviceResourceManagerResponseMessage`

| # | Field | Type | Notes |
|---|---|---|---|
| 1 | `payload` | bytes | Resource-specific protobuf. |
| 2 | `response_type` | optional enum | 1 SUCCESS, 2 RESOURCE_HANDLER_NOT_REGISTERED (0 unspecified). |

Rules **[code]**

- Handler lookup uses the path up to the first `?`. If `resource_path` is empty the path is
  `"/" + lowercase(resource type name)` (W: SignalRDeviceResourceProvider.ParseIncomingRequest;
  A: SignalRDeviceResourceManager.parseIncomingRequest).
- A caller that passes only a path sends `resource_type` UNKNOWN (W: DeviceResourceManager.SendRequestAsync;
  A: SignalRDeviceResourceManager, constant `DeviceResourceType.UNKNOWN`). **[wire]** some CDEH
  requests still set the legacy type (2, 5, 6, 9, 1) together with the path.
- The response always goes to `/internal/response` with `_originalRequestId`, content type
  `application/x-binary` (W: SignalRDeviceResourceResponseHandler).
- No handler: Android answers `response_type` 2 with empty payload; Phone Link answers nothing
  (section 1).
- Caller-side status mapping: `response_type` 2 gives `UnsupportedResourceType`; unparseable
  response gives `BadRequest` (Windows) or `INVALID_PROTOCOL_BUFFER` (Android); platform rejection
  `NotSubscribedToRoute` gives `UnsupportedResourceType`; reply timeout gives `ResponseTimeout`
  (W: DeviceResourceManagerUtils, DeviceResourceProviderBase).
- The phone only sends a DRM request to a DCG client that currently has a user session, else
  `PEER_UNREACHABLE` (A: SignalRDeviceResourceManager.sendRequestAsyncInternal).

Resource paths

| Path | Served by | Requests seen or coded | Inner payload types |
|---|---|---|---|
| `/clipboard` | both | GET (SYNC also accepted by the phone) | `ClipboardRequestMessage` / `ClipboardResponseMessage` (P: clipboard/v1/clipboard.proto) |
| `/notifications` | phone | GET | `NotificationsRequestMessage` / `NotificationsResponseMessage` (P: notification/v1/notification.proto), section 7.7 |
| `/devicestatus` | phone | GET, empty payload or `DeviceStatusRequestMessage` | `DeviceStatusResponseMessage` (P: device_info/v1/status.proto) |
| `/remotedevicestatus` | PC | GET, empty | `DeviceStatusResponseMessage` |
| `/wallpaper` | both | GET | `WallpaperRequestMessage` / `WallpaperResponseMessage` (P: device_info/v1/wallpaper.proto) |
| `/phoneapps`, `/appcontext` | phone | GET with `?since=<seq>` | P: phoneapps/v1, continuity/v1 |
| `/filesmetadata` | phone | SYNC, UPDATE | P: phone_files/v1 |
| `/media`, `/image`, `/contacts`, `/messages`, `/permissions`, `/hotspot`, `/ringmyphone`, `/remotecontrol`, `/camerametadata`, `/fileshare`, `/phone-mirroring/trigger-publish` | phone | various | other protos; out of scope |
| `/fileshare_android2cdeh_phase1` | PC | from phone | out of scope |
| `/fileTransfer` | PC (Phone Link) | from phone | W: YourPhone.SharedContent.Managed :: FileTransferApplicationService |

Phone-side list from A: every class implementing `IDeviceResourceManagerRequestHandler.getResourcePath`
and every subclass of `agents.transport.BaseDeviceResourceRequest`.

### 5.3 Publish / subscribe (MSAEP over the relay)

P: platform_sdk/v1/msaep_message.proto, pub_sub_payload.proto.

`MsaepMessage`

| # | Field | Value |
|---|---|---|
| 1 | `message_tag` int32 | Feature tag, table below. |
| 2 | `dcg_client_id` string | The **publisher's own** DCG client id. |
| 3 | `message_id` string | Fresh GUID per publish. Subscribers drop a message whose id equals the last one they delivered (A: ...subscribe.SubscriptionProviderObserver.onSubscribeNext). |
| 4 | `payload` bytes | Serialized `PubSubPayload`. |
| 5, 6 | `platform_major_version`, `platform_minor_version` | 1 and 1 (W: YourPhone.YPP.PlatformSdk :: Helper.ContextPayloadProtocolHelper.GenerateMsaepMessage; **[wire]** C-relay: 52). |

`PubSubPayload`: 1 `data` bytes, 2 `additional` bytes.

Message tags

| Tag | Windows name (W: YourPhone.Contracts.Connectivity.YPP :: MsaepMessageTag) | Android name (A: agents.ambientexperience.MsAepMessageTag) | Seen on wire |
|---|---|---|---|
| 1 | ProximalOnboarding | ProximalOnboarding | no |
| 2 | CameraStreaming | PhoneAsWebcam | yes, phone to PC |
| 3 | PermissionSyncResponse | PermissionSyncResponse | no |
| 4 | PhoneFiles | PhoneFiles | yes, phone to PC |
| 5 | Wallpaper | Wallpaper | no |
| 6 | Media | Media | no |
| 7 | ContentUpdate | ContentChange | no |
| 8 | DeviceStatus | DeviceStatus | yes (C-pair), phone to PC |
| 9 | Clipboard | Clipboard | no |
| 10 | PhoneMirroring | PhoneMirroring | yes, phone to PC |
| 11 | (absent) | Hotspot | no |

Field usage by direction

| Direction | Field carrying the feature message | Evidence |
|---|---|---|
| Phone to PC, generic cloud publisher | `additional` | **[code]** A: agents.transport.BaseCloudPublisher (`setAdditional`). **[wire]** tags 4, 8, 10. |
| Phone to PC, camera (tag 2) | `data` | **[wire]** C-relay: 52. **[code]** A: agents.camera.transport.CameraStreamingResourceRequestHandler sets either field. |
| PC to phone, clipboard (tag 9) | `data` | **[code]** the phone's only cloud subscriber reads `getData()` (A: agents.clipboard.platform.ClipboardSubscriptionObserver.onSubscribeNextInternal). Not on the wire. X: clipboard.md agrees. |

Mechanics

- A publish is a PLATFORM **request** on `/Context/Publish`, content type `application/x-binary`,
  sent to every partner with a session (A: SignalRContextProvider.publishAsync; W: SignalRContextProvider.PublishInnerAsync).
- Windows sends it one-way: it does not wait for a reply (`PlatformRequestOptions.OneWay`,
  W: SignalRContextProvider.PublishToAvailableCandidateAsync).
- Windows answers an incoming publish with `/internal/response`, `text/json`, `{}`
  (W: SignalRContextProvider.ProcessIncomingPublishAsync; **[wire]** C-relay: 41).
- Android does not answer an incoming publish (A: SignalRContextProvider.initializeProvider handler returns without a response).
- There is no subscribe message on the wire. Subscription is local: a subscriber registers a tag
  and receives every incoming publish with that tag (A and W: `subscribeAsync` only stores the observer).
  The phone's clipboard subscriber uses trust filter `MY_DEVICES`, TTL zero (never expires),
  type `CLOUD` (A: agents.clipboard.platform.ClipboardContextSubscriber).
- No size limit on the relay provider (`getPayloadMaximumSize` returns `Integer.MAX_VALUE`). The
  180-byte limit, AES-CBC and CMAC code in `MsaepProtocolHelper` belongs to the Bluetooth LE
  provider only.

### 5.4 Manifests and capability manifests

`ProtoManifest`, `ProtoManifestEntry`, `ProtoManifestAck` and `CapabilitiesManifestMessage`
(P: platform_sdk/v1/manifest.proto, capabilities_manifest.proto) are used only inside
named-streams channels of the peer-to-peer transport
(W: YourPhone.YPP.PlatformSdk :: Transport.Channel.NamedStreams.NamedStreamsChannel; A: ...transport.channel.namedstreams.NamedStreamsChannel).
They are not exchanged over the relay and play no part in clipboard or notifications. The
"capabilities" that matter for these two features are the DCG device-info strings (section 1)
and the value-set bitmasks in the `/connect/v1` reply (section 8.3).

### 5.5 Device status payloads

P: device_info/v1/status.proto. `DeviceStatusResponseMessage{1 status, 2 info}`; status 1 = OK.
`DeviceStatus` fields: 1 battery_percent, 2 battery_charging, 3 battery_power_save,
4 bluetooth_state, 5 do_not_disturb_status, 6 network_operator, 7 network_signal_strength,
8 network_signal_strength_max, 9 mobile_data_status, 10 ringer_mode, 11 wifi_signal_level,
12 wifi_state, 13 network_data_type, 14 sync_over_metered_connection, 15 airplane_mode,
16 network_type (1 WIFI, 2 ETHERNET, 3 CELLULAR), 17 is_connection_metered,
18 do_not_disturb_rule_enabled.

For `/remotedevicestatus` the Windows PC answered `info{battery_percent = -1, network_type = 2}`
**[wire]** (C-relay: 71). **[inferred]** -1 means "no battery".

---

## 6. Clipboard

Two unrelated mechanisms exist. The phone picks one per PC.

| | Cross-device clipboard | Legacy clipboard |
|---|---|---|
| Peer | WEA client (CDEH) | PL client (Phone Link) |
| Transport | PLATFORM: DRM `/clipboard` + publish tag 9 | APP: route `/clipboard`, value sets |
| Gate | DCG capability string `CLIPBOARD` on the WEA device, then FEATURE_ON | `configuration.ContentTransferCopyPaste` in `/connect/v1` |

Selection **[code]** (A: agents.clipboard.ClipboardEnablementProvider.evaluateClipboardSupport):

1. Phone has no clipboard listener support: `NOT_SUPPORTED`. Listener support is an OEM
   integration, not stock Android: Samsung `ClipboardRedirector` or a generic OEM
   `copyAndPaste` feature (A: com.microsoft.appmanager.ext.clipboard.ExtClipboardManagerBroker,
   extgeneric.clipboard.ExtGenericClipboardManagerBroker; the base broker returns false).
2. The PL remote app has no WEA sibling (same `distinguishedDeviceId`): `LEGACY_PROVIDED`.
3. The WEA sibling's server-side capability list contains `CLIPBOARD`: `CROSS_DEVICE_CAPABLE`,
   otherwise `LEGACY_PROVIDED`.

The capability list comes from DCG device metadata, cached per DCG client id
(A: agents.ypp.devicemanagement.provider.PeerDeviceCapabilitiesProvider; com.microsoft.appmanager.capabilities.FeatureCapabilityProvider keys `<id>_capable_on_remote_device`).

**[wire]** The phone told Phone Link `capabilities.contentTransfer = 6`, i.e. DragAndDrop (2) +
CopyPasteMigrated (4), no CopyPaste (1) bit, and Phone Link sent `ContentTransferCopyPaste = false`
(C-pair: 459, 409). So on a current Windows pair the legacy path is switched off and CDEH owns
the clipboard.

### 6.1 Messages (cross-device)

P: clipboard/v1/clipboard.proto.

`ClipboardRequestMessage`: 1 `request_type`, 2 `correlation_id` string.

| `ClipboardRequestType` | Value |
|---|---|
| UNSPECIFIED | 0 |
| CONTENT | 1 |
| FEATURE_ON | 2 |
| FEATURE_OFF | 3 |
| FEATURE_DISABLE | 4 |
| STATUS | 5 |

`ClipboardResponseMessage`: 1 `clipboard_item` repeated, 2 `status`, 3 `correlation_id`,
4 `error_type`, 5 `error_detail` string.

| `ClipboardResponseStatus` | Value | Used as |
|---|---|---|
| UNSPECIFIED | 0 | |
| OK | 1 | Success of CONTENT (with one item) or of a FEATURE_* request (no item). |
| INVALID_DEVICE_RESOURCE_REQUEST_TYPE | 2 | DRM request type was not GET or SYNC. |
| INVALID_DEVICE_RESOURCE_REQUEST_PATH | 3 | Defined, not produced by the phone. |
| INVALID_CLIPBOARD_REQUEST_TYPE | 4 | Unknown `request_type` (the phone's handler also lands here for STATUS, see 6.5). |
| UNRECOGNIZED_PAYLOAD | 5 | Request bytes did not parse. |
| CLIPBOARD_CHANGE | 6 | Publish body: "my clipboard changed". |
| INVALID_CONTENT | 7 | CONTENT could not be served; see `error_type`, `error_detail`. |
| FEATURE_ON | 8 | STATUS answer or publish body. |
| FEATURE_OFF | 9 | STATUS answer or publish body. |
| FEATURE_DISABLE | 10 | STATUS answer or publish body. |

`ClipboardErrorType`: 0 UNSPECIFIED, 1 REJECT, 2 FAIL.

`ClipboardItem`: 1 `item_type`, 2 `text` optional string, 3 `image_bytes` optional bytes,
4 `created_time` `google.protobuf.Timestamp` (seconds, nanos).

`ClipboardItemType`: 0 UNSPECIFIED, 1 IMAGE, 2 TEXT_PLAIN, 3 TEXT_HTML.

DRM wrapper for every clipboard request: `resource_type` 4, `request_type` 1 (GET),
`resource_path` `/clipboard`, `payload` = `ClipboardRequestMessage` **[wire]** (C-relay: 22, 82).

### 6.2 Feature state

The phone keeps, per PC DCG client id, a persisted "enabled on remote device" flag for the
feature name `CLIPBOARD` (A: FeatureCapabilityProvider key `<id>_enabled_on_remote_device`;
agents.clipboard.platform.ClipboardPeerDeviceStatusUpdater). It attaches its system clipboard
listener only while at least one **active WEA** remote app has that flag set, or the legacy
flag is set (A: agents.clipboard.ClipboardListenerManager.isFeatureEnabledOnPeerDevice).

Ways the flag changes **[code]**

| Event received by the phone | Effect |
|---|---|
| DRM request `FEATURE_ON` | flag on; reply `{status OK}` |
| DRM request `FEATURE_OFF` | flag off; reply `{status OK}`. The method also touches the clipboard history store, but that part did not decompile cleanly. |
| DRM request `FEATURE_DISABLE` | flag off; reply `{status OK}` |
| DRM request `CONTENT` | flag on (implicit), then content reply |
| Reply to the phone's `STATUS`: `FEATURE_ON` / `FEATURE_OFF` / `FEATURE_DISABLE` | on / off / off |
| Reply to the phone's `CONTENT`: `FEATURE_OFF` / `FEATURE_DISABLE` | off |
| Publish tag 9 with status `FEATURE_ON` / `FEATURE_OFF` / `FEATURE_DISABLE` | on / off / off |

Sources: A: ClipboardResourceRequestHandler.handleRequestInternal; ClipboardRequestManager.handleStatusRequestResult, handleContentRequestResponse; ClipboardSubscriptionObserver.onSubscribeNextInternal.

Observed on the wire (feature off on the PC)

- PC> DRM `/clipboard` `{request_type 3}`; PH> `{status 1}` (C-relay: 22 and 37, repeated 32 and 43).
  Trace scenario `CDEH.Clipboard.SyncFeatureEnable`, trigger `DeviceStatusUpdate`: CDEH re-sends
  its state after device-status updates. No correlation id in this request.
- PH> DRM `/clipboard` `{request_type 5, correlation_id}`; PC> `{status 9, correlation_id}`
  (C-relay: 82 and 84). Trace scenario `clipboard` / `requestStatus`. The phone sends this from
  its home screen after a successful `/remotedevicestatus` round trip, with the UI trace's
  correlation id (16 hex characters on the wire).

What the PC should do at session start to enable sync **[inferred from the above]**: send
`FEATURE_ON` (expect `{status 1}`), and answer any `STATUS` with `FEATURE_ON` echoing the
correlation id. X: clipboard.md reports this working live.

### 6.3 PC copies, phone receives

```
PC  --/Context/Publish-->  phone   MsaepMessage{tag 9, dcg_client_id = PC id, message_id = new GUID,
                                    payload = PubSubPayload{data = ClipboardResponseMessage{
                                        status 6 CLIPBOARD_CHANGE, correlation_id = C}}, versions 1.1}
phone --/DeviceResourceManager--> PC   (only if the enabled flag is off, "double check")
                                    ClipboardRequestMessage{request_type 5 STATUS, correlation_id = C}
PC  --/internal/response--> phone   ClipboardResponseMessage{status 8 FEATURE_ON, correlation_id = C}
phone --/DeviceResourceManager--> PC   ClipboardRequestMessage{request_type 1 CONTENT, correlation_id = C}
PC  --/internal/response--> phone   ClipboardResponseMessage{status 1 OK, correlation_id = C,
                                        clipboard_item = [exactly one item]}
```

**[code]** A: ClipboardSubscriptionObserver.handleClipboardChangeMessageInternal; ClipboardRequestManager.requestClipboardStatus, requestClipboardContent; agents.clipboard.ClipboardPasteHandler.handleToPhonePaste.
X: clipboard.md saw both variants (with and without the STATUS step).

Rules the phone applies to the CONTENT answer

| Condition | Result |
|---|---|
| `response_type` not SUCCESS or DRM failure | paste rejected with the DRM status |
| status 1 and `clipboard_item` count != 1 | failure `InvalidContentSize` |
| item type UNSPECIFIED | failure `UnspecifiedType` |
| status 9 or 10 | enabled flag turned off, nothing pasted |
| status 7 | logged as reject, or as fail when `error_type` = FAIL; `error_detail` is the reason string |
| any other status | failure `InvalidResponseStatus` |

Item handling on the phone

| `item_type` | Field used | Phone behaviour |
|---|---|---|
| TEXT_PLAIN (2) | `text` | Clip with MIME `text/plain`. |
| TEXT_HTML (3) | `text` = HTML | `ClipData.newHtmlText`; plain text derived on the phone with `Html.fromHtml`. Only one string is sent. |
| IMAGE (1) | `image_bytes` | Saved to the phone's clipboard history, exposed through a content URI labelled `image/png`, clip label "Image from PC". |

- An item with empty `image_bytes` and empty `text` is not stored (A: ClipboardPasteHandler.toHistoryItem).
- `created_time` is converted to milliseconds for history and timing telemetry.
- **[inferred]** send PNG for images, since the phone labels the bytes `image/png` without inspecting them.
- No size check on incoming content was found in the phone code. Use the phone's own outgoing
  limits (6.4) as the safe envelope. X: clipboard.md keeps PC images within 1 MiB.
- The phone marks clips it sets itself with a `PersistableBundle` extra keyed by its package
  name, and ignores clipboard-changed events for clips carrying that mark, so a paste from the
  PC is not echoed back (A: ClipboardPasteHandler.copyToClipboard; ClipboardEventSubscriber.onPrimaryClipChanged "IgnoreSelfUpdate").

### 6.4 Phone copies, PC receives

```
phone --/Context/Publish--> PC   MsaepMessage{tag 9, dcg_client_id = phone id, message_id = GUID,
                                  payload = PubSubPayload{additional = ClipboardResponseMessage{
                                      status 6, correlation_id = T}}}
PC  --/internal/response--> phone   {} (text/json)
PC  --/DeviceResourceManager--> phone   ClipboardRequestMessage{request_type 1 CONTENT, correlation_id = T}
phone --/internal/response--> PC   ClipboardResponseMessage{status 1, correlation_id = T, clipboard_item[1]}
                                    or {status 7 INVALID_CONTENT, correlation_id = T, error_type, error_detail}
```

**[code]** A: ClipboardEventSubscriber.onPrimaryClipChanged; agents.clipboard.platform.ClipboardPublisher; ClipboardResourceRequestHandler.handleContentRequest; ClipboardMessageBuilder.createCopyResponseContentMessage.

- `T` is the trace id of the phone's copy event (32 hex characters, **[inferred]** from the trace
  id format). The answer's `correlation_id` is whatever the PC sent in the CONTENT request.
- The phone does **not** check that the requested correlation id matches a publication. A
  CONTENT request always returns the phone's *current* primary clip. A PC may therefore pull
  the clipboard at any time while the feature is on.
- Before publishing the phone drops the event when: no clip or no description
  (`NoClipData`, `NoClipDescription`), self-set clip (`IgnoreSelfUpdate`), same clip timestamp as
  the previous event (`DuplicateTimestamp`), or no supported MIME type (`MimeTypeNotSupport`).
- Supported MIME types (A: agents.clipboard.ClipboardConstants.SUPPORTED_MIME_TYPES): `image/bmp`,
  `image/gif`, `image/jpeg`, `image/png`, `image/svg+xml`, `image/tiff`, `image/webp`,
  `image/x-ms-bmp`, `text/css`, `text/csv`, `text/html`, `text/plain`, `text/richtext`,
  `text/sgml`, `text/yaml`.

Content the phone returns

| Clip | Item |
|---|---|
| `text/html` | type 3, `text` = the clip's HTML text |
| any other `text/*` | type 2, `text` = the clip's text |
| `image/*` | type 1, `image_bytes` |

- Exactly one item, chosen as the first supported MIME type of the clip.
- Text limit: a string of 131072 UTF-16 code units or more is refused with status 7,
  `error_type` REJECT, `error_detail` `SizeExceed`.
- Images: the file bytes are sent unchanged (JPEG, PNG, GIF, BMP ...) when the file is at most
  1,048,576 bytes; `image/webp` is re-encoded to PNG; a larger image is scaled by
  `sqrt(1048576 / size)` in each dimension and re-encoded as JPEG quality 97
  (A: agents.clipboard.ClipboardUtility.getImageBytes, getScaledImageBytes). The receiver must
  sniff the image format.
- `created_time` is the phone's stored timestamp in seconds and nanoseconds.

Error details the phone can return with status 7: `NoClipData` (REJECT), `MimeTypeNotSupport`
(REJECT), `SizeExceed` (REJECT), `SecurityException` (REJECT), `GetImageDataFailed` (FAIL),
`ExtractDataFailed` (FAIL, default).

### 6.5 Other error answers from the phone

| Situation | Answer |
|---|---|
| DRM `request_type` not GET or SYNC | `{status 2}` |
| Payload does not parse | `{status 5}` |
| `request_type` not CONTENT / FEATURE_ON / FEATURE_OFF / FEATURE_DISABLE | `{status 4, correlation_id echoed}` |

A: ClipboardResourceRequestHandler. Note that STATUS is not in the phone handler's switch: a PC
that sends STATUS to this phone build gets status 4. **[inferred]** STATUS is a phone-to-PC
question only.

### 6.6 What the PC must advertise for cross-device clipboard

| Requirement | Evidence |
|---|---|
| The PC's DCG device metadata has `clientType` `WEA` and `capabilities` containing `CLIPBOARD` | **[wire]** C-pair: 192; **[code]** 6 selection rule, and `isCrossDeviceClipboardEnabledOnConnectedDevice` iterates WEA remote apps only |
| That DCG client has an active session with the phone | **[code]** ClipboardListenerManager |
| Phone is told the feature is on (FEATURE_ON request, STATUS answer or publish) | **[code]** 6.2 |
| Phone model supports the clipboard redirector | **[code]** 6 selection rule 1 |

Phone Link itself only uses the phone's `CLIPBOARD` string to show a settings link
(W: YourPhone.Settings.Managed :: CrossDeviceFeaturesSettingsGroupProvider).

### 6.7 Legacy clipboard (Phone Link path)

Kept for completeness; inactive whenever the WEA sibling advertises `CLIPBOARD`.

Enablement **[code]**

- Phone reports `capabilities.contentTransfer` bit 1 (CopyPaste) only when it chose
  `LEGACY_PROVIDED`; bit 4 (CopyPasteMigrated) when `CROSS_DEVICE_CAPABLE`; bit 2 for drag and
  drop (A: com.microsoft.mmx.screenmirroringsrc.dragdrop.DefaultContentTransferCapabilitySource;
  W: YourPhone.AppCore.Managed :: ContentTransferCapabilities).
- Phone Link enables it when phone `contractVersion` >= 3.87, Android SDK >= 29, CopyPaste bit
  set, and the user's PC-side toggle is on; it then sends `configuration.ContentTransferCopyPaste = true`
  (W: YourPhone.ScreenMirroring.Managed :: RemotingFeatureUtils.IsContentTransferCopyPasteEnabled; Sync.PhoneAppsEstablishConnectionPayload).
- The phone stores that flag (preference `pcContentTransferCopyPasteSupported`) and listens to
  its clipboard (A: ConnectionRequestHandler.processPartnerConfiguration; LegacyClipboardConfigStoreImpl).

PC to phone: APP request on route `/clipboard` (W: ClipboardManagerApplicationService; Communication.ClipboardPhoneRequest)

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `PCPhoneCopy` |
| `correlationVector` | String | request correlation id |
| `mimetypes` | StringArray | `["text/plain"]`, `["text/html","text/plain"]` (plain part only when phone `contractVersion` >= 3.95), or `["image/png"]` |
| `data` | StringArray | one string per text MIME type, same order; omitted for images |
| `image_bytes` | UInt8Array | PNG; Windows limits it to 840,000 bytes (`MaxImageSizeInBytes`) |
| common legacy keys | | `isuserinitiated`, `ignoreResponse`, `transportType` 0, `displayName`, `appVersion`, `installationId`, `contractVersion` |

Phone answers `{result 0, contractVersion}` in every case, including when the legacy path is
not enabled (A: agents.clipboard.transport.ContentTransferClipboardRequestHandler).

Phone to PC: `/legacy/phonecontent` with `contentType` `copypaste_metadata`
(A: agents.clipboard.transport.ContentTransferClipboardMessage; agents.MediaType.COPY_METADATA)

| Key | Type | Value |
|---|---|---|
| `mimetypes` | StringArray | MIME types of the items sent |
| `data` | StringArray | text values (each at most 131072 characters) |
| `image_bytes` | UInt8Array | image, same 1 MiB rule as 6.4 |
| `label` | String | clip label, optional |
| `correlationVector` | String | |

Windows answers `{result 0}`, or an empty value set when its copy-paste feature is off
(W: YourPhone.ScreenMirroring.Managed :: Processors.ClipboardProcessor.ProcessItem).

---

## 7. Notifications

All of this section is **[code]**. Android side: `agents.notifications.*`,
`agents.PhoneNotificationsListenerService`. Windows side: `YourPhone.Notifications.Managed`,
`YourPhone.Connectivity.Managed`.

### 7.1 Overview

- Push: phone to PC on APP route `/legacy/phonecontent`, `contentType` `notifications`, three
  parallel arrays. Each notification is a JSON document in a string.
- Commands: PC to phone on APP route `/notifications` (dismiss, clear, reconcile, launch,
  action, inline reply), `/command/audio` (media keys), `/settings` (per-app toggles),
  `/permission` (ask for listener access).
- There are no sequence numbers, checksums or sync ids for notifications. Reconciliation is
  always initiated by the PC with operation 3.

### 7.2 Phone to PC push

Request value set (A: notifications.messenger.PhoneNotificationsMessageBuilder; agents.sync.KvpMessageHelpers)

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `notifications` |
| `contractVersion` | Double | 3.99 |
| `correlationVector` | String | Random for incremental pushes; equal to the PC's `correlationVector` for a reconcile answer. |
| `installationId` | String | Phone install id. |
| `displayName` | String | Phone name. |
| `dedupeID` | String | Always empty. |
| `retryCount` | Int32 | 0 |
| `incremental` | Int32 | Always 1, also for reconcile answers. Windows never reads it. |
| `notificationKeys` | StringArray | Android `StatusBarNotification` key per entry. |
| `operations` | Int32Array | Operation code per entry. |
| `notifications` | StringArray | JSON document per entry, or `""` when the operation carries none. |
| status keys | various | `batteryPercent`, `batteryCharging`, `wifiState` ... when the PC enabled `BatteryIndicator` / `DeviceIndicators` in `/connect/v1`. |

The three arrays have equal length. Windows requires exactly these variant types and equal
lengths; otherwise it processes nothing and answers with an empty value set
(W: Processors.PhoneNotificationsProcessor.ProcessItem).

Operation codes in `operations`

| Code | Name (both sides) | Emitted by phone | PC action |
|---|---|---|---|
| 0 | Unknown | no | ignored |
| 1 | NewNotification | new **or updated** notification, with JSON | upsert by key; eligible for a toast |
| 2 | RemoveNotification | removal, JSON is `""` | delete by key, drop queued requests for that key |
| 3 | ExistingNotification | only inside reconcile answers, with JSON | upsert, no toast |
| 4 | ClearAllNotifications | never | used only as a PC request code |
| 5 | LaunchNotification (Windows name) | never | used only as a PC request code |
| 6 | MediaCommand / ControlNotificationMedia | never | unused on this route |
| 7 | SessionChange (Windows only) | never by Android | iOS path |

W: YourPhone.Contracts.Notifications :: PhoneNotificationOperationType; A: notifications.models.PhoneNotificationOperationType.

Two identical JSON strings in one batch make the Windows processor throw and answer `result 1`.

PC reply on `/internal/response`

| Case | Value set |
|---|---|
| Processed | `result` Int32 0 (and header `result: 0`) |
| Exception | `result` 1, `message` String |
| Bad shape | empty |
| Payload has key `metadata` (not used by Android for notifications) | `correlationVector`, `contentType` `notifications`, `contractVersion` Double 3.99, `itemCount` Int32, `result` 0 |

Generic gate results Windows can return before processing (W: YourPhone.Connectivity.Managed :: PhoneContentHandler.HandleAsync):
13 all features disabled, 1 blocked, 19 no device or PC session locked, 3 incompatible contract version.

How the phone reads the reply (A: agents.sync.SyncSequence.handleSendResult): only `result`.
0 success; missing reads as 24; 19 makes the phone end all user sessions with that PC; 16 and
17 end the sync; anything else is a failed attempt.

### 7.3 Notification JSON

Producer: A: notifications.models.NotificationItem.toJson (org.json; a null value means the key
is absent). Consumer: W: YourPhone.Notifications.Managed :: Adapters.AndroidNotificationEntityAdapter, ViewModels.PhoneNotification.

| Key | JSON type | Presence | Meaning | Read by Windows |
|---|---|---|---|---|
| `key` | string | always | Android notification key; identity in every command | yes, required |
| `id` | number | always | `sbn.getId()` | no |
| `tag` | string | optional | `sbn.getTag()` | no |
| `groupKey` | string | always | | no |
| `packageName` | string | always | | yes, required |
| `appName` | string | always (may be empty) | App label | yes |
| `publisherWebsite` | string | optional | Sanitized publisher URL | yes |
| `postTime` | number, ms | always | `sbn.getPostTime()`; echoed in reconcile | yes, required |
| `timestamp` | number, ms | always | `Notification.when` | yes |
| `isClearable`, `isGroup`, `isOngoing` | bool | always | | no |
| `flags` | number | always | Raw `Notification.flags` | bit 8 (only alert once) |
| `priority`, `eventCount` | number | always | | no |
| `importance` | number | operation 1 only | Channel importance 0 to 5 | yes; at or below 2 suppresses the toast |
| `category` | string | optional | | no |
| `tickerText` | string | optional | | no |
| `featureFlags` | number | always | Constant 3 | bit 2 = launch on phone supported |
| `platform` | number | always | Constant 0 (Android) | yes |
| `version` | string | always | Android API level as decimal string | presence only |
| `notificationClass` | number | always | 3 default dialer package, 1 default SMS package, 2 media style, 0 other | yes |
| `template` | string | optional | Android style class name | substring tests `$BigTextStyle`, `$InboxStyle`, `$MessagingStyle` |
| `title`, `text` | string | optional | | yes |
| `bigTitle`, `bigText` | string | optional | | yes, for BigTextStyle |
| `subText`, `infoText`, `conversationTitle` | string | optional | | no |
| `textLines` | array of string | optional | InboxStyle lines | yes |
| `messages` | array of string | optional | MessagingStyle texts | yes (last 7) |
| `senderNames` | array of string | with `messages`, same length | | yes |
| `showWhen` | bool | optional | | no |
| `notificationActions` | array of object | when the notification has actions | see below | yes |
| `playbackState` | number | media notifications with audio sync on | Android playback state | yes |
| `largeIcon`, `smallIcon` | string | media notifications only | Base64 (no line wraps) of a JPEG, quality 97 | yes |

`notificationActions` element: `actionName` string, `isActionInlineReply` bool (the action has
a free-form remote input), `actionIndex` number (index into the Android actions array; gaps
are possible). Windows uses the first inline-reply action as the reply box and at most 3 other
actions (W: NotificationsConstants.MaxActionCount).

Windows also reads `subtitle` and `isReadOnlyGroupMessage`; Android never writes them.

Icons: ordinary notifications carry none. Windows takes the app icon and name from the phone
apps sync by `packageName` (W: Toasts.PhoneNotificationsToastHelper.GetAppIconImagePathAsync).
Inline icons exist only for media-style notifications; the bitmap is downscaled when it exceeds
716,800 bytes (A: com.microsoft.appmanager.utils.FileUtils).

Not in the schema at all: pictures, people, channel id, remote-input labels or choices.

### 7.4 Incremental versus reconcile

Incremental (A: PhoneNotificationsListenerService; notifications.messenger.PhoneNotificationDispatcher, PhoneNotificationsSender)

- Posted or updated: operation 1 if the publish filter passes. Removed: operation 2, **not**
  filtered, so the PC receives removals for keys it never saw.
- Batching: first item immediately, then at most one batch per 500 ms. A batch is split at
  131072 bytes (approximate, icons included); each part is its own message.
- Publish filter (A: notifications.PhoneNotificationsPublishFilter): drops LTW's own
  notifications with id <= 1000, other Android users' notifications, media notifications while
  audio sync is off; then requires the notification not to be an empty auto-group, a group
  summary (flag 512), a progress notification or a text-less decorated custom view, and to be
  clearable or a MessagingStyle foreground-service notification.
- Per-app filter (A: notifications.PhoneNotificationsAppFilter): settings group
  `NotificationSyncSetting`, key = package, value `"0"` disables. `com.android.vending` is
  disabled by default once `/settings` has been used.

Reconcile (A: notifications.PhoneNotificationSyncPlanner; PhoneNotificationTransactionManager)

Input from the PC: `notificationKeys` and parallel `postTimes`.

| Phone state | Output entry |
|---|---|
| Active notification, key unknown to PC or `postTime` differs | operation 3 with JSON |
| Active notification, key and `postTime` match | nothing |
| PC key not active on the phone (or its app disabled) | operation 2 |

- Invalid input (`postTimes` shorter than keys, null keys) or listener not connected: an empty
  list is sent.
- The answer is **one** `/legacy/phonecontent` message (parts are re-assembled), sent even when
  empty (three empty arrays), with `correlationVector` equal to the request's.
- Empty input arrays therefore request a full dump.

### 7.5 PC to phone: route `/notifications`

Request value set (W: Communication.PhoneNotificationsRequest.BuildRequestMessage; A: notifications.requestsHandlers.PhoneNotificationRequestHandler)

| Key | Type | When |
|---|---|---|
| `contentType` | String `notifications` | always; anything else gives result 2 |
| `contractVersion` | Double 3.99 | always; `floor` must be 3 or the phone answers 3 |
| `correlationVector` | String, 16 hex | always |
| `operation` | Int32 | always; missing gives result 1 |
| `key` | String | operations 2 and 5 |
| `actionIndex` | Int32 | operation 5 with an action |
| `inlineReplyMessage` | String | operation 5 inline reply |
| `notificationKeysCount` | Int32 | operations 3 and 4 (the phone ignores it) |
| `notificationKeys` | StringArray | operations 3 and 4 |
| `postTimes` | Int64Array | operation 3 |
| common legacy keys | | `isuserinitiated` Bool, `ignoreResponse` Bool, `transportType` Int32 0, `displayName`, `appVersion`, `installationId` |

Operations

| `operation` | Purpose | Phone behaviour | Reply `result` |
|---|---|---|---|
| 2 | Dismiss one | Cancels the notification by `key`. A removal push (operation 2) follows. | 0 immediately |
| 3 | Reconcile | Section 7.4. | Deferred until the PC has answered the phone's reconcile push: 0 ok, 7 no listener permission, 8, 11, 10, 21 mapped failures, else 1 |
| 4 | Clear | No keys: cancel all. With `notificationKeys`: cancel each. | 0 immediately |
| 5, no `actionIndex` | Open on phone | Fires the content intent, then dismisses. | 0 immediately |
| 5, `actionIndex` + `inlineReplyMessage` | Inline reply | Fills the action's first free-form remote input and sends it. Uses a cached action for up to 300 s (100 entries) if the notification is gone. | 0 immediately (does not confirm delivery) |
| 5, `actionIndex` only | Action button | Fires that action. | Deferred: 20 an app came to the foreground; 0 nothing launched within about 0.9 s; 7 the phone needs its "appear on top" permission |
| other | | | 1 |

Notes

- Listener permission missing: result 7 for any operation.
- For operation 3 the PC must be able to answer the phone's incoming push while its own
  request is still pending, and must send `correlationVector` (it is the transaction id).
- Windows reads only `result` from the reply (and `contractVersion` when `result` is 3).
- Every phone reply contains `result` Int32 and `contractVersion` Double 3.99
  (A: agents.AppServiceProviderHelpers).
- Windows queues action and reply requests in a local table and sends each once, with a
  10 minute expiry and no automatic retry (W: Communication.PhoneRequestItemsProcessor).
- There is no mute, snooze or mark-as-read command to the phone. Windows mutes locally.

Result codes (W: YourPhone.Contracts.Connectivity :: ScenarioResult; same numbering on Android)

0 Success, 1 Failure, 2 UnknownType, 3 IncompatibleVersions, 4 UserAccepted, 5 UserDenied,
6 UserPermanentlyDenied, 7 NeedsPermission, 8 MeteredConnection, 9 NeedsInitialPermission,
10 CanceledDisconnected, 11 CanceledCoalesced, 12 MeteredConnectionSyncDisabled,
13 AllFeaturesDisabled, 14 InvalidRequest, 15 DatabaseOperationFailed, 16 FeatureFlagDisabled,
17 DeviceResolutionFailed, 18 DeviceNotSupported, 19 UserSessionInactive, 20 AppLaunched,
21 TwoPhoneModeSyncDisabled, 22 UserRevokedTrust, 23 NonDefaultUserProfile.

Windows treats 0, 10, 11 and 16 as success (W: YourPhone.Utilities :: ResponseHelpers.GetRequestFinishedStatus).

### 7.6 Related routes

`/command/audio` (W: YourPhone.Audio :: AudioCommandRequest; A: notifications.requestsHandlers.AudioCommandRequestHandler)

| Key | Type | Value |
|---|---|---|
| `audioCommandValue` | Int32 | 0 open the listener settings screen on the phone, 1 play, 2 pause, 3 next, 4 previous |
| `key` | String | media notification key |
| `correlationVector` | String | |

No `contentType`. Reply `result` 0 or 1.

`/settings` (W: Communication.SettingsRequest, Settings.NotificationSettingsUpdateService; A: agents.SettingsRequestHandler). `contentType` `settings`, `triggerType` Int32.

| `triggerType` | Request keys | Reply key |
|---|---|---|
| 25 read all | none | `syncSetting` String = JSON `{"settings":[item...]}` |
| 26 set one | `settingGroupId` String `NotificationSyncSetting`, `settingKey` String (package), `settingType` Int32 11, `settingValue` String `"1"` or `"0"`, `settingMuteExpirationTimestamp` Int64 0 | `savedSetting` String = one JSON item |
| 27 set many | `settings` String = JSON `{"settings":[item...]}` | `syncSetting` |

Item: `settingGroupId`, `settingKey`, `settingType` (11 Bool, 4 Int32, 12 String, 9 Double),
`settingValue`. Results: 0, 14 invalid, 15 database failure. Batch (27) is used by Windows only
when the phone reports `deviceCapabilityNegotiation` bit 8 and a Windows feature flag is on.
Settings are not required for notifications to flow.

`/permission` (W: YourPhone.Notifications.Managed :: NotificationPermissionService; YourPhone.Utilities :: IRemoteAppClientExtensions.SendPermissionsRequestAsync; A: agents.PermissionRequestHandler)

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `permission` |
| `permissionType` | Int32 | 64 notification listener; 134217728 post notifications; -2147483648 sensitive notifications |
| `silent` | Bool | false prompts on the phone; true only queries |
| `permissionSessionId` | String | PC app session id |
| `correlationVector` | String | |

Reply `result`: 0 or 4 granted; 5, 6, 7 not granted; 18 device not supported. With `silent`
true, or when already granted, the phone answers at once with 4 or 5.

### 7.7 The protobuf pull path (`/notifications` resource)

The phone also serves DRM path `/notifications` (A: notifications.platform.NotificationResourceRequestHandler; P: notification/v1/notification.proto).

| Message | Fields |
|---|---|
| `NotificationsRequestMessage` | 1 `type` (1 = GET), 2 `keys` repeated string, 3 `post_times` repeated int64 |
| `NotificationsResponseMessage` | 1 `status`, 2 `notifications` repeated `NotificationInfo` |
| `NotificationInfo` | 1 key, 2 title, 3 text, 4 big_text, 5 app_name, 6 package_name, 7 post_time, 8 timestamp, 9 category, 10 is_clearable, 11 sub_text, 12 conversation_title, 13 notification_class |

Status: 1 OK, 2 INVALID_REQUEST, 3 PERMISSION_NOT_GRANTED, 4 NO_NOTIFICATION, 5 UNKNOWN_ERROR.

Semantics: snapshot of active notifications passing the publish filter, newest first; entries
whose key and post time both match the request are omitted. No push, no removals, no actions,
no icons. `notification_class` here is 1 MessagingStyle, 2 MediaStyle, 3 CallStyle, 0 other.
**[inferred]** the caller is the WEA client; the phone code does not restrict it by client type,
and it was not seen on the wire.

### 7.8 Preconditions for the phone to push notifications

| Condition | Source |
|---|---|
| Notification-listener access granted on the phone | A: agents.permissions.PermissionsHelper (`PermissionTypes.NOTIFICATIONS_LISTENER` = 7, flag 64) |
| Listener service connected and the agent service initialised | A: PhoneNotificationsListenerService |
| At least one **active remote app of client type PL** | A: agents.sync.SyncExecutor.executeMulticastAsync uses `getActiveRemoteApps(PL)`. Client type comes from DCG peer metadata `clientType`, default `PL` when absent (A: agents.RemoteAppUtil). Under connection sharing a PL app counts as active while its WEA sibling is connected. |
| Sync allowed by the phone's metered-connection policy | A: agents.AgentConnectivityManager |

Not required: any `configuration` key in `/connect/v1`, any PC capability bit, any `/settings`
exchange. The only notification-related configuration key is `AudioInfoSyncEnabled` (media
notifications, icons, `playbackState`).

Permission state reaches the PC three ways

1. `/connect/v1` reply, `permissions` object (section 8.3).
2. Reply code of `/permission`.
3. Push on `/legacy/phonecontent` with `contentType` `permissions`: `itemCount` Int32 1,
   `permissionTypes` Int32Array `[64]`, `permissionStates` Int32Array `[0]` granted or `[1]`
   denied (2 request shown, 3 request notified). PC answers `{result 0}`, or `{result 14}` when
   the arrays are invalid (A: agents.permissions.sync.PermissionsSyncCoordinator; W: YourPhone.Devices.Managed :: Sync.Permissions.PermissionsContentProcessor).

Initial reconcile at connect: section 8.2, keys `operation`, `notificationKeys`, `postTimes`.

---

## 8. `/connect/v1`

APP request from the PL client. `_route` `/connect/v1`, `_requestId` GUID, `_rejectionVersion` 1,
no content-type header. Sent when the platform connection becomes connected, with a 60 s
cooldown between repeats; reply timeout 600 s for background connects
(W: YourPhone.Connectivity.Managed :: Services.EstablishConnectionManager). **[wire]** sent twice
in one session 14 s apart (C-pair: 409, 549).

### 8.1 Request, as observed (C-pair: 409, 549) and its code origin

Top level

| Key | Type | Observed | Origin |
|---|---|---|---|
| `contentType` | String | `connect` | EstablishConnectionManager.BuildEstablishConnectionPayload; phone rejects anything else |
| `correlationVector` | String | 16 hex | same |
| `contractVersion` | Double | 3.99 | YourPhone.Utilities :: CommunicationConstants.ContractVersionValue, added by RemoteAppClient |
| `appVersion` | String | `1.26072.257.0` | RemoteAppClient |
| `displayName` | String | PC host name | RemoteAppClient |
| `installationId` | String | upper-case GUID | RemoteAppClient |
| `attributes` | Object | `appVersion`, `displayName`, `flightRing` (`Public`) | YourPhone.Devices.Managed :: DeviceInfoEstablishConnectionPayload.BuildLocalAttributes |
| `configuration` | Object | below | several contributors |
| `sequenceNumbers` | Object | below | several contributors |
| `EffectiveSampleRate` Double, `FlightRing` String (`Retail`), `IsSampled` Bool, `UploadSampleRate` Int32, `sampleId` String | | telemetry sampling | TelemetryInfoEstablishConnectionPayload |
| `operation`, `notificationKeysCount`, `notificationKeys`, `postTimes` | Int32, Int32, StringArray, Int64Array | **absent in the capture** | YourPhone.Notifications.Managed :: Sync.SyncNotificationsEstablishConnectionPayload, section 8.2 |

`configuration` (all Bool unless noted; value in the first / second observed request)

| Key | Observed | Phone use (A: agents.ConnectionRequestHandler.processPartnerConfiguration) |
|---|---|---|
| `SequencedContentSyncs` | true | Phone reads `sequenceNumbers` only when true; if true and the map is missing the request is abandoned. |
| `SyncSkipMetadataForAuto` | false | |
| `ContactThumbnails`, `ContactsV2Sync` | true | contacts |
| `CallLogs` | false | |
| `Wallpaper` | true | |
| `MediaInfoSync` | true; `MediaInfoSnapshotSize` Int32 2000; `AutoHydratedThumbnailsCount` Int32 25; `PhotosLegacySync` false | photos (defaults 2000 and 40) |
| `ContentTransferCopyPaste` | false | legacy clipboard switch, section 6.7 |
| `Exp006` | true | |
| `TaskContinuity` true, `TaskContinuityVersion` UInt32 1, `BrowserHistory` true | | |
| `BatteryIndicator`, `DeviceIndicators`, `DeviceIndicatorsBluetooth`, `DeviceIndicatorsDND`, `DeviceIndicatorsVolume`, `AirplaneMode` | true | status keys added to phone messages (`BatteryIndicator` defaults true) |
| `AudioInfoSyncEnabled` | true | media notifications; takes effect when the phone's agent service next initialises |
| `AndroidCanaryOptInNotifications` | false | |
| `MessagingSync`, `MessagingMassText` true; `MessagingSend`, `MessagingRcsReceive` false then true; `MessagingRcsSend` false; `MessagingRcsUnsupportedMessageTypes` Int32Array (second request only) | | messaging |
| `RecentApps`, `AppHandoff` | false then true | |
| `RemoteControlPhoneToPc` | true | |
| `UnlinkableVersion` | Int32 2 | |
| `btWakeUserEnabled` | false | |
| `fileTransferToPcRetryEnabled`, `yppPresenceFlowConfig` | true | |
| `ContentTransferDragDropPhoneToPC`, `...PCToPhone`, `...FullTrust`, `...PhoneToPCMaxFileSizeMB`, `...MaxFileCount`, `AndroidBetaOptInNotifications` | absent | read by the phone with defaults false / 512 / 100 |

`sequenceNumbers` (all Int64; -1 means "I have nothing")

First request: `browserHistory`, `contact`, `contactdate`, `contacturl`, `continuityAppContext`,
`conversation`, `emailaddress`, `media_info`, `mms`, `phoneApps`, `phonenumber`,
`postaladdress`, `sms`, `subscription`, `wallpaper`, all -1. Second request adds `rcs_chat`,
`rcs_conversation`, `rcs_filetransfer`, `recentApps` and carries the values learned from the
first reply. Notifications never appear here.

Other keys the phone reads: `forceRefreshOfTypes` Object {`contentTypes` StringArray,
`relatedCorrelationIds` StringArray} (optional); `IsSampled`.

Side effects on the phone **[code]**: stores `attributes.displayName`, `appVersion`,
`flightRing` on the remote app, and updates the connection-sharing status from the sender's
client type (A: ConnectionRequestHandler.processPartnerAttributes).

### 8.2 Notifications inside the connect request **[code]**

Windows adds, at top level, `operation` Int32 3, `notificationKeysCount` Int32,
`notificationKeys` StringArray (every stored key), `postTimes` Int64Array (each stored
`postTime`) when all of these hold: the phone previously reported `permissions.notifications`
true, the PC-local notifications toggle is on, and the previously stored
`capabilities.notifications` has bit 2 (W: SyncNotificationsEstablishConnectionPayload.Load).
If the first two hold but bit 2 is unknown (first ever connect), Windows instead sends a
separate `/notifications` operation 3 request in parallel.

The phone acts only when `operation` is Int32 3 and `postTimes` is an Int64Array; it then
answers with one `/legacy/phonecontent` reconcile push whose `correlationVector` equals the
connect request's. The connect reply itself does not mention notifications
(A: notifications.PhoneNotificationConnectionSyncCoordinator.processConnectionPayload).

### 8.3 Reply, as observed (C-pair: 459, 557) and its code origin

Headers: `_route` `/internal/response`, `_originalRequestId`. No `result` header. Arrived 1.5 s
after the request, after the phone had already started pushing content.

A: ConnectionRequestHandler.tryProcessRequest, createDevice*Blob; agents.DeviceStatusBuilderHelper.

| Key | Type | Observed / meaning |
|---|---|---|
| `result` | Int32 | 0 |
| `contractVersion` | Double | 3.99 |
| `yppVersion` | Int32 | 8 (constant) |
| `yppCapabilities` | Int32 | 127 |
| per content type sequence numbers: `contact`, `contactdate`, `contacturl`, `emailaddress`, `phonenumber`, `postaladdress`, `conversation`, `sms`, `mms`, `subscription`, `media_info`, `wallpaper`, `phoneApps`, `recentApps`, `continuityAppContext` | Int64 | the phone's current sequence per type |
| `attributes` | Object | `displayName`, `manufacturer`, `deviceModel`, `sdkVersion` (LTW version), `osVersion`, `androidSdkVersion` Int32, `clientModelName` Int32, `clientModelRevision` Int32, `flightRing` (`PRODUCTION`), `defaultLocale`, `countryCode`, `platform` Int32 1, `market`, `assetCategory`, `packageName`, `userId` |
| `capabilities` | Object | below |
| `permissions` | Object | below |
| `settings` | Object | messaging settings: `capabilities` Int32, `markAsReadAvailable`, `mmsAutoDownloadAvailable`, `mmsAutoDownloadEnabled`, `rcsSendAvailable` |
| `mediaSettings` | Object | `dcim_directory` String |
| `deviceConfiguration` | Object | `ignoringBatteryOptimization` Bool |
| `userAttributes` | Object | `aadcOptionalDataCollectionPolicy` Int32 |
| `cameraStreamConfiguration` | Object | `cameraStreamFps`, `cameraStreamCaptureWidth`, `cameraStreamCaptureHeight` Int32 |
| `ltwUpdate` | Object | `ltwUpdateState` Int32, `ltwUpdateGentleSetTime` Int64 |
| `ltwA2DMigrationNeeded`, `ltwTermsUpdateAvailable`, `hotspotUserConsent`, `oemBluetoothRfcommServerOpen`, `wallpaperDevicePermission` | Bool | |
| device status: `batteryPercent`, `batteryCharging`, `batteryPowerSave`, `bluetoothState`, `doNotDisturbStatus`, `doNotDisturbRuleEnabled`, `networkOperator`, `networkSignalStrength`, `networkSignalStrengthMax`, `networkIndicatorApiSupport`, `networkDataType`, `mobileDataStatus`, `ringerMode`, `wifiSignalLevel`, `wifiState`, `airplaneMode`, `syncOverMeteredConnection` | Int32 / Bool / String | |

`capabilities` (Int32 unless noted)

| Key | Observed | Meaning |
|---|---|---|
| `notifications` | 14 | Bits: 1 ANCS_CONNECTION_CAPABLE (iOS only), 2 ECR_HANDLES_NOTIFICATIONS (always set by Android), 4 PROFILE_COMPUTER_ROLE_AVAILABLE, 8 SENSITIVE_NOTIFICATIONS_ENABLED (A: notifications.NotificationCapability; W: YourPhone.AppCore.Managed :: NotificationsCapabilities). Says nothing about listener access. |
| `registeredPermissionTypes` | 75648863 (0x4824F5F) | OR of legacy permission flags. Bit 0x40 NotificationsListener must be set or Windows disables the feature; 0x4000 AudioControl; 8 PhoneApps (W: DeviceCapabilities). |
| `deviceCapabilityNegotiation` | 15 | 1 metered sync, 2 ring update notification, 4 permissions sync, 8 batch notification settings. |
| `contentTransfer` | 6 | 1 CopyPaste, 2 DragAndDrop, 4 CopyPasteMigrated (section 6.7). |
| `remoting` 94207, `statusCapabilities` 6143, `messaging` 48, `photos` 3, `contacts` 1, `continuity` 7, `hotspot` 3, `cameraStream` 1, `filesCapabilities` 3, `fileTransferCapabilities` 15, `bluetoothCapabilities` 1, `ringMyPhoneCapabilities` 1, `wakeCapabilities` 1 | | other features |
| `inputInjectorAvailable`, `blackScreenAvailable`, `isTwoPhoneModeEnabled` | Bool | |

`permissions` (all Bool)

| Key | Observed | Meaning |
|---|---|---|
| `notifications` | false | Notification-listener access granted. Drives everything in section 7. |
| `post_notifications` | true | LTW may post its own notifications. |
| `notification_sensitive` | false | Companion "computer" role associated (sensitive content not redacted by Android). |
| `photos`, `photos_full`, `photos_delete`, `read_media_images`, `messaging`, `calls`, `call_logs`, `contacts`, `camera`, `files`, `shared_content`, `bluetooth`, `oem_bluetooth`, `wifi_p2p`, `auto_launch` | | other features |

Windows reads types strictly: nested maps must be Object, flags Bool, masks Int32
(W: the `Apply` methods of the `*EstablishConnectionPayload` classes).

### 8.4 Other APP traffic around the handshake **[wire]**

- The phone pushes content on `/legacy/phonecontent` as soon as it has processed the connect
  request, before and after replying: `wallpaper`, then metadata rounds (`metadata` Int32 1,
  id and checksum arrays) for `mediaInfo`, `phoneApps`, `contactsV2`, later `messaging`
  (C-pair: 421, 444, 450, 454, 756).
- PC answers each with `/internal/response`, header `result: 0`, value set `{result 0}` or, for
  a metadata round, `{contentType, contractVersion, correlationVector, itemCount, result, <wanted id arrays>}`
  (C-pair: 431, 458).
- Every phone push repeats `contractVersion` 3.99, `installationId`, `displayName`, `dedupeID`
  (empty), `retryCount` 0 and the device-status keys.
- No other APP-level handshake was observed. `/permission/status` polling exists in Windows
  first-run code only.

---

## 9. Differences between the two code bases

| Topic | Windows (Phone Link) | Android |
|---|---|---|
| Envelope `header_bytes` | includes the 4-byte count | excludes it |
| PLATFORM `_requestId` | decimal counter | GUID |
| Unhandled DRM path | silent | `response_type` 2 |
| Incoming `/Context/Publish` | answers `{}` | no answer |
| Outgoing publish | one-way | waits for the reply |
| `PubSubPayload` field | not determinable (CDEH) | writes `additional`, reads `data` |
| Tag names | CameraStreaming, ContentUpdate; no tag 11 | PhoneAsWebcam, ContentChange; Hotspot = 11 |
| `DeviceResourceType` local enum | has LockMyPc | no LockMyPc; unknown proto values map to UNKNOWN |
| Notification JSON | reads `subtitle`, `isReadOnlyGroupMessage` | writes neither; writes many keys Windows ignores |
| `notificationClass` | 1 messaging, 2 media, 3 call | value-set path: by default SMS / dialer package; protobuf path: by style |
| APP reply `result` header | set | not set (value-set key only) |

---

## 10. Open questions

1. **One identity or two.** Clipboard needs a `WEA` identity advertising `CLIPBOARD`;
   notification push targets `PL` remote apps. On Windows these are two DCG identities sharing
   one connection. Not established: whether a single non-Windows client can hold both roles,
   whether the phone accepts `/connect/v1` from a WEA-typed sender and then counts a PL app as
   active, or whether two enrolments and the connection-sharing behaviour must be reproduced.
   Needs a live test.
2. **PC-side clipboard publish.** That the PC must put `CLIPBOARD_CHANGE` in `PubSubPayload.data`
   rests on the phone's reader and on X:; no CDEH code and no wire sample.
3. **Clipboard on at session start.** Not captured with the feature on, so the exact messages
   CDEH sends when enabled (FEATURE_ON request, publish, or both) are unknown.
4. **Size limits toward the phone.** None found in the phone code for incoming clipboard items.
5. **Notifications on the wire.** Nothing captured. A capture with listener access granted
   would confirm the push shape, the embedded reconcile in `/connect/v1`, and whether the phone
   ever gzips (`_isGzippedCompressed`).
6. **`AudioInfoSyncEnabled` timing.** The phone copies it into the listener process only when
   its agent service initialises; whether it applies within the same session is unclear.
7. **Who calls the protobuf `/notifications` resource**, and whether CDEH uses it.
8. **Duplicate replies.** The double `{}` acknowledgements are attributed to two Windows
   processes by inference only.
9. **Tag 8 publish body** (42 bytes, C-pair) was not decoded against a proto.
10. **`/PlatformDisconnectRequest`** carried JSON `{}` although a protobuf with a reason enum
    exists (P: platform_sdk/v1/platform_message.proto); the phone's handling was not read.
