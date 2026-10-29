# Phone apps list: app name and app icon for a notification's package

Implementation-grade specification of one Phone Link feature, the phone apps list sync
(content type `phoneApps`), as far as a PC client needs it to show an app name and an app icon
next to each phone notification. The reader implements the PC side; the peer is an Android
phone running Link to Windows (LTW).

Revision 1, 2026-10-09.

Read first, not repeated here: `messages.md` sections 3 (sequence numbers, full versus
incremental sync), 4.1 to 4.4 (common keys, metadata round, action codes) and 5 (replies);
`photos.md` section 2; `session-clipboard-notifications.md` sections 2 (envelope, value set),
5.2 (DeviceResourceManager), 5.3 (publish), 7.3 (notification JSON) and 8 (`/connect/v1`).

Sources and how they are cited

| Tag | Meaning | Pointer form |
|---|---|---|
| **[code-android]** | Decompiled Link to Windows 1.26082.130.0 (jadx). `com.microsoft.mmx.agents` is abbreviated `agents`, `com.microsoft.appmanager` is `appmanager`. | `A: class.method` |
| **[code-windows]** | Decompiled Phone Link 1.26072.257.0. | `W: assembly :: class.method` |
| **[wire]** | Captured traffic, read for structure only. `P:` = `captures/vm-pairing-2026-10-09/flows.jsonl`, `R:` = `captures/vm-raw-2026-10-09/flows.jsonl`; the number is the record `seq`. | `P:450` |
| **[inferred]** | Deduced, not directly confirmed. Reasoning inline. | |

`X:` points at recovered proto sources under `protocol/recovered/android/`.

What the captures contain **[wire]**

| Exchange | Records |
|---|---|
| One complete first sync between Windows and the phone: connect, metadata message, PC answer, three content batches, one recent-apps message, all acknowledgements | P:409, 450, 464, 492, 508, 513, 528, 533, 546, 550, 555 |
| A second connect with matching sequence numbers (nothing pushed) | P:549, 557; R:147, 163; R:5128, 5136 |
| Nine incremental pushes that carry only `recentApps*` arrays | R:2211, 3054, 3060, 3203, 3209, 3379, 3474, 3493, 5468 |
| The other Windows client pulling the PLATFORM resource `/phoneapps` | P:73, 78 (`since=2`) and P:401, 484 (`since=-1`) |

Not on the wire in any capture: an incremental push with app rows (install, update, removal),
a partial answer to the metadata message (Windows asked for every id), a request on
`/applications`, `forceRefreshOfTypes`, a publish with tag 7. Those parts are code only.

No app name, package name, account or device name from the captures appears in this document.
Examples use placeholders such as `com.example.app`.

---

## 0. The model in twelve lines

1. The phone keeps a table of every app that has a launcher activity: a **random 63-bit id**,
   package name, label, version name and a last-updated time. That time is also the checksum.
2. The PC switches the feature on with `configuration.Exp006` in `/connect/v1` and states what
   it holds with `sequenceNumbers.phoneApps` and `sequenceNumbers.recentApps`.
3. The phone pushes on APP route `/legacy/phonecontent`, `contentType` `phoneApps`: a full sync
   (metadata message, then content batches) or an incremental sync (content only).
4. The metadata message lists **ids and checksums only**. No package name, no label.
5. The PC answers with the ids it wants (`phoneAppsIds`) and `itemCount`. `itemCount` 0 ends
   the sync with success and the phone treats the PC as up to date.
6. Content batches are parallel arrays. Icons are PNG, concatenated in one byte array
   (`content`) with a lengths array (`iconSizes`).
7. A content batch always contains the icon of every app in it. There is no way to get names
   without icons, and no way to ask by package name.
8. The phone renders and PNG-encodes **all requested icons before it sends the first batch**.
9. `recentApps` is a second data set (the phone's recent task list) that travels in the same
   content type. A client that only wants icons ignores it.
10. App installs, updates and removals arrive as incremental pushes with an `actions` array.
11. A notification already carries the app label (`appName` in its JSON). Only the icon needs
    this sync.
12. Apps without a launcher activity never appear here. Windows shows a placeholder for them.

```
PC                                                          Phone
 |-- APP /connect/v1 {configuration.Exp006, sequenceNumbers} ->|
 |<- APP /legacy/phonecontent phoneApps {metadata:1, ids} -----|   full sync only
 |-- /internal/response {result, itemCount, phoneAppsIds} ---->|
 |<- /internal/response (connect reply: phoneApps, recentApps)-|
 |<- APP /legacy/phonecontent phoneApps {arrays, content} -----|   1..n batches
 |-- /internal/response {result:0} --------------------------->|   after each
 |<- APP /legacy/phonecontent phoneApps {recentApps* arrays} --|   only if recent ids were requested
 |-- /internal/response {result:0} --------------------------->|
```

---

## 1. Enablement

### 1.1 `/connect/v1` configuration keys

| Key | Type | Windows sends | Phone use |
|---|---|---|---|
| `Exp006` | Bool | always `true` **[code-windows]** W: YourPhone.ScreenMirroring.Managed :: Sync.PhoneAppsEstablishConnectionPayload.LoadConfiguration; **[wire]** P:409, 549 | The switch. Stored as preference `RemotingPhoneScreenAndAppsSyncCoordinatorSupported` (file `MmxAgentsPrefs`), default `false` when the key is missing. `true` selects the sequenced sync described here; `false` selects an older ETag protocol (section 10.3) and stops all pushes of this spec. **[code-android]** A: agents.ConnectionRequestHandler.processPartnerConfiguration; A: agents.phoneapps.DefaultPhoneAppsController.updateConfiguration; A: agents.DeviceData.isRemotingPhoneScreenAndAppsSyncCoordinatorEnabledByPc |
| `RecentApps` | Bool | `true` when the stored phone capabilities have the recent-apps bits, else `false` **[code-windows]** same method; W: Utilities.RemotingFeatureUtils.IsRecentAppsSupported; **[wire]** false in P:409, true in P:549 | **Not read.** The string does not occur in the Android sources. Recent apps are sent whenever the phone supports them: P:409 sent `false` and the phone still listed recent apps in P:450. **[code-android]** (absence) + **[wire]** |
| `AppHandoff` | Bool | feature dependent; false then true in P:409, 549 | Not read by the phone apps code. Out of scope. |
| `SequencedContentSyncs` | Bool | `true` | Required: the phone reads `sequenceNumbers` only when this and `MessagingSync` are both true (A: agents.DeviceData.doesPcSupportSequencedSyncs). See `messages.md` 2.1. |
| `MessagingSync` | Bool | `true` | Required, same reason. |
| `SyncSkipMetadataForAuto` | Bool | `false` **[wire]** P:409 | Keep `false`. With `true` the phone skips the metadata round and a PC number of -1 produces a content-only push of **every app with its icon**, with no chance to select (section 1.6). A: agents.sync.SyncSettings.preferIncrementalSync |

Two phone-side facts an implementer must know **[code-android]**:

- `Exp006` and the "PC supports phone apps" flag are **preferences of the phone, not of one
  PC**. The last connect request wins. Consequence **[inferred]**: a client that connects with
  a `configuration` object lacking `Exp006` switches the sequenced sync off for a Windows PC
  linked to the same phone until that PC connects again.
- Whenever the value of `Exp006` **changes**, the phone drops its sync subscriptions, clears
  the app table and refills it. Every app gets a **new random id** and a new checksum
  (A: DefaultPhoneAppsController.updateConfiguration, ensureTriggers, updateTriggers;
  A: agents.PhoneAppsWriter.ensurePhoneAppsTableUpToDate; A: agents.PhoneAppsWriterHelper.makeAppEntity, generateRandomId).
  Any id cache on the PC is void after that. Always send `Exp006: true`.

### 1.2 Sequence-number keys

In the `sequenceNumbers` object of `/connect/v1`. Both must be Int64; any other type is treated
as absent (A: DefaultPhoneAppsController.setTargetState tests `instanceof Long`).

| Key | Covers | Item id | Item checksum |
|---|---|---|---|
| `phoneApps` | Apps with a launcher activity | Random positive 63-bit number made on the phone when the row is created | Row's last-updated time, milliseconds since the Unix epoch |
| `recentApps` | The phone's recent task list. Only on phones that support the feature (section 7). | Random positive 63-bit number, separate id space | Row's last-updated time |

A: agents.sync.ContentType (`phoneApps`, `recentApps`); A: agents.phoneapps.sync.PhoneAppsMediaItem.getChecksum;
A: agents.recentapps.RecentAppsMediaItem.getChecksum **[code-android]**.
**[wire]** P:450: all ids distinct, positive, at most 63 bits, listed in ascending order; all
checksums 13-digit numbers and, right after pairing, identical for every app.

What Windows sends **[code-windows]** PhoneAppsEstablishConnectionPayload.Load: `phoneApps` =
its stored "current" number or -1, only when the phone's `registeredPermissionTypes` has bit 8
(W: YourPhone.AppCore.Managed :: DeviceCapabilities.PhoneApps); `recentApps` likewise, only when
recent apps are supported. **[wire]** P:409 `phoneApps` -1 and no `recentApps`; P:549 `phoneApps`
2, `recentApps` 3; R:147 and R:5128 both keys present.

Sending `phoneApps` as Int64 (any value) also sets the phone preference `phoneAppsPCSupported`
to true. It is never set back to false. Without it the phone ignores package
install and removal broadcasts and only catches up at the next connect (section 8)
**[code-android]** setTargetState; A: agents.PhoneAppsReceiver.PhoneAppsReceiverTask.doInBackground.

### 1.3 `forceRefreshOfTypes`

Optional top-level Object in `/connect/v1`: `contentTypes` StringArray and
`relatedCorrelationIds` StringArray, parallel (A: ConnectionRequestHandler.tryProcessRequest).
The phone acts on it only for the entry `phoneApps` (A: ConnectionRequestHandler.forceFullSyncs).

**With `Exp006` true it does nothing useful**: the handler sets `phoneAppsPCSupported` and
returns (A: DefaultPhoneAppsController.forceFullSync) **[code-android]**. It starts a sync only
in the old ETag mode. Windows never writes the key: the string does not occur in the Windows
sources **[code-windows]** (absence). Do not use it. Section 5.4 lists what forces a full sync.

### 1.4 Phone-side conditions

All **[code-android]**.

| Condition | Where | Effect when false |
|---|---|---|
| Permission type `PHONE_APPS` (value 4, legacy flag 8) | A: agents.permissions.PermissionsHelper.hasPermissionsForContentType | Never false: the check returns true without asking Android for anything. |
| `Exp006` true | A: DefaultPhoneAppsController.setTargetState, updateTriggers | No sequence numbers in the connect reply, no push, no change triggers. |
| `SequencedContentSyncs` and `MessagingSync` true, `sequenceNumbers` object present | A: ConnectionRequestHandler.tryProcessRequest | `sequenceNumbers` not read. If both flags are true and the object is missing the connect request is abandoned. |
| Sync allowed (not all-features-off, metered rule, two-phone mode, secondary profile) | A: agents.sync.SyncSequence.sendMessageAsync | Pushes are not sent. |
| App has an activity with action `android.intent.action.MAIN` and category `android.intent.category.LAUNCHER` | A: agents.phoneapps.PhoneAppsSource.getAllActivityInfo | The app is not in the list at all. One row per package. With the `extgeneric` feature module installed the LTW package itself and `com.android.stk` are also left out. |
| Change-driven pushes: the PC is an active remote app of client type `PL` **and** the phone holds a non-empty sequence state for it | A: agents.sync.SyncCoordinatorBase.onChangeDetected; A: agents.phoneapps.sync.PhoneAppsSyncCoordinator.requiresContentSessionForReactiveSync | No push on change. The state becomes non-empty when the PC sends a number in `/connect/v1` or when any sync to it finishes with result 0. |

### 1.5 What the connect reply says

A: ConnectionRequestHandler.setCoordinatorStates, createDeviceCapabilityBlob;
A: DefaultPhoneAppsController.setTargetState **[code-android]**. Read by
W: PhoneAppsEstablishConnectionPayload.Apply **[code-windows]**. Shape **[wire]** P:459, 557; R:163.

| Key | Type | Meaning |
|---|---|---|
| `phoneApps` (top level) | Int64 | The phone's current sequence number. Present whenever `Exp006` is true, whether or not the PC sent the key. Observed 2. Windows stores it as the *expected* number (missing key stored as -1). |
| `recentApps` (top level) | Int64 | Same for recent apps. Present only on phones that support recent apps. Observed 3, also in the reply to P:409, which had not sent the key. Its presence is the PC's signal that it must send `recentApps` in later connects (section 1.6). |
| `capabilities.registeredPermissionTypes` | Int32 | Bit 8 = phone apps feature exists. Always set by this build (A: agents.devicesupport.SupportedFeaturesProvider). Windows sends no phone-apps numbers without it. |
| `capabilities.remoting` | Int32 | `RemotingCapability` mask. Bit 2 `RecentApps` and bit 0x800 `RecentAppsMinimumDBVersion` together mean recent apps are supported (W: RemotingFeatureUtils.IsRecentAppsSupported). Observed 94207. Not needed for icons. |

There is no `permissions` entry for this feature. The reply does not carry app data. The
reply waits for the phone's first scan of the app table (A: agents.sync.DataSourceBase.getSequenceNumber).

### 1.6 Which sync the connect starts

A: SyncCoordinatorBase.setTargetState, determineSyncType **[code-android]**. The phone builds a
map from the PC's Int64 values for `phoneApps` and (if the phone supports it) `recentApps`,
then decides. `skip` is `SyncSkipMetadataForAuto`. "Tracked types" are `phoneApps`, plus
`recentApps` on phones that support it.

| Situation | Result |
|---|---|
| PC sent neither key, `skip` false | **Full sync** (section 2). **[wire]** matches the live observation: a connect without `phoneApps` still gets the metadata message. |
| For some tracked type the PC value is absent or -1 and the phone's number is above 0, `skip` false | **Full sync** of both types. **[wire]** P:409 (`phoneApps` -1) gave P:450. |
| Same, `skip` true | Incremental from -1: every current row, with icons, no metadata round. Avoid. |
| PC value -1 and phone number 0 or less for a type | That type is ignored. |
| Every tracked type equal | Nothing. **[wire]** P:549 to 557, R:147 to 163. |
| Otherwise | **Incremental sync** since the PC's numbers (section 8). |

Consequence: on a phone that reports `recentApps`, a PC that sends `phoneApps` but **omits
`recentApps`** gets a full sync at every connect. Send both.

After any sync that ends with result 0 the phone records the numbers of that sync as the PC's
state (A: SyncCoordinatorBase.lambda$initiateSync$4; A: agents.phoneapps.sync.PhoneAppsMessageBuilder.getSequenceNumbers).
That includes a full sync the PC ended with `itemCount` 0.

Syncs of this coordinator run one at a time; a request that arrives during a sync is merged
with other waiting ones, a full request winning over an automatic one
(A: SyncCoordinatorBase.mergeSyncDetails, inner subscriber `onNext`).

---

## 2. The metadata message (phone to PC)

APP request on `/legacy/phonecontent`, headers `_requestId` and `_route` only **[wire]** P:450
(2710 bytes for 115 apps). Built by A: agents.MessageBuilderBase.getMetadata and
A: PhoneAppsMessageBuilder.getMetadataInternalIfSyncCoordinator, getMetadataItemCount **[code-android]**.
Read by W: YourPhone.ScreenMirroring.Managed :: Processors.PhoneAppsProcessor (constructor,
HandleMetadataForSyncCoordinator, HandleMetadataForRecentApps) **[code-windows]**.

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `phoneApps` |
| `metadata` | Int32 | 1. Marks the metadata message. |
| `itemCount` | Int32 | Number of app ids **plus** number of recent-app ids. Observed 116 = 115 + 1. |
| `phoneAppsIds` | Int64Array | Every app id. Ascending order **[wire]**; the order carries no meaning. |
| `checksums` | Int64Array | **Parallel with `phoneAppsIds`.** Last-updated time of each row. |
| `sequenceNumber` | Int64 | The phone's `phoneApps` number for this list. Observed 2. |
| `recentAppsIds` | Int64Array | Recent-app ids. Only on phones that support recent apps. |
| `recentAppsChecksums` | Int64Array | **Parallel with `recentAppsIds`.** |
| `recentAppsSequenceNumber` | Int64 | The phone's `recentApps` number. Observed 3. |
| `phoneAppsSettings` | Object | `phoneAppsCapabilities` Int32: the same mask as `capabilities.remoting`. |
| `contractVersion` | Double | 3.99 |
| `correlationVector` | String | Same value in the metadata message and every content message of this sync **[wire]** (six messages, one value). |
| `installationId`, `displayName` | String | Phone identity. |
| `dedupeID` | String | `""` |
| `retryCount` | Int32 | 0 |
| device status keys | various | `batteryPercent` and friends, as on every phone push. |

There is no `incremental` key. There are no package names, labels, versions or icons.

If the phone has neither apps nor recent apps (`itemCount` 0) no message is sent and the sync
ends with success (A: agents.sync.SyncSequence.loadMetadata).

What Windows does with it **[code-windows]**: `PhoneApps.Synchronize(ids, checksums)` deletes
local rows whose id is not listed and returns the ids that are new or whose checksum differs
(W: YourPhone.Utilities :: Extensions.IUpdatableTableExtensions.SynchronizeWithData). The list
is therefore also the authoritative "these are all the apps" statement.

---

## 3. The PC's answer to the metadata message

Envelope: route `/internal/response`, headers `_originalRequestId`, `result` (`"0"`),
`_rejectionVersion` (`"1"`) **[wire]** P:464 (1250 bytes).

Every key the phone reads **[code-android]** A: SyncSequence.handleSendResult, handleSuccessfulResponse;
A: PhoneAppsMessageBuilder.getRequestedItemCount, getMediaItemMessagesIfSyncCoordinator:

| Key | Exact type | Required | How the phone uses it |
|---|---|---|---|
| `result` | Int32 | Optional here (default 0), but send it. A value of another type throws and fails the sync. | 0 continues. 19 ends all user sessions with this PC. 16 or 17 end the sync as "disabled" or "device not resolved". Anything else fails the sync; the PC's recorded state is not updated. |
| `itemCount` | Int32 | Required to receive content. Absent counts as 0. Another type throws. | Tested only against 0. Any positive value makes the phone build content from the id arrays; the number itself is not compared with the array lengths. |
| `phoneAppsIds` | Int64Array | Optional | The app rows to send, **in this order**. Ids the phone no longer has are skipped silently. Another type throws and fails the sync. |
| `recentAppsIds` | Int64Array | Optional | The recent-app rows to send. If the key is present and at least one id exists, one extra message with `recentApps*` arrays follows the app batches (section 4.4). |
| `phoneAppsETag` | any | **Must be absent** | Left over from the old protocol. If present its text is parsed as a number and, when it is not 0, the phone acts as if `itemCount` were 1. Text that is not a number throws. |

Keys Windows also sends and the phone does not read **[code-windows]** W: PhoneAppsProcessor.AssembleResponseMetadata;
**[wire]** P:464: `contentType` String `phoneApps`, `contractVersion` Double 3.99,
`correlationVector` String (copied from the metadata message). Windows sets `itemCount` to the
number of app ids plus the number of recent-app ids it requests and adds `recentAppsIds` only
when recent apps are supported. In P:464 it asked for all 115 apps and the one recent app,
`itemCount` 116.

Effect of `itemCount` 0 (or absent) **[code-android]**:

- The sync ends at once with success. No content is built, no icon is rendered.
- The phone records its current `phoneApps` and `recentApps` numbers as this PC's state.
- From then on the PC counts as having a content session: later changes on the phone arrive as
  **incremental pushes** (sections 7 and 8). **[wire]** matches the live observation of
  `recentApps*` pushes after such an answer.
- The app list is **not** offered again by itself. To get it later the PC must cause a new full
  sync (section 5.4).

Do not send `itemCount` above 0 with no usable id: the phone then has no content to send and
the sync fails with an internal load error (A: agents.sync.AppServiceMessageToOutgoingMessageAdapter.getPayloadAsKvp) **[code-android]**.

Windows answers before it processes with result 13, 1, 19 or 3 in some states
(`session-clipboard-notifications.md` 7.2); not relevant for a custom client.

---

## 4. Content batches (phone to PC)

Each is an APP request on `/legacy/phonecontent` with a fresh `_requestId` and the sync's
`correlationVector`. The phone waits for the PC's reply before it sends the next one.

### 4.1 App batch

A: PhoneAppsMessageBuilder.buildAppServiceMessages, getMediaMapFromPhoneApps **[code-android]**;
read by W: PhoneAppsProcessor.ProcessPhoneApps **[code-windows]**; shape **[wire]** P:492, 513, 533.

All arrays are **parallel**: same length `itemCount`, index i describes app i.

| Key | Type | Meaning |
|---|---|---|
| `contentType` | String | `phoneApps` |
| `itemCount` | Int32 | Number of apps in **this batch**. |
| `phoneAppsIds` | Int64Array | App id. Identity for updates and deletes. |
| `appPackageNames` | StringArray | Android package name, for example `com.example.app`. The join key to a notification's `packageName`. |
| `appNames` | StringArray | Launcher label in the phone's current locale; tab, CR and LF replaced by a space (A: agents.util.ConversionUtils.regularName). |
| `appVersions` | StringArray | `versionName`. `""` when the app has none. |
| `phoneAppsLastUpdatedTimes` | Int64Array | Row's last-updated time, ms since the Unix epoch. |
| `checksums` | Int64Array | The same values as `phoneAppsLastUpdatedTimes` **[wire]** and as the metadata message for the same id **[wire]**. |
| `phoneAppsFavorites` | Int64Array | Favourite rank stored on the phone. Observed 0 for every app. Windows does not read the key. |
| `content` | UInt8Array | All icons of the batch, concatenated in item order, no separators. |
| `iconSizes` | Int64Array | Byte length of each icon inside `content`. 0 means no icon for that item. |
| `actions` | Int32Array | **Incremental batches only.** -1 none, 0 create, 1 update, 2 delete (`messages.md` 4.4). Absent in a full sync; Windows then upserts every row. |
| `sequenceNumber` | Int64 | **Only in the last app batch** of the sync. The phone's `phoneApps` number the PC now holds. |
| `incremental` | Int32 | 1, incremental batches only. |
| `phoneAppsSettings` | Object | `phoneAppsCapabilities` Int32. |
| `contractVersion`, `correlationVector`, `installationId`, `displayName`, `dedupeID`, `retryCount`, device status keys | | As in section 2. |

There is no `metadata` key and no per-item icon format or pixel-size field.

A deleted app (action 2) has **only its id**: the strings are `""`,
`phoneAppsLastUpdatedTimes` -1, `checksums` 0, `phoneAppsFavorites` -1, `iconSizes` 0
**[code-android]**. The PC must keep id to package to resolve a delete.

Windows reads strictly **[code-windows]**: `itemCount` as Int32, the id, time, checksum and size
arrays as Int64Array, names as StringArray, `content` as UInt8Array, `actions` as Int32Array,
`sequenceNumber` as Int64.

### 4.2 Batching

A: PhoneAppsMessageBuilder.getBatchesOfPhoneApps; A: PhoneAppsMediaItem.getTotalPhoneAppSizeInBytes **[code-android]**.

- The phone estimates each app as `27 + len(package) + len(label) + len(version) + icon bytes`
  (string lengths in UTF-16 units) and closes a batch before the running sum reaches
  **716 800** (`MAX_BATCH_SIZE_IN_BYTES`). Deleted rows count 0.
- **[wire]** 115 apps came as three batches of 39, 43 and 33 apps with estimates of 715 761,
  713 409 and 539 056, in exactly the order of the PC's `phoneAppsIds`, none missing. (The
  decompiled loop reads as if the app that overflows a batch were dropped. The capture shows it
  opens the next batch.)
- A single app whose estimate alone reaches the limit travels in a batch of its own.
- At most 50 messages per sync, metadata included (A: agents.sync.SyncExecutor.executeAsync).
  That is about 34 MB of icons and not a practical limit.
- **All batches are built before the first is sent**: one call loads the requested rows,
  renders and PNG-encodes every icon, and only then splits the result
  (A: PhoneAppsMessageBuilder.getMediaItemMessagesIfSyncCoordinator, hydratePhoneAppsWithIcons).

If a requested row exists in the table but the app has no launcher activity any more, icon
loading throws and the **whole sync fails**, not only that app
(A: PhoneAppsMessageBuilder.getAppIconAndCompressIfNeeded) **[code-android]**.

### 4.3 The PC's reply to a content message

Value set `{result: Int32 0}`, headers `_originalRequestId`, `result: 0`, `_rejectionVersion: 1`
**[wire]** P:508, 528, 546, 555 (14 bytes each); R:2213. On an exception Windows answers
`result` 1 and `message` String (W: PhoneAppsProcessor.ProcessItemForSyncCoordinator).

Always include `result`: for a content message the phone's default for a missing key is 24,
which it logs as unexpected and does not treat as success (`messages.md` section 5). A failed
sync leaves the PC's recorded numbers unchanged, so the same changes are sent again. Apply
batches idempotently: upsert by id, delete by id.

### 4.4 Recent-apps message

Sent after the app batches when the PC's answer contained `recentAppsIds` with at least one
existing id (full sync), or when the recent list changed (incremental, section 7).
A: PhoneAppsMessageBuilder.getMediaMapFromRecentApps **[code-android]**; W: PhoneAppsProcessor.ProcessRecentApps
**[code-windows]**; shape **[wire]** P:550 (full, 1185 bytes), R:2211 (incremental).

| Key | Type | Meaning |
|---|---|---|
| `recentAppsItemCount` | Int32 | Number of entries. |
| `recentAppsIds` | Int64Array | Recent-app id (not an app id). |
| `recentAppsPackageNames` | StringArray | Package of the task. |
| `recentAppsChecksums` | Int64Array | Last-updated time of the entry. |
| `recentAppsDescriptions` | StringArray | Document or page title when the app reports one, else `""`. |
| `recentAppsIntentActions` | StringArray | Intent action to relaunch. Length 26 in every observed entry, consistent with `android.intent.action.MAIN` **[inferred]**. |
| `recentAppsTaskIds` | Int64Array | Android task id. |
| `recentAppsRanks` | Int32Array | Position in the recent list. Observed 1 for a single entry. |
| `recentAppsWindowsDocumentUris`, `recentAppsWebDocumentUris` | StringArray | App hand-off links, `""` when none. Present on phones that support recent apps. |
| `recentAppsActions` | Int32Array | Incremental only. |
| `recentAppsSequenceNumber` | Int64 | The phone's `recentApps` number. |
| `phoneAppsSettings`, common keys | | As above. `incremental` Int32 1 when incremental. |

All `recentApps*` arrays are parallel. The message has **no `itemCount` key** and no
`phoneApps*` key. Reply as in 4.3.

---

## 5. Icons

### 5.1 Format

**[code-android]** A: PhoneAppsMessageBuilder.getBitmapFromDrawable, getAppIconAndCompressIfNeeded, getAppIconGivenBitmap;
A: appmanager.utils.BitmapExtensionsKt.compressToTargetSize. **[wire]** all 115 icons of P:492
to 533 checked by signature and header.

| Property | Value |
|---|---|
| Container | **PNG**, always. `Bitmap.CompressFormat.PNG`; 115 of 115 icons start with the PNG signature. No JPEG, no WebP. |
| Pixels | 8 bits per channel, RGBA with alpha, not interlaced (PNG colour type 6 in all 115 headers **[wire]**; bitmap config `ARGB_8888` **[code-android]**). |
| Size | The launcher icon drawable's **intrinsic size on that phone**, square in every observed case. Not normalised by the phone. |
| Observed sizes | 202x202 for 97 icons, 135x135 for 12, and one each of 180, 206, 270, 281, 304 and 423 pixels square. |
| Why those numbers **[inferred]** | 202 is 72 dp and 135 is 48 dp at the phone's density of about 2.81: adaptive icons report 72 dp, plain bitmap icons 48 dp. Other phones give other sizes (144 and 96 at density 2, 216 and 144 at 3, 288 and 192 at 4). |
| Upper bound | If the uncompressed bitmap (`width * height * 4`) exceeds 716 800 minus the row's text estimate, it is scaled down to fit. That is about **423x423**; the one 423x423 icon in the capture is such a case. |
| Missing icon | `iconSizes[i]` 0 and no bytes. Happens when scaling fails. Windows then stores no icon. |
| Shape | The drawable as Android draws it into an empty bitmap. Adaptive icons should come with the system icon mask applied and transparent pixels outside it **[inferred]**; the capture's icons were not viewed. Windows shows the icon with a square crop (W: YourPhone.Notifications.Managed :: Toasts.PhoneNotificationsToastHelper, `ShapeCrop` `square`). |

Typical byte size **[wire]** (115 icons): total 1 960 226 bytes; mean 17 045; median 13 717;
90th percentile 31 908; smallest 3 340; largest 58 891.

### 5.2 Slicing

One concatenated byte array per batch plus a lengths array, not one value per item.

```
offset = 0
for i in 0 ..< itemCount:
    n = iconSizes[i]                      // Int64
    icon[i] = content[offset ..< offset + n]   // empty when n == 0
    offset += n
// sum(iconSizes) == content.count          [wire] exact in all three batches
```

Swift: `ValueSet.split(_:sizes:)` in `app/Sources/WinPhoneCore/Messaging/ValueSet.swift` does
this and returns nil when the sizes do not add up; `content` arrives as `.bytes`.

Windows stores the bytes unchanged as a blob, sniffs the image type from the stream for the
file extension and writes `app_icon_<package><version><ext>` into a temporary `app_icons`
folder (W: PhoneNotificationsToastHelper.GetAppIconImagePathAsync) **[code-windows]**. Keying the
cache file by package and version is a sound choice for a client too.

### 5.3 What can and cannot be selected

| Question | Answer | Basis |
|---|---|---|
| Names and packages without icons? | **No.** The metadata message has ids and checksums only; every content batch renders the icon of every non-deleted app in it. No flag turns that off. | **[code-android]** getMetadataInternalIfSyncCoordinator, hydratePhoneAppsWithIcons |
| Icons for some apps only? | **Yes, by id**: the phone sends exactly the rows named in the answer's `phoneAppsIds`. Not captured (Windows asked for all). | **[code-android]** getMediaItemMessagesIfSyncCoordinator; A: agents.PhoneAppsReader.getPhoneAppsByIds |
| Icons for given **package names**? | **Not on first contact.** Ids are random and nothing maps an id to a package until that row has been received once. After one full pass the PC knows id to package and can re-request any subset by id. | **[code-android]** PhoneAppsWriterHelper.generateRandomId; **[wire]** P:450 has no strings |
| A smaller or different icon size? | No parameter exists. | **[code-android]** |
| Is the app label needed from here? | No. Each notification's JSON has `appName` (`session-clipboard-notifications.md` 7.3) and Windows uses that as the toast title; it takes only the icon from this sync. | **[code-windows]** PhoneNotificationsToastHelper (toast title from `appName`, logo from `GetAppIconImagePathAsync`) |

Windows lookup for a notification **[code-windows]** GetAppIconImagePathAsync: package
`com.microsoft.appmanager` or `com.microsoft.appmanager.dev` gets a built-in asset; otherwise
`PhoneAppsManager.GetApp(packageName)` and its icon blob; otherwise a placeholder bell. A
client needs the same fallback, because apps without a launcher activity (many system
components that post notifications) are never in the list.

### 5.4 Requesting icons later

There is no "give me these icons" request. Icons arrive only inside a sync, so the PC must
make the phone start one. Three ways:

**(a) Next `/connect/v1` with `phoneApps` absent or -1** (and `SyncSkipMetadataForAuto` false).
The phone starts a full sync: metadata message, then the PC names ids. **[code-android]**
section 1.6; **[wire]** P:409 to 450 and the live observation. Windows repeats `/connect/v1`
at most every 60 s (`session-clipboard-notifications.md` section 8); whether the phone limits
repeats was not checked.

**(b) APP request on route `/applications`** **[code-android]**, never captured.
Registered for A: agents.PhoneAppsRequestHandler; logic in A: agents.DefaultPhoneAppsRequestProcessor.tryProcessRequest;
gate in A: agents.ScenarioRequestHandlerBase.handleAsync.

| Key | Type | Required | Value |
|---|---|---|---|
| `contentType` | String | yes (a missing key throws) | `phoneApps`. Any other value gets `result` 2. |
| `correlationVector` | String | yes (a missing key throws) | Becomes the `correlationVector` of the pushes it causes. |
| `contractVersion` | Double | yes (unboxed without a null check) | 3.99; integer part must be 3, else `result` 3. |
| `isuserinitiated` | Bool | no | Raises push priority. |
| `configuration` | Object | no | If present it is applied like the connect configuration: **include `Exp006: true`**, or the missing key reads as false and resets the feature (section 1.1). Simplest: omit the object. |
| `subcontentType`, `phoneAppsMessage` | | no | Old protocol only. Do not send. |

With `Exp006` on, the phone sets `phoneAppsPCSupported`, starts a **forced full sync to the
sender** regardless of sequence numbers, and answers the `/applications` request only when
that sync has finished: `result` Int32 0 done, 7 permission, 8 metered sync off, 10 cancelled,
11 coalesced with another sync, 21 two-phone mode, 1 other failure
(A: agents.AppServiceProviderHelpers.createResponseFromPayloadProcessingResult). The list still
arrives as pushes on `/legacy/phonecontent`, which the PC must answer first.

Windows has a request class for this route (W: YourPhone.ScreenMirroring.Managed :: Communication.PhoneAppsRequest,
route constant `RemotingConstants.PhoneAppsRoute`), but it writes `contentType`
`phoneAppsContent` and `subContentType` UInt32, which this Android build answers with `result`
2 **[code-windows]** + **[code-android]**. So (b) rests on the Android code alone; see open
question 1.

**(c) Do nothing and wait for changes.** An incremental push carries the row and icon of every
app that was installed or updated since the PC's number (section 8). This never delivers apps
that do not change.

---

## 6. Cost and timing

### 6.1 Measured: the first sync in the pairing capture **[wire]**

Times are capture-proxy timestamps. The phone had 115 launcher apps.

| Step | Record | Time after the PC's answer | Payload bytes |
|---|---|---|---|
| `/connect/v1` | P:409 | -1.66 s | 1 917 |
| Metadata message, 115 app ids + 1 recent id | P:450 | -0.35 s | 2 710 |
| PC answer, all 116 ids | P:464 | 0 | 1 250 |
| Batch 1, 39 apps | P:492 | 8.64 s | 717 051 |
| PC acknowledgement | P:508 | 9.12 s | 14 |
| Batch 2, 43 apps | P:513 | 10.37 s | 714 728 |
| PC acknowledgement | P:528 | 10.93 s | 14 |
| Batch 3, 33 apps, carries `sequenceNumber` | P:533 | **11.73 s** | 540 318 |
| PC acknowledgement | P:546 | 12.09 s | 14 |
| Recent-apps message, 1 entry | P:550 | 12.41 s | 1 185 |
| PC acknowledgement, sync complete | P:555 | 12.61 s | 14 |

Totals: **115 app ids** in the metadata message; **3 content batches, 1 972 097 bytes**
(1 960 226 of them icon bytes), plus one 1 185-byte recent-apps message; **11.7 s from the PC's
answer to the last app batch**, 12.6 s to the end of the sync. Each message was one DCG
fragment.

Where the time went:

- 8.6 s passed before the first batch. That is the phone loading, drawing and PNG-encoding 115
  icons, plus the upload of the first 717 kB. Upper bound for building: about 75 ms per icon.
- The later batches were already built: 1.25 s and 0.80 s after the previous acknowledgement,
  which is serialisation and upload of about 700 kB each.
- The figure is pessimistic: in the same seconds the phone was also answering the other
  Windows client's PLATFORM pull of the same 115 icons (P:401 to 484, one response of
  1 971 022 bytes after 9.75 s) and sending a 1.67 MB photo batch (P:472).

Evidence that other traffic waits **[wire]**: Windows answered the contacts metadata message
0.13 s after the phone-apps one (P:467), yet the small contacts batch (88 820 bytes, P:494)
arrived 16 ms after phone-apps batch 1, 8.5 s later. A second `/connect/v1` sent right after
the last batch was answered in 0.47 s (P:549, 557).

Why **[inferred]** from code: the content of a push is produced when the transport asks for the
message bytes (A: AppServiceMessageToOutgoingMessageAdapter.getPayloadBuffer calling
A: SyncSequence content provider), and that call builds every batch of the sync. The DCG
sender is one stop-and-wait loop per target (`relay-transport.md`, fragment sender). A large
phone-apps answer therefore occupies the phone's send path to this PC for the whole build and
then for about a second per 700 kB batch.

### 6.2 Cost model

| Item | Cost | Basis |
|---|---|---|
| Metadata round, PC answers `itemCount` 0 | about 2.7 kB in, under 0.1 kB out, no icon work | **[wire]** P:450; live observation |
| Per requested app | about 17 kB (median 14 kB) and at most about 75 ms of phone time | **[wire]** 6.1 |
| One batch | up to about 40 apps or 700 kB | **[wire]** |
| All apps of the captured phone | 2.0 MB, 3 batches, about 12 s | **[wire]** |
| Connect with matching numbers | nothing | **[wire]** P:549 |
| PLATFORM `/phoneapps?since=-1` | everything in one 2.0 MB response, about 10 s, no selection | **[wire]** P:401, 484 |

### 6.3 How to keep it small

1. **Take the name from the notification** (`appName`). That costs nothing and covers apps
   that are not in this list.
2. **Never request what is cached.** Keep (id, checksum, package, label, version, PNG) on disk
   per phone. On a metadata message request only ids that are missing or whose checksum
   differs; delete cached ids that are not listed. This is what Windows does.
3. **Send the stored numbers** (`phoneApps`, `recentApps`) in `/connect/v1` once the cache
   covers the last id list. Then a connect costs nothing and changes come as small incremental
   pushes.
4. **Bound each request.** Requesting only the packages that have posted notifications is not
   possible directly, because ids cannot be mapped to packages in advance (5.3). What a client
   can do is cap the number of ids per sync, for example 10 to 25 (about 170 to 430 kB, one
   batch, roughly 1 to 2 s of phone time by the bound above), and fetch the rest in later
   syncs (5.4 a or b). The list is in random-id order, so there is no way to fetch "important
   apps first"; expect a given package after half the passes on average. **[inferred]**; the
   partial answer is code only.
5. **Or pay once at a quiet moment.** One full request right after pairing, as Windows does,
   costs the 12 s above once per phone. After that only deltas flow.
6. **Do not pull PLATFORM `/phoneapps?since=-1`** and do not set `SyncSkipMetadataForAuto`:
   both deliver every icon without selection.
7. **Keep `Exp006` true and constant.** A flip regenerates every id and voids the cache (1.1).

Events that resend everything without being asked **[code-android]**: a change of the phone's
primary locale (every label is reloaded and every row gets a new checksum,
A: PhoneAppsWriterHelper.keepPhoneAppsTableInSyncWithDevice, fullSyncWithDevice) and, on
Samsung builds, a change of the icon theme (A: agents.phoneapps.sync.PhoneAppsDataSource content
observer; A: PhoneAppsWriter.forceUpdateCurrentPhoneApps). Both mark all apps as updated, and a
PC with a recorded state then receives an incremental push with **all** apps and icons. It
cannot be declined; answer `{result: 0}` and use or discard it.

---

## 7. The `recentApps*` arrays

What they are **[code-android]** + **[code-windows]**: the phone's list of recently used apps
(Android tasks), with optional document title and hand-off links. Windows shows them as
"recent apps" in its phone screen and Start menu surfaces and launches them through app
streaming (W: YourPhone.ScreenMirroring.Managed :: ViewModels.RecentAppsViewModel, PhoneScreenAppsViewModel).
They have nothing to do with notifications or icons. Windows resolves the display name and
icon of a recent app from the phone-apps table by package name and skips entries whose package
it does not know (W: PhoneAppsProcessor.ProcessRecentApps).

They exist only on phones where the OEM integration reports recent-apps support
(A: appmanager.ext.OemFeatureImpl.isRecentAppsSupported; A: appmanager.extgeneric.compatibility.ExtGenericOemFeature.isRecentAppsSupported).
The PC cannot switch them off separately: `configuration.RecentApps` is not read (1.1).

Where they appear:

| Message | Keys | Notes |
|---|---|---|
| Metadata message | `recentAppsIds`, `recentAppsChecksums`, `recentAppsSequenceNumber`; counted in `itemCount` | Section 2 |
| Full-sync content | Section 4.4, no `recentAppsActions` | Only if the PC's answer listed `recentAppsIds` |
| Incremental push | Section 4.4 with `incremental` 1 and `recentAppsActions` | Sent whenever the recent list changed. **It is always the complete current list**, every entry with action 0, not a delta. An empty list is sent as one dummy entry with id 1 and action 2. Windows replaces its whole recent list on such a message. A: PhoneAppsMessageBuilder.getMediaMapFromRecentApps; A: agents.recentapps.RecentAppsReader.getAllRecentApps; W: ProcessRecentApps |

**[wire]** R: nine such pushes in about two hours of phone use, 1 235 to 1 415 bytes each, 1 to
3 entries, no `phoneApps*` key in any of them. Each time the user switches apps on the phone
one may follow.

Can a client that only wants icons ignore them? **Yes.**

- In the answer to the metadata message: omit `recentAppsIds` (or send an empty Int64Array)
  and do not count recent ids in `itemCount`. No recent-apps message is then built.
- For every incremental push that has only `recentApps*` keys: answer `{result: Int32 0}` and
  drop it. A missing or non-zero result makes the phone treat the push as failed and repeat the
  same list with the next change.
- Keep the latest `recentAppsSequenceNumber` seen (metadata message or push) and send it as
  `sequenceNumbers.recentApps` in the next `/connect/v1`. Otherwise every connect starts a
  full sync (1.6).

The pushes themselves cannot be stopped while the phone holds a state for the PC, short of
turning the whole feature off with `Exp006` false, which also affects other PCs (1.1).

---

## 8. Incremental changes while connected

All **[code-android]**; an app change was not captured. The mechanism is the generic one of
`messages.md` 3.2 and 3.5.

1. Android broadcasts `PACKAGE_ADDED`, `PACKAGE_REPLACED` or `PACKAGE_REMOVED`. If
   `phoneAppsPCSupported` is true the phone updates its table: a new package gets a new row
   with a new random id; a replaced package keeps its id and gets new label, version and
   last-updated time; a removed package's row is deleted
   (A: PhoneAppsReceiver.PhoneAppsReceiverTask.doInBackground; A: PhoneAppsWriter.updatePhoneAppsTableGivenIntent;
   A: PhoneAppsWriterHelper.upsertPackage). An add or remove that is part of a replace is ignored.
2. The table change triggers a scan with no minimum interval (scan interval 0); the `phoneApps`
   number goes up by 1 (A: PhoneAppsDataSource database observer; A: agents.sync.DataSourceBase.performScan).
3. For every PC that qualifies (1.4, last row) the phone starts an automatic sync, which
   resolves to incremental.
4. One or more app batches arrive, schema 4.1 plus `incremental` Int32 1 and `actions`:

| Change | `actions[i]` | Row content |
|---|---|---|
| Installed | 0 | Full row and icon |
| Updated (also label, locale or icon-theme change) | 1 | Full row and icon |
| Removed | 2 | Id only (4.1) |

   Order inside the sync: deletes, then updates, then creates (A: DataSourceBase.loadChangesSince).
   The last app batch carries the new `sequenceNumber`. No metadata message, no PC choice:
   the icons of all changed apps are included.
5. If the recent list also changed since the PC's number, one recent-apps message follows
   (section 7).
6. The PC answers each message `{result: 0}`, applies it, and stores the new number.

If `phoneAppsPCSupported` is false, steps 1 to 4 do not happen live. At the next connect the
phone reconciles its table with the installed packages, which finds new and removed packages
but **not updated ones** (A: PhoneAppsWriterHelper.quickSyncWithDevice). Send
`sequenceNumbers.phoneApps` as Int64 at least once to set the flag.

Changes made while the PC was away are delivered the same way at the next connect, as the
difference from the number the PC sends (1.6).

A second path announces changes to the other Windows client: PLATFORM publish with tag 7
(`ContentChange`) carrying `sync.v1.SyncMessage` with `content_type` `phoneApps` and the new
number, after which that client pulls `/phoneapps?since=<its number>` (section 10.1). A `PL`
client does not need it.

---

## 9. Minimum viable client

### 9.1 Always

- `/connect/v1`: `configuration.Exp006` true, `SequencedContentSyncs` true, `MessagingSync`
  true, `SyncSkipMetadataForAuto` false.
- Answer **every** `phoneApps` push on `/legacy/phonecontent` with `/internal/response`,
  headers `_originalRequestId`, `result: 0`, `_rejectionVersion: 1`, and a value set that
  contains `result` Int32 0.
- Tell the three message kinds apart by keys: `metadata` present = metadata message;
  `phoneAppsIds` without `metadata` = app batch; `recentAppsIds` without `metadata` and without
  `phoneAppsIds` = recent-apps message.
- Notification title: the notification's own `appName`.

### 9.2 Name only (no icon traffic at all)

| Step | Direction | Content |
|---|---|---|
| 1 | PC to phone | `/connect/v1` with `sequenceNumbers.phoneApps` and `.recentApps` = the numbers stored from the last metadata message or push, if any |
| 2 | phone to PC | Metadata message (first time only, or when the numbers are missing) |
| 3 | PC to phone | `{result: Int32 0, itemCount: Int32 0}`; store `sequenceNumber` and `recentAppsSequenceNumber` |
| 4 | later | Incremental pushes: answer `{result: 0}`, store the newest numbers, drop the rest |

### 9.3 Icons

Selection by package is impossible before the row has been seen once (5.3), so the smallest
exchange that yields (package, label, icon) is "ask for ids, learn what they are".

Per phone, keep a cache keyed by app id: checksum, package, label, version, PNG bytes; plus the
last `phoneApps` and `recentApps` numbers and a flag "cache covers the last id list".

| Step | Direction | Content |
|---|---|---|
| 1 | PC to phone | `/connect/v1`. If the cache covers the last id list: send both stored numbers. Otherwise send `phoneApps` Int64 -1 to get a metadata message (omitting the key works too, but only an Int64 value sets `phoneAppsPCSupported`, section 1.2). |
| 2 | phone to PC | Metadata message: `phoneAppsIds`, `checksums`, `sequenceNumber`, perhaps `recentApps*` |
| 3 | PC | Delete cached ids that are not listed. `wanted` = listed ids that are not cached or whose checksum differs. `ask` = all of `wanted`, or its first K (6.3). |
| 4 | PC to phone | `{result: Int32 0, itemCount: Int32 ask.count, phoneAppsIds: Int64Array ask}`. No `recentAppsIds`, no `phoneAppsETag`. With `ask` empty this is 9.2 step 3. |
| 5 | phone to PC | App batches. For each: slice `content` by `iconSizes`, upsert rows by id, answer `{result: 0}`. The batch with `sequenceNumber` is the last. Do not wait for ids that never come: vanished ids are skipped. |
| 6 | PC | If `wanted` is now covered: store the numbers and set the flag. If not: keep the flag clear so that the next sync (5.4 a or b) offers the list again. |
| 7 | later | Incremental batches: `actions` 0 and 1 upsert, 2 delete by id. Store `sequenceNumber`. |
| 8 | display | Icon = cached PNG of the row whose package equals the notification's `packageName`; fall back to a generic icon. |

On the captured phone, asking for everything at step 4 is the exchange of section 6.1: 2.7 kB
in, 1.3 kB out, three batches of about 2.0 MB in, about 12 s.

### 9.4 Pitfalls

- `itemCount` and `result` must be Int32, `phoneAppsIds` Int64Array. A wrong type fails the
  sync on the phone without a visible error.
- After a sync ended with `itemCount` 0 the phone believes the PC is complete. Nothing is
  offered again until a full sync is forced (5.4).
- Checksums are times, not content hashes. A phone that rebuilt its table (data cleared,
  `Exp006` flipped) presents all-new ids: treat an id list with no overlap as a new phone.
- A delete carries no package name.
- Do not treat the label from this sync as stable: it follows the phone's locale.

---

## 10. Other paths

### 10.1 PLATFORM device resource `/phoneapps`

Used by the other Windows client (`session-clipboard-notifications.md` 5.2). A:
agents.phoneapps.sync.PhoneAppsResourceRequestHandler, PhoneAppsPublisherCoordinator.getContentResponsePayloadBuilder
**[code-android]**; X: phoneapps/v1/phoneapps.proto, sync/v1/metadata.proto; **[wire]** P:73, 78, 401, 484.

- Request: `DeviceResourceManagerMessage` with `request_type` GET (1), `resource_type` UNKNOWN
  (4), `resource_path` `/phoneapps?since=<n>`, empty payload. Other request types give status
  `BAD_REQUEST` (3); a missing or non-numeric `since` likewise; sync not allowed gives
  `SYNC_DISABLED` (5).
- Response payload `PhoneAppsResponseMessage`: `status` (1 OK), `metadata.content[]` of
  `SyncMetadata{content_type "phoneApps", sequence_number}`, `items[]` of `PhoneAppSync`, each
  either `create_or_update.item` (`PhoneApp`: `id`, `app_package_name`, `last_updated_time`
  Timestamp, `app_name`, optional `app_version`, `favorite_rank`, `app_icon` bytes, `checksum`)
  or `delete.id`.
- `since=-1` returns every app with its icon in **one** response. `since=<n>` returns only the
  changes after n. `since=<current>` returns the metadata alone.
- **[wire]** `since=2` with the phone at 2: 23-byte response after 0.40 s. `since=-1`: one
  response of 1 971 022 bytes, 115 items, 1 960 226 icon bytes, after 9.75 s. The icons are the
  same PNGs in the same sizes as on the APP path.
- Icons are per item here (`app_icon`), not a concatenated array. The same PNG encoding and
  the same 716 800 scaling rule apply; a drawable without intrinsic size is drawn at 48 dp.
- Side effect: any GET sets `Exp006` and `phoneAppsPCSupported` to true on the phone.
- No recent apps on this path. No selection. Not useful for a client that wants to stay small,
  except that `since=<current>` is a cheap way to read the phone's number.

### 10.2 Publish tag 7

Phone to PC, `MsaepMessage.message_tag` 7 (`ContentChange`), payload `sync.v1.SyncMessage` with
`changed_content[]` of `SyncMetadata` (`phoneApps`, new number). Sent when the app table
changes and the experiment `PhoneAppsPublish` is on (A: agents.phoneapps.PhoneAppsPublisher;
A: PhoneAppsPublisherCoordinator.getPubSubPayloadBuilderAsync) **[code-android]**. Not captured.

### 10.3 The old ETag protocol (`Exp006` false)

For recognition only; do not implement. **[code-android]** A: PhoneAppsMessageBuilder.originalGetMediaItemMessages,
getMetadataInternal, getRequestedItemCount; A: agents.PhoneAppsProvider.

- The metadata message has no id arrays. The PC answers with `phoneAppsETag`; if it equals the
  phone's counter nothing is sent, otherwise **all** apps follow in batches of 30.
- Batch keys: `itemCount` (total apps), `appNames`, `appPackageNames`, `appVersions`,
  `removedPackageList`, `content`, `iconSizes`, `phoneAppsETag` Int64, `syncType` Int32
  (1 full, 2 removed, 3 added or replaced). No ids, no checksums, icons not size-capped.
- `/applications` with `subcontentType` Int32 0 or 1 answers at once with `appPackageNames`
  (0: the packages in the phone's table; 1: installed, not stopped, non-system packages); with
  `phoneAppsMessage` it **overwrites the phone's table**.
- The Windows processor in this build handles only the id-based format (it looks for
  `phoneAppsIds`) **[code-windows]**.

---

## 11. Differences between the two code bases

| Topic | Android | Windows | Consequence |
|---|---|---|---|
| `/applications` request | Requires `contentType` `phoneApps`; reads `subcontentType` Int32 | Sends `contentType` `phoneAppsContent`, `subContentType` UInt32 | The Windows request is answered with `result` 2. A client must use the Android names. |
| `configuration.RecentApps` | Not read | Sent | Recent apps cannot be declined by configuration. |
| `phoneAppsFavorites` | Sent | Not read; Windows keeps its own favourite rank by package | Ignore. |
| `forceRefreshOfTypes` | Read, but a no-op with `Exp006` on | Never sent | Dead in this version pair. |
| Completion of a sync | Batches end with the one that has `sequenceNumber`; vanished ids are skipped | Stores the numbers only once every requested app id (or every requested recent id) has arrived (W: PhoneAppsProcessor.ProcessItemForSyncCoordinator) | A client should key on `sequenceNumber`. |
| `itemCount` in the PC answer | Only compared with 0 | Apps plus recent apps | Any positive value works. |

---

## 12. Open questions

1. **`/applications` from a custom client.** The forced full sync is read from Android code
   only and the Windows request shape does not match it. Not verified: that the route accepts
   the request from our client, the reply timing, and how often it may be repeated.
2. **Partial answer on the wire.** Requesting a subset of `phoneAppsIds` follows from the code
   but was never captured. In particular the last-batch `sequenceNumber` and the recorded PC
   state after a partial request should be confirmed live.
3. **Build time per icon alone.** The 75 ms figure is an upper bound from a capture in which
   the phone built the same icons twice and synced photos and contacts at the same time. An
   isolated measurement with 10, 25 and all ids would give a real cost curve.
4. **What exactly blocks.** That a phone-apps build delays other pushes to the same PC is seen
   once on the wire (contacts batch) and explained from code by inference. Whether requests
   *from* the PC (for example `/notifications` commands) are also delayed during the build was
   not captured.
5. **Repeat limit of `/connect/v1` on the phone.** Needed to judge method 5.4 (a) for paced
   fetching.
6. **Icons of apps without a launcher activity.** Not available through this feature. Whether
   any other route (for example the media-style `largeIcon`, or the PLATFORM `/image` resource)
   can supply an icon for such a package was not investigated.
7. **Adaptive-icon rendering.** Icons are drawn from `ActivityInfo.loadIcon` at intrinsic size.
   Whether themed or monochrome icons, or OEM icon masks, change the bytes on other phones is
   unknown; only one phone was captured.
8. **Declining without creating a state.** Answering the metadata message with a non-zero
   `result` (for example 16) would leave the phone without a state for the PC and so without
   change-driven pushes, at the price of a metadata message at every connect. Read from code,
   not tried; side effects on the phone's telemetry or retry behaviour are unknown.
9. **Phones without recent-apps support.** All captures come from a phone that has it. On
   other phones the `recentApps*` keys and the `recentApps` reply key should simply be absent
   **[code-android]**; not seen.
