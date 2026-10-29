# Contacts (`contactsV2`): names and photos for phone numbers and e-mail addresses

Implementation-grade specification of one Phone Link feature, limited to what a PC client needs
to show a contact **name** (and optionally a small photo) for a phone number or e-mail address
that appears in text messages and notifications. The reader implements the PC side in Swift; the
peer is an Android phone running Link to Windows (LTW).

Revision 1, 2026-10-09.

Read first, not repeated here:

- `messages.md` sections 3 (sync model, sequence numbers), 4.1 to 4.4 (common keys, metadata
  round, content batches, action values) and 5 (what the PC must reply).
- `photos.md` section 2 (the same model for a single-table content type).
- `session-clipboard-notifications.md` sections 2 (envelope, value set), 7.6 (`/permission`) and
  8 (`/connect/v1`).

The contacts sync is the same pattern with six sub-tables in one content type. Only the
differences and the exact names are given below.

Sources and how they are cited

| Tag | Meaning | Pointer form |
|---|---|---|
| **[code-android]** | Decompiled Link to Windows 1.26082.130.0 (jadx). Package `com.microsoft.mmx.agents` is abbreviated `agents`. | `A: class.method` |
| **[code-windows]** | Decompiled Phone Link 1.26072.257.0. | `W: assembly :: class.method` |
| **[wire]** | Captured traffic, read for structure only. `P:` = `captures/vm-pairing-2026-10-09/flows.jsonl`, `R:` = `captures/vm-raw-2026-10-09/flows.jsonl`; the number is the record `seq`. | `P:454` |
| **[inferred]** | Deduced, not directly confirmed. | |

What the captures contain **[wire]**

| Exchange | Records |
|---|---|
| First connect with all contact numbers -1, connect reply | P:409, P:459 |
| Full sync: metadata message, PC answer naming every id, one content batch, PC acknowledgement | P:454, P:467, P:494, P:511 |
| Reconnect with equal numbers, no contact traffic | P:549, P:557 and R:147, R:163 |

Not on the wire in any capture: an incremental contact push, a deletion, a sync of more than one
batch, a partial request (fewer sub-tables than offered), a `/contacts/v2` request. Those parts
are code only.

No name, phone number, e-mail address, photo, account or device name appears in this document.
All capture figures are counts, sizes and times.

---

## 1. The feature in one page

| Step | Direction | Route | What |
|---|---|---|---|
| 1 | PC to phone | `/connect/v1` | `sequenceNumbers` tells the phone what the PC holds for six keys. |
| 2 | phone to PC | `/legacy/phonecontent`, `contentType` `contactsV2` | **Full sync**: one metadata message (ids and checksums of six sub-tables), the PC answers with the ids it wants, content batches follow. Or **incremental sync**: content batches only. The PC answers every message. |
| 3 | phone to PC | same | Any later change in the phone's contacts produces another push. |
| 4 | PC to phone | `/contacts/v2` | Optional: force a full sync. |

One content type, `contactsV2`. The six sub-tables are objects inside the same message:

| Sub-table | Sequence key | Android source (A: `agents.contacts.*Reader`) | Row id |
|---|---|---|---|
| contacts | `contact` | `ContactsContract.Data`, rows grouped by `contact_id` | aggregate contact id |
| phone numbers | `phonenumber` | `ContactsContract.CommonDataKinds.Phone` | data row `_id` |
| e-mail addresses | `emailaddress` | `ContactsContract.CommonDataKinds.Email` | data row `_id` |
| postal addresses | `postaladdress` | `ContactsContract.CommonDataKinds.StructuredPostal` | data row `_id` |
| dates (birthday etc.) | `contactdate` | `ContactsContract.Data`, mimetype `vnd.android.cursor.item/contact_event` | data row `_id` |
| URLs | `contacturl` | `ContactsContract.Data`, mimetype `vnd.android.cursor.item/website` | data row `_id` |

The sequence keys are the lower-case strings of A: `agents.sync.ContentType.toString`
**[code-android]**; the same six constants are in W: `YourPhone.Contacts.Managed :: Utilities.ContactsConstants`
**[code-windows]**; all six are on the wire in P:409, P:454, P:459 **[wire]**.

There is no filter on the contact set: every contact that has at least one data row is listed
(A: `agents.contacts.ContactV2DataSource` creates an empty filter list and never adds to it)
**[code-android]**. No time window, no "visible only", no account filter.

A second, unrelated path exists and is **not** usable for number lookup: the PLATFORM device
resource `/contacts` (A: `agents.contacts.platform.ContactsResourceRequestHandler`, protobuf
`ContactSearchRequestMessage` / `ContactSearchResponseMessage`). It searches by contact *name*
only (precise, then fuzzy), default 20 results **[code-android]**.

---

## 2. Enablement

### 2.1 `/connect/v1` configuration keys

| Key | Windows sends | Read by the phone | Effect |
|---|---|---|---|
| `SequencedContentSyncs` | true | yes | Required. The phone reads `sequenceNumbers` (and therefore starts any contact sync) only when this **and** `MessagingSync` are both true (A: `agents.DeviceData.doesPcSupportSequencedSyncs`; A: `agents.ConnectionRequestHandler.tryProcessRequest`) **[code-android]**. |
| `MessagingSync` | true | yes | See above. Required even for a client that wants contacts only. |
| `SyncSkipMetadataForAuto` | false | yes | When true the phone never runs the metadata round on its own (`preferIncrementalSync`); a missing or -1 number then yields a content-only push of **every** row of that sub-table with action 0 (A: `agents.sync.SyncCoordinatorBase.determineSyncType`; A: `agents.sync.DataSourceBase.loadChangesSince`) **[code-android]**. Leave false. |
| `ContactsV2Sync` | true | **no** | The string does not occur in the Android app. Windows sets it unconditionally (W: `YourPhone.Contacts.Managed :: Sync.PayloadHelpers.LoadConfiguration`) **[code-windows]**; observed true in P:409, P:549, R:147 **[wire]**. Sending false or omitting it does not stop the push. |
| `ContactThumbnails` | true | stored only | Written to the preference `contactThumbsPcSupported` (A: `agents.DeviceData.setPcWantsContactThumbnails`); nothing in the decompiled app reads that preference **[code-android]**. It does **not** switch photos off (section 6). |

There is no configuration key that disables the contacts push. The only gates are the phone
permission (2.3) and the sequence numbers (2.2).

### 2.2 `sequenceNumbers` keys

All Int64; the phone casts each present value to `Long`, any other type fails the connect request
(A: `ConnectionRequestHandler.setCoordinatorStates`) **[code-android]**.

| Key | Meaning |
|---|---|
| `contact`, `phonenumber`, `emailaddress`, `postaladdress`, `contactdate`, `contacturl` | -1 or absent: "I have nothing". N >= 0: "I hold the phone's state as of N". |

What the phone does with them, evaluated once per connect and again on every change it detects
(A: `SyncCoordinatorBase.setTargetState`, `determineSyncType`, `noDataForContentType`)
**[code-android]**:

| What the PC sent | Phone behaviour |
|---|---|
| **None of the six keys** | **Full sync** at once. This is the case of a client that ignores contacts: the map is empty, and an empty map selects "full" directly. Matches the live observation that the metadata message arrives although no contact number was sent. |
| At least one key, and for some sub-table the key is absent, or is -1 while the phone's number is above 0 | **Full sync** of all six sub-tables. |
| A key is -1 and the phone's number for it is 0 or less (nothing to sync) | That sub-table is ignored for the decision. An *absent* key is never ignored this way. |
| All six keys present and equal to the phone's numbers | Nothing is sent. **[wire]** P:549 (PC 1 for all six), P:557 (phone 1 for all six), no `contactsV2` message afterwards; same in R:147, R:163. |
| All six present, at least one differs | **Incremental sync** (section 8). |

Windows adds the six keys only when the phone is "contacts capable" (bit 0x800 of
`capabilities.registeredPermissionTypes`, or a Bluetooth contacts capability), using its stored
numbers or -1 (W: `Sync.ContactsEstablishConnectionPayload.Load`; W: `Utilities.ContactsFeatures.IsContactsCapable`)
**[code-windows]**. P:409 carried -1 for all six **[wire]**.

To keep the phone quiet without implementing the sync, a client can echo the six numbers from the
previous connect reply (2.4) **[inferred]** from the table above.

### 2.3 Phone-side gates **[code-android]**

| Gate | Source |
|---|---|
| Android permission `android.permission.READ_CONTACTS` only. Permission type `CONTACTS`, enum value 12, legacy flag 2048 (0x800). | A: `agents.permissions.PermissionsHelper` (`CONTACTS_PERMISSION`); A: `agents.PermissionTypes` |
| Without it: no contact keys in the connect reply, `permissions.contacts` false, no pushes, `/contacts/v2` answers `result` 7. | A: `ConnectionRequestHandler.setCoordinatorStates`; A: `agents.sync.SyncExecutor.executeAsync` (returns 3 internally); A: `agents.ContactsV2RequestHandler.tryProcessRequest` |
| Pushes caused by a change go to every active remote app of client type `PL`. | A: `SyncCoordinatorBase.onChangeDetected` |
| Sync allowed by the metered-connection policy. | A: `agents.sync.SyncSequence.sendMessageAsync` |

The six data sources start observing and scanning as soon as the permission is held, whatever the
PC sends (A: `agents.AgentRegister.updateContactTriggers`; A: `agents.ContactV2SyncCoordinator.subscribe`).

To ask the user for the permission: `/permission` with `permissionType` Int32 2048 **[inferred]**
from the flag numbering (W: `YourPhone.AppCore.Managed :: DevicePermissions.Contacts` = 0x800); not captured.

### 2.4 What the connect reply says

A: `ConnectionRequestHandler.tryProcessRequest`, `createDeviceCapabilityBlob`, `createDevicePermissionBlob`,
`createDeviceAttributeBlob` **[code-android]**; read by W: `ContactsEstablishConnectionPayload.Apply`
and W: `YourPhone.Devices.Managed :: Sync.DeviceInfoEstablishConnectionPayload` **[code-windows]**;
shape confirmed by P:459, P:557 **[wire]**.

| Key | Type | Meaning |
|---|---|---|
| `contact`, `phonenumber`, `emailaddress`, `postaladdress`, `contactdate`, `contacturl` (top level) | Int64 | The phone's **current** sequence number per sub-table. Present only with the permission. Observed 1 for all six right after the first scan. |
| `permissions.contacts` | Bool | `READ_CONTACTS` granted. Observed true. |
| `capabilities.contacts` | Int32 | Bit 1 `SYNC_V2`, always set by Android (A: `agents.contacts.ContactsCapability`). Windows names: 1 SyncV2, 2 Pbap1_1, 4 TflContactSync (W: `YourPhone.AppCore.Managed :: ContactsCapabilities`). Observed 1. |
| `capabilities.registeredPermissionTypes` | Int32 | Bit 0x800 set means the phone build supports contacts. Observed set. |
| `attributes.countryCode` | String, 2 characters | The phone's current country (ISO 3166 alpha-2). Needed for number matching (section 7). |

Reading the six numbers waits for the first scan of each sub-table
(A: `agents.sync.DataSourceBase.getSequenceNumber`), so the first connect reply after the
permission is granted can be late by the time of six content-provider scans **[code-android]**.

Windows stores the reply values only as "expected" numbers (to show a syncing state). The numbers
it sends next time come from the `sequenceNumbers` object of pushes (sections 3 and 5)
**[code-windows]** W: `ContactsEstablishConnectionPayload.Apply`; W: `Processors.ContactsProcessor.Complete`.

---

## 3. The metadata message (phone to PC)

APP request on `/legacy/phonecontent`, headers `_requestId` and `_route` only **[wire]** P:454.
A: `agents.MessageBuilderBase.getMetadata`; A: `agents.ContactsV2MessageBuilder.getMetadataInternal`,
`getMetadataItemCount` **[code-android]**. Every key below was present in P:454 **[wire]**.

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `contactsV2` |
| `metadata` | Int32 | 1. Marks the metadata round. |
| `itemCount` | Int32 | Sum of the lengths of the six id arrays. |
| `contactIds` | Int64Array | Every contact id, ascending. |
| `contactChecksums` | Int64Array | Parallel with `contactIds`. |
| `phoneNumberIds` | Int64Array | Every phone-number row id, ascending. |
| `phoneNumberChecksums` | Int64Array | Parallel with `phoneNumberIds`. |
| `contactEmailAddressIds` | Int64Array | Every e-mail row id. |
| `contactEmailAddressChecksums` | Int64Array | Parallel with `contactEmailAddressIds`. |
| `contactPostalAddressIds`, `contactPostalAddressChecksums` | Int64Array | Parallel pair. |
| `contactDateIds`, `contactDateChecksums` | Int64Array | Parallel pair. |
| `contactUrlIds`, `contactUrlChecksums` | Int64Array | Parallel pair. |
| `sequenceNumbers` | Object | Exactly six Int64 entries: `contact`, `phonenumber`, `emailaddress`, `postaladdress`, `contactdate`, `contacturl`. The numbers of the snapshot being offered. |
| `contactSettings` | Object | `contactCapabilities` Int32 (same mask as `capabilities.contacts`, observed 1). |
| `contractVersion`, `correlationVector`, `installationId`, `displayName`, `dedupeID`, `retryCount`, device status keys | | As on every phone push (`messages.md` 4.1). |

Each ids array is parallel with its own checksums array and with nothing else. The id spaces are
separate: a phone-number id and a contact id can have the same value.

Checksums (opaque to the PC, compare for equality only) **[code-android]**:

| Sub-table | Checksum | Source |
|---|---|---|
| contact | Java hash of the `data_version` of the contact's name, organization, nickname, photo and note rows, plus the `photo_uri` and `photo_thumb_uri` strings. Any 32-bit value, may be negative. | A: `agents.contacts.ContactItem.buildMetadata`, `getChecksum` |
| phone number | `data_version` + 1 | A: `agents.contacts.PhoneNumberItem` |
| e-mail | `data_version` | A: `agents.contacts.EmailAddressItem` |

**[wire]** P:454: lengths 100 contact, 205 phone number, 15 e-mail, 3 postal, 16 date, 3 URL;
`itemCount` 342; payload 2 980 bytes (envelope 3 085). The contact, phone-number and e-mail id
arrays were in ascending order.

If the phone has no rows at all (`itemCount` 0) no metadata message is sent and the sync ends
(A: `agents.sync.SyncSequence.loadMetadata`) **[code-android]**.

Producing this message costs the phone one scan of **each** of the six sources
(A: `ContactV2SyncCoordinator.getFullSyncPayload` calls `loadMetadata` on all six); the contact
scan reads every data row of every contact (id, version and photo URI columns only)
**[code-android]**. This cost is paid whether or not the PC then asks for anything.

---

## 4. The PC's answer to the metadata message

APP message on `/internal/response`, headers `_originalRequestId`, `_route`, `_rejectionVersion`
(`"1"`), `result` (`"0"`) **[wire]** P:467.

Written by W: `Processors.ContactsProcessor.AssembleResponseMetadata` **[code-windows]**. Read by
A: `SyncSequence.handleSendResult`, `handleSuccessfulResponse`; A: `MessageBuilderBase.getRequestedItemCount`;
A: `ContactsV2MessageBuilder.getMediaItemMessages` **[code-android]**. The structured jadx output
of the last method is unreliable (duplicated blocks, and a first emptiness test printed inverted),
so the key names, the null and length checks and the final test were checked against an
instruction-level decompilation of the same class (jadx fallback mode): the phone returns "no
content" only when **all** twelve row lists (found and deleted, per sub-table) are empty.

| Key | Type | Read by phone | Required | Meaning |
|---|---|---|---|---|
| `result` | Int32 | yes | no (missing counts as 0 here) | 0. Any other value fails the sync; 19 ends the user session. Always send it. |
| `itemCount` | Int32 | yes | **yes, and above 0, to receive content** | Windows: total number of ids in the six arrays. The phone only tests it against 0. |
| `contactIds` | Int64Array | yes | no | Contact ids whose rows are wanted. |
| `phoneNumberIds` | Int64Array | yes | no | Phone-number row ids wanted. |
| `contactEmailAddressIds` | Int64Array | yes | no | E-mail row ids wanted. |
| `contactPostalAddressIds` | Int64Array | yes | no | Postal row ids wanted. |
| `contactDateIds` | Int64Array | yes | no | Date row ids wanted. |
| `contactUrlIds` | Int64Array | yes | no | URL row ids wanted. |
| `contentType` | String | no | no | `contactsV2` |
| `contractVersion` | Double | no | no | 3.99 |
| `correlationVector` | String | no | no | Copied from the metadata message. |

The request keys have the **same names as the ids arrays of the metadata message**. There is no
key for photos.

Phone behaviour by case **[code-android]**:

| Answer | Phone behaviour |
|---|---|
| `itemCount` absent or 0 | The sync **ends as successful**. No content is sent. The phone records this PC as holding all six sequence numbers of the metadata message, so later changes arrive as incremental pushes (section 8). |
| `itemCount` > 0, an id array absent or of length 0 | That sub-table is skipped: its reader is not called, its object in the batch has `itemCount` 0. |
| `itemCount` > 0, an id array present and non-empty | One query for exactly those ids. An id that no longer exists comes back as an entry with action 2. |
| `itemCount` not Int32 (for example Int64) | Cast failure; the sync fails (internal result 7) and the PC's state is not updated. |
| An id array not Int64Array | Cast failure, logged as "Exception reading metadata response"; no rows are sent **[code-android]**, the sync does not complete as successful **[inferred]**. |
| `itemCount` > 0 but all six arrays absent or empty | No content message can be built. Not traced further; do not send this (open question 6). |
| `result` other than 0 | Sync failed; nothing recorded. |

What Windows requests: per sub-table it deletes local rows whose id is not listed, and asks for
every id that is new or whose stored checksum differs; for contacts also every id whose stored
thumbnail is NULL (W: `YourPhone.Contacts.Managed :: WinRT.DataStore.ContactTable.Synchronize`;
W: `YourPhone.Utilities :: Extensions.IUpdatableTableExtensions.SynchronizeWithData`)
**[code-windows]**. It always sends all six arrays, empty when nothing is wanted. On the first
sync it asked for everything: six arrays of lengths 100, 205, 15, 3, 16, 3, `itemCount` 342,
payload 997 bytes, 0.418 s after the metadata message **[wire]** P:467.

The metadata message is the authoritative "these are all rows" list: delete local rows that are
not in it, whatever you then request.

---

## 5. Content batches (phone to PC)

APP requests on `/legacy/phonecontent`, same `correlationVector` as the metadata message, one at a
time; the phone waits for the PC's reply before sending the next (A: `agents.sync.SyncExecutor.executeNextOperation`).
Built by A: `ContactsV2MessageBuilder.ContactV2BatchYielder.next` and A: `agents.ContactsBuilderHelper`
**[code-android]**; read by W: `Processors.ContactsProcessor.ProcessItem` and
W: `Processors.ContactEntityHelpers` **[code-windows]**; shape confirmed by P:494 **[wire]**.

### 5.1 Top level

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `contactsV2` |
| `contacts` | Object | 5.2 |
| `phoneNumbers` | Object | 5.3 |
| `emailAddresses` | Object | 5.4 |
| `postalAddresses`, `contactDates`, `contactUrls` | Object | 5.5 |
| `contactSettings` | Object | `contactCapabilities` Int32 |
| `sequenceNumbers` | Object | **Last batch only.** 5.7 |
| `incremental` | Int32 1 | Only in batches of an incremental sync. Absent in P:494. |
| common keys | | As in section 3. No `metadata`, no top-level `itemCount`. |

Every batch contains all six objects; an object with nothing in it has `itemCount` 0 and
zero-length arrays **[code-android]**. Inside one object all arrays are parallel and have
`itemCount` elements. Null strings are sent as `""`.

Batching (A: `ContactV2BatchYielder.next`; A: `agents.PayloadHelpers.getAppServiceMessageSizeLimit`)
**[code-android]**: items are appended in the fixed order contacts, phone numbers, e-mail, postal,
dates, URLs until the *estimated* size reaches 1 048 576 bytes (`AppServiceMessageMaximumSize`).
Estimate per contact: 16 + the UTF-16 length of its strings + its thumbnail bytes; per phone
number or e-mail: 24 + string lengths. A sub-table can be split across two batches. Because
contacts always come first, a number never arrives in an earlier batch than a contact row
requested in the same sync; it can arrive in a later one. At most 50 messages per sync including
the metadata message (A: `SyncExecutor.executeAsync`). All requested rows of all sub-tables are
loaded into memory before the first batch is built (A: `ContactsV2MessageBuilder.getMediaItemMessages`).

### 5.2 `contacts`

A: `ContactsBuilderHelper.buildContactsMapFromIds`; A: `agents.contacts.ContactItem.buildUpdateItem`.

| Key | Type | Meaning | Read by Windows |
|---|---|---|---|
| `itemCount` | Int32 | | yes |
| `contactIds` | Int64Array | Android aggregate contact id. **The join key.** | yes |
| `checksums` | Int64Array | See the warning below. | yes |
| `lastUpdatedTimes` | Int64Array | Unix milliseconds (`contact_last_updated_timestamp`), 0 when the contact has no name, organization or nickname row. | yes, required |
| `displayNames` | StringArray | Android primary display name (`display_name`). Filled only when the contact has a structured-name row; otherwise `""`. | yes |
| `alternativeNames` | StringArray | `display_name_alt` (family name first). | no |
| `givenNames`, `middleNames`, `familyNames` | StringArray | Structured-name parts. | yes |
| `namePrefixes`, `nameSuffixes` | StringArray | | yes |
| `nicknames` | StringArray | First nickname row. | yes |
| `companies`, `jobTitles` | StringArray | Organization row. | yes |
| `notes` | StringArray | Free-text note. | yes |
| `actions` | Int32Array | 5.6 | yes |
| `thumbnailSizes` | Int64Array | Byte length of each contact's photo, 0 for none. | yes |
| `thumbnails` | UInt8Array | All photos concatenated in index order (section 6). | yes |

There is **no** starred / favourite field, no account or source, no group, no ringtone. The
projection is the fixed list in A: `ContactItem.PROJECTION` **[code-android]**.

A name to show: `displayNames[i]` if not empty; Windows falls back to the formatted address, not
to the company or nickname (W: `ViewModels.ContactViewModel.CalculateDisplayName`) **[code-windows]**.

Checksum warning: the content `checksums` value is computed without the photo URI strings, the
metadata `contactChecksums` value with them (A: `ContactItem.buildUpdateItem` does not read those
columns) **[code-android]**. **[wire]** P:454 against P:494: the two values differed for exactly
the 12 contacts that had a photo and were equal for the other 88. To diff correctly at the next
metadata round, store the value from the **metadata** message, not from the batch. For phone
numbers and e-mail the two were equal for every row **[wire]**.

**[wire]** P:494: 100 entries, ascending ids, the same order as requested; `displayNames` and
`givenNames` non-empty for all, `familyNames` for 66, `companies` for 23.

### 5.3 `phoneNumbers`

A: `ContactsBuilderHelper.buildPhoneNumbersMapFromIds`; A: `agents.contacts.PhoneNumberItem.buildUpdateItem`.

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | |
| `phoneNumberIds` | Int64Array | Data row id. Stable for the life of the row. |
| `contactIds` | Int64Array | **Contact id of the owning contact**; equals a value of `contacts.contactIds`. |
| `checksums` | Int64Array | Same value as in the metadata message. |
| `phoneNumbers` | StringArray | Normalized number: Android's `data4` (E.164 when Android could derive it), otherwise `PhoneNumberUtils.normalizeNumber` of the entered text (digits and a leading `+` kept, letters mapped to digits). Use this for matching. |
| `displayNumbers` | StringArray | The number as the user typed it (`data1`), with spaces and punctuation. Use this for display. |
| `types` | Int32Array | See below. |
| `labels` | StringArray | Custom label text when `types` is 8, otherwise `""`. |
| `actions` | Int32Array | 5.6 |

`types` (A: `agents.contacts.PhoneNumberType`; W: `WinRT.DataStore.PhoneNumberType`)

| Value | Name | Android `data2` |
|---|---|---|
| 0 | unknown | (deleted entry) |
| 1 | home | 1 |
| 2 | mobile | 2 |
| 3 | work | 3 |
| 4 | work mobile | 17 |
| 5 | main | 12 |
| 6 | other | anything else |
| 7 | school | never produced by Android |
| 8 | custom | 0 |

**Join.** `phoneNumbers.contactIds[i]` to `contacts.contactIds[j]`, an integer equality. One
contact has zero or more numbers; one number row has exactly one contact. The same join key is
used by `emailAddresses.contactIds` and the other three sub-tables.

**[wire]** P:494: 205 rows for 89 distinct contacts (11 of the 100 contacts had no number), at
most 5 numbers per contact; every `contactIds` value was present in `contacts.contactIds`;
203 of 205 `phoneNumbers` values started with `+`, none was empty; 125 were identical to their
`displayNumbers` value; `types` values seen 1, 2, 3, 5, 6, 8; `labels` non-empty for 2 rows.

### 5.4 `emailAddresses`

A: `ContactsBuilderHelper.buildEmailAddressesMapFromIds`; A: `agents.contacts.EmailAddressItem`.

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | |
| `contactEmailAddressIds` | Int64Array | Data row id. |
| `contactIds` | Int64Array | Owning contact id (join as in 5.3). |
| `checksums` | Int64Array | |
| `emailAddresses` | StringArray | Address as stored (`data1`). The array has the same name as its parent object. |
| `emailAddressType` | Int32Array | 0 unknown, 1 home, 2 work, 3 school (never produced), 4 other, 5 custom, 6 mobile (A: `agents.contacts.EmailAddressType`). |
| `emailAddressLabel` | StringArray | Custom label when the type is 5. |
| `actions` | Int32Array | |

**[wire]** P:494: 15 rows for 13 contacts, all joined; types seen 1, 2, 4, 5.

### 5.5 The other three objects (keys only)

All have `itemCount` Int32, `contactIds` Int64Array, `checksums` Int64Array, `actions` Int32Array.
**[code-android]** `ContactsBuilderHelper`; shape **[wire]** P:494.

| Object | Id array | Other keys |
|---|---|---|
| `postalAddresses` | `contactPostalAddressIds` | `postalAddressDisplayAddress`, `postalAddressStreet`, `postalAddressCity`, `postalAddressRegion`, `postalAddressPostalCode`, `postalAddressCountryCode`, `postalAddressSubLocality`, `postalAddressLabel` (StringArray), `postalAddressType` (Int32Array) |
| `contactDates` | `contactDateIds` | `displayDate`, `label` (StringArray), `type` (Int32Array) |
| `contactUrls` | `contactUrlIds` | `address`, `label` (StringArray), `type` (Int32Array) |

Note the singular key names `type` and `label` here against `types` and `labels` in `phoneNumbers`.

### 5.6 Actions

Values as in `messages.md` 4.4 (A: `com.microsoft.appmanager.sync.ContentChangeAction`;
W: `YourPhone.Utilities :: SyncAction`): -1 none / sync, 0 create, 1 update, 2 delete. If
`actions` is absent Windows assumes -1 **[code-windows]**.

| Situation | Value | Source |
|---|---|---|
| Full sync, contact row | -1 | **[wire]** P:494 (all 100); the reader does not set an action **[code-android]** |
| Full sync, row of any other sub-table | 1 | **[wire]** P:494 (phone numbers, e-mail); `buildUpdateItem` sets `UPDATE_ALL` **[code-android]** |
| Full sync, requested id that no longer exists | 2 | **[code-android]** `ContactsBuilderHelper.createDeleted...ForIds` |
| Incremental sync, row first seen after the PC's number | 0 | **[code-android]** `DataSourceBase.loadChangesSince` |
| Incremental sync, checksum changed after the PC's number | 1 | same |
| Incremental sync, row gone | 2 | same |

PC behaviour: 2 means delete by id; every other value means insert or replace the whole row
(W: `ContactsProcessor.ProcessContacts`, `ProcessPhoneNumbers`: deletions first, then upserts)
**[code-windows]**. An entry with action 2 has only its id; strings are `""`, numbers 0
(including `contactIds` in the sub-table objects), `thumbnailSizes` 0.

Order inside one object **[code-android]**: full sync, found rows then deletions; incremental
sync, deletions, then updates, then creations.

### 5.7 `sequenceNumbers`

Present in the metadata message (clean, six entries) and in the **last** content batch of a sync.
In a batch the object is built from a copy of the common message keys, so besides the six Int64
entries it also contains `contentType`, `contractVersion`, `correlationVector`, `installationId`,
`displayName`, `dedupeID`, `retryCount` and the device status keys **[code-android]**
`ContactV2BatchYielder.next`; **[wire]** P:494 (30 entries). Read the six known keys and ignore
the rest.

These are the numbers to store and to send in the next `/connect/v1`. Windows writes them only
when the sync is complete, that is when every id it requested has arrived, or immediately when it
requested nothing (W: `ContactsProcessor.ProcessItem`, `AssembleResponseMetadata`, `Complete`)
**[code-windows]**. Store all six even if you fetched two sub-tables: any absent key forces a full
sync next time (2.2).

### 5.8 The PC's answer to a batch

`/internal/response`, value set `{result: Int32 0}`, header `result: 0` **[wire]** P:511 (payload
14 bytes); W: `ContactsProcessor.ProcessItem` **[code-windows]**. `result` is mandatory here: for a
content message the phone's default for a missing key is 24, which it does not treat as completion
(A: `SyncSequence.handleSendResult`) **[code-android]**. On a failure Windows answers `result` 1.
When the last batch is acknowledged with 0 the phone records the six numbers as this PC's state
(A: `SyncCoordinatorBase.lambda$initiateSync$4`).

---

## 6. Photos

| Fact | Source |
|---|---|
| A photo travels **inline** in the `contacts` object of the batch that carries the contact row: `thumbnailSizes[i]` bytes of `thumbnails`, taken in index order. Offset of contact i = sum of the sizes before it. | **[code-android]** `ContactsBuilderHelper.buildContactsMapFromIds`; **[code-windows]** `ContactEntityHelpers.BuildContactsEntitiesFromValueSet` |
| The bytes are Android's stored contact thumbnail (photo data row, column `data15`), sent unchanged. | **[code-android]** `ContactItem.buildUpdateItem` |
| Each one is a complete JPEG file. 12 of 100 contacts had one; sizes 3 639 to 7 679 bytes, 65 053 bytes together; pixel sizes 96x96 (7), 96x54 (3), 54x96 (2). | **[wire]** P:494 (file markers and frame headers only) |
| There is no separate thumbnail request, no larger photo, and no way to decline: the builder is always called with thumbnails included, and neither `ContactThumbnails` nor the `contactThumbs` sub-content type (section 9.3) changes that. | **[code-android]** `ContactV2BatchYielder.next`; 2.1 |
| A contact without a photo has size 0 and contributes no bytes. An entry with action 2 has size 0. | **[code-android]** |
| A changed or removed photo changes the contact's metadata checksum, so it comes as a normal contact update (action 1) with the new bytes or size 0. | **[code-android]** `ContactItem.getChecksum` |

The only way to avoid photo bytes is not to request the contact row. A client that wants names
must accept the photos of the contacts it requests; it may discard the `thumbnails` array without
parsing it. Windows' separate "PBAP thumbnail" classes (W: `Sync.PbapThumbnail.*`) serve the
Bluetooth contact path and are not used with Android over the relay **[inferred]**.

---

## 7. Cost and timing

### 7.1 Measured, first sync after pairing **[wire]**

All times are seconds from the start of the capture.

| Event | Record | Time | Size |
|---|---|---|---|
| PC sends `/connect/v1` (six contact numbers -1) | P:409 | 208.526 | |
| Phone sends the metadata message: 100 contact ids, 205 phone-number ids, 15 e-mail, 3 postal, 16 date, 3 URL, `itemCount` 342 | P:454 | 209.900 | payload 2 980 bytes |
| Phone sends the connect reply | P:459 | 210.013 | |
| PC answers, requesting all 342 | P:467 | 210.318 | payload 997 bytes |
| Phone sends the **only** content batch | P:494 | 218.843 | payload 88 820 bytes (envelope 88 925), one DCG fragment |
| PC acknowledges | P:511 | 219.423 | payload 14 bytes |

- Number of content batches: **1**.
- Wall-clock time from the PC's metadata answer to the last batch: **8.525 s**.
- Of the 88 820 bytes, 65 053 (73 %) were the photos of 12 contacts. The rest, about 23.8 KB,
  held 100 contacts, 205 numbers, 15 e-mail rows, 22 other rows and two copies of the common keys:
  roughly 0.24 KB per contact including its numbers.

The 8.5 s is an upper bound, not the cost of reading contacts. In the same window the phone was
also delivering a 1.67 MB `mediaInfo` content message (P:472, t=214.499), a 1.97 MB PLATFORM
response (P:484, t=217.660) and a 0.72 MB `phoneApps` batch (P:492, t=218.827); the contacts batch
followed that last one by 16 ms. No APP or PLATFORM message left the phone between t=210.013 and
t=214.499, and a small PLATFORM request the PC sent at t=210.428 (P:470) was answered at t=217.684
(P:486), 7.3 s later. So during first-sync traffic the phone's outgoing messages are delivered one
after another and a small answer waits behind megabyte-sized ones **[wire]**; how much of the
8.5 s was contact reading cannot be separated from this capture (open question 1).

### 7.2 Why the phone looks busy **[code-android]**

- All requested rows of all sub-tables are read and held in memory before the first batch
  (A: `ContactsV2MessageBuilder.getMediaItemMessages`): one query per sub-table with an
  `IN (...)` list of the requested ids. The contact query returns every data row of the requested
  contacts including photo blobs.
- The content message is produced lazily by a provider that the transport calls when it is ready
  to send (A: `SyncSequence.getContentMessageProvider`), so the reading happens on the send path
  **[inferred]** this is what delays other outgoing messages.
- The priority value of a contacts sync is 40 (35 for an incremental one), the same class as
  `phoneApps`; a user-initiated request shifts it by 25 (A: `PayloadHelpers.getPriorityForMessageBuilder`).

### 7.3 Can the PC ask for only `contact` and `phonenumber`?

**Yes for the content, no for the metadata.**

| Part | Reducible | Why |
|---|---|---|
| Metadata message | No | Always lists all six sub-tables and scans all six sources (section 3). About 3 KB for 342 rows **[wire]**. |
| Content: e-mail, postal, dates, URLs | Yes | Leave those four arrays out (or empty) and set `itemCount` to the number of ids you do request. Each sub-table's reader runs only when its array is present and non-empty (section 4) **[code-android]**. The phone does proportionally less work: two queries instead of six, and the batch has four empty objects. Not exercised on the wire; Windows uses the same mechanism with empty arrays on every sync where a sub-table is unchanged **[code-windows]**. |
| Content: photos of the requested contacts | No | Section 6. They dominated the captured batch. |
| Content: a subset of contacts or numbers | Yes | Any subset of ids is honoured, in one answer; there is no paging and no second answer for the same metadata round. |

After such a partial sync completes, the phone records the PC as up to date for **all six**
numbers. Rows that were not requested never arrive later unless they change, or the PC forces a
new full sync (section 9.3) **[code-android]** `SyncCoordinatorBase.lambda$initiateSync$4`.

Rough projection for requesting contacts and phone numbers only **[inferred]** from 7.1: text
about 0.24 KB per contact, plus about 5.4 KB per contact that has a photo. 1 000 contacts with the
same photo ratio would be about 0.9 MB, in one or two batches.

---

## 8. Matching a message address to a contact

How Windows does it **[code-windows]**:

| Step | Source |
|---|---|
| Classify the address: e-mail or phone number, by a native helper. | W: `YourPhoneControls.Projection :: Utilities.RegexHelper.IsEmail` (native, not decompiled) |
| Index every contact phone number under `GetE164PhoneNumber(phoneNumbers value, device country)`. The input is the `phoneNumbers` array (normalized), not `displayNumbers`. | W: `YourPhone.Contacts.Managed :: ViewModels.ContactViewModelManager.AddPhoneNumberToContactLookup` |
| Index every contact e-mail address under the address string itself, unchanged. | W: `ContactViewModelManager.AddEmailAddressToContactLookup` |
| Normalize a message address the same way and look it up by **exact string equality** in that dictionary (default, ordinal, case-sensitive comparer). | W: `ContactViewModelManager.LookupByPhoneNumberAndCountryInternal`, `LookupByEmailInternal` |
| Country used for a contact number: `attributes.countryCode` of the connect reply. For a message participant: the `countryIsos` value of the message's SIM subscription if not empty, else the device country. | W: `YourPhone.Devices.Managed :: DeviceInfoEstablishConnectionPayload`; W: `YourPhone.Messaging.Managed :: Processors.ParticipantEntityHelpers` |
| Several contacts can share one key; the first one with a non-empty display name gives the name, the first one with a photo gives the photo. | W: `ViewModels.ContactViewModel.CalculateDisplayName`, `CalculateThumbnail` |
| No match: a temporary entry whose name is the formatted number. | W: `ContactViewModelManager.AddContactToTemporaryLookupTable` |
| Addresses ending in `@rcs.google.com` are never participants. | W: `ParticipantEntityHelpers.IsValidParticipantAddress` |

`GetE164PhoneNumber` is native (W: `YourPhone.AppCore.Managed :: WinRT.Utilities.PhoneNumberUtils`,
a projection of a C++ class); its rules are not in the corpus. Its name and its `(number,
countryIso)` signature say: parse the number in the context of a default region and print it in
E.164 form.

Recommended rule for a Swift client **[inferred]**:

1. Key for a contact number: take `phoneNumbers[i]`. If it starts with `+`, keep `+` and the
   digits. (203 of 205 captured values were already in this form **[wire]**.)
2. Otherwise strip everything except digits. Remove the national trunk prefix of the phone's
   country if present (for example a leading `0` in most of Europe, `8` in Russia and
   Kazakhstan), then prefix `+` and the country calling code of `attributes.countryCode`. A
   number-parsing library with a default region does all of this in one call.
3. Apply the same steps to the message address, with the subscription's country when the
   message has one.
4. Short codes and alphanumeric sender ids do not parse; compare them as raw strings. They will
   normally match no contact.
5. E-mail addresses: exact comparison as Windows does; lower-casing both sides first is a safe
   improvement.
6. Do **not** fall back to comparing the last N digits unless the exact match fails and you accept
   false positives; Windows does not do it.

The suffix-style matcher in the Windows code (`phone_number_like`, W: `YourPhone.Utilities :: Database.SqliteExtension.IsValidPhoneNumberSearch`)
serves the contact search box, not address resolution **[code-windows]**.

---

## 9. Changes while connected

### 9.1 What triggers a push **[code-android]**

- Each of the six sources registers a content observer (contacts on `ContactsContract.Contacts`,
  phone numbers on `...CommonDataKinds.Phone`, e-mail on `...Email`, postal on
  `...StructuredPostal`, dates and URLs on `ContactsContract.Data`) and rescans its ids and
  checksums when it fires, rate limited by `ContactsMinScanInterval`, default **30 000 ms**
  (A: `agents.contacts.*DataSource`; A: `com.microsoft.appmanager.experiments.SDKFeatures`).
- A scan that finds a new id, a changed checksum or a vanished id raises that sub-table's
  sequence number by one and starts an "auto" sync to every active Phone Link client
  (A: `DataSourceBase.performScan`; A: `SyncCoordinatorBase.onChangeDetected`).
- The sync type is decided again from the numbers recorded for that PC (table in 2.2). A PC that
  completed a sync, **including one answered with `itemCount` 0**, gets an incremental sync. A PC
  for which nothing is recorded gets a full sync, that is another metadata message.

Expect a delay of up to about 30 s between an edit on the phone and the push, and possibly more
than one push for one edit (for example the contact scan and the phone-number scan firing
separately) **[inferred]**.

### 9.2 The incremental push **[code-android]**, not captured

A: `ContactV2SyncCoordinator.getIncrementalSyncPayload`; A: `DataSourceBase.loadChangesSince`.

- No metadata message. Content batches with the schema of section 5 plus `incremental` Int32 1.
- Each object lists only the rows that changed since the PC's number for that sub-table, with
  actions 0, 1, 2 (5.6). Changed contact rows carry their photo.
- The last batch carries `sequenceNumbers` (5.7) with the new numbers of all six sub-tables.
- The PC answers `{result: 0}`. Apply deletions and upserts, then store the six numbers.

Windows handles it without any stored state: a content message whose `correlationVector` it does
not know creates a new `ContactsProcessor` from the message itself; with no `metadata` key nothing
is diffed, the rows are applied, and the numbers are stored at once
(W: `ContactsProcessor` constructor and `ProcessItem`; W: `YourPhone.Connectivity.Managed :: PhoneContentHandler.HandleContentPayload`)
**[code-windows]**.

A client that has no contact table yet can treat an incremental push safely: upsert what it
carries. It will not make the table complete.

### 9.3 Forcing a full sync: `/contacts/v2` **[code-windows]** + **[code-android]**, not captured

APP request from the PC (W: `Sync.ContactsSyncManager.SyncContactsAsync`; W: `Sync.ContactsRequest.BuildRequestMessage`).
Windows sends it from the Contacts page refresh and from the Messages and Calls pages when they
need contacts.

| Key | Type | Value | Read by phone |
|---|---|---|---|
| `contentType` | String | `contactsV2` | no |
| `correlationVector` | String | Reused as the `correlationVector` of the pushes it causes. | yes |
| `subcontentTypes` | StringArray | `contactsV2`, `contactThumbs`, `phoneNumbers`, `emailAddresses`, `postalAddresses`, `contactDates`, `contactUrls` | yes: only whether `contactThumbs` is in it, and only to set the unused thumbnail preference |
| `configuration` | Object | `ContactsV2Sync` true, `ContactThumbnails` true | yes: `ContactThumbnails` only |
| `contractVersion` | Double | 3.99. Required, as for every scenario request (`photos.md` 2.5). | yes |
| `isuserinitiated` | Bool | Raises the push priority. | yes |

Phone behaviour (A: `agents.ContactsV2RequestHandler.tryProcessRequest`): without the permission,
reply `result` 7. Otherwise start a **forced full sync** to the sender (metadata message, PC
answer, batches, regardless of sequence numbers) and reply to the `/contacts/v2` request only
after that sync has finished, with `result` 0 on success (other codes as in `photos.md` 2.5).
The PC must therefore answer the pushes before the request completes.

`subcontentTypes` does not select sub-tables: the full sync always offers all six. Selection is
done in the answer to the metadata message (section 4). `forceRefreshOfTypes` in `/connect/v1` is
not an alternative; the phone acts on it only for `phoneApps`
(A: `ConnectionRequestHandler.forceFullSyncs`).

If the request's `configuration.ContactThumbnails` differs from the stored preference, the phone
drops the recorded state of **every** PC and re-initializes its six sources before starting
(A: `agents.ContactsConfigHelper`; A: `AgentRegister.ensureContactTriggersStateInSync`). The
preference is overwritten by `/connect/v1` (`ContactThumbnails`) and by this request (true exactly
when `contactThumbs` is listed). Keep the three consistent: the same Bool in both
`configuration` objects, and `contactThumbs` listed exactly when it is true.

---

## 10. Minimum viable client

Goal: `(contact id, display name)` and `(phone number, contact id)` for all contacts.
Photos cannot be excluded (section 6); ignore the `thumbnails` bytes.

### 10.1 Exchange

1. `/connect/v1`: `configuration.SequencedContentSyncs` true and `configuration.MessagingSync`
   true (both required, 2.1); `sequenceNumbers` with the six keys of 2.2 as Int64: the stored
   numbers, or -1 for all six when the local table is empty.
2. Phone sends the metadata message (section 3) if the numbers differ. From it:
   - delete local contacts not in `contactIds` and local numbers not in `phoneNumberIds`;
   - `wantContacts` = contact ids that are new or whose `contactChecksums` value differs from the
     stored one; `wantNumbers` likewise with `phoneNumberChecksums`. On a first sync, everything.
3. Answer on `/internal/response` (headers as in section 4):

   | Key | Type | Value |
   |---|---|---|
   | `result` | Int32 | 0 |
   | `itemCount` | Int32 | `wantContacts.count + wantNumbers.count` |
   | `contactIds` | Int64Array | `wantContacts` |
   | `phoneNumberIds` | Int64Array | `wantNumbers` |
   | `contactEmailAddressIds`, `contactPostalAddressIds`, `contactDateIds`, `contactUrlIds` | Int64Array | empty (as Windows sends when nothing is wanted) |
   | `contentType`, `contractVersion`, `correlationVector` | | `contactsV2`, 3.99, copied |

   If both lists are empty, `itemCount` is 0, the sync ends here, and the six numbers of the
   metadata message's `sequenceNumbers` are stored at once.
4. For each content batch (same `correlationVector`): from `contacts` take `contactIds`,
   `displayNames`, `actions` (and, for a photo, `thumbnailSizes` with `thumbnails`); from
   `phoneNumbers` take `phoneNumberIds`, `contactIds`, `phoneNumbers`, `displayNumbers`,
   `actions`. Action 2 deletes by id, anything else upserts. Answer `{result: 0}`.
5. When a batch contains `sequenceNumbers`, the sync is complete: store the six numbers. Store
   the checksums from the **metadata** message for the rows received (5.2).
6. Build the lookup of section 8 from `phoneNumbers` values and `attributes.countryCode`.

With e-mail: add `contactEmailAddressIds` to the request and read `emailAddresses`.

### 10.2 Afterwards

- Any later `contactsV2` message without `metadata` is an incremental push (9.2): apply, answer
  `{result: 0}`, store the numbers from its `sequenceNumbers` when present. It may contain
  e-mail, postal, date and URL rows that were never requested; ignore those objects.
- Any later `contactsV2` message with `metadata` restarts at step 2.
- A connect reply number lower than the stored one means the phone's table was reset: drop the
  local table and send -1 for all six **[inferred]** (same reasoning as `photos.md` 2.2).

### 10.3 Not implementing contacts at all

Answer every metadata message with `{result: 0, itemCount: 0}` (the current behaviour of
`app/Sources/WinPhoneCore/Features/NotificationSync.swift`, `declinedSyncTypes`). Each connect
without contact numbers then costs one metadata message of about 3 KB and six scans on the phone.
To avoid even that, send back the six numbers of the last connect reply (2.2) **[inferred]**.
Answer any incremental batch with `{result: 0}`.

---

## 11. Differences between the two code bases

| Topic | Android | Windows |
|---|---|---|
| `ContactsV2Sync` | Never read. | Always sent true. |
| `ContactThumbnails` | Stored, never read; photos always sent. | Always sent true; table diff treats a NULL thumbnail as "request again". |
| `alternativeNames` | Sent. | Not read. |
| `postalAddressSubAdministrativeArea` | Not sent. | Read if present. |
| Contact `checksums` in a batch | Computed without photo URIs, so unequal to the metadata value for contacts with a photo. | Stores the batch value; such contacts are requested again at every full metadata round. |
| `sequenceNumbers` in the last batch | Contains the common message keys as well. | Reads the six known keys only. |
| Phone number type 7 (school), e-mail type 3 (school) | Never produced. | Defined. |

---

## 12. Open questions

1. **Real phone-side cost.** The 8.5 s in 7.1 includes queueing behind megabytes of unrelated
   first-sync traffic. A capture of a contacts sync on an otherwise idle session, and one
   requesting only `contactIds` and `phoneNumberIds`, would give the true figures.
2. **Partial requests on a live phone.** Requesting two of six sub-tables follows from the code
   and from Windows' empty arrays, but no capture shows an answer where a sub-table with offered
   ids is left out entirely. Also unverified: that the phone then really records all six numbers.
3. **Photos cannot be declined.** Concluded from the absence of any reader of
   `contactThumbsPcSupported` in the decompiled sources. A reader in native code or in a
   dynamically loaded module would change section 6.
4. **Native normalization.** `PhoneNumberUtils.GetE164PhoneNumber` and `RegexHelper.IsEmail` are
   native and not in the corpus; the rules in section 8 are a reconstruction. Edge cases (numbers
   with extensions, numbers the parser rejects, what is returned for a short code) are unknown.
5. **Incremental sync.** Never captured. Unknown: the exact rate-limiting behaviour of the
   30 000 ms scan interval (first event or last event wins), and what the phone sends when an
   incremental sync finds no changed row.
6. **`itemCount` above 0 with no ids.** The phone builds no content message; whether the sync
   then ends, hangs until the phone's 2 minute request timeout, or fails was not traced.
7. **Contact aggregation changes.** When Android merges or splits contacts, a phone-number row
   keeps its id and `data_version` but gets a new `contact_id`. Its checksum does not change, so
   the row is not pushed again, and the PC's `contactIds` value for it may point at a deleted
   contact **[inferred]**. Windows deletes the numbers of a deleted contact by contact id; whether
   the surviving contact's numbers are then re-sent is unknown.
8. **More than one batch.** The 1 048 576 byte estimate and the 50-message cap come from code.
   No capture has a contact set large enough to split; the position of `sequenceNumbers` in a
   multi-batch sync (last batch only) is code only.
9. **`/contacts/v2`.** Request schema from Windows code, handler from Android code; never
   captured, including the timing of its reply.
10. **Which contacts are listed.** The code applies no filter. Whether SIM contacts, work-profile
    contacts and hidden or "other" contacts appear was not checked against a phone.
11. **`permissionType` 2048** for the contacts permission prompt is derived from the flag
    numbering, not observed.
