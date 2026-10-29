# File transfer between PC and phone

Implementation-grade specification of one Phone Link feature area: sending files from the PC to
the phone ("send to my phone", share target, drag onto Phone Link) and from the phone to the PC
("Send to PC" in the Android share sheet). Written for a PC-side client in Swift that an Android
phone running Link to Windows (LTW) treats like Windows.

Revision 1, 2026-10-09.

Transport, envelopes, the two Windows client types (`PL`, `WEA`), the device resource manager
(DRM) and publish/subscribe are specified in `session-clipboard-notifications.md` (sections 1, 2,
5) and `relay-transport.md`. They are not repeated here.

## Sources and tags

| Tag | Meaning | Pointer style |
|---|---|---|
| **[code-android]** | Decompiled Link to Windows 1.26082.130.0 (jadx) | `A:` class, package prefix `com.microsoft.mmx.agents` shortened to `agents`, `com.microsoft.appmanager` to `appmanager` |
| **[code-windows]** | Decompiled Phone Link 1.26072.257.0 | `W:` assembly :: class |
| **[wire]** | Seen in a capture, structure only | `C-raw:` `captures/vm-raw-2026-10-09/flows.jsonl` seq; `C-pair:` / `C-relay:` as cited in `session-clipboard-notifications.md` |
| **[inferred]** | Deduced, not directly confirmed | reasoning given |
| `P:` | Recovered proto source under `protocol/recovered/android/` | file :: message |

Limits of the evidence, stated once:

1. **No file transfer exists in any capture.** `C-raw` contains no `/nanohandshake`, no
   `/fileshare*` request, no `fileTransfer` content push and no HTTP flow to OneDrive or Graph
   **[wire]** (route and resource tallies of the whole capture; HTTP records are only the DCG
   negotiate, the hub socket and one `/Dispatcher/Wake`). Everything in sections 3 and 4 is
   code-only unless marked.
2. Cross Device Experience Host (CDEH, the `WEA` client) is **not decompiled**. Its half of the
   `WEA` path is known only from the Android peer code and from the recovered protos whose
   `csharp_namespace` is `CrossDevice.Share.FileShare.Protocol.V1`.
3. The peer-to-peer transport ("Nano") is a native library on both sides (`LibNanoAPI` on
   Windows, `com.microsoft.nano.jni` on Android). Its wire format is unknown. This document
   specifies everything above it.

## 0. Result in one paragraph

On Android, file bytes **never travel over the hub relay and never through OneDrive**. Both
directions and both Windows client types move bytes over a Nano peer-to-peer connection
(direct IP, ICE with STUN, ICE with TURN, or Wi-Fi Direct). The relay carries only the request
that starts a transfer and the Nano signalling. OneDrive upload sessions exist in Phone Link but
serve iPhones only. The "phone files" resource (`/filesmetadata`, publish tag 4) gives listing,
thumbnails and file management over the relay, but file contents again go through Nano. A client
without Nano can receive and answer the phone's transfer request and can browse the phone's
storage, but cannot move a file in either direction.

---

## 1. Mechanisms, owners and gates

### 1.1 Mechanism table

| Mechanism | Used for Android? | Windows owner | Bytes travel over | Evidence |
|---|---|---|---|---|
| **A. Phone Link legacy path** (`TransferSolutionNano` = `Nano`) | Yes, both directions, when the target is a `PL` remote app | `PL` | Nano connection of the screen-mirroring stack ("AppProxyConnection"), workflow name `fileTransfer`, one Message channel and one Blob channel | **[code-windows]** W: YourPhone.SharedContent.Managed :: FileTransferSharingService, FileSendSession.GetTransferSolution; W: YourPhone.ScreenMirroring.Managed :: AppProxyConnection.FileTransfer.FileTransferService. **[code-android]** A: agents.filetransfer.transport.nano.FileTransferWorkflow |
| **B. Cross Device path** ("file share to CDEH", migration target) | Yes, both directions, when the target is a `WEA` remote app that lists `FILE_TRANSFER` | `WEA` | Platform device connection (Nano), platform channel of type NamedStreams | **[code-android]** A: agents.filetransfer.platform.FileTransferRequestManager, FileTransferSendChannelRequestHandler, FileTransferReceiveChannelRequestHandler, FileTransferPlatformAdapter |
| **C. OneDrive upload session + link over relay / push** (`TransferSolutionOneDrive`) | **No.** iPhone only | `PL` (and `WEA`, by its capability strings) | Microsoft Graph, user's consumer OneDrive | **[code-windows]** W: YourPhone.SharedContent.Managed :: FileTransferSharingBlobService, FileTransferDdpsCallback; W: YourPhone.YPP :: BlobManager.OneDriveAPIHelper. **[code-android]** no OneDrive or Graph code in the app: the strings `FILE_TRANSFER_ONEDRIVE`, `createUploadSession`, `graph.microsoft.com/v1.0/me/drive` do not occur in the decompiled sources |
| **D. Bytes inline over the relay** | **No** for files. Thumbnails of phone files only (section 6) | n/a | n/a | **[code-android]** no file-content field exists in any relay message of this feature; P: file_transfer/v1, phone_files/v1 |
| **E. Phone files resource** (`/filesmetadata`, tag 4) | Yes, for browsing. Content through NamedStreams over Nano | `WEA` | Relay for metadata and thumbnails, Nano for content | section 6 |
| **F. Bluetooth** | **No** for bytes | n/a | n/a | **[code-android]** `agents.filetransfer` has no Bluetooth dependency; Bluetooth appears only as a signalling provider of the platform (`agents.ypp.ambientexperience.providers.bluetooth`). **[code-windows]** `NearbySharing.Manager.NearbySharingManager` is a stub (mock device list, send method not implemented) |
| **G. Local network / Wi-Fi Direct** | Yes, as Nano transport types, not as a separate protocol | both | Nano | **[code-android]** A: agents.ypp.ambientexperience.transport.nano.connect.NanoTransportType: `IP` 0, `ICE_LOCAL` 1, `ICE_STUN` 2, `ICE_TURN` 3, `IP_WIFI_P2P` 4, `UNKNOWN` 100 |
| **H. Drag and drop inside screen mirroring** | Separate feature, not covered here | `PL` | Nano (scopes `/drag/...` in `windows-catalog.md`) | **[code-windows]** names only |

### 1.2 Which path each direction uses today

Phone to PC **[code-android]** (A: appmanager.filetransfer.domain.GetFileShareDevicesUseCase,
SendFilesUseCase):

1. The share screen lists every remote app in the phone's store. A `WEA` remote app is listed
   only if the DCG service reports the string `FILE_TRANSFER` for it
   (A: appmanager.filetransfer.FileTransferCapabilityProvider, feature name `FILE_TRANSFER`,
   checked "from server"). A `PL` remote app is always listed.
2. Entries are grouped by `distinguishedDeviceId`; within a group the `WEA` entry wins.
3. The send method is chosen by the picked entry's client type: `WEA` gives path B
   (`sendToCrossDevice`), `PL` gives path A (`sendToPhoneLink`).

On a current Windows PC both client types exist for one device and `WEA` registers
`FILE_TRANSFER`, so path B is used **[inferred]** from 1 to 3 plus **[wire]** the registered
capability lists (C-pair: 192, 213).

PC to phone **[code-windows]**:

1. Phone Link picks `Nano` when the phone's `fileTransferCapabilities` has bit 1, else `OneDrive`
   when the phone lists `FILE_TRANSFER_ONEDRIVE` and is a cloud-enrolled device
   (`ConsentVersion >= 0`), else nothing (W: FileSendSession.GetTransferSolution;
   W: SharedContentFeatures.IsFileTransferEnabled, IsOneDriveFileTransferSupportedAndEnabled;
   W: YourPhone.Utilities :: DeviceDataExtensions.IsClientManagerDevice).
2. If the phone's `fileTransferCapabilities` has bit 8 and the remote feature
   `FileShareSliverViaCDEH` is on, Phone Link does not send at all: it activates CDEH's share
   host (`MicrosoftWindows.CrossDevice_cw5n1h2txyewy!ShareUXHostApp`) with the URI scheme
   `ms-crossdevice-share`, query `scenarioId=WinShareSendFiles`, `deviceId`, `deviceName`
   (W: FileTransferWindowApplicationService; SendFilesHelper.CreateCrossDeviceShareUri;
   SharedContentFeatures.IsSliverSendFilesViaCdehEnabled). That is path B.

### 1.3 Capability strings and flags

DCG capability strings (registered in device metadata, section 1 of the session spec):

| String | Registered by | Read by | Effect |
|---|---|---|---|
| `FILE_TRANSFER` | phone (unconditional, A: appmanager.filetransfer.di.FileTransferModule); Windows `WEA` **[wire]** | phone, for `WEA` remote apps | Phone offers path B to that `WEA` app, and sets flag 8 below **[code-android]** |
| `PHONE_FILES` | phone (unconditional, A: agents.ypp.devicemanagement.provider.DeviceCapabilityModule) | CDEH **[inferred]** | Phone files feature |
| `FILE_TRANSFER_ONEDRIVE` | Windows `PL` and `WEA` **[wire]**; iPhone **[inferred]** | Phone Link, on the phone's list (W: SharedContentConstants.FileTransferOneDriveCapability) | Selects path C. An Android phone never lists it **[wire]** (C-pair: 162) and never reads it **[code-android]** |
| `FILE_TRANSFER_ONEDRIVE_WNS_PUSH` | Windows `WEA` only **[wire]** | not referenced in Phone Link or in the Android app | **[inferred]** tells the iPhone app that the PC can be woken by a WNS push for path C |

Value-set flags in `/connect/v1` (Phone Link handshake, `PL` only):

| Where | Key | Type | Meaning | Evidence |
|---|---|---|---|---|
| request, `configuration` | `fileTransferToPcRetryEnabled` | Bool | PC supports session retry (remote feature `EnableFileTransferRetry`) | **[wire]** C-raw: 147, 5128. **[code-windows]** W: Sync.SharedContentEstablishConnectionPayload.Load |
| reply, `capabilities` | `fileTransferCapabilities` | Int32 bit set | 1 `FILE_TRANSFER_SUPPORTED`, 2 `FILE_TRANSFER_ON_PLATFORM_SUPPORTED`, 4 `FILE_TRANSFER_TO_PHONE_RETRY_SUPPORTED`, 8 `FILE_TRANSFER_PHONE_TO_CDEH_SUPPORTED` | **[wire]** key and type, C-raw: 163, 5136. **[code-android]** A: appmanager.filetransfer.api.FileTransferCapability; A: agents.ConnectionRequestHandler. **[code-windows]** W: YourPhone.AppCore.Managed :: FileTransferCapabilities |
| reply, `capabilities` | `filesCapabilities` | Int32 bit set | 1 `FILES_CAPABLE`, 2 `FILES_SYNC_YPP`, 4 `FILES_THROUGH_APPS_STACK`; the phone sets 1 and 2 | **[wire]** C-raw: 163. **[code-android]** A: appmanager.phonefiles.api.FilesCapabilities; A: agents.files.FilesCapabilitiesProvider |
| reply, `permissions` | `shared_content` | Bool | Phone-side permission Phone Link requires before sending | **[wire]** C-raw: 163. **[code-windows]** W: SharedContentEstablishConnectionPayload.Apply |

The phone always sets bits 1, 2 and 4. It adds bit 8 only when the `PL` sender has a `WEA`
sibling with the same `distinguishedDeviceId` and that sibling lists `FILE_TRANSFER`
**[code-android]** (A: agents.filetransfer.FileTransferEnablementProvider;
A: agents.remotedevice.RemoteDeviceManager.getDcgClientIdFromRandomDcgClientId).

Consequence for a client whose `PL` and `WEA` identities have different
`distinguishedDeviceId` values (ours): the phone lists them as two separate share targets, never
sets bit 8 for the `PL` identity, and offers the `WEA` identity only if it registers
`FILE_TRANSFER` **[inferred]** from the rules above.

---

## 2. Shared building blocks

### 2.1 Transfer description

Two encodings of the same record exist.

**JSON**, used on path A (A: agents.filetransfer.sync.FileTransferMessage,
FileTransferContentMessage with Gson names; W: FileTransfer.FileTransferDetail,
FileTransferDetailItem) **[code-android] + [code-windows]**:

| JSON key | Type | Notes |
|---|---|---|
| `TransferId` | string | Phone as sender: its trace id. Windows as sender: a new GUID. |
| `Scenario` | string | Table below. |
| `SenderName` | string | Windows: machine name. Phone: empty. |
| `ReceivedFileCount` | number | Files completed so far. |
| `Content` | array | Items below. |
| `PcFolder` | string or null | Only in the PC's completion message: the download folder path. |
| `SessionTryCount` | number or null | 1 from this phone build; greater than 0 selects "message format V2" on Windows. |

Item: `FileId` string, `FileName` string, `FileSize` number (bytes), `FileHash` string (always
empty in both code bases), `FileStatus` number.

**Protobuf**, used on path B (P: file_transfer/v1/transfer_info.proto):

`FileShareMessage`: 1 `transfer_id` string, 2 `scenario` string, 3 `sender_name` string,
4 `received_file_count` int32, 5 `content` repeated `FileShareContentMessage`, 6 `pc_folder`
string, 7 `session_try_count` int32, 8 `is_concurrent_mode` bool.

`FileShareContentMessage`: 1 `file_id` string, 2 `file_name` string, 3 `file_size` int64,
4 `file_hash` string, 5 `file_status` enum.

`FileShareFileStatus`: 0 UNSPECIFIED, 1 NOT_STARTED, 2 IN_PROGRESS, 3 COMPLETED. The JSON
`FileStatus` uses the same numbers; a missing or 0 value reads as 1
(A: agents.filetransfer.sync.FileTransferMessageSerializer).

Scenario strings **[code-android] + [code-windows]** (A: agents.filetransfer.sync.FileTransferMessageGenerator;
W: FileTransferSharingReceivingDelegate, FileTransferSharingSendingDelegate):

| Scenario | Sent by | Meaning |
|---|---|---|
| `FileTransferToPc` | phone | Offer: list of files the phone wants to send. |
| `FileTransferToPcFile` | PC (path A only) | "Send me this file now": the wanted item has status 2. |
| `FileTransferToPcCompleted` | PC, then phone | PC: all received, with `PcFolder`. Phone: acknowledgement. |
| `FileTransferToPcCancel` | phone | Cancel (the phone uses this scenario for every cancel, in both directions). |
| `FileTransferToPhone` | PC | Offer: list of files the PC wants to send. |
| `FileTransferToPhoneFile` | phone | "Send me this file now" (path A), or "ready, send" (path B). |
| `FileTransferToPhoneCompleted` | phone | All received. |
| `FileTransferToPhoneRejected` | phone | Another transfer is active. |

File ids: the phone derives a name-based UUID per file (A: agents.filetransfer.model.FileTransferFileDetail);
Windows assigns a random GUID per path (W: FileTransfer.FileTransferLookupTable). Treat them as
opaque strings.

No checksum is exchanged: `FileHash` is never filled, and no hash is verified on either side
**[code-android] + [code-windows]**. Integrity rests on the Nano connection (connection types
are named `IpSrtp`, `IceSrtp`, `IpSrtpWifiP2p`, A: com.microsoft.nano.jni.connect.ConnectionType)
and on the phone's size check when a stream closes with an error (A: agents.filetransfer.utilities.FileTransferWriter.close).

### 2.2 Nano connection: what is known

| Item | Path A (`PL`) | Path B (`WEA`) |
|---|---|---|
| Signalling | APP request `/nanohandshake` from the PC (section 2.3) | PLATFORM `/Context/Message` and `/Context/Message/<own DCG id>` with `ContextSourceMessage` (P: platform_sdk/v1/context_source.proto): `cs_initialize_message`, `cs_initialize_ack_message`, `cs_connection_info`, `cs_wifi_p2p_info`, `cs_identity_challenge`, `cs_identity_response`. **[wire]** C-pair: 279 to 308; C-raw: 223 such messages, none tied to a file transfer |
| Who connects | PC is the Nano client, phone starts a Nano server (A: agents.NanoHandshakeRequestHandler, `initializeAndStartNanoServer`) | not examined |
| Connection info | JSON string produced by the native library; keys read by Android: `connectionid`, `connectiontype`, `connectioninformation` (A: ...transport.nano.connect.ConnectionInfoParser) | same parser |
| Transport choice on Windows | `Ip`, `Ice`, `IceStun`, `IceStunAndTurn` (W: AppProxyConnection.ConnectionSvc.ConnectionTypes.TransportType); STUN and TURN servers from DCG `/CloudRelay/Relay` (W: ConnectionSvc.CloudRelay.CloudRelayAdapter) | `CSInitializeMessage` field 5 `transport_preference` int32; the phone defines a bit set IP 1, ICE_LOCAL 2, ICE_STUN 4, ICE_TURN 8, IP_WIFI_P2P 16 (A: NanoTransportPreference). **[inferred]** that this bit set is the field's value |
| Native connect properties (Windows) | `open.timeout` (`7000` ms for IP, `10000` otherwise), `ice.stun.url`, `ice.turn.url`, `ice.turn.username`, `ice.turn.password`, `exp.iceFilterTransportClose` = `1` (W: ConnectionSvc.Connect.ConnectAdapter) | unknown |
| Overall connect timeout | 90 s (W: ConnectionSvc.ConnectionService.ConnectionTimeout); file transfer waits 45 s for the channel, 10 s on a retry (W: FileTransferSharingService) | unknown |
| Channels | Nano `ChannelType.Message` and `ChannelType.Blob`, created by the phone once the workflow `fileTransfer` starts (A: FileTransferWorkflow.startAsync) | Platform channel `PROTO_PLATFORM_CHANNEL_TYPE_NAMED_STREAMS_CHANNEL` (1), created with `ProtoCreatePlatformChannelRequest` on device-connection route `/Channel/ProtoCreatePlatformChannelRequest`, answered on `/Channel/ProtoPeerPlatformChannelCreationResult` (P: platform_sdk/v1/platform_channel.proto; A: ...transport.channel.PlatformChannelProvider) |

All rows **[code-android]** or **[code-windows]** as cited. The byte-level Nano protocol
(handshake, SRTP keying, channel framing, blob chunking) is **not known**.

### 2.3 `/nanohandshake` (path A signalling) **[code-windows] + [code-android]**

APP request from the PC to the phone's `LTW` client, route `/nanohandshake`
(W: YourPhone.ScreenMirroring.Managed :: AppProxy.FetchConnectionHandler; A: agents.NanoHandshakeRequestHandler).

Request value set:

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `nanoHandshake` |
| `workflow` | String | `fileTransfer` |
| `handshake` | String | The PC's Nano connection info (JSON text from the native library) |
| `sequenceNumber` | Int64 | Windows FILETIME of "now". The phone casts it to a 64-bit integer; another type fails. |
| `correlationVector` | String | Windows passes the transfer id |
| `isuserinitiated` | Bool | true |

Reply value set: `handshake` String (the phone's Nano connection info) on success, with
`result` 0. Failure shapes:

| Case | Reply |
|---|---|
| Request lacks `handshake` or `sequenceNumber`, or the phone does not support the stack | "device not supported" response |
| `workflow` is `fileTransfer` and a transfer is already active for this sender or for any `PL` peer | canceled/disconnected response with `rejectReason` String `workflowInProgress`. Windows maps it to error `TransferInProgress` (W: FileTransferSharingService.RejectReasonWorkflowInProgress) |
| Host name resolution failed while starting the server | app-service response code 14 |
| Phone's agent service is shut down and does not come back within 5 s | canceled/disconnected response |

Side effect on the phone: an accepted handshake stores the sender as the "pending Phone Link
device"; the next file-transfer channel is attributed to it
(A: agents.filetransfer.manager.FileTransferSessionManager.setPendingPlDcgClientId).

---

## 3. Phone to PC

### 3.1 Path A: target is a `PL` remote app

All steps **[code-android] + [code-windows]**, none on the wire.

| # | Dir | Carrier | Message | Receiver's duty |
|---|---|---|---|---|
| 1 | PH> | relay, APP request, route `/legacy/phonecontent` | Value set, `contentType` `fileTransfer`, with `fileTransferFileDetail` (below) | Reply as for any content push. Windows hands the JSON to its receive service and completes the item (W: Processors.FileTransferProcessor). |
| 2 | PC> | relay, APP request `/nanohandshake` | section 2.3, `correlationVector` = `TransferId` | Phone starts its Nano server and returns its connection info. |
| 3 | both | Nano | connection established; the phone's workflow `fileTransfer` creates one Message channel and one Blob channel and opens both | PC opens its side with a delegate that receives messages and blobs (W: FileTransferSharingReceivingDelegate). |
| 4 | PC> | Nano Message channel, scope `/fileTransfer`, UTF-8 JSON | `Scenario` `FileTransferToPcFile`, `TransferId`, `SenderName`, `ReceivedFileCount`, `SessionTryCount`, `Content` | Phone looks up the pending offer, copies the statuses from `Content`, and sends the item whose status is 2. |
| 5 | PH> | Nano Blob channel | one blob, name = the item's `FileId`, size = `FileSize` | PC creates a temporary file with a random name in the download folder and appends each buffer it is handed (W: FileTransferReceivingStream). |
| 6 | | | repeat 4 and 5 per file | When a blob stream closes without error the PC renames the temporary file to `FileName` (unique-name policy on collision) and marks the item 3. |
| 7 | PC> | Message channel | `Scenario` `FileTransferToPcCompleted`, `ReceivedFileCount`, `Content` (all items with final statuses), `SessionTryCount`, `PcFolder` | Phone checks that **every** item it offered now has status 3; otherwise it ends with error `TRANSFER_PEER_ERROR` (A: FileTransferSession, completion handling for direction SEND). |
| 8 | PH> | Message channel | `Scenario` `FileTransferToPcCompleted`, `TransferId`, `SessionTryCount` | PC waits up to 10 s for this acknowledgement (W: FileTransferSharingReceivingDelegate.MessageTimeoutSec), then closes the channel and the Nano connection. |

Step 1 value set (A: agents.filetransfer.sync.FileTransferCoordinator; A: agents.sync.KvpMessageHelpers.getBaseMessageMap):

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `fileTransfer` |
| `fileTransferFileDetail` | String | JSON of section 2.1: `Scenario` `FileTransferToPc`, `TransferId`, `Content` with every item at status 1, `SessionTryCount` 1, `ReceivedFileCount` 0, `SenderName` and `PcFolder` empty |
| `correlationId` | String | trace correlation id |
| `contractVersion` | Double | 3.99 |
| `correlationVector` | String | |
| `dedupeID` | String | empty |
| `retryCount` | Int32 | 0 |
| `installationId`, display name, device status keys | as on every `/legacy/phonecontent` push | |

The trace state carries `ypScenarioId` = `fileTransfer`. The phone treats the send as failed
(`SEND_COMMAND_FAIL`) when the request result is anything other than success
(A: appmanager.filetransfer.domain.SendFilesUseCase.sendToPhoneLink).

Message format rule for step 4 **[code-windows]** (W: FileTransferReceivingSessionRetryHelper.IsUseMessageFormatV2):
when the offer's `SessionTryCount` is greater than 0 (always, with this phone build), `Content`
is the **full list** with statuses: the wanted file 2, finished files 3, the rest 1. With
`SessionTryCount` 0 it is a single-item list. The phone side accepts both: it reads statuses for
the ids present and sends the one marked 2 (A: FileTransferSession.updateFileManagerInfo).

Ordering, chunking, resume:

- Strictly one file at a time, in the PC's order **[code-windows]**.
- Chunk sizes are decided inside the native library; the application layer only sees buffers
  **[code-android]** (A: agents.filetransfer.transport.FileTransferBlob.getData) **[code-windows]**
  (W: FileTransferReceivingStream.WriteData).
- No byte-range resume. A failed file is requested again from the start, up to 3 attempts per
  file; the PC waits 10 s for a blob to start after each request **[code-windows]**
  (W: FileTransferSharingReceivingDelegate.ReceiveProcessAsync).
- Session-level retry counters exist (`MaxSessionRryCount` 2 on Windows) but no call site
  increments them in this build **[code-windows]**.
- One transfer at a time per Phone Link process (a semaphore; a second request is dropped with
  `CannotGetSemaphore`) **[code-windows]**.

Cancel: the phone sends `FileTransferToPcCancel` with `TransferId`; Windows closes the channel
(W: FileTransferSharingReceivingDelegate.OnMessageReceived). Any other scenario closes with
`UnknownScenario`.

### 3.2 Path B: target is a `WEA` remote app

Phone side **[code-android]**; PC side **[inferred]** from the phone's expectations.

| # | Dir | Carrier | Message | Notes |
|---|---|---|---|---|
| 1 | PH> | relay, PLATFORM `/DeviceResourceManager` | DRM request, type GET, path `/fileshare_android2cdeh_phase1`, payload `NanoDelegateInitRequest` | A: agents.filetransfer.platform.FileTransferRequestManager |
| 2 | PC> | relay, `/internal/response` | DRM response, payload `NanoDelegateInitResponse` | Phone proceeds only on status 1 |
| 3 | PC> | Nano | PC opens (or reuses) the platform device connection and creates a NamedStreams channel with scenario id `fileShare_2B0F3A34-0C30-4CC0-8165-87FC30DB1E35` | A: FileTransferSendChannelRequestHandler. The name "NanoDelegateInit" says the phone delegates the Nano setup to the PC |
| 4 | PH> | channel message, scope `/fileTransfer/platform`, protobuf | `FileShareMessage`, scenario `FileTransferToPc`, `transfer_id`, `content`, `session_try_count` 1 | Sent as soon as the channel opens (A: FileTransferPlatformAdapter) |
| 5 | PC> | channel streams | PC requests the files as named streams; the manifest entry id is the `file_id` | Phone serves each id from its pending list (A: FileTransferSendStreamProvider) |
| 6 | PC> | channel message | `FileShareMessage`, scenario `FileTransferToPcCompleted`, `content` with every item at status 3 | Same all-completed check as path A step 7 |
| 7 | PH> | channel message | `FileTransferToPcCompleted` acknowledgement, then the phone closes the channel | |

P: file_transfer/v1/session_info.proto:

| Message | Fields |
|---|---|
| `NanoDelegateInitRequest` | 1 `file_transfer_session_id` string (the phone's trace id, also the later `transfer_id`) |
| `NanoDelegateInitResponse` | 1 `file_transfer_session_id` string, 2 `status` enum, 3 `message` string |
| `NanoDelegateInitResponseStatus` | 0 UNSPECIFIED, 1 OK, 2 UNRECOGNIZED_PAYLOAD, 3 EMPTY_PAYLOAD, 4 INVALID_DEVICE_RESOURCE_REQUEST_TYPE, 5 INVALID_DEVICE_RESOURCE_REQUEST_PATH |

Phone-side outcome of step 2 (A: agents.filetransfer.model.FileTransferInitResponseStatus): DRM
failure or missing payload gives `REQUEST_FAILED`; an unparseable payload gives
`RESPONSE_UNRECOGNIZED_PAYLOAD`; any status other than OK ends the send with
`SEND_COMMAND_FAIL`. A DRM answer with `response_type` 2 (no handler) therefore fails the send
immediately.

On this path the phone accepts only two incoming scenarios: `FileTransferToPhone` and
`FileTransferToPcCompleted`. `FileTransferToPcFile` is **not** understood here and ends the
session with `DESERIALIZATION_FAILED` (A: agents.filetransfer.platform.FileTransferMessageListener).

NamedStreams sub-routes are built from the scenario id: `/<scenarioId>/Manifest`,
`/<scenarioId>/ManifestRequest`, `/<scenarioId>/ManifestAck`, `/<scenarioId>/NamedStreams<scope>`,
`/<scenarioId>/Messaging<scope>` (A: ...transport.channel.protocol.ChannelScopeUtils), with
`ProtoManifest`, `ProtoManifestEntry` (`id`, `size`, `metadata`), `ProtoManifestStreamRequest`,
`ProtoFile`, `ProtoTransferComplete`, `ProtoManifestAck` (P: platform_sdk/v1/manifest.proto)
**[code-android]**. Their sequencing was not traced.

### 3.3 Where Windows stores the file, and the notification **[code-windows]**

- Folder: local setting `FileTransferDownloadFolderKey` if present, else the user's Downloads
  folder plus `Phone Link` (W: Utilities.FileTransferFileSystemHelper.GetFilesDownloadPath;
  SharedContentConstants.FileTransferDefaultFolderName).
- Written under a random temporary name in that folder, renamed to the offered `FileName` with
  the "generate unique name" collision policy after the stream closes cleanly; deleted on error.
- One toast when at least one file arrived: single-file form with the file path, or multi-file
  form with the folder (W: FileTransferApplicationService.FileReceivedEvent; FileTransfer.Views.FileTransferNotification).
  Toast actions carry `OpenFile`, `OpenFolder`, `Cancel:` and `TransferId`.

### 3.4 Limits and multiple files

- Several files in one share are one offer with several `Content` items, transferred one after
  another in one Nano connection **[code-android] + [code-windows]**.
- No size limit and no file-count limit exist in the Android path of either code base
  **[code-android] + [code-windows]**. (The 100-file limit and the 300 s rate window in
  `SharedContentFeatures` apply to iPhone/OneDrive only.)
- The phone refuses a second transfer while one is active: per peer, and globally for `PL`
  peers (A: FileTransferSessionManager.createSession, hasActiveBaseChannelSession).

Phone error codes (A: agents.filetransfer.constants.FileTransferError), useful when reading
phone logs: `LOST_CURRENT_FILE` -1, `TRANSFER_CHANNEL_LOST` -2, `TRANSFER_PEER_ERROR` -3,
`FILE_NOT_FOUND` -4, `SEND_COMMAND_FAIL` -5, `CONNECTION_UNKNOWN_ERROR` -7,
`CONNECTION_USER_ENDED` -8, `CONNECTION_KEEP_ALIVE_TIMEOUT` -9, `CONNECTION_PEER_ENDED` -10,
`TRANSFER_IN_PROGRESS` -11, `FILE_MANAGER_INFO_SYNC_FAILED` -12, `FILE_WRITING_FAILED` -13,
`DESERIALIZATION_FAILED` -14, `PLATFORM_UNKNOWN_ERROR` -15, `PLATFORM_STREAM_NOT_READY` -16,
`PLATFORM_ERROR_CLOSED_STREAM` -17, `TRANSFER_IN_PROCESS_OTHER_PLATFORM` -18,
`INITIALIZING_FILE_LIST_FAIL` -19, `FILE_HANDLER_LOST` -20, `NANO_KEEP_ALIVE_TIMEOUT_RETRIED` -22,
`STREAM_CANCELED` -30 to `STREAM_UNKNOWN_ERROR` -37, `SEND_COMMAND_FAIL_WEBLINK` -38.

---

## 4. PC to phone

### 4.1 Path A: sender is the `PL` client

Preconditions checked by Phone Link before anything is sent **[code-windows]**
(W: FileTransferApplicationService.CheckAndroidDeviceStatusAsync):

| Check | Failure |
|---|---|
| Device connectivity state is connected | `NoConnection` |
| `fileTransferCapabilities` has bit 1 | `LTWNotUpdated` |
| Phone permission `shared_content` is true; if not, one silent `/permission` request for `DevicePermissions.SharedContent` (value `0x400`) | `NeedsPermission` |

Steps **[code-windows] + [code-android]**:

| # | Dir | Carrier | Message | Receiver's duty |
|---|---|---|---|---|
| 1 | PC> | relay, APP `/nanohandshake` | section 2.3, `workflow` `fileTransfer`, `correlationVector` = new transfer GUID | Phone starts its Nano server; rejects with `workflowInProgress` if busy. |
| 2 | both | Nano | connection; phone creates and opens Message and Blob channels | |
| 3 | PC> | Message channel `/fileTransfer`, JSON | `Scenario` `FileTransferToPhone`, `TransferId`, `SenderName` (machine name), `ReceivedFileCount` 0, `SessionTryCount` 1, `Content` (every item status 1, `FileHash` empty) | Phone creates a receive session for the pending Phone Link device. If another transfer is active it answers `FileTransferToPhoneRejected`. |
| 4 | PH> | Message channel | `Scenario` `FileTransferToPhoneFile`, `TransferId`, `ReceivedFileCount`, `SessionTryCount`, `Content` = full list, the wanted item at status 2 | PC updates its statuses and progress, then sends that item. |
| 5 | PC> | Blob channel | one blob named `<FileId>#<n>`, `n` counting sends of that file from 1 | Phone strips everything from `#`, finds the item, writes the bytes. An unknown id ends with `LOST_CURRENT_FILE`. |
| 6 | | | repeat 4 and 5 until every item is 3 | |
| 7 | PH> | Message channel | `Scenario` `FileTransferToPhoneCompleted`, `Content` with final statuses, `ReceivedFileCount`, `SessionTryCount`, `TransferId` | PC marks success and closes the channel and the connection. |

Pointers: W: FileTransferSharingSendingDelegate (`Send`, `OnMessageReceived`, blob id format,
`RetrieveFileId`); W: FileTransferSendingStream; A: agents.filetransfer.transport.FileTransferChannelListener;
A: agents.filetransfer.transport.FileTransferReceiveBlobProvider; A: agents.filetransfer.manager.FileTransferSession.

Details:

- In single-item format (never used with this phone build) the PC expects exactly one item in
  `Content` of step 4; in V2 it picks the item with status 2. No such item closes the transfer
  with an error **[code-windows]**.
- The PC stream object reports the remaining size and hands out buffers of at most the size the
  native library asks for; progress is `bytes read / file length`, scaled by `1 / file count`
  **[code-windows]** (W: FileTransferSendingStream.GetSize, GetData).
- Cancel on the PC closes the channel; the phone then ends with a connection error. The phone's
  own cancel arrives as `FileTransferToPcCancel`, which the Windows sending delegate does not
  know and treats as `Unknown Scenario` (it closes) **[code-windows]**.
- Rejection mapping on Windows: `OpenFileFailed`, `FileTransferToPhoneRejected` and
  `Nano - DeviceLocked` count as "rejected", everything else as "failed" **[code-windows]**
  (W: FileTransferSharingService.IsRejectedError).

### 4.2 Path B: sender is the `WEA` client

Phone side **[code-android]**; the PC side is CDEH and **[inferred]**.

| # | Dir | Carrier | Message | Notes |
|---|---|---|---|---|
| 1 | PC> | relay, DRM GET `/fileshare` | `FileTransferRequestMessage{request_type 1 PERMISSION}` | **[wire]** C-pair: 249 (legacy resource type 9, payload one varint field = 1) |
| 2 | PH> | relay | `FileTransferResponseMessage{status}` | **[wire]** C-pair: 262 (status 1) |
| 3 | PC> | Nano | NamedStreams channel, scenario id `fileShare_FDF73A34-0C30-4CC0-8165-87FC30DB1E35` | Phone's acceptance: wrong scenario gives `INVALID_SCENARIO` 6; no files permission gives `PERMISSION_REVOKED` 2; an active session with this peer gives `NOT_SUPPORTED` 5; else `SUCCESS` 1 (A: FileTransferReceiveChannelRequestHandler; P: platform_channel.proto :: ChannelAcceptanceStatus) |
| 4 | PC> | channel message, scope `/fileTransfer/platform` | `FileShareMessage`, scenario `FileTransferToPhone`, `transfer_id`, `content`, optional `is_concurrent_mode` | A second offer while not in the initial state is ignored |
| 5 | PH> | channel message | scenario `FileTransferToPhoneFile`, full `content`, `received_file_count`, `session_try_count`, `is_concurrent_mode` echoed | |
| 6 | PC> | channel streams | named streams, manifest entry id = `file_id`, size = file size | Phone writes each stream to the receive folder (A: FileTransferReceiveStreamProvider) |
| 7 | PH> | channel message | `FileTransferToPhoneCompleted` when all items are 3 | Without `is_concurrent_mode` the phone repeats step 5 after each file; with it, it waits for all streams |

P: file_transfer/v1/get.proto:

| Message | Fields |
|---|---|
| `FileTransferRequestMessage` | 1 `request_type`: 0 UNSPECIFIED, 1 PERMISSION |
| `FileTransferResponseMessage` | 1 `status`: 0 UNSPECIFIED, 1 OK, 2 FEATURE_NOT_SUPPORT, 3 INVALID_DEVICE_RESOURCE_REQUEST_TYPE, 4 UNRECOGNIZED_PAYLOAD, 5 INVALID_FILE_TRANSFER_REQUEST_TYPE, 6 MISSING_PERMISSION |

`/fileshare` is served by the phone for GET only; it answers OK when the phone holds its files
permission, else MISSING_PERMISSION (A: agents.filetransfer.platform.FileTransferResourceRequestHandler).
This single exchange is the only part of any file transfer that is wire-confirmed, and it works
over the relay.

### 4.3 Where the phone stores the file **[code-android]**

- Folder: public Downloads directory plus `Received from PC`, plus a sub-folder named after the
  sending device's display name when known (A: appmanager.filetransfer.api.FileTransferStorageContract).
  An older folder `Send from my PC` is migrated.
- Name collisions get a suffix ` (2)`, ` (3)` and so on before the extension
  (A: agents.filetransfer.utilities.FileTransferUtils.getValidFileName).
- A file whose stream closes with an error is kept only if the bytes written equal `FileSize`;
  otherwise it is deleted and the item returns to status 1 (A: FileTransferWriter.close).
- After the session the phone records history, rescans the folder and posts a notification
  (A: FileTransferSessionManager.persistReceivedFiles).

---

## 5. OneDrive path (iPhone only)

Not usable with an Android phone: Phone Link's receiver explicitly returns "incorrect device
status" for Android (W: FileTransfer.Ddps.FileTransferDdpsCallback.CheckDeviceStatus), the
sender picks OneDrive only when bit 1 of `fileTransferCapabilities` is absent (section 1.2),
and Link to Windows for Android contains no OneDrive transfer code. Recorded here because the
question keeps coming up and because the strings are registered by both Windows clients.

### 5.1 HTTP calls made by Phone Link **[code-windows]** (W: YourPhone.YPP :: BlobManager.OneDriveAPIHelper, FileBlobManager, Utilities.FileBlobConstants)

Host `graph.microsoft.com`, bearer token on every call.

| Purpose | Method and path |
|---|---|
| Drive and quota | `GET /v1.0/me/drive` |
| Find the agreed folder (name `Microsoft File Share`, in the drive root) | `GET /beta/me/drive/root/children?select=id,name,size,fileSystemInfo,file,folder,fileTransfer_4c55fb25,fileTransfer_40b22624` |
| Create it | `POST /v1.0/me/drive/root/children` (JSON folder body) |
| List transfers | `GET /beta/me/drive/items/{folderId}/children?select=...` (same select) |
| Start an upload | `POST /v1.0/me/drive/items/{folderId}:/{escaped file name}:/createUploadSession`, header `Prefer: pacToken=N`, JSON body; on 400 or 403 the same call is repeated once with `?whatin` for diagnostics |
| Upload bytes | `PUT {uploadUrl}` with `Content-Range`, at most 10,485,760 bytes per request (`MaxHttpsBodyBufferSize`); 202 continues, 200 or 201 finishes; on 416 the session is queried with `GET {uploadUrl}` and resumed from the reported range |
| Tag the item | `PATCH /beta/me/drive/items/{itemId}?select=fileTransfer_4c55fb25`, JSON custom facet `fileTransfer_4c55fb25` with `senderId`, `receiverId`, `quickXorHash`, `sessionId`, `sessionFileCount` (the phone's facet is `fileTransfer_40b22624`) |
| Item metadata | `GET /beta/me/drive/items/{itemId}?select=...` |
| Download | `GET /v1.0/me/drive/items/{itemId}?select=@microsoft.graph.downloadUrl` (header `Prefer: pacToken=N`), then `GET {downloadUrl}` |
| Delete | `DELETE /v1.0/me/drive/items/{itemId}` and `POST /v1.0/me/drive/items/{itemId}/permanentDelete` |

HTTP client timeout 120 s; retries on network errors, 5xx, 403, 408 and similar. Blobs have a
time to live of 14,400 s by default (minimum 900 s). Integrity uses OneDrive's QuickXorHash
(W: FileTransfer.Streaming.QuickXorHash).

Control plane around it: after uploading, the PC wakes the iPhone through DCG `/Dispatcher/Wake`
with an APNs alert whose payload lists the session and file ids (tags `FileTransferSingle`,
`FileTransferMultiple`; at most 10 ids per payload). In the other direction the phone sends a
DRM request, type SYNC, path `/fileTransfer`, payload UTF-8 JSON `DdpsPayloadItem`
(`FileTransferSessionId`, `FileIds`, `Tag`, `VersionCode` 1, `SenderId`; tags `IOS_ONEDRIVE`,
`CHECK_STATUS`, `DEPRECATE_PHONE_LINK`), and the PC downloads the listed items
(W: FileTransferDdpsCallback; P: file_transfer/v1/session_info.proto :: DdpsPayloadItem).

### 5.2 Token and account **[code-windows]** (W: BlobManager.BlobManagerTokenProvider)

- Account: the consumer Microsoft account signed in to Phone Link (provider
  `https://login.microsoft.com`, authority `consumers`), token fetched silently through the
  Windows web account manager.
- Client id: `8CF55838-E496-42C5-829B-F8D6945288F3` (`MsaAppId`, the same id Phone Link uses for DCG).
- Scope: `Files.ReadWrite`. A second scope, `https://my.microsoftpersonalcontent.com/v2/Files.ReadWrite`,
  is defined for direct content access.

A token for `https://dcg.microsoft.com/DCG.ReadWrite` has the DCG service as its audience and is
not a Graph token; it **does not suffice** for these calls **[inferred]** from the separate
token request and scope. A client would need a second token for `Files.ReadWrite`. Whether the
device-code flow with this client id grants that scope without further consent is untested
(section 9).

### 5.3 Capture check **[wire]**

`captures/vm-raw-2026-10-09/hosts.log` lists 127 TLS connections. No OneDrive host appears
(none of `api.onedrive.com`, `*.1drv.com`, `*.sharepoint.com`, `my.microsoftpersonalcontent.com`).
`graph.microsoft.com` appears twice, each time about two seconds after a `login.live.com`
connection; the requests themselves were not recorded. **[inferred]** an account profile
lookup after token refresh, unrelated to file transfer.

### 5.4 Is there a non-OneDrive path a third-party client can use?

For Android the only paths are A and B, and both need Nano. There is no relay-only variant.

---

## 6. Phone files (`/filesmetadata`, publish tag 4)

### 6.1 What it is

The phone exposes its shared storage (MediaStore-backed file index) to the PC: full and
incremental metadata sync, thumbnails, create, rename, move, delete with a recycle bin, and
storage totals **[code-android]** (A: agents.files.*; P: phone_files/v1/*). On Windows it is a
CDEH feature: the capture names the scenario `CDEH.PhoneFiles.FullSyncToLocalDB` **[wire]**
(C-pair: 279), Phone Link contains no `/filesmetadata` client, and Phone Link locates the result
as a storage-provider sync root per device (W: StartMenu.PhoneFilesManager) **[code-windows]**.
**[inferred]** this is the "phone in File Explorer" integration. Owner: `WEA`.

Gates on the phone **[code-android]**: capability string `PHONE_FILES`; an experiment switch
(A: appmanager.phonefiles.PhoneFilesExpManager.isPhoneFilesEnabledWithNewPlatform) which, when
off, makes every `/filesmetadata` request answer status 8 FEATURE_DISABLED; and the phone's
all-files permission, reported in the configuration publish.

### 6.2 DRM requests on `/filesmetadata` (PC to phone, over the relay)

Outer message: `DeviceResourceManagerMessage` with the path `/filesmetadata`; CDEH also sets the
legacy resource type 1 **[wire]**. The request type selects the payload type **[code-android]**
(A: agents.files.transport.FilesResourceRequestHandler):

| DRM type | Request payload | Response payload |
|---|---|---|
| 4 SYNC | `FilesSyncRequest{config_sync_request{}}` | `FilesSyncResponse{status}`. **[wire]** C-pair: 349; C-raw: 36, 96 (24-byte DRM message each). **[inferred]** the phone then publishes its configuration (6.3): in C-raw a 1405-byte tag-4 publication follows each request (47 after 36, 101 after 96) and the handler is named `FilesConfigurationSyncRequestHandler` |
| 1 GET | `FilesGetRequest` with one of `thumbnail_request` (1), `files_metadata_sync_request` (2), `prefetch_thumbnail_request` (3), plus `request_id` (4) | `FilesGetResponse{status, one of thumbnail_response (2), files_metadata_sync_response (3), prefetch_thumbnail_response (4), request_id (5)}` |
| 2 UPDATE | `FilesUpdateRequest` with one of `create_file_request` (1), `create_folder_request` (2), `rename_request` (3), `move_file_request` (4), `move_folder_request` (5) | `FilesUpdateResponse{status, optional target_metadata}`. **[wire]** create-folder requests and answers, C-relay: 91 to 178 |
| 3 DELETE | `FilesDeleteRequest{target_uri, target_checksum, is_batch, batch_requests[]}` | `FilesDeleteResponse{status, target_uri, is_batch, batch_responses[]}` |

Key messages (field numbers from P: phone_files/v1):

- `FileMetadata`: 1 `id` int64, 2 `uri` string, 3 `name`, 4 `path`, 5 `file_type` (0 UNSPECIFIED,
  1 IMAGE, 2 VIDEO, 3 AUDIO, 4 DOCUMENT, 5 PLAYLIST, 6 SUBTITLE, 7 NONE), 6 `size` int64,
  7 `created_time`, 8 `modified_time` (protobuf Timestamp), 9 `checksum` int64, 10 `is_directory` bool.
- `GetFilesMetadataSyncRequest`: 1 `sync_type` (1 FULL_SYNC, 2 INCREMENTAL_SYNC), 2 `seq_num`,
  3 `is_user_initiated`, 4 `supports_batched_response`, 5 `batch_continuation_token`,
  6 `is_no_engagement_sync` (all optional except 1).
- `FullFileSyncPayload`: 1 `metadata[]`, 2 `ending_sequence_number`, 3 `full_sync_max_capacity_reached`,
  4 `has_more_batches`, 5 `batch_continuation_token`, 6 `batch_index`, 7 `estimated_total_items`,
  8 `provisional_ending_sequence_number`.
- `IncrementalFileSyncPayload`: 1 `sync_operation[]` (each one of `create`, `update`, `delete`,
  carrying a `FileMetadata`), 2 `starting_sequence_number`, 3 `ending_sequence_number`.
- `GetThumbnailRequest`: 1 `target_uri`, 2 `target_checksum`, 3 `width`, 4 `height`, 5 `request_id`.
  `GetThumbnailResponse`: 1 `metadata`, 2 `thumbnail` bytes, 3 `status`.
- `FilesResponseStatus`: 0 UNSPECIFIED, 1 SUCCESS, 2 NO_PERMISSION, 3 NOT_FOUND,
  4 CHECKSUM_MISMATCH, 5 IO_ERROR, 6 NOT_SUPPORTED, 7 REQUEST_NOT_SET, 8 FEATURE_DISABLED,
  9 PLATFORM_ERROR, 10 CANCELLED, 11 SYNC_FAILED, 12 BATCH_RESTART_REQUIRED.

Behaviour **[code-android]**:

- A thumbnail request carries the item's `checksum`; a mismatch answers status 4
  (A: agents.files.thumbnail.FilesThumbnailRequestHandler). Rename, move and delete requests
  carry the same field (P: update.proto, delete.proto); **[inferred]** they are checked the same way.
- A full sync with `supports_batched_response` true is paged with an opaque continuation token
  (P: batch_token.proto :: BatchedSyncContinuationToken is its content); status 12 means "start
  over" (A: agents.files.transport.FilesMetadataGetRequestHandler).
- A thumbnail is produced with the platform's `ContentResolver.loadThumbnail` at the requested
  size (A: agents.files.thumbnail.ContentResolverThumbnailProvider); unsupported types answer
  status 6.
- A metadata request without `is_no_engagement_sync` counts as user engagement on the phone.

### 6.3 Publications with tag 4 (phone to PC)

`MsaepMessage{message_tag 4}`, `PubSubPayload.additional` = `FilesResponsePayload`
(P: phone_files/v1/response_payload.proto), one of:

| Field | Message | Content |
|---|---|---|
| 1 | `FilesConfigurationPayload` | 1 `capability`, 2 `permission`, 3 `thumbnail_supported_file_types[]`, 4 `thumbnail_prefetch_config[]` (`name`, `path`, `prefetch_count`, `add_to_pictures_library`), 5 `gigabyte_to_byte`, 6 `recycle_bin_path`, 7 `batch_delete_capability`, 8 `is_get_thumbnail_over_nano_mobile_enabled`, 9 `is_prefetch_thumbnails_over_nano_mobile_enabled`, 10 `is_files_request_over_nano_capable`, 11 `is_wifip2p_permission_manager_capable`, 12 `is_wifip2p_permissions_granted`, 13 `is_image_semantic_search_permission_granted` |
| 2 | `FilesSyncUpdateMessage` | 1 `sync_type`, 2 `seq_num`: "something changed, sync from here" |
| 3 | `StorageInfoPayload` | 1 `available_size_bytes`, 2 `total_size_bytes` |

**[wire]** all three kinds decoded in C-relay: 33, 103, 113. In C-raw there are 49 tag-4
publications in three sizes of the publish body: 1405 bytes (25 times), 16 bytes (16 times),
6 bytes (8 times) (C-raw: 21, 47, 101; 496, 540). **[inferred]** from the sizes: configuration,
storage info, sync update. Each must be answered with JSON `{}` like any publish.

### 6.4 How a file's content is fetched

Not over the relay. Three NamedStreams platform channels exist, all on the Nano device
connection **[code-android]**:

| Scenario id | Purpose | Message scopes |
|---|---|---|
| `fileTransfer_1EAA053C-0354-4DF8-AA05-888312CCC57E` | File content, both directions (download a file; upload into a file made with `create_file_request`) | `/com.microsoft.mmx.agents.files.transport.create_file_response`, `/com.microsoft.mmx.agents.files.transport.files_stream_error` (payload `FilesStreamsMessage`: 1 `file_uri`, 2 `stream_message_status`, 3 `content`) |
| `thumbnailTransfer_2FAB064D-0465-5EF9-BB16-999423DDD68F` | Thumbnails over Nano | `/getThumbnailRequest`, `/prefetchThumbnailsRequest`, `/getThumbnailResponse`, `/prefetchThumbnailsResponse`, `/thumbnailErrorResponse` |
| `filesRequestTransfer_3GAC175E-1576-6FA0-CC27-000534EEE79G` | Metadata requests over Nano | `/filesRequest`, `/filesRequestResponse` |

Pointers: A: agents.files.transport.FilesChannelRequestHandler, FileTransferMessenger;
A: agents.files.transport.thumbnail.ThumbnailChannelRequestHandler, ThumbnailContentManager;
A: agents.files.transport.filesrequest.FilesRequestChannelRequestHandler, FilesRequestContentManager.

### 6.4a Addendum of 2026-10-10: a second reading of the phone's code, and the Mac client

Corrections and details **[code-android]** (A: agents.files.*, appmanager.phonefiles.*):

- The "experiment switch" of 6.1 is no experiment in this build:
  `isPhoneFilesEnabledWithNewPlatform()` is `SystemUtils.isAPI30OrAbove()`. Android 11 or later
  has the feature; older phones answer status 8.
- The permission is Android's "all files access" (`Environment.isExternalStorageManager()`) on
  API 30 and later. Every GET without it answers status 2. SYNC is not gated: it reports
  `permission = false` in the configuration.
- The answer to SYNC is sent only once the configuration publication has been taken by the PC
  (A: sync.FilesPayloadPublishHelper.publishConfigPayload): the publication comes first.
- **[live, 2026-10-10 19:59]** In practice that answer can take very long: the phone sends the
  publication to every computer linked to it (here both of the Mac's sessions got it 0.3 s
  after the SYNC) and, per its code, first waits for each target's connection
  (`SignalRContextSource.ensureConnectedAsync`, `SignalRPublishActivityObserver` waits for all
  attempts). With a linked PC switched off, no answer came within a minute. The Mac client
  therefore goes on as soon as the configuration publication is here (or after 8 s without
  one) and takes the SYNC answer whenever it comes.
- The listing is a **flat index** of MediaStore's `Files` table of the volume `external`,
  folders being rows too; names beginning with a dot are left out. There are no requests per
  folder: the PC builds the tree from `path`.
- Unbatched full sync: one answer, at most 50,000 rows, newest first; field 3 says when cut.
  Batched (`supports_batched_response`, empty token first): 5,000 rows a batch by `_id`, the
  token of each answer for the next, `has_more_batches` false on the last, which alone carries
  `ending_sequence_number`. The phone keeps a batch session for ten minutes and 200 batches;
  anything out of step answers status 12.
- `is_user_initiated` makes the phone rescan its storage first. Before each metadata answer it
  publishes `StorageInfoPayload`. A change on the phone is published as `FilesSyncUpdateMessage`;
  the PC then asks for an incremental sync from its last sequence number.
- Thumbnails come from `ContentResolver.loadThumbnail` and are scaled down to about 179,000
  pixels, then JPEG. So 6.5's guess is wrong: a large requested size does **not** give a usable
  copy of a picture. Kinds with thumbnails: image, video, audio.
- A file's bytes: the PC opens a NamedStreams channel of the scenario in 6.4 on the Nano
  connection and sends `/<scenario>/ManifestRequest` with a `ProtoManifest` whose entry `id` is
  the file's `uri`; the phone answers with a blob of that id, and closes the channel after each
  file. No recording of this exists; the Windows client for it (CDEH) is not in the corpus.

The Mac client [built, never run against the phone]: `Features/PhoneFilesSync.swift` on the
`WEA` session (`RoleSession.storage`): SYNC, then the batched full list, then incremental syncs
when the phone publishes a change; thumbnails by GET; `PhoneFileTree` turns the flat list into
folders (and makes up folders the phone lists no row for). The app's **Phone Storage** section
asks only when it is opened. Nothing on the phone is written or deleted.

A file's content [built, never run against the phone]: `NanoFileReceiver.fetch` reuses the
recorded exchange of a share on this session (`nano-wire-notes.md` 10.8) with two changes:
the channel is asked for under the scenario `fileTransfer_1EAA053C-…`, and instead of waiting
for an offer the PC sends `/<scenario>/ManifestRequest` as soon as the scenario's message
channel is greeted, with one entry whose key and `id` are the file's `uri` and whose `size`
is the listed size. The blob that arrives under that name is the file; the blob reports of a
share end it; a message on `…/files_stream_error` or a refused channel ends it with the reason.
One file per connection (`PhoneFileReceiver.fetch`, `LinkController.downloadPhoneFile`), over
the direct connection only, so both devices must be on one network. What CDEH puts in the
manifest's `size` and `metadata` is not known.

Tests: `PhoneFilesTests` (a phone scripted from the code above),
`testAFileOfThePhonesStorageIsFetchedByItsAddress` and its failing twin, app tests in
`PhotoExportTests`. Open: whether batches of 5,000 rows pass the relay; what the phone shows
its user when the permission is missing; whether the phone takes the manifest as sent.

### 6.5 Is it a simpler way to fetch a file from the phone?

No for arbitrary files: content needs the same Nano connection as path B, plus the NamedStreams
layer. Yes for two narrower needs that work on the relay alone:

1. **Browsing**: SYNC for configuration, GET for full or incremental metadata, tag 4 for change
   signals. This gives names, paths, sizes, dates and types of everything on shared storage.
2. **Previews**: GET `thumbnail_request` with a chosen width and height returns image bytes in
   the DRM response. A large requested size may give a usable copy of a picture
   **[inferred]**, not tested; the encoding and any upper bound were not determined.

Photos specifically are better served by the existing `/media/v1` route (`photos.md`), which
returns full images over the relay.

---

## 7. Minimum viable client

### 7.1 (a) Receive one file the user shares from the phone

Smallest path is A (the first message arrives on the relay and no CDEH behaviour has to be
guessed). Requirements, in order:

1. `PL` identity connected, `/connect/v1` done. Do **not** register `FILE_TRANSFER` on the `WEA`
   identity, so that the phone offers only the `PL` entry (section 1.3).
2. Handle APP `/legacy/phonecontent` with `contentType` `fileTransfer`: read
   `fileTransferFileDetail`, parse the JSON, require `Scenario` = `FileTransferToPc`, reply
   success.
3. Send APP `/nanohandshake` (section 2.3) with the PC's Nano connection info and
   `workflow` `fileTransfer`; read `handshake` from the reply.
4. **Nano**: connect as client; accept the phone's Message and Blob channels.
5. Send `FileTransferToPcFile` on `/fileTransfer` with the full `Content`, first item status 2.
6. Receive one blob, write it to a temporary file, rename to `FileName`.
7. Send `FileTransferToPcCompleted` with `Content` (item status 3), `ReceivedFileCount` 1,
   `SessionTryCount` echoed, `PcFolder`; wait up to 10 s for the phone's
   `FileTransferToPcCompleted`; close.

Steps 2, 3, 5 and 7 are plain messages we can build today (`ValueSet`, `PeerMessenger.appRequest`,
JSON). Steps 4 and 6 need the Nano transport.

### 7.2 (b) Send one file from the PC so it appears on the phone

Path A again:

1. `PL` identity connected; `/connect/v1` reply has `fileTransferCapabilities` bit 1 and
   `permissions.shared_content` true (else send a `/permission` request for the shared-content
   permission, `0x400`; **[inferred]** that the request uses the same numbering as the other
   permission types in the session spec, section 7.6).
2. APP `/nanohandshake`, `workflow` `fileTransfer`.
3. **Nano**: connect; accept the two channels.
4. Send `FileTransferToPhone` with one `Content` item (new GUID, name, size, status 1),
   `SessionTryCount` 1.
5. On `FileTransferToPhoneFile`, send the file as one blob named `<FileId>#1`.
6. On `FileTransferToPhoneCompleted`, close. On `FileTransferToPhoneRejected`, report "phone busy".

Again only step 3 and the blob in step 5 are out of reach.

### 7.3 What can be shipped without Nano

| Piece | Messages | Value |
|---|---|---|
| Fail fast instead of hanging | Answer the `fileTransfer` push with a rejection so the phone reports a send failure at once rather than waiting for a handshake that never comes | Honest UX. The exact reply that produces an immediate failure is an open question (section 9) |
| Show what was offered | Parse `fileTransferFileDetail` | The Mac can tell the user which files the phone tried to send and why it cannot take them |
| Browse phone storage | `WEA` identity: DRM SYNC and GET on `/filesmetadata`, subscribe to tag 4 | File list and thumbnails |
| Permission probe | `WEA` identity: DRM GET `/fileshare` | Tells whether the phone would accept an incoming share |

---

## 8. Feasibility for a macOS client with a `PL` and a `WEA` identity connected

| Goal | Verdict | Needs |
|---|---|---|
| Receive a file shared from the phone | **Blocked on Nano.** Request handling and all control messages are buildable now | Nano client: connection from the `/nanohandshake` info, Message channel, Blob channel receive |
| Send a file to the phone | **Blocked on Nano.** Same | Nano client plus Blob channel send |
| Either direction through the `WEA` path | Blocked on Nano, and more work than path A: context-source signalling, platform channel creation, NamedStreams manifests, and CDEH behaviour that is not decompiled | Nano plus the platform channel layer |
| OneDrive transfer | **Not available** for Android phones, whatever token we hold | n/a |
| Relay-only transfer of arbitrary files | **Does not exist** in the protocol | n/a |
| Browse the phone's files, thumbnails, rename, move, delete | **Buildable now** on the `WEA` identity with `DeviceResources`, `ContextPublisher` and the generated `PhoneFiles_V1_*` types; subject to the phone's experiment switch and files permission | nothing new |
| Get a photo from the phone to the Mac | **Already built** through `/media/v1` | nothing new |
| Small text or image either way | **Already built** through the clipboard | nothing new |

Recommendation: treat file transfer as the first consumer of the Nano work item in `PLAN.md`
(step 8). Path A is the right first target because its Nano usage is the smallest: one
connection, one message channel with a single scope, one blob channel, PC as client. Screen
mirroring uses the same connection service and handshake route, so the investment carries over.

### 8.1 Swift pieces that already exist

| Need | Existing code |
|---|---|
| APP requests and replies, `/legacy/phonecontent` handler | `Messaging/PeerMessenger.swift`, `Messaging/ValueSet.swift` |
| DRM requests and serving | `Platform/DeviceResources.swift` (sends resource type UNKNOWN with the path, which the phone accepts) |
| Tag 4 subscription | `Platform/ContextPublisher.swift`, `Tag.phoneFiles` |
| Path B and `/fileshare` messages | `Generated/file_transfer_v1_get.pb.swift` (`FileTransfer_V1_FileTransferRequestMessage`, `FileTransfer_V1_FileTransferResponseMessage`, their two enums); `Generated/file_transfer_v1_session_info.pb.swift` (`FileTransfer_V1_NanoDelegateInitRequest`, `FileTransfer_V1_NanoDelegateInitResponse`, `FileTransfer_V1_NanoDelegateInitResponseStatus`, `FileTransfer_V1_DdpsPayloadItem`); `Generated/file_transfer_v1_transfer_info.pb.swift` (`FileTransfer_V1_FileShareMessage`, `FileTransfer_V1_FileShareContentMessage`, `FileTransfer_V1_FileShareFileStatus`) |
| Phone files | `Generated/phone_files_v1_*.pb.swift`: `PhoneFiles_V1_FilesSyncRequest`, `FilesSyncResponse`, `FilesGetRequest`, `FilesGetResponse`, `GetFilesMetadataSyncRequest`, `GetFilesMetadataSyncResponse`, `FullFileSyncPayload`, `IncrementalFileSyncPayload`, `GetThumbnailRequest`, `GetThumbnailResponse`, `PrefetchThumbnailRequest`, `PrefetchThumbnailResponse`, `FilesUpdateRequest`, `FilesUpdateResponse`, `FilesDeleteRequest`, `FilesDeleteResponse`, `FileMetadata`, `FilesResponsePayload`, `FilesConfigurationPayload`, `FilesSyncUpdateMessage`, `StorageInfoPayload`, `FilesStreamsMessage`, `BatchedSyncContinuationToken`, and the enums |
| Platform channel and context-source messages (for later Nano work) | `Generated/platform_sdk_v1_platform_channel.pb.swift`, `platform_sdk_v1_manifest.pb.swift`, `platform_sdk_v1_context_source.pb.swift` |
| Missing | A Codable type for the JSON of section 2.1; a `/nanohandshake` request builder; everything Nano |

---

## 9. Open questions

1. **Nano wire protocol.** Handshake content, key exchange for the SRTP-named connection types,
   channel creation and blob framing are all inside the native libraries. Nothing here can be
   finished without it. A capture of one real transfer on the same LAN (transport type `IP`)
   next to the `/nanohandshake` exchange would be the best starting material.
2. **Which path does a real Windows PC take with this phone today?** Reasoned to be path B
   (section 1.2) but never observed. One "Send to PC" and one "send to phone" with the capture
   running would settle it and would show CDEH's side of path B.
3. **Fail-fast reply.** Which answer to the `fileTransfer` push makes the phone show an immediate
   failure without retrying: a rejection header, or a non-zero `result`? The phone's
   `RequestResult.Status` distinguishes `REMOTE_REJECTED` and `REMOTE_UNSUBSCRIBED` from
   `SUCCESS`, but the retry policy for this content type was not traced.
4. **How long does the phone wait** between its offer and the PC's `/nanohandshake` before it
   gives up, and what does the share screen show meanwhile? Not traced in
   `appmanager.filetransfer.viewmodel.FileTransferViewModel`.
5. **Two share targets.** With different `distinguishedDeviceId` values the phone will list our
   `PL` and `WEA` identities separately if `WEA` registers `FILE_TRANSFER`. Confirm on the live
   phone that leaving `FILE_TRANSFER` off shows exactly one entry.
6. **Workflow start inside Nano.** How the PC tells the phone which workflow (`fileTransfer`) to
   start on a fresh connection, beyond the `workflow` key of the handshake
   (W: AppProxyConnection.ConnectionSvc.Workflow.WorkflowMessageChannel) was not traced.
7. **NamedStreams sequencing** on path B (manifest, request, ack, stream, transfer complete)
   and whether `/Channel/...` messages can ever travel on the relay rather than on the device
   connection.
8. **Phone files experiment switch.** Whether it is on for every phone or only for some; on the
   test phone the feature answers and publishes **[wire]**, other phones may return status 8.
9. **Thumbnail size ceiling and encoding** for `GetThumbnailRequest` over the relay.
10. **Graph token for our client id.** Only relevant if iPhone support is ever wanted: can the
    device-code sign-in with `8CF55838-...` obtain `Files.ReadWrite`?
11. **Purpose of CDEH's repeated create-folder requests** on `/filesmetadata` seen in C-relay.

---

## 10. Corrections to earlier project documents

- `PLAN.md` section 2.3 lists file transfer as "Relay route plus OneDrive upload sessions".
  For Android that is wrong: it is a relay request plus a Nano connection. OneDrive is the
  iPhone path.
- `session-clipboard-notifications.md` section 5.2 lists `/fileTransfer` as a resource Phone Link
  serves "from phone". It is served for iPhones only (DRM type SYNC, JSON body), and the Android
  app never sends it. The Message-channel scope `/fileTransfer` inside Nano is a different thing
  with the same name.
- `windows-catalog.md` lists `/fileTransfer` among the screen-mirroring routes. For Android it is
  the scope of the Nano Message channel, not a relay route; no relay message uses it.

---

## Addendum, 2026-10-09: path B recorded and decoded **[wire]**

A phone-to-PC share from Link to Windows to real Windows was recorded on both carriers and
decoded in full (`nano-wire-notes.md` sections 9 and 10). It confirms section 3.2 and fills in
what was open:

- Real Windows takes **path B** with this phone: the phone's `/fileshare_android2cdeh_phase1`
  resource request appears on the relay, once, at the share.
- The bytes went by **Direct IP UDP** between the two devices on one network, although Windows
  also offered ICE.
- **NamedStreams sequencing** (open question 7): after the platform channel is created the
  phone sends its `FileShareMessage` offer (items at status `IN_PROGRESS`), the PC asks with one
  message on `/<scenario id>/ManifestRequest` carrying a `ProtoManifest` of the wanted entries,
  the phone sends each file as a blob named by its file id, and both sides exchange
  `FileTransferToPcCompleted`. No `/Manifest` and no `/ManifestAck` message occurred.
- The platform channel is carried by two multiplexer channels the phone creates, one
  `Messaging` and one `Blob`.


## Addendum, 2026-10-09 22:22: PC to phone on path A, live **[live]**

Section 4.1 was built into the Mac client (`Nano/NanoFileSender.swift`, `NanoConnection.sendBlob`)
and worked with the phone on the first try: two files (2,028,800 and 346,452 bytes), each
confirmed by the phone with `FileTransferToPhoneCompleted`, 1.1 s and 0.4 s from the request for
a connection to the confirmation.

Confirmed by those runs:

- The same `/nanohandshake` request as for receiving, with a new lower-case GUID as
  `correlationVector`, makes the phone listen; the launcher channel and the `/workflow` request
  are the same; the phone then creates its message and blob channels (open question 6).
- The offer `FileTransferToPhone` on `/fileTransfer` (every item at status 1, `SenderName`,
  `SessionTryCount` 1, `ReceivedFileCount` 0, empty `FileHash`) is answered within 10 to 20 ms
  by `FileTransferToPhoneFile`.
- A blob named `<FileId>#1` in the phone's own layout is accepted: a start packet, data in
  segments of 100,000 bytes (each piece carrying the number of pieces of its segment, the
  segment's index and size, and its offset in the segment), a completion packet of kind 1.
  Pieces of 1,040 bytes were used.
- `permissions.shared_content` was true; the permission request was not needed.

Not yet tried live: several files in one transfer, a large file, a cancel on either side, a
phone that is busy.
