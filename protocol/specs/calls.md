# Calls: call log sync (`callLogs`), dial on phone, and the Bluetooth boundary

Implementation-grade specification of what the Phone Link "Calls" feature sends over the cloud
relay session, for a reader who implements the PC side in Swift. The peer is an Android phone
running Link to Windows (LTW). Three parts:

1. the **call log** (recent calls) pushed by the phone as content type `callLogs`;
2. the **requests the PC can make** about calls: a forced call log resync and "dial on phone";
3. the **boundary**: what Windows does over Bluetooth instead, and therefore what a relay-only
   client cannot do.

Revision 1, 2026-10-09.

Read first, not repeated here:

- `messages.md` sections 3.2 (what a sequence number is), 3.3 (how the phone chooses a sync) and
  5 (what the PC must reply, result codes).
- `photos.md` section 2 (the same sync model for a content type with a single table; call logs
  are the closest relative) and 2.5 (a PC request that forces a full sync).
- `contacts.md` sections 7 and 8 (names for phone numbers; the call log carries none).
- `session-clipboard-notifications.md` (called **SCN** below) sections 2 (envelope, value set),
  7.3 to 7.6 (notification JSON, `/notifications`, `/permission`) and 8 (`/connect/v1`).

Sources and how they are cited

| Tag | Meaning | Pointer form |
|---|---|---|
| **[code-android]** | Decompiled Link to Windows 1.26082.130.0 (jadx). Package `com.microsoft.mmx.agents` is abbreviated `agents`, `com.microsoft.appmanager` is `appmanager`. | `A: class.method` |
| **[code-windows]** | Decompiled Phone Link 1.26072.257.0. | `W: assembly :: class.method` |
| **[wire]** | Captured traffic, read for structure only (key names, types, counts). `R:` = `captures/vm-raw-2026-10-09/flows.jsonl`; the number is the record `seq`. | `R:147` |
| **[inferred]** | Deduced, not directly confirmed. Also used for facts taken from the public Android SDK contract of `CallLog.Calls` (column units, type codes), which is neither of the two code bases. | |

What the captures contain **[wire]**

**No capture contains any call traffic.** The decoder finds no message with `contentType`
`callLogs`, no request on `/calling` or `/calling/dial`, and no Int64 `call_logs` key in any of
the four capture files (`vm-raw`, `vm-pairing`, `vm-relay`, `vm-baseline`). What the wire does
confirm is the surrounding frame:

| Fact | Records |
|---|---|
| `/connect/v1` request has `configuration.CallLogs` of type Bool | R:147, R:5128 |
| `/connect/v1` request `sequenceNumbers` has 19 Int64 keys and **no** `call_logs` | R:147, R:5128 |
| Connect reply has `permissions.call_logs` Bool and `permissions.calls` Bool, and no top-level `call_logs` | R:163, R:5136 |
| Shape of a PC request with the common legacy keys (`contractVersion` Double, `isuserinitiated` Bool, `ignoreResponse` Bool, `transportType` Int32, `displayName`, `appVersion`, `installationId`, `correlationVector` String) | R:3733 (on `/media/v1`) |
| Shape of a `/permission` request and its reply (`permissionType` Int32, `silent` Bool; reply `result` Int32) | R:2375, R:2378 |
| `/notifications` requests seen: operations 2, 3 and 4 only. No operation 5 (action) | R:2405, R:2381, R:2422 |
| `phoneCommand` pushes exist and carry `phoneCommandType` Int32 | R:4745 |

Everything else in this document is **code only**: the whole `callLogs` exchange, `/calling`,
`/calling/dial`, the permission value 256. Sections say so again where it matters.

No phone number, name, account or device name appears in this document. Examples use invented
values.

---

## 1. The feature in one page

| Part | Direction | Route | `contentType` | What | Status |
|---|---|---|---|---|---|
| Enable | PC to phone | `/connect/v1` | `connect` | `configuration.CallLogs` Bool true; `sequenceNumbers.call_logs` Int64 | request frame on the wire: `CallLogs` present as a Bool, `call_logs` absent |
| Call log, full sync | phone to PC | `/legacy/phonecontent` | `callLogs` | One metadata message (`callLogsIds`, `callLogsLastUpdatedTimes`, `sequenceNumber`), PC answers `itemCount` + `callLogsIds`, then batches of at most 50 calls | code only |
| Call log, incremental | phone to PC | `/legacy/phonecontent` | `callLogs` | Batches only, with `incremental` 1 and `actions` | code only |
| Force a resync | PC to phone | `/calling` | `callLogs` | Starts a full sync to the sender; also switches the feature on | code only |
| Dial on phone | PC to phone | `/calling/dial` | `dialOnPhone` | `phoneNumber`; the phone opens its dialer with the number filled in. It does **not** place the call | code only; Windows no longer sends it |
| Delete an entry, mark missed calls seen, clear the log | | | | **Do not exist** | section 6.2 |
| Call state (ringing, active, ended), answer, decline, hang up, audio | | | | **Not on the relay.** Bluetooth Hands-Free Profile between Windows and the phone | section 9 |

Answers to the questions this document was written for:

- **Does the call log need the Bluetooth "Calls" setup?** No, not on the protocol level. The
  phone needs only the Android permission `READ_CALL_LOG` and the switch `CallLogs`. Windows
  additionally waits for its own PC-side consent flag for the Calls feature (section 2.5), which
  is a toggle, not the Bluetooth pairing.
- **Can a relay-only client start a call?** It can make the phone show its dialer with a number
  entered (`/calling/dial`); a person must then press the call button on the phone. Nothing on
  the relay places, answers or ends a call.
- **Names.** The call log has no name field. Resolve numbers with the contacts sync.

---

## 2. Enablement

### 2.1 `/connect/v1` configuration key

| Key | Type | Windows sends | Phone default | Effect on the phone |
|---|---|---|---|---|
| `CallLogs` | Bool | true exactly when the PC-side Calls consent is on and the phone is Android (2.5) | false | Stored in the preference `callLogsFeatureFlag`. Then the call log coordinator is **subscribed** when the flag is true and `READ_CALL_LOG` is granted, otherwise **unsubscribed**. |
| `SequencedContentSyncs`, `MessagingSync` | Bool | true | false | Both must be true or the phone ignores `sequenceNumbers` entirely (`contacts.md` 2.1). |
| `SyncSkipMetadataForAuto` | Bool | false | false | When true, a -1 number yields a content-only push of every row with action 0 instead of the metadata round. Leave false. |

A: `agents.ConnectionRequestHandler.processPartnerConfiguration`; A: `agents.DeviceData`
(methods `i` and `e`, preference `callLogsFeatureFlag` in `MmxAgentsPrefs`);
A: `agents.AgentRegister.ensureCallLogTriggerStateInSync`, `updateCallLogTrigger`
**[code-android]**. W: `YourPhone.Calling.Managed :: Sync.CallingEstablishConnectionPayload.LoadConfiguration`
**[code-windows]**. The key is on the wire as a Bool in R:147 and R:5128 **[wire]**; SCN 8.1
records it as false in the pairing capture.

What "subscribed" means **[code-android]** (A: `agents.CallLogsSyncCoordinator.subscribe`,
`unsubscribe`; A: `agents.sync.SyncCoordinatorBase`; A: `agents.sync.DataSourceBase.addListener`,
`removeListener`):

- Subscribed: the coordinator consumes sync requests, and the call log data source registers a
  content observer on the Android call log and scans it.
- Unsubscribed: the observer is removed, the recorded state of **every** PC is cleared, and sync
  requests for call logs are dropped without an answer (they are published to a subject that has
  no consumer).

The flag is one preference for the whole phone, not per PC. Every `/connect/v1` from any PC
overwrites it. With two computers linked to one phone, the last connect decides; a connect with
`CallLogs` false from the other computer silently stops call log pushes to this one until the
next `/connect/v1` or `/calling` request **[inferred]** from the code above.

### 2.2 `sequenceNumbers` key

| Key | Type | Meaning |
|---|---|---|
| `call_logs` | Int64 | -1: "I have nothing". N >= 0: "I hold the phone's call log as of sequence N". Any other value type fails the connect request (cast to `Long`). |

The string is `agents.sync.ContentType.CALL_LOGS.toString()` **[code-android]** and
`CallingConstants.CallLogsSeqNoKey` **[code-windows]**. Note the three spellings: `CallLogs`
(configuration switch), `call_logs` (sequence key and permission key), `callLogs` (content type).

What the phone does with it, provided `READ_CALL_LOG` is granted
(A: `ConnectionRequestHandler.setCoordinatorStates`; A: `CallLogsSyncCoordinator.setTargetSequenceNumber`;
A: `SyncCoordinatorBase.setTargetState`, `determineSyncType`, `noDataForContentType`)
**[code-android]**:

| PC sent | Phone behaviour |
|---|---|
| Key absent | Nothing at connect, and no `call_logs` in the reply. This is what Windows did in R:147 and R:5128 **[wire]**. See the note below for what a later change does. |
| -1, phone's number 0 or less | Nothing (the phone has nothing to sync). |
| -1, phone's number above 0 | **Full sync**, section 3.3. |
| Equal to the phone's number | Nothing. |
| Any other number | **Incremental sync**, section 5. |
| Permission not granted | Key ignored; no `call_logs` in the reply. |

Two hazards, both **[inferred]** from the code and not tested:

1. **Do not send `call_logs` with `CallLogs` false.** The handler records the number and then
   reads the phone's current number, which waits without a timeout for the first scan of the call
   log. The scan only ever runs while the coordinator is subscribed. If the feature has been off
   since the LTW process started, that wait never ends and the connect reply never comes
   (A: `DataSourceBase.getSequenceNumber`, `initialScanOperation`). Windows always sets both from
   the same condition.
2. **A PC that sends no `call_logs` can still receive call log pushes** when the feature is on
   (switched on by another PC, or by an earlier `/calling` request). A change in the call log
   starts an automatic sync to every active `PL` client; for a client with no recorded number
   that resolves to a full sync, so a `callLogs` metadata message arrives
   (A: `SyncCoordinatorBase.onChangeDetected`, `determineSyncType` with an empty state). Answer it
   (section 4.2), with `itemCount` 0 if the data is not wanted. The current Swift client does
   exactly that (`app/Sources/WinPhoneCore/Features/NotificationSync.swift`, `declinedSyncTypes`).

Windows adds the key only when the phone is call-log capable and the Calls consent is on, using
its stored number or -1 (W: `CallingEstablishConnectionPayload.Load`;
W: `Utilities.CallingFeatures.IsCallLogsCapable`) **[code-windows]**.

### 2.3 Phone-side gates **[code-android]**

| Gate | Source |
|---|---|
| Android permission `android.permission.READ_CALL_LOG`, and only that. Permission type `CALL_LOGS`, enum value 9, legacy flag 256 (0x100). | A: `agents.permissions.PermissionsHelper` (`CALL_LOGS_PERMISSION`, `hasPermissionsForContentType`); A: `agents.PermissionTypes` |
| The `callLogsFeatureFlag` preference (2.1). | A: `AgentRegister.ensureCallLogTriggerStateInSync` |
| The phone build "supports calling": on the generic build, the device has a telephony radio. Otherwise `CALL_LOGS`, `CALLS` and `DIAL_ON_PHONE` are missing from the registered set, their bits are missing from `registeredPermissionTypes` (so Windows never asks), and the triggers are not armed when the agent starts. | A: `agents.devicesupport.SupportedFeaturesProvider`; A: `com.microsoft.deviceExperiences.BaseOemFeature.isCallingSupported`; A: `AgentRegister.registerOrUpdateTriggersIfNeeded` |
| Pushes caused by a change go to every active remote app of client type `PL`. | A: `SyncCoordinatorBase.onChangeDetected` |
| Sync allowed by the metered-connection policy. | A: `agents.sync.SyncSequence.sendMessageAsync` |

Not a gate: Bluetooth state, Bluetooth pairing with the PC, the `calls` permission, contacts
permission, any capability of the PC. No code on the phone's call log path looks at Bluetooth.

### 2.4 What the connect reply says

A: `ConnectionRequestHandler.tryProcessRequest`, `createDevicePermissionBlob`,
`createDeviceCapabilityBlob` **[code-android]**; read by W: `CallingEstablishConnectionPayload.Apply`
**[code-windows]**.

| Key | Type | Meaning | Wire |
|---|---|---|---|
| `call_logs` (top level) | Int64 | The phone's **current** call log sequence number. Present only when the PC sent `call_logs` and the permission is granted. Reading it waits for the first scan. | not captured |
| `permissions.call_logs` | Bool | `READ_CALL_LOG` granted. | key and type in R:163, R:5136 |
| `permissions.calls` | Bool | Always false from this Android build: the permission test has no case for `CALLS` (A: `PermissionsHelper.hasPermissionsForContentType`). Windows stores it as its "calls device permission". It gates nothing in the call log sync. | key and type in R:163, R:5136 |
| `capabilities.registeredPermissionTypes` | Int32 | Bits 0x10 Calls, 0x100 CallLogs, 0x20000 DialOnPhone are set when the phone supports calling (2.3). Windows names: W: `YourPhone.AppCore.Managed :: DeviceCapabilities`. | key in R:163; SCN 8.3 records the value |
| `attributes.countryCode` | String | Needed to match call log numbers against contacts (`contacts.md` 8). | SCN 8.3 |

There is no `capabilities.calling` or similar mask; nothing else in the reply concerns calls.

Windows stores the reply's `call_logs` only as the "expected" number (to show a syncing state).
The number it sends next time comes from the `sequenceNumber` inside pushes (4.1, 4.3)
**[code-windows]** W: `CallingEstablishConnectionPayload.Apply`; W: `Sync.CallHistoryProcessor.Complete`.

### 2.5 What Windows requires before it asks for call logs **[code-windows]**

| Condition | Meaning | Source |
|---|---|---|
| `CallsPCPermission` is true | The PC-side consent for the Calls feature. Set by the user on the Calls page or in Settings, set for a new device once when the remote feature `CallsPCPermissionEnableByDefault` is on, always set for iOS. **It is a stored Bool, not a Bluetooth state.** | W: `Utilities.CallingFeatureUtils.IsCallLogsSyncSupportedAndEnabled`; W: `ViewModels.CallingNodeViewModel.ErrorActionInvokedAsync`; W: `Settings.CallingSettingsGroupViewModel`; W: `Services.CallingDevicesApplicationService.TryEnableCallsPCPermissionByDefault` |
| Phone platform is Android | iOS uses Bluetooth PBAP for call history instead. | same; W: `Sync.CallHistoryRequest` |
| Phone is call-log capable | Bit 0x100 of `registeredPermissionTypes`, or a Bluetooth call-history capability. Needed for `call_logs` in `sequenceNumbers`, not for the `CallLogs` switch. | W: `CallingFeatures.IsCallLogsCapable` |
| The Windows build has the calling API | When a content batch arrives, Windows applies it only if `Windows.ApplicationModel.Calls.CallsPhoneContract` version 5 is present and the phone-line limited-access feature unlocks; otherwise it answers `result` 16 and stores nothing. A platform check, not a pairing check. | W: `CallHistoryProcessor.ProcessItem`; W: `CallingFeatureUtils.IsCallingSupportedAndEnabled` |

The Bluetooth setup has its own flag, `CallsCompletedFTU`, set when the Hands-Free device
reaches the "ready" stage (W: `CallingNodeViewModel.HandleHfpDeviceStateAsync`). The call log
sync does not read it. Windows even has a "set up calls" toast that is shown when a synced batch
contains rows **while `CallsCompletedFTU` is still false** (W: `CallHistoryProcessor.TryAndDisplayCallsSetupToastOnMissedCallAsync`;
W: `Utilities.CallingToastNotificationUtils.ShouldShowCallsSetupToastOnMissedCall`), which shows
that call logs are expected to arrive before the Bluetooth link exists.

In practice the two are started together: turning the consent on also makes Windows begin the
Hands-Free registration (W: `CallingDevicesApplicationService.OnDeviceValueChanged`,
`StartForDeviceAsync`). Only the app badge for missed calls needs `CallsCompletedFTU`
(W: `Badging.CallingBadgeDataProvider.GetBadgeItemCountAsync`).

**[inferred]** In R the consent was off: both connect requests lack `call_logs` although SCN 8.3
records the phone as call-log capable.

### 2.6 Asking for the permission

`/permission` (SCN 7.6) with `permissionType` Int32 **256** and `silent` false. Windows sends
exactly this (W: `CallingNodeViewModel.GetCallLogsPermissionAsync` through
`SendPermissionsRequestAsync(DevicePermissions.CallLogs, ...)`) **[code-windows]**; the phone maps
the number back to `CALL_LOGS` by its flag value (A: `PermissionTypes.getPermissionType`;
A: `agents.PermissionRequestHandler`) **[code-android]**. Reply `result` 0 or 4 means granted;
Windows then requests a full sync (section 6.1). The request shape is on the wire for another
permission (R:2375, R:2378); the value 256 was not captured.

---

## 3. Sync model

### 3.1 Source, scope, identity **[code-android]**

A: `agents.callinglogs.CallLogsReader`, `CallLogsDataSource`, `CallLogsMediaItem`.

| Aspect | Value |
|---|---|
| Source | Android call log provider, `CallLog.Calls.CONTENT_URI`. |
| Scope | Rows whose `date` is within the last **30 days** (2 592 000 000 ms before now, evaluated at each scan). No filter on type, SIM or number. |
| Item id | The row's `_id`. |
| Item checksum | The row's `last_modified` (Unix milliseconds). |
| Order in the metadata list | `last_modified` descending. |
| Order of rows in content batches | `date` descending (newest call first). |
| Columns read for content | `_id`, `number`, `date`, `duration`, `type`, `is_read`, `last_modified`, `subscription_id`. Nothing else. |
| Change detection | Content observer on the call log URI and its descendants; each notification schedules a scan, rate-limited by the experiment value `CallLogsMinScanInterval`, default 1000 ms. |
| Sequence number | As in `messages.md` 3.2: -1 before the first scan; raised by exactly 1 by any scan that finds an added id, a changed checksum or a vanished id. One counter per phone, not per PC. |

Consequences:

- A call that ages past 30 days leaves the view at the next scan and is then reported as a
  deletion (action 2), or is simply absent from the next metadata list **[inferred]**. Scans
  happen only when the call log changes, so the aged row goes with the next new call.
- Anything that rewrites a row on the phone changes `last_modified` and therefore the checksum:
  a missed call being marked read, the dialer's cached-name refresh, a duration update
  **[inferred]** from the Android provider's behaviour.
- The first scan after the LTW process starts never notifies listeners (the old number is -1),
  so changes made while LTW was not running reach the PC at the next `/connect/v1`, not as a
  spontaneous push (A: `DataSourceBase.performScan`).

### 3.2 The exchange at a glance

Same as `photos.md` 2.3 and 2.4 with different key names:

```
PC  -> phone  /connect/v1            CallLogs true, sequenceNumbers.call_logs = -1
phone -> PC   /legacy/phonecontent   callLogs, metadata 1, ids + checksums, sequenceNumber
PC  -> phone  /internal/response     result 0, itemCount n, callLogsIds [wanted]
phone -> PC   /legacy/phonecontent   callLogs batch 1 (<= 50 rows)
PC  -> phone  /internal/response     result 0
...
phone -> PC   /legacy/phonecontent   callLogs last batch, sequenceNumber
PC  -> phone  /internal/response     result 0
```

All messages of one sync carry the same `correlationVector`. The phone sends one message at a
time and waits for the answer.

### 3.3 Full sync **[code-android]**

A: `CallLogsSyncCoordinator.getFullSyncPayload`; A: `agents.CallLogsMessageBuilder`;
A: `agents.sync.SyncSequence`, `SyncExecutor`.

1. The phone scans the call log (this also updates its view table and may raise the sequence
   number) and sends the metadata message (4.1).
2. The PC answers with the ids it wants (4.2). `itemCount` 0 or absent ends the sync as
   successful.
3. The phone reads the requested rows by id and sends them in batches of at most 50 rows (4.3).
   The last batch carries `sequenceNumber`.
4. After the last answer with `result` 0 the phone records this PC as holding that number.

Differences from the other content types:

- **The metadata message is sent even when the list is empty** (`itemCount` 0, two zero-length
  arrays). Call logs are the only builder that allows empty metadata
  (A: `CallLogsMessageBuilder.getAllowEmptyMetadata`). Answer it with `itemCount` 0.
- **A requested id that no longer exists is silently missing** from the batches. There is no
  action-2 entry for it in a full sync (the by-id query simply returns fewer rows). Do not wait
  for every requested id.
- The by-id read has no 30-day filter; any `_id` the provider still holds is returned.
- Batches are cut by row count, not by size.

### 3.4 Limits **[code-android]**

| Limit | Value | Source |
|---|---|---|
| Rows per content batch | 50 | A: `CallLogsMessageBuilder.buildPayloads` |
| Messages per sync, metadata message included | 50 | A: `SyncExecutor.executeAsync` |
| Rows deliverable by one full sync | 49 x 50 = 2 450 | from the two above |
| Rows deliverable by one incremental sync | 50 x 50 = 2 500 | same |

What happens beyond the cap was not traced (open question 6). A 30-day window rarely holds
that many calls.

---

## 4. Payload schemas

Types are value-set types (SCN 2). Arrays in one message are parallel: index i describes call i.
Null strings are sent as `""`, also inside string arrays (A: `agents.ypp.valueset.ValueSetSerializerUtility`)
**[code-android]**. Everything in this section is code only.

Key names are the same string constants on both sides: A: `CallLogsMessageBuilder`;
W: `YourPhone.Calling.Managed :: Utilities.CallingConstants`.

### 4.1 Metadata message (phone to PC)

APP request on `/legacy/phonecontent`. A: `agents.MessageBuilderBase.getMetadata`;
A: `CallLogsMessageBuilder.getMetadataInternal`, `getMetadataItemCount` **[code-android]**.
Read by W: `CallHistoryProcessor` (constructor) **[code-windows]**.

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `callLogs` |
| `metadata` | Int32 | 1 |
| `itemCount` | Int32 | Length of `callLogsIds`. May be 0. |
| `callLogsIds` | Int64Array | Every in-scope call id, ordered by `last_modified` descending. |
| `callLogsLastUpdatedTimes` | Int64Array | Parallel with `callLogsIds`: the checksum (`last_modified`, Unix ms). |
| `sequenceNumber` | Int64 | The sequence number of the snapshot being offered. **Singular, top level.** There is no `sequenceNumbers` object in call log messages. |
| `contractVersion`, `correlationVector`, `installationId`, `displayName`, `dedupeID`, `retryCount`, device status keys | | As on every phone push (`messages.md` 4.1). |

Example with invented values:

```
contentType: "callLogs"   metadata: 1   itemCount: 3
callLogsIds:              [1043, 1042, 1038]
callLogsLastUpdatedTimes: [1760000300000, 1760000200000, 1759990000000]
sequenceNumber: 17
```

### 4.2 The PC's answer to the metadata message

APP message on `/internal/response`, headers as in `contacts.md` section 4
(`_originalRequestId`, `_rejectionVersion` `"1"`, `result` `"0"`).

Written by W: `CallHistoryProcessor.AssembleResponseMetadata` **[code-windows]**. Read by
A: `SyncSequence.handleSendResult`, `handleSuccessfulResponse`; A: `MessageBuilderBase.getRequestedItemCount`;
A: `CallLogsMessageBuilder.getMediaItemMessages` **[code-android]**.

| Key | Type | Read by phone | Required | Meaning |
|---|---|---|---|---|
| `result` | Int32 | yes | send it | 0. Missing counts as 0 for a metadata answer; any other value fails the sync (19 ends the user session). |
| `itemCount` | Int32 | yes | **yes, above 0, to receive content** | Windows: number of ids requested. The phone only tests it against 0. Must be Int32 (cast). |
| `callLogsIds` | Int64Array | yes | yes when `itemCount` > 0 | The ids whose rows are wanted. **Same key name as in the metadata message.** Must be Int64Array (cast). |
| `contentType` | String | no | no | `callLogs` |
| `contractVersion` | Double | no | no | 3.99 |
| `correlationVector` | String | no | no | Copied from the metadata message. |

Phone behaviour by case **[code-android]**:

| Answer | Phone behaviour |
|---|---|
| `itemCount` absent or 0 | The sync ends as successful. The phone records this PC as holding `sequenceNumber`; later changes arrive as incremental pushes. |
| `itemCount` > 0, `callLogsIds` non-empty | One query for exactly those ids, rows sent newest first in batches of 50. |
| `itemCount` > 0, `callLogsIds` absent, empty, or naming only ids that no longer exist | No batch can be built. The sync does not complete normally; not traced further (open question 5). Do not send this. |
| `callLogsIds` of another type | Cast failure, reported as a failed content load; no rows. |
| `result` other than 0 | Sync failed; nothing recorded; the same sync is tried again at the next trigger. |

What Windows requests: it deletes local rows whose id is not listed and asks for every id that
is new or whose stored `last_updated_time` differs from the offered checksum
(W: `YourPhone.Calling.WinRT.DataStore.CallHistoryTable.Synchronize`;
W: `YourPhone.Utilities :: Extensions.IUpdatableTableExtensions.SynchronizeWithData`)
**[code-windows]**. When it wants nothing it answers `itemCount` 0 with an empty `callLogsIds`
and stores `sequenceNumber` at once (W: `CallHistoryProcessor.AssembleResponseMetadata`, `Complete`).

The metadata message is the authoritative "these are all calls of the last 30 days" list: delete
local rows that are not in it, whatever is then requested.

### 4.3 Content batch (phone to PC)

APP request on `/legacy/phonecontent`. Built by A: `CallLogsMessageBuilder.buildPayloads`
**[code-android]**; read by W: `CallHistoryProcessor.ProcessItem` and
W: `Sync.EntityHelpers.BuildCallHistoriesFromValueSet` **[code-windows]**.

| Key | Type | Meaning | Read by Windows |
|---|---|---|---|
| `contentType` | String | `callLogs` | routing |
| `itemCount` | Int32 | Rows in this batch, 1 to 50. | yes, required |
| `callLogsIds` | Int64Array | Call id (Android `_id`). | yes |
| `callLogsPhoneNumbers` | StringArray | The other party's number, 4.4. | yes |
| `callLogsDate` | Int64Array | Start of the call, Unix milliseconds. | yes |
| `callLogsDuration` | Int64Array | Duration in seconds, 4.4. | stored, not shown |
| `callLogsType` | Int32Array | Call type code, 4.4. | yes |
| `callLogsRead` | BoolArray | The row's `is_read` column equals 1. | stored only |
| `callLogsPhoneAccountIds` | StringArray | The row's `subscription_id` column, 4.4. `""` when null. | stored only |
| `callLogsLastUpdatedTimes` | Int64Array | `last_modified`, Unix ms. Equals the checksum of 4.1. | yes |
| `actions` | Int32Array | **Incremental batches only**: 0 create, 1 update, 2 delete. Absent in full-sync batches. | yes, optional |
| `incremental` | Int32 | 1, incremental batches only. | no |
| `sequenceNumber` | Int64 | **Last batch of the sync only.** The number to store. | yes |
| common keys | | As in 4.1. No `metadata`. | |

All eight `callLogs...` arrays are always present and have `itemCount` elements. Windows casts
each to its exact array type and throws when any is missing or when fewer rows than `itemCount`
can be read **[code-windows]**.

Example of a full-sync batch with invented values:

```
contentType: "callLogs"   itemCount: 2
callLogsIds:              [1043, 1042]
callLogsPhoneNumbers:     ["+15550100", "5550123"]
callLogsDate:             [1760000290000, 1760000100000]
callLogsDuration:         [0, 75]
callLogsType:             [3, 2]
callLogsRead:             [false, false]
callLogsPhoneAccountIds:  ["1", "1"]
callLogsLastUpdatedTimes: [1760000300000, 1760000200000]
sequenceNumber: 17
```

### 4.4 Field semantics

| Field | Semantics | Tag |
|---|---|---|
| `callLogsPhoneNumbers` | The provider's `number` column, verbatim: as dialled or as presented by the network, **not normalized**, national or international form. Empty for a withheld or unknown number; Windows has a "private number" label for a row without a number. Normalize as in `contacts.md` 8 before matching. | [code-android] `CallLogsReader.buildCallLogs`; [code-windows] `ViewModels.CallLog.CalculateDisplayName` |
| `callLogsDate` | Unix ms. Windows converts with `FromUnixTimeMilliseconds`. | [code-windows] `EntityHelpers` |
| `callLogsDuration` | Seconds; 0 for calls that were not connected. | [inferred] Android SDK `CallLog.Calls.DURATION`; Windows stores the raw number |
| `callLogsType` | 1 incoming (answered), 2 outgoing, 3 missed, 4 voicemail, 5 rejected (declined by the user), 6 blocked, 7 answered externally (on another device). The phone sends the raw `type` column, so vendor-specific values are possible; treat any other value as unknown. | [code-android] raw column; [code-windows] `Utilities.CallTypes` has exactly these seven names in this order plus 0 Unknown |
| `callLogsRead` | Meaningful for missed calls: true once the user has seen the missed call on the phone. For other types it is whatever the dialer wrote, usually false. | [inferred] Android SDK `CallLog.Calls.IS_READ` |
| `callLogsPhoneAccountIds` | Identifier of the phone account (SIM) the call used, as the dialer stored it: on current Android usually the subscription id as a decimal string, on older builds or other dialers an ICCID or another opaque string. Comparable with `subscriptions.ids` of `messages.md` 4.8 only when it parses as that integer. | [inferred]; [code-windows] never read after storing |
| `callLogsLastUpdatedTimes` | Store it per row as the checksum to compare in the next metadata round. | [code-windows] `CallHistoryTable.ChecksumName` |

How Windows presents the types **[code-windows]** (W: `Utilities.CallsUtils.ResolveCallTypeToString`;
W: `CallHistoryTable`, recent-calls query): 1, 4, 6 and 7 are labelled as incoming, 2 outgoing,
3 missed, 5 declined; type 6 is left out of the "recent calls" list; the missed-call badge counts
type 3 rows newer than a locally stored timestamp, not `callLogsRead`.

**Not in the message at all** **[code-android]** (the projection is the fixed list of 3.1): the
contact name cached by the dialer, the number's label or type, the `new` flag, the presentation
code that distinguishes "private" from "unknown" from "payphone", the country ISO, the geocoded
location, video-call features, the via number, the voicemail recording, the block reason.

### 4.5 The PC's answer to a content batch

`result` Int32 0 in the value set and `result: 0` as a header, as for every content type
(`messages.md` 5). Always include `result`; for a batch the phone's default for a missing key is
24, which neither completes nor fails the sync (A: `SyncSequence.lambda$next$2`, `handleSendResult`)
**[code-android]**.

Other answers Windows can give **[code-windows]** (W: `CallHistoryProcessor.ProcessItem`):
`result` 16 when the Windows build lacks the calling API (the phone ends the sync as "disabled"
and records nothing); the generic gate results of SCN 7.2 before processing.

A failed or interrupted sync is replayed from the old number, so apply batches idempotently:
upsert by id, delete by id.

---

## 5. Keeping the list current: incremental pushes **[code-android]**, not captured

A: `CallLogsSyncCoordinator.getIncrementalSyncPayload`; A: `DataSourceBase.loadChangesSince`;
A: `agents.sync.ContentViewRepository.getChangesSince`.

When they happen: at `/connect/v1` if the PC's `call_logs` differs from the phone's number (and
is not -1), and afterwards whenever a scan raises the number while the PC is an active `PL`
client. A new call, a missed call being read, a call deleted on the phone and a call ageing out
of the 30-day window all raise it.

Timing: the call log row for a finished call is written by the phone's telephony stack when the
call ends, so the push follows the **end** of a call, after the scan delay of about 1 s. There is
no push when a call starts ringing or is answered **[inferred]** (the provider has no row yet).

Shape: no metadata message. Content batches as in 4.3 with `incremental` Int32 1 and `actions`:

| Row state relative to the PC's number | `actions` | Other arrays |
|---|---|---|
| Tombstoned after it | 2 | Only `callLogsIds` is meaningful: number `""`, date 0, duration 0, type 0, read false, account `""`, last-updated 0. |
| Existed before, checksum changed after it | 1 | Full row. |
| Created after it | 0 | Full row. |

Order across the whole sync: all deletions first, then all updates (newest call first), then all
creations (newest call first); then cut into batches of 50. The last batch carries
`sequenceNumber`. Apply in array order; delete before upsert.

The PC answers each batch `{result: 0}` and stores `sequenceNumber` when it appears.

Windows needs no stored state for this: a content message with an unknown `correlationVector`
creates a new processor from the message itself; without a `metadata` key nothing is diffed, the
rows are applied and the number is stored (W: `CallHistoryProcessor` constructor and `ProcessItem`;
W: `YourPhone.Connectivity.Managed :: PhoneContentHandler.HandleContentPayload`) **[code-windows]**.

Edge cases:

- A PC number that the phone's history no longer covers the PC's state for (phone data cleared,
  LTW reinstalled) produces an incremental sync with nothing to send, for which no batch can be
  built (open question 5). **[inferred]** treat a connect reply `call_logs` **lower** than the
  stored number as "start over": drop the local list and send -1, or force a full sync (6.1).
- With `SyncSkipMetadataForAuto` true and a PC number of -1, the "incremental" push lists every
  current row with action 0 and never says which local rows to delete. Another reason to leave
  that switch false.

---

## 6. Requests from the PC

### 6.1 `/calling`: force a full call log sync **[code-windows]** + **[code-android]**, not captured

The only request about call logs. APP request, `_route` `/calling`.

Written by W: `Sync.CallHistoryRequest.BuildRequestMessage`, sent by
W: `Managers.CallHistoryManager.SyncCallHistoryAsync` through `SendLegacyRequestAsync`
**[code-windows]**. Handled by A: `agents.CallingRequestHandler.tryProcessRequest` after the
common checks of A: `agents.ScenarioRequestHandlerBase.handleAsync` **[code-android]**.

| Key | Type | Value | Read by phone |
|---|---|---|---|
| `contentType` | String | `callLogs` | yes; anything else gives `result` 2 |
| `correlationVector` | String | Request correlation id; reused as the `correlationVector` of the pushes it causes. Send it. | yes |
| `contractVersion` | Double | 3.99. **Required**: unboxed without a null check; integer part must be 3 or the answer is `result` 3. | yes |
| `isuserinitiated` | Bool | Raises the push priority. | yes |
| `relatedCorrelationIds` | StringArray | One element, the correlation id. | no |
| `subcontentTypes` | StringArray | One element, `callLogs`. | no |
| `ignoreResponse` Bool, `transportType` Int32 0, `displayName`, `appVersion`, `installationId` String | | Added by W: `YourPhone.Connectivity.Managed :: RemoteAppClient`. | no |

No headers beyond the standard ones. (For iOS, Windows sends a different content type with the
header `x-bt-content: pbap/getCalls`; that path is Bluetooth and does not concern Android.)

Phone behaviour, in order **[code-android]**:

1. Sets `callLogsFeatureFlag` to **true**, as if `CallLogs` had been true in `/connect/v1`.
2. Without `READ_CALL_LOG`: reply `result` 7, nothing else.
3. Subscribes the coordinator if needed (2.1).
4. Starts a **forced full sync** to the sender: metadata message, PC answer, batches (3.3),
   regardless of sequence numbers.
5. Replies to the `/calling` request only **after** that sync has finished.

| Reply key | Type | Value |
|---|---|---|
| `result` | Int32 | 0 sync completed; 7 no call log permission; 8 metered sync off; 10 cancelled; 11 coalesced; 21 two-phone mode; 1 any other failure, including a PC answer other than 0 to one of the pushes (A: `agents.AppServiceProviderHelpers.createResponseFromPayloadProcessingResult`). Without any sync: 2 wrong `contentType`; and from the common checks before the handler runs, 3 contract version, 8 / 13 / 21 / 23 sync not allowed (`device-controls.md` section 1). |
| `contractVersion` | Double | 3.99 |

So the PC must answer the pushes while its own request is still pending. After a successful
forced sync the phone records the PC's number, so later changes arrive incrementally even if the
PC never sent `call_logs` in `/connect/v1`.

`forceRefreshOfTypes` in `/connect/v1` is not an alternative: the phone acts on it only for
`phoneApps` (A: `ConnectionRequestHandler.forceFullSyncs`).

When Windows sends it **[code-windows]** (W: `CallingNodeViewModel.RefreshCallLogsAsync` and its
callers): the refresh button of the Calls page; right after the call log permission was granted;
and once automatically when the local history is empty although permission and consent are
present. It is not sent when the phone reported no contacts capability
(W: `CallHistoryManager.SyncCallHistoryAsync`). On `result` 7 Windows clears its stored call log
permission. Windows does **not** send it after a call ends on Android (that refresh exists for
the iOS Bluetooth path only, W: `CallingNodeViewModel.OnCallStateChanged`); for Android it
relies on the incremental push of section 5.

### 6.2 What does not exist **[code-android]**

- **No delete.** No handler writes to the Android call log. The only two classes that touch
  `CallLog.Calls` are the reader and the data source of 3.1, and both only query.
- **No "mark missed calls as seen".** Same reason. Windows keeps its own "seen" timestamp
  locally (W: `CallingBadgeDataProvider.UpdateTimestampForBadgeClear`) **[code-windows]**. The
  missed-call notification on the phone can be dismissed through `/notifications` operation 2
  when notification sync is on (SCN 7.5); whether that also resets the phone's missed-call state
  depends on the dialer **[inferred]**.
- **No paging, no query by number or date, no single-entry fetch from the PC.** Selection is
  only possible in the answer to a metadata message (4.2).
- **No call log resource on the PLATFORM side.** None of the 17 device-resource handler classes
  concerns calls, none of the publish tags of SCN 5.3 does, and the content-change publish
  (tag 7) is produced for phone apps and app context only.
- The complete APP route map has 26 routes; the only two with calls in them are `/calling` and
  `/calling/dial` (A: `appmanager.DaggerMainApplication_HiltComponents_SingletonC`, route map).

---

## 7. Dial on phone: `/calling/dial` **[code-android]**, not captured

A: `agents.DialCommandRequestHandler.tryProcessRequest`.

### 7.1 Sender

Phone Link 1.26072 contains the request class (W: `YourPhone.Calling.Managed :: Sync.CallingRequest`)
and the route constant (`CallingConstants.DialCommandsRoute`), but **nothing in the decompiled
assemblies constructs the request or uses the constant**, and nothing reads the capability bit
`DialOnPhone` **[code-windows]**. Windows places calls through its Bluetooth phone line instead
(W: `CallingNodeViewModel.PlaceCallAsync`; W: `Managers.CallLineManager.DialWorkerAsync`). The
route looks like a leftover of the time before Bluetooth calling **[inferred]**. The phone
handler is still registered, so a client may use it; expect no Windows behaviour to compare
against, and no guarantee that future LTW builds keep it.

### 7.2 Request

APP request, `_route` `/calling/dial`.

| Key | Type | Value | Read by phone |
|---|---|---|---|
| `contentType` | String | `dialOnPhone` | yes; anything else gives `result` 2 |
| `phoneNumber` | String | The number to put in the dialer. Any value type is accepted; the phone takes its string form. Absent gives `result` 2. | yes |
| `contractVersion` | Double | 3.99. Required, as in 6.1. | yes |
| `correlationVector` | String | The Windows class uses a fresh GUID string. | no (logging only) |
| `subcontentTypes` | StringArray | One element, `dialOnPhone`. | no |
| `itemCount` | Int32 | 1 | no |
| `isuserinitiated` and the other common legacy keys | | As in 6.1. | `isuserinitiated` only, for activity tracking |

Example: `{contentType: "dialOnPhone", phoneNumber: "+15550100", contractVersion: 3.99, correlationVector: "<id>"}`.

### 7.3 What the phone does

It starts an activity with the intent action `android.intent.action.DIAL`, data `tel:` followed
by the string exactly as received, and the new-task flag. That is all.

- **This opens the phone's dialer with the number filled in. It does not place the call.** The
  user has to press the call button on the phone, and the call then runs on the phone (earpiece,
  speaker, or whatever audio device the phone is using). Placing a call directly would need the
  `CALL` action and the `CALL_PHONE` permission; LTW never uses either. This handler is the only
  place under `com.microsoft` that builds a `tel:` URI.
- **Android permission needed: none.** The handler has no permission check: not `READ_CALL_LOG`,
  not the `CallLogs` switch, not contacts.
- **Bluetooth: not involved.** The handler does not look at any Bluetooth state.
- The number is not validated, normalized or encoded. Because the URI is parsed as text, a `#`
  starts a fragment and everything from it on is lost; percent-encode `#` as `%23` (needed for
  service codes) **[inferred]** from URI syntax, not tested.
- The activity is started from LTW's application context while LTW is usually in the background.
  The handler does not use LTW's own background-launch helper. On current Android a background
  activity start can be suppressed by the system without an error, and with the phone locked the
  dialer appears only after unlocking **[inferred]**. The reply does not tell.

### 7.4 Reply

| `result` | When |
|---|---|
| 0 | The start-activity call returned. **Not** a confirmation that the dialer became visible, and never a statement about a call. |
| 1 | The start-activity call threw (for example no app handles the intent). |
| 2 | `contentType` is not `dialOnPhone`, or `phoneNumber` is missing. |
| 3 | `contractVersion` integer part is not 3. |
| 8, 13, 21, 23 | Sync not allowed: metered connection, all features disabled, two-phone mode, secondary user profile (`device-controls.md` section 1). |

Every reply also has `contractVersion` Double 3.99. The reply is immediate; there is no
follow-up message of any kind. If the user does place the call, the only later trace on the
relay is the call log push when the call ends (section 5).

---

## 8. Incoming and ongoing calls on the relay

### 8.1 There is no call-state message **[code-android]**

Nothing in LTW reports ringing, off-hook or idle to the PC, and nothing accepts "answer",
"decline", "hang up", "mute" or "hold":

- No APP route, device-resource handler or publish tag for it (6.2).
- Two places listen to the phone's call state, and neither tells the PC: the camera-stream
  feature (A: `agents.camera.devicemonitor.CallingModeObserverCompat`, `CallingModeObserver`),
  which lets the phone-as-webcam stream react to a call, and the "lapsed user" tips
  (A: `agents.lapsedusers.DefaultLapsedUserTriggers`, `LapsedUserBackgroundService`), which show
  a local hint on the phone.
- No class under `agents` calls into Android's telecom service to place, accept or end a call;
  the single use of that service asks for the default dialer's package name (8.2).
- `phoneCommand` is a push from the phone to the PC, and its types are: 0 metered-sync setting,
  1 launch URI, 2 sync disabled, 3 hotspot permission update, 4 post-notification permission,
  5 contact-sync consent, 6 camera permission, 7 sensitive-notification permission
  (W: `YourPhone.Background :: Processors.PhoneCommandProcessor.PhoneCommandType`)
  **[code-windows]**. None concerns calls. Pushes of this content type are on the wire (R:4745);
  their type values were not read.

### 8.2 Dialer notifications (`notificationClass` 3)

This is the only way a call shows up on the relay while it is happening, and it is part of the
notification sync, not of the Calls feature. It needs notification-listener access on the phone
(SCN 7.8).

| Fact | Tag and pointer |
|---|---|
| A notification's JSON has `notificationClass` 3 when its package is the phone's **default dialer** package. The test is by package, not by notification style. | [code-android] `agents.notifications.models.NotificationItem.getNotificationClass`, `isPhoneCallNotification` |
| A notification is pushed only if it is **clearable**, or is a MessagingStyle foreground-service notification (plus the other filters of SCN 7.4). | [code-android] `agents.notifications.PhoneNotificationsPublishFilter.shouldPublishNotification` |
| The incoming-call and ongoing-call notifications of Android dialers are ongoing (not clearable) and are not MessagingStyle, so they are **filtered out**. The PC gets no key for them and therefore cannot address their Answer / Decline / Hang up buttons with `/notifications` operation 5. | [inferred] from the filter and from how dialers post call notifications; not verified on a phone |
| A **missed-call** notification is clearable and is pushed, with `notificationClass` 3 and its buttons in `notificationActions` (typically "call back" and "message", labels are the dialer's). | [inferred], same basis |
| The PC can press such a button with `/notifications` operation 5 and `actionIndex` (SCN 7.5). The button belongs to the dialer; a "call back" button normally makes the dialer place the call at once. This is the only relay path that can actually start a call without a touch on the phone, and only to the number that was missed. Reply 20 (an app came to the foreground), 0 or 7 as in SCN 7.5. | [inferred]; operation 5 was never captured (R has operations 2, 3, 4 only) |
| Operation 5 without `actionIndex` opens the notification's target on the phone (the dialer's call history) and dismisses it. | [code-android], SCN 7.5 |
| The protobuf pull path (`/notifications` resource, SCN 7.7) classifies by style instead: `notification_class` 3 when the template name contains `CallStyle`. It applies the same publish filter and has no actions. | [code-android] `agents.notifications.platform.NotificationResourceRequestHandler` |

What Windows does with class 3 **[code-windows]**: clicking such a notification navigates to its
own Calls page (W: `YourPhone.Notifications.Managed :: Utilities.NotificationsActionsHelper.TryNavigateToNodeUriAsync`,
URI `ms-phone:calling?deviceid=...`), and such notifications are left out of the notifications
badge once Calls is consented and set up (W: `Badging.NotificationsBadgeDataProvider.ShouldIncludeNotificationInBadgeCount`).
It does not try to answer calls through notification actions.

Whether any captured notification had `notificationClass` 3 was not examined: the JSON travels
inside strings, which the structure-only decoder does not open.

**[inferred]** A client that wants a "phone is ringing" indication without Bluetooth has no
source for it on the relay. The earliest signal is the missed-call notification (after the
ringing stopped) or the call log push (after the call ended).

---

## 9. What cannot work without Bluetooth

Stated briefly; none of this is in the relay protocol.

| Function | How Windows does it | Tag and pointer |
|---|---|---|
| Call audio on the PC (speaker, microphone) | Bluetooth Hands-Free Profile; the PC is the hands-free unit of the phone. | [code-windows] `Managers.HfpDeviceManager`, `Utilities.PhoneLineTransportDeviceFactory` (Windows `PhoneLineTransportDevice`) |
| Incoming-call alert on the PC, caller number, answer, decline | The Windows phone-line API on top of that Hands-Free connection. | [code-windows] `Managers.CallLineManager`, `Utilities.CallingToastNotificationHelper` |
| Placing a call from the PC that actually connects | `DialAsync` on the active phone line; needs consent, completed setup and a ready Hands-Free device. | [code-windows] `CallLineManager.DialWorkerAsync`; `Utilities.DirectDialProvider.UpdateCanDialAsync` |
| Hang up, hold, mute, keypad tones, moving the call between phone and PC | Same API. | [code-windows] `CallLineManager` |
| Pairing and registration for the above | Classic Bluetooth pairing plus registration of the phone as a phone-line transport device. | [code-windows] `HfpDeviceManager.RegisterAsync`, `ConnectAsync`; `Utilities.HfpRegistrar` |

LTW has no code for any of it: on the phone the Hands-Free audio gateway is the Android system's
Bluetooth stack, not the app **[code-android]** (no call control anywhere under `agents`, 8.1).

Works without Bluetooth: the call log (sections 2 to 6), opening the dialer with a number
(section 7), missed-call notifications and their buttons (8.2).

---

## 10. Smallest implementation

What a relay-only PC client has to do for (a) the recent-calls list, (b) keeping it current,
(c) starting a call to a number on the phone. All of it is code-derived; nothing here was
exercised on the wire.

### 10.1 (a) Receive the recent-calls list

1. `/connect/v1`: `configuration.CallLogs` true (with `SequencedContentSyncs` and
   `MessagingSync` true, as today), and `sequenceNumbers.call_logs` Int64: the stored number, or
   -1 when the local list is empty. Never send `call_logs` while `CallLogs` is false (2.2).
2. From the connect reply: if `permissions.call_logs` is false, the feature is unavailable until
   the user grants it; optionally send `/permission` with `permissionType` Int32 256, `silent`
   false (2.6), and on `result` 0 or 4 continue with step 3b.
3. Start the sync, either way:
   - a. automatically: with `call_logs` -1 and at least one call on the phone, the metadata
     message arrives by itself;
   - b. explicitly: send `/calling` with `contentType` `callLogs`, `contractVersion` 3.99,
     `correlationVector`, `isuserinitiated` (6.1). This works even without step 1, because the
     request switches the feature on. Its reply comes after the sync.
4. On a `/legacy/phonecontent` push with `contentType` `callLogs` **and** `metadata`:
   - delete local calls whose id is not in `callLogsIds`;
   - `want` = ids that are new, or whose stored last-updated value differs from the offered
     `callLogsLastUpdatedTimes` value;
   - remember `sequenceNumber` as pending;
   - answer on `/internal/response`: `result` Int32 0, `itemCount` Int32 `want.count`,
     `callLogsIds` Int64Array `want`, plus `contentType` `callLogs`, `contractVersion` 3.99 and
     the copied `correlationVector`;
   - if `want` is empty the sync is over: store the pending number now.
5. On each `callLogs` push **without** `metadata`: read the eight parallel arrays of 4.3, upsert
   each row by id (delete it instead when `actions[i]` is 2), answer `{result: 0}`. When the
   message has `sequenceNumber`, store it.
6. Show: newest `callLogsDate` first; the label from `callLogsType` (4.4); the name from the
   contacts sync by normalized number (`contacts.md` 8), the raw number otherwise, a "private
   number" label for `""`.

Do not wait for every requested id (3.3): a call deleted between the two steps never arrives.
The sync is complete when a batch carries `sequenceNumber`.

### 10.2 (b) Keep it current

- While connected nothing has to be sent. Incremental pushes (section 5) arrive after each
  finished call and after each change on the phone; step 5 above handles them.
- A push **with** `metadata` at any time restarts at step 4.
- On reconnect send the stored number; equal numbers mean no traffic.
- Persist per call: id, number, date, duration, type, read, account id, last-updated. Persist
  one Int64 for the sequence number, and only from a batch that was applied.
- If the connect reply's `call_logs` is lower than the stored number, drop the list and resync
  from -1 (section 5, edge cases).
- If pushes stop although calls were made, another computer has probably switched `CallLogs`
  off (2.1): send `/calling` to switch it back on and resync. A cheap policy is to send
  `/calling` whenever the user opens the calls view, which is what Windows does on refresh.
- Rows older than 30 days disappear from the phone's view; they are deleted by the next
  metadata round or by an action 2. Keep them locally only if a longer history is wanted, and
  then exempt them from the "not in `callLogsIds`" deletion.

### 10.3 (c) Start a call to a number

Send `/calling/dial` with `contentType` `dialOnPhone`, `phoneNumber` String, `contractVersion`
3.99, `correlationVector` (7.2). `result` 0 means the phone was asked to show its dialer with
that number. Tell the user to press call on the phone: the relay cannot do it, and cannot report
whether the call was made. Encode `#` as `%23`.

Calling back a missed caller without touching the phone is possible only through the
missed-call notification's own button (8.2), when notification sync is on and the dialer offers
one.

### 10.4 Swift notes

- The pattern is the one in `app/Sources/WinPhoneCore/Features/ContactSync.swift` (`apply`,
  `answerMetadata`) with a single table and a single top-level `sequenceNumber`;
  `AppCatalogSync.swift` is the closer single-table example.
- `ValueSet` already has the needed accessors: `int64s`, `strings`, `int32s`, `bools` (for
  `callLogsRead`), `int`.
- `ConnectExchange.configuration` currently sends `CallLogs` false, and
  `NotificationSync.declinedSyncTypes` contains `callLogs`. Both change together with adding
  `call_logs` to the sequence numbers.
- `itemCount` in the metadata answer must be `.int32`, `callLogsIds` must be `.int64Array`, also
  when empty.

---

## 11. Differences between the two code bases

| Topic | Android | Windows |
|---|---|---|
| `/calling/dial` | Handler registered and working. | Request class and route constant exist; nothing sends it. |
| `CallLogs` switch | One preference for the whole phone; any connect overwrites it; `/calling` sets it true. | Computed per device from the Calls consent. |
| `subcontentTypes`, `relatedCorrelationIds` in `/calling` | Not read. | Always sent. |
| `callLogsDuration` | Sent. | Stored; no view reads it. |
| `callLogsRead` | Sent. | Stored; the badge uses a local timestamp instead. |
| `callLogsPhoneAccountIds` | Sent. | Stored; never read. |
| `permissions.calls` | Always false. | Stored as "calls device permission". |
| Type 6 (blocked) | Sent like any other row. | Stored, hidden from recent calls, labelled as incoming. |
| Content batch on a PC without the calling API | Treats `result` 16 as "feature disabled", ends the sync. | Answers 16, stores nothing. |
| Requested id that vanished | Omitted silently. | Tracks the requested ids as pending and stores the sequence number only when none is left (W: `CallHistoryProcessor.ProcessItem`, `Complete`). A vanished id therefore leaves the number unstored and the next connect starts another sync. A client should store the number when `sequenceNumber` appears instead. |
| Empty call log | Sends a metadata message with `itemCount` 0. | Empties its table, answers `itemCount` 0. |

---

## 12. Open questions

1. **Nothing here was captured.** A capture with the Calls consent switched on in Phone Link
   would confirm `CallLogs` true, `call_logs` in both directions, the metadata message, the
   answer and at least one batch. A second capture after one phone call would confirm the
   incremental push and its timing.
2. **Does the phone really push call logs with no Bluetooth pairing at all?** The phone code has
   no Bluetooth condition and the Windows gate is a stored consent flag (2.5), so the answer
   should be yes. It was not observed, and the current Swift client declines the sync.
3. **The connect hang of 2.2 (hazard 1).** Derived from an untimed wait in the code. Whether a
   thread pool or a transport timeout rescues the connect request in practice is unknown. Avoid
   the combination rather than test it on a phone in use.
4. **`/calling/dial` on a current phone.** Whether the dialer appears when LTW is in the
   background, when the screen is off and when the phone is locked; whether Android's
   background-activity rules suppress it; what the user sees. The reply cannot tell.
5. **Syncs with nothing to send.** An incremental sync that finds no change, and a metadata
   answer with `itemCount` > 0 whose ids no longer exist, both leave the phone without a batch
   to build. The content provider then reports a load failure; whether the sync ends as failed,
   and how quickly, was not traced.
6. **More than 2 450 calls in 30 days.** The executor stops after 50 messages; the last batch
   with `sequenceNumber` would then never be sent. Not traced.
7. **`callLogsPhoneAccountIds` format** on the target phone (subscription id, ICCID or
   something else), and whether it can be joined with `subscriptions.ids` for dual-SIM display.
8. **`callLogsType` values outside 1 to 7** on vendor dialers, and what `callLogsPhoneNumbers`
   holds for withheld numbers on the target phone (empty string or a vendor marker).
9. **`callLogsRead`** for types other than missed, and whether reading a missed call on the
   phone reliably produces an update push (it depends on the dialer touching the row).
10. **Missed-call notification buttons** (8.2): which buttons the target phone's dialer offers,
    whether "call back" dials at once, and the reply code of operation 5 for it. Operation 5 has
    never been captured for any notification.
11. **Incoming-call notification filtering** (8.2) is concluded from the publish filter and from
    general dialer behaviour. A dialer that posts a clearable or MessagingStyle call
    notification would make ringing visible, and its buttons addressable, over the relay.
12. **`permissionType` 256** for the call log prompt is taken from both code bases but was not
    captured; the captured `/permission` requests were for other permissions.
13. **Scan rate limiting.** Whether the 1000 ms interval delays the first event or only spaces
    later ones, and therefore the real delay between the end of a call and the push.
