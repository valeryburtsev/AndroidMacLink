# Photos: recent media list, thumbnails, full image

Implementation-grade specification of the Phone Link "Photos" feature for a PC-side client that
an Android phone running Link to Windows (LTW) treats like Windows Phone Link. Scope: how the PC
learns the list of recent photos, gets thumbnails, fetches one image, deletes a photo, and what
arrives when a new photo is taken.

Revision 1, 2026-10-09.

Read first, not repeated here: `session-clipboard-notifications.md` sections 1 (two clients on
one connection), 2 (envelopes, value sets), 5.2 (DeviceResourceManager), 5.3 (publish), 7.2
(how the phone reads a reply to a push) and 8 (`/connect/v1`); `relay-transport.md` for
fragments.

Sources and how they are cited

| Tag | Meaning | Pointer form |
|---|---|---|
| **[code-android]** | Decompiled Link to Windows 1.26082.130.0 | `A:` class.method, package `com.microsoft.mmx.agents` abbreviated to `agents` |
| **[code-windows]** | Decompiled Phone Link 1.26072.257.0 | `W:` assembly :: class.method |
| **[wire]** | Seen in a capture, read for structure only | `C-pair:` seq in `captures/vm-pairing-2026-10-09/flows.jsonl`; `C-raw:` seq in `captures/vm-raw-2026-10-09/flows.jsonl` |
| **[inferred]** | Deduced, not directly confirmed | reasoning given inline |

`P:` points at recovered proto sources under `protocol/recovered/android/`.

What the captures do and do not contain

- **[wire]** One complete initial sync of the media list exists: connect (C-pair: 409), metadata
  push (444), PC answer (458), connect reply (459), content push with thumbnails (472), PC
  acknowledgement (505), second connect with matching sequence numbers (549, 557).
- **[wire]** Two capability probes of the PLATFORM resource `/media` (C-pair: 282 and 292, 356
  and 363).
- **Not captured at all**: any `/media/v1` request (thumbnails, full image, delete, refresh), any
  incremental push, any publish with tag 6. Those parts rest on code from both sides, which
  agree with each other.

---

## 0. The model in ten lines

1. The phone keeps a **snapshot** of its N most recent *images* (N = `MediaInfoSnapshotSize`,
   default 2000) and a **sequence number** that grows whenever the snapshot changes.
2. The PC states the sequence number it holds in `/connect/v1` (`sequenceNumbers.media_info`).
3. If they differ, the phone **pushes** on APP route `/legacy/phonecontent`, `contentType`
   `mediaInfo`: either a full sync (metadata round, then content) or an incremental one.
4. Every item is described by **parallel arrays**. Thumbnails travel in the same message as one
   concatenated byte array plus an array of lengths.
5. Missing thumbnails and image bytes are **pulled** by the PC on APP route `/media/v1`
   (`contentType` `thumbnails` or `photos`). The answer carries the bytes inline in the value set.
6. Delete is a request on the same route (`requestType` 0).
7. There is no separate transfer channel, no progress message, no cancel message.
8. The "full image" is **not the original** when the file is larger than 716800 bytes: the phone
   re-encodes a scaled JPEG.
9. Videos are not part of this feature in this version.
10. A second, independent path exists on the PLATFORM side (resource `/media`, publish tag 6).
    Phone Link does not use it.

```
PC                                                     Phone
 |-- APP /connect/v1 {configuration, sequenceNumbers} -->|
 |<- APP /legacy/phonecontent mediaInfo {metadata:1} ----|   full sync only
 |-- /internal/response {itemCount, mediaIds, ...} ----->|
 |<- /internal/response (connect reply, media_info) -----|
 |<- APP /legacy/phonecontent mediaInfo {arrays, bytes} -|
 |-- /internal/response {result:0} --------------------->|
 |-- APP /media/v1 {contentType: thumbnails|photos} ---->|   on demand
 |<- /internal/response {arrays, bytes} -----------------|
```

---

## 1. Enablement

### 1.1 What the PC puts in `/connect/v1`

`configuration` (Object)

| Key | Type | Windows sends | Phone use |
|---|---|---|---|
| `MediaInfoSync` | Bool | `true` for an Android phone **[code-windows]** W: YourPhone.Photos.Managed :: Utilities.MediaFeatures.IsMediaInfoSyncSupportedAndEnabled; **[wire]** C-pair: 409 | Stored as preference `pcSupportsMediaInfoSyncs`, default `false`. Gates the phone's change triggers and the reading of `media_info`. **[code-android]** A: agents.ConnectionRequestHandler.processPartnerConfiguration, agents.DeviceData.y / f |
| `MediaInfoSnapshotSize` | Int32 | 2000 (constant) **[code-windows]** MediaFeatures.GetMediaInfoSnapshotSize; **[wire]** 409 | Maximum number of items in the snapshot. Default 2000 if absent. No clamp. **[code-android]** DeviceData.x / c, agents.MediaProvider.getExtendedMedia |
| `AutoHydratedThumbnailsCount` | Int32 | 25 (remote feature `AutoHydratedThumbnailsCount`, default 25) **[code-windows]** MediaFeatures.GetAutoHydratedThumbnailsCount; **[wire]** 409 | How many thumbnails the phone attaches on its own to an **incremental** push. Default 40 if absent. Not used in a full sync. **[code-android]** DeviceData.h / a, agents.MediaInfoMessageBuilder.getMediaItemMessages |
| `PhotosLegacySync` | Bool | always `false` **[code-windows]** W: YourPhone.Photos.Managed :: Sync.PhotosEstablishConnectionPayload.LoadConfiguration; **[wire]** 409 | **Not read.** The string does not occur in the Android sources. **[code-android]** (absence) |
| `SequencedContentSyncs` | Bool | `true` **[wire]** 409 | Must be `true` or the phone ignores `sequenceNumbers`. **[code-android]** DeviceData.doesPcSupportSequencedSyncs |
| `MessagingSync` | Bool | `true` **[wire]** 409 | Also required: `doesPcSupportSequencedSyncs` is the AND of this flag (stored as `combinedMessagingSyncSupported`) and `SequencedContentSyncs`. **[code-android]** agents.MessagingConfigHelper.updateDeviceDataWithMessagingConfig, DeviceData.j |
| `SyncSkipMetadataForAuto` | Bool | `false` **[wire]** 409 | `true` makes the phone prefer incremental syncs and skip the metadata round (section 2.2). **[code-android]** agents.sync.SyncSettings.preferIncrementalSync |

`sequenceNumbers` (Object)

| Key | Type | Value |
|---|---|---|
| `media_info` | Int64 | The sequence number of the last media list the PC fully processed, or -1. Windows adds it only when the phone's stored `registeredPermissionTypes` has bit 1 (photos). **[code-windows]** PhotosEstablishConnectionPayload.Load; W: YourPhone.Devices.Managed :: Store.Device.PhotosDeviceCapability. **[wire]** -1 on first connect, 1 on the next (C-pair: 409, 549; C-raw: 147) |

The type must be Int64: the phone casts the value to `Long`
**[code-android]** ConnectionRequestHandler.setCoordinatorStates.

"Legacy sync" versus "MediaInfoSync": only MediaInfoSync exists in these two builds. Windows has
no content processor for a pushed `photos` content type (its only photos processor is for
`mediaInfo`) **[code-windows]** W: YourPhone.Photos.Managed :: Processors.MediaProcessorFactory.Type,
and Android has no message builder for one **[code-android]** (only agents.MediaInfoMessageBuilder
returns a photos-related content type). The words `photos` and `thumbnails` survive only as
`contentType` values of PC requests on `/media/v1`.

### 1.2 Conditions on the phone

All **[code-android]**.

| Condition | Where | Effect when false |
|---|---|---|
| Photos permission (section 1.4) | ConnectionRequestHandler.setCoordinatorStates; agents.sync.SyncExecutor.executeAsync via MediaInfoMessageBuilder.hasRequiredPermissions; agents.MediaRequestHandler.tryProcessRequest | `media_info` is not read and not returned; no push; `/media/v1` answers `result` 7 |
| `MediaInfoSync` true (or any earlier `/media/v1` request, which sets the same preference) | setCoordinatorStates; agents.AgentRegister.ensureMediaInfoTriggersStateInSync | No push on connect, no push on change |
| `sequenceNumbers.media_info` present | setCoordinatorStates | No sync is started by the connect |
| Sync allowed (not all-features-off, metered rule, two-phone mode, secondary profile) | agents.ScenarioRequestHandlerBase.handleAsync; agents.sync.SyncSequence.sendMessageAsync | Requests answered with `result` 13, 8, 21, 23 or 1; pushes not sent |
| Sender is an active remote app of client type `PL` | agents.sync.SyncCoordinatorBase.onChangeDetected | No change-driven push (see open question 4) |

### 1.3 What the phone's reply tells the PC

Reply to `/connect/v1` **[wire]** C-pair: 459, 557; C-raw: 163. Producer **[code-android]**
ConnectionRequestHandler.tryProcessRequest, createDeviceCapabilityBlob, createDevicePermissionBlob;
com.microsoft.appmanager.photos.DefaultPhotosFeatureController. Consumer **[code-windows]**
PhotosEstablishConnectionPayload.Apply.

| Key | Type | Meaning |
|---|---|---|
| `media_info` (top level) | Int64 | The phone's current sequence number. Present only when the photos permission is granted, `MediaInfoSync`, `SequencedContentSyncs` and `MessagingSync` were true and the PC sent `media_info`. Windows stores it as the *expected* number; a missing key is stored as -1. If it differs from what the PC sent, a push follows (or has already started). Observed 1. |
| `capabilities.photos` | Int32 | Bit mask. 1 `MEDIA_DELETE` (always set), 2 `PERMISSION_REQUIRED_MEDIA_DELETE` (set when the app targets and runs on Android 11, API 30, or later). Windows names: `MediaDelete`, `PermissionRequiredMediaDelete`, 4 `ICloudPhotos` (iOS only). Observed 3. **[code-android]** agents.PhotosCapability; **[code-windows]** W: YourPhone.AppCore.Managed :: PhotosCapabilities |
| `capabilities.registeredPermissionTypes` | Int32 | Bit 1 must be set or Windows treats the phone as having no photos feature (it then sends no `media_info`). **[code-windows]** Device.PhotosDeviceCapability |
| `permissions.photos` | Bool | Read access to images, possibly partial (section 1.4). Observed `true`. |
| `permissions.photos_full` | Bool | Read access to all images. Observed `true`. |
| `permissions.photos_delete` | Bool | The phone may delete images. Observed `true`. |
| `permissions.read_media_images` | Bool | Raw state of one Android permission; Windows photos code does not read it. Observed `false`. |
| `mediaSettings` | Object | One key, `dcim_directory` String: absolute path of the most probable camera folder on the phone (first existing of `100MEDIA`, `100ANDRO`, `Camera`, `100LGDSC` under the public DCIM directory, else the DCIM directory). Windows maps it into the Phone-files sync root; it is not needed for this feature. |

### 1.4 Permissions

**[code-android]** A: agents.permissions.PermissionsHelper.checkPhotosPermissions, hasPermissionsForContentType.

| Name in reply | Granted when |
|---|---|
| `photos` | App is "all files" manager (API 30+), or: API 34+ `READ_MEDIA_VISUAL_USER_SELECTED` or `READ_MEDIA_IMAGES`; API 33 `READ_MEDIA_IMAGES`; older `READ_EXTERNAL_STORAGE` |
| `photos_full` | Same, but on API 34+ only `READ_MEDIA_IMAGES` counts |
| `photos_delete` | App targets and runs on API 30+: "all files" manager. Otherwise `WRITE_EXTERNAL_STORAGE` |

Asking the user **[code-windows]** W: YourPhone.Utilities :: Extensions.IRemoteAppClientExtensions.SendPermissionsRequestAsync:
APP request on route `/permission` with `contentType` String `permission`, `permissionType`
Int32, `silent` Bool, `permissionSessionId` String, `correlationVector` String plus the usual
sender keys. `permissionType` is 1 for photos, 0x20000000 for full photos, 0x200000 for delete
(W: YourPhone.AppCore.Managed :: DevicePermissions). Result 0 or 4 means granted; 5, 6, 7 mean
not granted (W: YourPhone.Photos.Managed :: ViewModels.MediaNodeViewModel.UpdateDevicePhotosPermissionCache).
The answer to a `/media/v1` request also carries `photos_full` Bool (sections 2.5, 4, 5).

---

## 2. Sync model

### 2.1 Snapshot and sequence number

All **[code-android]** unless marked.

- Source: `MediaStore.Images.Media.EXTERNAL_CONTENT_URI` only. **No videos.**
  (A: agents.MediaProvider.getMedia.)
- Folder filter on the file path (`_data LIKE`): `%/DCIM/Camera/%`, `%/DCIM/100MEDIA/%`,
  `%/DCIM/100ANDRO/%`, `%<external storage>/Photo/%`, `%<external storage>/Video/%`,
  `%/DCIM/Screenshots/%`, `%/Pictures/Screenshots%`. With experiment `NoMediaProviderFilter`
  (default off) the looser set `%/DCIM/%`, `%/Pictures/%`, `%/Screenshots/%`, `%/Download/%`
  applies. The same filter applies to every later lookup by id, so an id outside these folders
  is "not found". (MediaProvider.DEFAULT_CAMERA_LOCATION_ARGS, getMediaFolders, getExtendedMediaBatch.)
- Order and size: two queries (items with a taken date, newest first; items without, by date
  added, newest first) merged newest first and cut at `MediaInfoSnapshotSize`.
  (MediaProvider.getMedia, mergeImageLists.)
- The phone stores `(id, checksum)` per item in a local table (`content.db`). A scan that finds
  any new id, changed checksum or vanished id raises the sequence number by one; vanished ids
  become tombstones. (A: agents.sync.ContentViewRepository.setViewForContentType;
  agents.sync.DataSourceBase.loadMetadata.)
- Scans are triggered by a `ContentObserver` on the images URI and throttled by
  `MediaInfoMinScanInterval`, default 5000 ms. (A: agents.MediaInfoDataSource.initialize;
  DataSourceBase.initialize; com.microsoft.appmanager.experiments.SDKFeatures.)
- The number is -1 before the first scan; reading it waits for that scan.
  (DataSourceBase.getSequenceNumber.) **[wire]** it was 1 after the first scan of a non-empty
  gallery (C-pair: 444).
- The name of the number is `media_info` in `/connect/v1` and its reply, and `sequenceNumber`
  inside pushes (A: agents.sync.ContentType.MEDIA_INFO; MediaInfoMessageBuilder).

### 2.2 Which sync the connect starts

**[code-android]** A: agents.sync.SyncCoordinatorBase.setTargetState, determineSyncType, initiateSync;
agents.MediaInfoSyncCoordinator. `skip` is `SyncSkipMetadataForAuto`.

| PC `media_info` | Phone number | `skip` | Result |
|---|---|---|---|
| key absent | any | any | nothing |
| -1 | 0 or less (nothing to sync) | any | nothing |
| -1 | positive | false | **Full sync**, section 2.3 |
| -1 | positive | true | **Incremental** from -1: every snapshot item with action 0, one content message, no metadata round |
| equal to phone | | any | nothing |
| anything else | | any | **Incremental** since the PC's number, section 2.4 |

**[wire]** PC -1, phone 1, skip false gave a full sync (C-pair: 409, 444). PC 1, phone 1 gave
nothing (C-pair: 549 to 557; C-raw: 147 to 163).

**[inferred]** A PC number higher than the phone's (phone data cleared) takes the last row: the
change query returns nothing and the phone pushes an empty incremental message with its own
lower number. A client should treat a reply `media_info` lower than its stored number as "start
over": drop its list and request a full sync (section 2.5).

After a push completes with result 0 the phone records the pushed number as the PC's state
(SyncCoordinatorBase.lambda$initiateSync$4). It does not wait for the next connect.

### 2.3 Full sync: metadata round, then content

Both messages are APP **requests** from the phone on `/legacy/phonecontent` with headers
`_requestId` (GUID) and `_route` only **[wire]** C-pair: 444, 472. Both carry the same
`correlationVector` **[wire]**.

Step 1, metadata message (schema 3.2). **[code-android]** agents.MessageBuilderBase.getMetadata,
MediaInfoMessageBuilder.getMetadataInternal. Lists every snapshot id with its modified time and
checksum.

Step 2, the PC answers on `/internal/response` (schema 3.3). **[code-windows]**
W: YourPhone.Photos.Managed :: Processors.MediaProcessor (constructor, AssembleResponseMetadata).
Windows deletes local items not in the list, compares checksums and asks for the items that are
new or changed.

How the phone reads the answer **[code-android]** A: agents.sync.SyncSequence.handleSendResult,
handleSuccessfulResponse; MessageBuilderBase.getRequestedItemCount:

| Answer | Phone behaviour |
|---|---|
| `result` 0 (or no `result` key) and `itemCount` Int32 > 0 | Sends the content message |
| `result` 0 (or absent) and `itemCount` 0 or absent | **Ends the sync as successful and records the PC as up to date.** No content is sent. |
| `result` 19 | Ends all user sessions with this PC |
| any other `result` | Sync failed; PC state not updated |

Step 3, content message (schema 3.4). One message for the whole set: the phone looks up every id
in the answer's `mediaIds` and attaches a thumbnail for every id in `mediaRequestedIds`
**[code-android]** MediaInfoMessageBuilder.getMediaItemMessages, buildPayloadInternal. There is
no batching and no cap on either array in the phone code.

Step 4, the PC answers `{result: Int32 0}` and repeats the result as header `result: 0`
**[wire]** C-pair: 505; **[code-windows]** MediaProcessor.ProcessItem,
W: YourPhone.Connectivity.Managed :: PhoneContentHandler.CreateOutgoingResponse. On an exception
Windows answers `result` 1 and `message` String. Always include `result`: for a content message
the phone's default for a missing key is 24, which it logs as unexpected and does not treat as
completion **[code-android]** SyncSequence.lambda$next$2, handleSendResult.

**[wire]** timing in C-pair: answer 0.26 s after the metadata message; content message 4.5 s
later (25 thumbnails, 1.67 MB payload, one DCG fragment); acknowledgement 4.7 s after that.

### 2.4 Incremental sync

**[code-android]** MediaInfoSyncCoordinator.getIncrementalSyncPayload; DataSourceBase.loadChangesSince;
ContentViewRepository.getChangesSince; agents.sync.KvpMessageHelpers.createMediaItemMapImpl. Not
on the wire.

- One content message, no metadata round. It has the schema of 3.4 plus `incremental` Int32 1.
- It lists only changed items, each with a `mediaActions` code: 0 created (first seen after the
  PC's number), 1 updated (checksum changed), 2 deleted (tombstone).
- Order inside the message: deleted items, then updated, then created.
- A deleted item has only its id filled in: strings empty, numbers 0, checksum 0, no thumbnail.
- Thumbnails are attached for the first `AutoHydratedThumbnailsCount` items with action 0 or 1.
- The PC answers `{result: 0}`. **[code-windows]** with no stored processor for the
  correlation id, Windows builds a `MediaProcessor` from the content message itself, removes the
  ids with action 2, upserts the rest and stores `sequenceNumber`
  (PhoneContentHandler.HandleContentPayload; MediaProcessor.ExtractThumbnailsFromPayload).

### 2.5 PC-initiated refresh

APP request on `/media/v1` with `contentType` `mediaInfo`. **[code-windows]**
W: YourPhone.Photos.Managed :: Communication.SyncMediaRequest, ViewModels.MediaNodeViewModel.LoadMediaFromRemoteDeviceAsync
(refresh button, and after a permission grant).

| Key | Type | Value | Read by phone |
|---|---|---|---|
| `contentType` | String | `mediaInfo` | yes |
| `correlationVector` | String | request correlation id; reused as the `correlationVector` of the pushes it causes | yes |
| `contractVersion` | Double | 3.99. **Required**: the phone unboxes it without a null check | yes |
| `isuserinitiated` | Bool | raises push priority | yes |
| `relatedCorrelationIds`, `subcontentTypes` | StringArray | one element each | no |
| `ignoreResponse` Bool, `transportType` Int32 0, `displayName`, `appVersion`, `installationId` String | | added by W: YourPhone.Connectivity.Managed :: RemoteAppClient | no |

Phone behaviour **[code-android]** MediaRequestHandler.tryProcessRequest: sets
`pcSupportsMediaInfoSyncs`, re-arms the triggers, starts a **forced full sync** to the sender
(section 2.3, regardless of sequence numbers) and also asks the wallpaper coordinator for a full
sync. The reply to the `/media/v1` request is sent only **after** that sync has finished:

| Reply key | Type | Value |
|---|---|---|
| `result` | Int32 | 0 done; 7 no photos permission; 8 metered sync off; 10 cancelled; 11 coalesced with another sync; 21 two-phone mode; 1 other failure (A: agents.AppServiceProviderHelpers.createResponseFromPayloadProcessingResult) |
| `contractVersion` | Double | 3.99 |
| `photos_full` | Bool | current full-access state (absent when the request was refused before any sync started, for example `result` 7 from the permission check) |

So this is "pull" only in name: the list itself still arrives as pushes on
`/legacy/phonecontent`, which the PC must answer before the `/media/v1` reply comes.

`forceRefreshOfTypes` in `/connect/v1` is **not** an alternative: the phone acts on it only
for `phoneApps` **[code-android]** ConnectionRequestHandler.forceFullSyncs. The `/media/v1`
request is the only way to force a full media sync.

### 2.6 Result codes on `/media/v1`

**[code-android]** ScenarioRequestHandlerBase.handleAsync, lambda$handleAsync$1; agents.AgentConnectivityHelper.getSyncNotAllowedResponse.

| `result` | When |
|---|---|
| 0 | success |
| 1 | exception, empty or missing `mediaIds`, or any id failed to delete |
| 2 | handler produced nothing: unknown `contentType`, or delete without `mediaIds` / `checksums` |
| 3 | `contractVersion` integer part is not 3 |
| 7 | permission missing (photos, or delete for a delete request) |
| 8, 13, 21, 23 | metered sync disabled, all features disabled, two-phone mode, secondary user or profile |

Every reply also has `contractVersion` Double 3.99. The phone's replies carry no `result`
header; read the value-set key.

---

## 3. Schema of the media list

### 3.1 Keys common to every `mediaInfo` push

**[code-android]** KvpMessageHelpers.getBaseMessageMap; **[wire]** C-pair: 444, 472.

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `mediaInfo` |
| `contractVersion` | Double | 3.99 |
| `correlationVector` | String | same for all messages of one sync |
| `installationId`, `displayName` | String | phone install id and name |
| `dedupeID` | String | empty |
| `retryCount` | Int32 | 0 |
| device status keys | various | as on every push (other spec, section 8.4) |

### 3.2 Metadata message (full sync, step 1)

**[code-android]** MediaInfoMessageBuilder.getMetadataInternal, buildSettingsMap; **[wire]** C-pair: 444.

| Key | Type | Meaning |
|---|---|---|
| `metadata` | Int32 | 1. Its presence marks the metadata round. |
| `itemCount` | Int32 | number of snapshot items (may be 0) |
| `mediaIds` | Int64Array | MediaStore `_id` per item, newest first (section 2.1) |
| `mediaTimes` | Int64Array | modified time per item, Unix milliseconds |
| `checksums` | Int64Array | checksum per item (section 3.5) |
| `sequenceNumber` | Int64 | sequence number of this snapshot |
| `mediaSettings` | Object | `mediaCapabilities` Int32 (same mask as `capabilities.photos`), `mediaHasDeletePermission` Bool (only on API 30+) |

The three arrays have equal length. Windows fails the sync if `mediaTimes` or `checksums` is
shorter than `mediaIds` **[code-windows]** MediaProcessor constructor.

### 3.3 The PC's answer to the metadata message

**[code-windows]** MediaProcessor.AssembleResponseMetadata; **[wire]** C-pair: 458 (headers
`_originalRequestId`, `_route` `/internal/response`, `_rejectionVersion`, `result`).

| Key | Type | Value | Read by phone |
|---|---|---|---|
| `result` | Int32 | 0 | yes |
| `itemCount` | Int32 | number of ids in `mediaIds`. **Must be Int32 and above 0 to receive content.** | yes |
| `mediaIds` | Int64Array | ids whose metadata the PC wants (Windows: new or changed checksum, in the order of the metadata message) | yes |
| `mediaRequestedIds` | Int64Array | ids whose thumbnail should be attached (Windows: the first `min(pending, AutoHydratedThumbnailsCount)` of `mediaIds`; none if remote feature `MediaOptimizedThumbnails` is on) | yes |
| `contentType` | String | `mediaInfo` | no |
| `contractVersion` | Double | 3.99 | no |
| `correlationVector` | String | copied from the push | no |

**[wire]** on a first sync `mediaIds` equalled the full metadata list and `mediaRequestedIds`
its first 25 entries.

Type strictness **[code-android]**: `itemCount` is cast to `Integer`, both arrays to `long[]`
(MessageBuilderBase.getRequestedItemCount; MediaInfoMessageBuilder.getMediaItemMessages). A wrong
type fails the sync. A missing `mediaRequestedIds` simply means no thumbnails.

### 3.4 Content message: parallel arrays

Used by: full sync step 3, incremental sync, and the reply to a `thumbnails` request.
**[code-android]** MediaInfoMessageBuilder.buildPayloadInternal; agents.ImageInfo. **[code-windows]**
MediaProcessor.ExtractThumbnailsFromPayload. **[wire]** C-pair: 472 (all types below confirmed).

All arrays have one entry per item, same index. There are no nested per-item objects.

| Key | Type | Meaning | Source column / rule |
|---|---|---|---|
| `mediaIds` | Int64Array | item id; stable key for every later request | MediaStore `_id` |
| `mediaNames` | StringArray | file name with extension | `_display_name` |
| `mediaTimes` | Int64Array | modified time, Unix **milliseconds**, always a multiple of 1000 | `date_modified` (seconds) x 1000 |
| `mediaTakenTimes` | Int64Array | taken time, Unix **milliseconds** | `datetaken` if above 0, else `date_added` x 1000 |
| `mediaMimeTypes` | StringArray | MIME type, `""` if unknown | `mime_type`. **[wire]** `image/jpeg` and `image/heic` both occur |
| `mediaHeights`, `mediaWidths` | Int64Array | pixel size **as stored**, before applying orientation | `height`, `width` |
| `mediaSizes` | Int64Array | size of the original file in bytes | `_size` |
| `mediaOrientations` | StringArray | clockwise rotation in degrees as text | `orientation`. **[wire]** `"0"`, `"90"`, `"180"`, `"270"` and `""` (null) occur |
| `mediaURIs` | StringArray | `content://media/external/images/media/<id>` | built from the id. Windows stores it and never uses it |
| `checksums` | Int64Array | checksum (section 3.5) | |
| `mediaActions` | Int32Array | -1 none (full sync and `thumbnails` reply), 0 create, 1 update, 2 delete | A: com.microsoft.appmanager.sync.ContentChangeAction. **[wire]** all -1 in a full sync |
| `mediaThumbnailSizes` | Int64Array | byte length of each item's thumbnail, 0 if none | |
| `mediaThumbnails` | UInt8Array | all thumbnails concatenated in item order, no separators | |
| `sequenceNumber` | Int64 | pushes only; absent in a `thumbnails` reply | |
| `incremental` | Int32 | 1, incremental pushes only | |

Rules for the reader

- Slice `mediaThumbnails` by walking `mediaThumbnailSizes`; items with size 0 consume nothing.
  The sum of sizes equals the blob length **[wire]**.
- Do not assume order. **[wire]** the content message listed items in ascending id order, not
  in the newest-first order of the metadata message; the thumbnails belonged to exactly the ids
  the PC had put in `mediaRequestedIds`, wherever they sat. Sort by `mediaTakenTimes` yourself.
- Items the phone could not find are simply missing from the arrays.
- Windows requires `mediaTimes` and `mediaSizes` to be at least as long as `mediaIds` and
  indexes the other arrays without checking **[code-windows]**.
- There is no folder or bucket field, no file path, no GPS, no video duration.
- Store `sequenceNumber` as the new `media_info` only after the message has been processed
  completely **[code-windows]** MediaProcessor.ProcessItem.

Note for the Swift client: `ValueSet.Value` has no case for `DataValueType_UInt8Array` (18, proto
field `uint8_array` = 21). Such values currently arrive as `.other`; add a bytes case or read
`uint8Array` from the retained variant.

### 3.5 Field semantics

| Field | Detail |
|---|---|
| id | A MediaStore row id. Stable while the file exists; may be reused by Android after deletion **[inferred]**. |
| checksum | Java `Objects.hash(fileName, fileLength, fileLastModified)` widened to 64 bits: a signed 32-bit value, often negative. 0 when the file path is unknown. **[code-android]** ImageInfo.getChecksum; **[wire]** all values fit Int32. It changes when the file is renamed, resized or touched. Echo it back in a delete request. |
| orientation | Apply to the **full image** only if the image bytes do not already say so (section 5). Do not apply to thumbnails: **[wire]** for items stored landscape with orientation 90 or 270 the thumbnail was already portrait, and thumbnails carry no EXIF block. Swap `mediaWidths` and `mediaHeights` for layout when orientation is 90 or 270. |
| times | Both in milliseconds since 1970 UTC. Windows shows a "new photo" toast when taken time, modified time and now are all within 120 s of each other **[code-windows]** W: YourPhone.Photos.Managed :: Toasts.MediaToastDispatcher.CheckHeuristic. |

---

## 4. Thumbnails

### 4.1 Three ways a thumbnail arrives

| Way | Selected by | Evidence |
|---|---|---|
| Inside the full-sync content message | PC, via `mediaRequestedIds` in its metadata answer | **[wire]** C-pair: 458, 472 |
| Inside an incremental push | phone, first `AutoHydratedThumbnailsCount` created or updated items | **[code-android]** |
| Reply to a `/media/v1` `thumbnails` request | PC, via `mediaIds` | **[code-android]**, **[code-windows]** |

"Auto hydrated" therefore means two things: on Windows the number of ids it puts in
`mediaRequestedIds`; on the phone the number of thumbnails it volunteers in incremental pushes.
Both come from the same configured count (25 on Windows, phone default 40).

### 4.2 Request on `/media/v1`

**[code-windows]** W: YourPhone.Photos.Managed :: Communication.MediaRequest, Sync.MediaRequestMaker.RequestThumbnailsAsync;
**[code-android]** MediaRequestHandler.tryProcessRequest, getMediaPayload.

| Key | Type | Value | Read by phone |
|---|---|---|---|
| `contentType` | String | `thumbnails` | yes |
| `mediaIds` | Int64Array | ids wanted; must be non-empty | yes |
| `correlationVector` | String | request id | yes |
| `contractVersion` | Double | 3.99, required | yes |
| `isuserinitiated` | Bool | Windows overwrites it from the request options, whose default is `false` (RemoteAppClient.SendLegacyRequestAsync) | yes |
| `ignoreResponse`, `transportType`, `displayName`, `appVersion`, `installationId` | | sender boilerplate | no |

Must not contain a key named `requestType`: its presence turns the request into a delete
(section 6.1).

### 4.3 Reply

`result` 0, `contractVersion`, `photos_full` Bool, plus the complete array set of section 3.4
(without `sequenceNumber`, `mediaActions` all -1). Every found item gets a thumbnail attempt; a
failed one has size 0. The PC sends nothing back.

### 4.4 Format and size

**[code-android]** ImageInfo.getThumbnailBytes.

- Bitmap from `MediaStore.Images.Thumbnails.getThumbnail(resolver, id, 1 /* MINI_KIND */, null)`,
  compressed as **JPEG quality 100**.
- Only when experiment `EnforceMaxThumbnailSize` is on (default off): quality is lowered in
  steps of 10 down to 50 until the result is at most 50000 bytes.
- **[wire]** 25 thumbnails: all JPEG (`FF D8 FF`), 31782 to 104380 bytes each, long side 512 to
  600 pixels (512x288, 600x270, 576x432 and similar), already upright, also for HEIC originals.
  So the cap was off on the captured phone.
- No thumbnail is produced when the file path is unknown or the file is gone (size 0).

### 4.5 Batching as done by Windows

**[code-windows]** W: YourPhone.Photos.Managed :: Sync.ThumbnailRequestDispatcher, Sync.MediaRequestDispatcher,
Utilities.PhotosConstants.

- At most 25 ids per request (`DefaultThumbnailsPerBatchMaxCount`), one request in flight,
  first request 1000 ms after the first id is queued.
- A reply with `result` 0 but an item of size 0 counts as a failure for that id. An id is given
  up on its fourth failure (`AllowedFailures` 2, compared with the count before increment;
  W: Sync.MediaRequestPool.Fail).
- `result` 7, 9, 12, 13, 21 or 23 empties the queue (W: YourPhone.Utilities :: Connectivity.ResponseHelpers
  maps them to NeedsPermission, NeedsInitialPermission, MeteredConnectionSyncDisabled,
  AllFeaturesDisabled, TwoPhoneModeSyncDisabled, NonDefaultUserProfile). Note the phone answers
  a request refused for the metered rule with 8, which Windows counts as an ordinary failure.
- `result` 10 and 11 count as success on Windows.
- Request timeout 120 s (W: YourPhone.Utilities :: Connectivity.RequestOptions).
- The coded back-off (3 s doubling to 60 s) reads the millisecond *component* of the time span,
  which is 0, so in practice there is no delay between batches **[inferred]** from the
  decompiled arithmetic.

The phone sets no limit on the number of ids per request; ids are looked up 500 at a time
**[code-android]** MediaProvider.getExtendedMediaByIds. Expect roughly 30 to 100 KB per
thumbnail when sizing a batch.

---

## 5. Full image

### 5.1 Request on `/media/v1`

Same request as section 4.2 with `contentType` `photos`. **[code-windows]**
MediaRequestMaker.RequestImagesAsync, Sync.ImageRequestDispatcher (one id per request, at most 5
requests in flight, same failure rule as thumbnails).

### 5.2 Reply

**[code-android]** MediaInfoMessageBuilder.buildImagePayload; **[code-windows]**
MediaProcessor.ExtractImagesFromPayload.

| Key | Type | Meaning |
|---|---|---|
| `result` | Int32 | 0 |
| `contractVersion` | Double | 3.99 |
| `photos_full` | Bool | full-access state |
| `mediaIds` | Int64Array | ids found, in the phone's lookup order |
| `mediaSizes` | Int64Array | **byte length of each image inside `content`** (not the original file size, unlike the same key in section 3.4) |
| `content` | UInt8Array | image files concatenated, no separators |

Slice `content` by `mediaSizes`. A size of 0 means the phone could not read the file; Windows
treats it as "no data" and retries. An empty `mediaIds` means not found.

The bytes travel **inline in the value set** of the reply, as one APP message through the
normal DCG fragment layer. No device-resource path, no named stream, no side channel, no
separate transfer session is involved.

### 5.3 What the bytes are

**[code-android]** ImageInfo.c, getScaledImageBytes. The request path always takes the "scaled"
branch.

| Original file | Bytes sent |
|---|---|
| at most 716800 bytes (700 KiB) | the file unchanged, in its own format (JPEG, HEIC, PNG ...) |
| larger | a new **JPEG, quality 97**. Scale factor f = sqrt(716800 / fileLength); target size round(width x f) by round(height x f); decoded with sample size floor(1 / f), then scaled. EXIF tags `DateTime`, `DateTimeOriginal` (or the file's modified time), `Make`, `Model`, `Orientation` are copied from the original. |
| unreadable or not decodable | zero bytes |

Consequences

- **The original full-resolution file cannot be fetched through this feature.** A 3 MB photo
  comes back with roughly a quarter of its pixels. Windows Save as, Copy, Drag, Open and Share
  all use these bytes **[code-windows]** W: YourPhone.Photos.Managed :: ViewModels.MediaViewModel
  (SaveAs, CopyAsyncImpl, SetDragEventArgsAsync, OpenAsync, ShareAsync).
- The output size is not bounded exactly: pixel count is scaled by 716800 / fileLength, then
  encoded at quality 97 **[inferred]**. Expect a few hundred KB up to about 1 to 2 MB.
- **HEIC / HEIF**: there is no dedicated handling on either side (the strings do not occur in
  the photos code). A HEIC above the threshold becomes a JPEG as a side effect of the scaling;
  a HEIC at or below it is sent as HEIC. `mediaNames` and `mediaMimeTypes` still describe the
  original, so a `.heic` name can come with JPEG bytes. Decide the format from the first bytes,
  not from the name. Windows saves under the original name and extension regardless
  **[code-windows]** MediaViewModel.SaveAs.
- Orientation: the scaled JPEG keeps the EXIF `Orientation` tag; whether its pixels are already
  rotated for HEIC sources is not determinable from code (open question 6).

### 5.4 Progress, cancellation, timeouts

- No progress message exists. One request, one reply.
- Cancellation is local on Windows: the id is dropped from the queue; a request already sent is
  not recalled **[code-windows]** ImageRequestDispatcher.CancelRequests, MediaRequestDispatcher.
- Windows waits 30 s for the bytes in the UI (W: Sync.MediaHydrator.OpenReadAsync,
  MediaViewModel.WaitForMediaStreamReference) on top of the 120 s request timeout.
- No size limit is coded on the phone for this reply. **[wire]** an APP message of 1.67 MB
  crossed the relay as a single fragment (C-pair: 472).

---

## 6. Operations from the PC

### 6.1 Delete

Request on `/media/v1`. **[code-windows]** W: YourPhone.Photos.Managed :: Communication.DeleteMediaRequest,
MediaNodeViewModel.DeleteAsync. **[code-android]** MediaRequestHandler.handleDelete, ImageInfo.delete.

| Key | Type | Value |
|---|---|---|
| `requestType` | Int32 | 0. Presence selects delete; any other value is an error. |
| `mediaIds` | Int64Array | ids to delete, no duplicates |
| `checksums` | Int64Array | same length; the checksum the PC holds for each id. 0 skips the check. |
| `correlationVector` | String | |
| `contractVersion` | Double | 3.99, required |
| (no `contentType`) | | Windows sends none |

Phone: needs the photos permission and the delete permission (else `result` 7). An item is
deleted through the content resolver only if its current checksum equals the one sent (or 0
was sent). Reply:

| Key | Type | Value |
|---|---|---|
| `result` | Int32 | 0 if every id was deleted, else 1 |
| `mediaSuccessfullyDeletedIds` | Int64Array | |
| `mediaUnsuccessfullyDeletedIds` | Int64Array | checksum mismatch, delete failed, or id not found |
| `contractVersion` | Double | 3.99 |

Windows reads the arrays only when `result` is 0, so a partial failure is shown as a full
failure **[code-windows]**. Its timeout for this request is 60 s (remote feature
`MediaDeleteTimeoutMs`). Before deleting, when `capabilities.photos` has bit 2 and
`permissions.photos_delete` is false, it first sends `/permission` with type 0x200000
(MediaNodeViewModel.CheckDeletePermissionsAsync). The deletion later shows up as an incremental
push with action 2 (section 2.4).

### 6.2 Save, copy, drag out, open, share

Purely local on the PC, all fed by the bytes of section 5 (fetched first if absent). No
additional route.

### 6.3 Open on phone

Does not exist in the photos code of either side. `mediaURIs` is delivered but unused by
Windows **[code-windows]** (only written to its media table).

### 6.4 Refresh

Section 2.5.

---

## 7. A new photo taken while connected

**[code-android]** throughout; nothing on the wire.

1. The MediaStore observer fires; the scan runs (at most one per 5000 ms by default) and the
   sequence number goes up (DataSourceBase.onChange, performScan).
2. For every active `PL` remote app the coordinator starts an automatic sync
   (SyncCoordinatorBase.onChangeDetected, beginSync). With the PC's number known from the
   earlier connect or push this is an **incremental** push (section 2.4): one item with
   `mediaActions` 0, its metadata, its thumbnail (it is among the first
   `AutoHydratedThumbnailsCount`), the new `sequenceNumber`, `incremental` 1.
3. The PC answers `{result: 0}` and stores the number.
4. If the new photo pushes the oldest item out of the snapshot window, that id arrives in the
   same message with action 2 **[inferred]** from the tombstone logic in
   ContentViewRepository.setViewForContentType.

If the phone holds no number for this PC (the PC never sent `media_info` and never completed a
push), the automatic sync is a full sync instead, or an incremental from -1 when
`SyncSkipMetadataForAuto` is on.

Independently, the phone publishes a PLATFORM notification (section 8.2).

---

## 8. The second path: PLATFORM resource `/media` and publish tag 6

Android calls this "remote snipping". Phone Link 1.26072 contains no code for it
**[code-windows]** (no reference to these proto types); the capture shows Cross Device
Experience Host using it **[wire]**. P: remotesnipping/v1/get.proto, metadata.proto, publish.proto.

### 8.1 Device resource `/media`

Carrier: DeviceResourceManager request (other spec, section 5.2), `resource_path` `/media`,
`request_type` GET. **[code-android]** A: agents.MediaInfoResourceRequestHandler.

`MediaRequestMessage`: 1 `request_type` enum (1 CAPABILITIES, 2 THUMBNAIL, 3 PHOTO),
2 `media_id` optional int64.

`MediaResponseMessage`: 1 `capabilities` repeated enum (always `[1]` =
NEW_MEDIA_NOTIFICATIONS), 2 `has_permissions` bool (the **full** photos permission),
3 `status` enum, 4 `item` optional `MediaMetadata`.

`MediaMetadata`: 1 `media_id` int64, 2 `date_modified` Timestamp (seconds only), 3 `date_taken`
Timestamp (seconds only), 4 `thumbnail` optional bytes, 5 `photo` optional bytes.

| `status` | When |
|---|---|
| 1 OK | |
| 2 BAD_REQUEST | not GET, unparseable, unknown request type, no `media_id`, or kill switch `RSDisable` on |
| 3 NOT_FOUND | id not in the snapshot folders, or bytes unavailable |
| 4 MISSING_PERMISSIONS | full photos permission missing (checked for THUMBNAIL and PHOTO) |
| 5 SYNC_DISABLED | sync not allowed |

`thumbnail` is the JPEG of section 4.4; `photo` is the bytes of section 5.3 (same 716800-byte
rule). One item per request.

**[wire]** C-pair: 282 and 356: request with legacy `resource_type` 6 (MEDIA), GET, path
`/media`, payload `{request_type: 1}`. Answers 292 and 363: `response_type` 1, payload
`{capabilities: [1], has_permissions: true, status: 1}`.

### 8.2 Publish tag 6 (Media)

**[code-android]** A: agents.MediaInfoContentChangeMonitor, agents.MediaInfoChangePublisher,
agents.transport.BaseCloudPublisher.

- When a scan finds a **created** item whose modified time is at most 30 s old, the phone
  publishes `MediaChangeMessage{1 change_type = 1 (NEW_PHOTO), 2 changed_media = [MediaMetadata{media_id, date_modified}]}`
  with MSAEP tag 6, in `PubSubPayload.additional` (other spec, section 5.3).
- Only the newest such item is published; at most one publish per
  `MediaInfoMinPublishIntervalMillis` (default 1000 ms).
- The monitor starts with the phone's agent service and does not depend on `MediaInfoSync`.
  It is off when `RSDisable` is on.
- The message has no thumbnail; the receiver is expected to call `/media` for it.

---

## 9. Minimum viable client

Assumes the client already completes `/connect/v1` as in the other spec and answers every
`/legacy/phonecontent` push.

### 9.1 (a) Grid of the N most recent photos with thumbnails

1. In `/connect/v1` send `configuration`: `MediaInfoSync` Bool true, `MediaInfoSnapshotSize`
   Int32 N, `AutoHydratedThumbnailsCount` Int32 K, `SequencedContentSyncs` true, `MessagingSync`
   true, `SyncSkipMetadataForAuto` false; and `sequenceNumbers.media_info` Int64 = stored number
   or -1.
2. From the reply read `permissions.photos`. If false, stop (optionally ask with `/permission`,
   type 1). Read top-level `media_info`; if it equals the stored number the list is current and
   nothing will arrive.
3. On a push with `contentType` `mediaInfo` **and** key `metadata`: remember `sequenceNumber`;
   drop local items whose id is not listed; answer with `result` Int32 0, `itemCount` Int32 =
   count, `mediaIds` Int64Array = ids that are new or whose checksum changed, `mediaRequestedIds`
   Int64Array = the ids of those you want thumbnails for now (for a small N: all of them),
   `contentType`, `contractVersion`, `correlationVector`. If nothing is wanted answer
   `itemCount` 0 and store the number.
4. On a push with `contentType` `mediaInfo` **without** `metadata`: for each index apply
   `mediaActions` (2 = remove id; otherwise upsert), slice thumbnails, sort by
   `mediaTakenTimes` descending, store `sequenceNumber`, answer `{result: 0}` with header
   `result: 0`.
5. For items still without a thumbnail send `/media/v1` with `contentType` `thumbnails`,
   `mediaIds` (25 or fewer), `correlationVector`, `contractVersion` 3.99, `isuserinitiated`,
   and parse the reply like step 4.

That is three message kinds: the connect keys, one answer shape for the metadata round, one
acknowledgement. Step 5 is optional when `mediaRequestedIds` covered everything.

Shortcut without sequence numbers: send `/media/v1` `{contentType: mediaInfo, correlationVector, contractVersion}`
at any time; steps 3 and 4 follow, then the reply to the request. Be ready for a `wallpaper`
push as a side effect.

### 9.2 (b) Fetch one image and save it

1. Send `/media/v1` with `contentType` `photos`, `mediaIds` Int64Array `[id]`,
   `correlationVector`, `contractVersion` 3.99, `isuserinitiated` true.
2. Check `result` 0, find the id in `mediaIds`, take `mediaSizes[i]` bytes from `content`.
3. Size 0 or empty arrays: retry once or twice, then report failure.
4. Choose the extension from the leading bytes (JPEG `FF D8 FF`; HEIC has `ftyp` at offset 4),
   keep the base name from `mediaNames`, honour EXIF orientation when displaying.
5. Tell the user this is a reduced copy when the listed `mediaSizes` (original) exceeded 716800.

### 9.3 Pitfalls

| Pitfall | Why |
|---|---|
| Answering the metadata round with a bare `{result: 0}` | The phone marks the PC as up to date and sends no content (section 2.3). |
| `itemCount` as Int64, ids as Int32Array | Cast failure on the phone, sync fails. |
| Omitting `contractVersion` in a `/media/v1` request | Null unboxing on the phone; no useful answer. |
| A stray `requestType` key in a thumbnails or photos request | Treated as delete. |
| Rotating thumbnails by `mediaOrientations` | They are already upright. |
| Trusting file name or MIME type of fetched bytes | Large HEIC files arrive as JPEG. |
| Reading `mediaSizes` of a `photos` reply as original size | There it is the slice length. |
| Storing `sequenceNumber` before the content message is processed | A crash in between loses items for good; the phone will not resend. |
| Expecting videos or photos from arbitrary folders | Images in camera and screenshot folders only. |

---

## 10. Open questions and limits

1. **No wire sample** of `/media/v1` (thumbnails, photos, delete, refresh), of an incremental
   push, or of a tag 6 publish. Shapes come from both code bases and agree; byte-level details
   such as how an empty Int64Array or an empty `mediaThumbnails` is encoded are unverified.
2. **Originals.** Photos delivers a reduced JPEG for files above 700 KiB. How Windows reaches
   the untouched file (the Phone-files sync root that `dcim_directory` is mapped into) belongs
   to a different feature and is not specified here.
3. **Videos.** Not in the snapshot in this LTW version. Whether another build or feature flag
   adds them was not determined.
4. **Client identity.** Change-driven pushes go to active remote apps of client type `PL`; the
   `/media` resource and tag 6 are used by the `WEA` client on Windows. Whether one non-Windows
   identity gets both is the same unresolved question as item 1 of the other spec's section 10.
5. **Thumbnail size and rotation across devices.** One phone was captured. Thumbnail pixel
   size comes from the Android thumbnail service and may differ by Android version and vendor;
   that thumbnails are pre-rotated is observed, not coded in LTW (the code reads the orientation
   and discards it).
6. **Rotation of the scaled full image for HEIC sources.** The EXIF `Orientation` tag is
   copied; whether Android's decoder has already rotated the pixels (which would double-rotate
   in a viewer) needs a live test.
7. **Size of the scaled JPEG.** No hard upper bound in code; the estimate in section 5.3 is
   inferred.
8. **Large requests.** No cap on `mediaRequestedIds`, on `mediaIds` in a thumbnails request or
   on N. The practical ceiling of a single APP message over the relay is not known; 1.67 MB
   worked.
9. **Sequence number rollback** (section 2.2) is inferred from the query logic, not tested.
10. **Experiment flags on the phone** (`EnforceMaxThumbnailSize`, `NoMediaProviderFilter`,
    `MediaInfoMinScanInterval`, `RSDisable`) are server controlled; only their coded defaults
    are known. The captured thumbnails exceed 50000 bytes, so the first was off there.
11. **`PhotosLegacySync`.** Sent as `false` by Windows, ignored by this Android build. What the
    legacy protocol looked like cannot be recovered from these versions.
12. **Id reuse** after deletion is an assumption about MediaStore, not something the protocol
    states. The checksum in the delete request is the only guard.
