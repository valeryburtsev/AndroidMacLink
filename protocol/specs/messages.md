# Text messages (SMS / MMS / RCS)

Implementation-grade specification of one Phone Link feature: how the PC learns the phone's
conversations and messages, receives new ones, and sends a message. The reader implements the
PC side; the peer is an Android phone running Link to Windows (LTW).

Revision 1, 2026-10-09.

Read first, not repeated here: `session-clipboard-notifications.md` sections 1 (two clients,
client type `PL`), 2 (binary envelope, headers, value set), 7.5 (result codes) and 8
(`/connect/v1`). Everything below travels as APP messages whose payload is one
`pbvalueset.ValueSet`.

Sources and how they are cited

| Tag | Meaning | Pointer form |
|---|---|---|
| **[code-android]** | Decompiled Link to Windows 1.26082.130.0 (jadx). Package `com.microsoft.mmx.agents` is abbreviated `agents`, `com.microsoft.appmanager` is `appmanager`. | `A: class.method` |
| **[code-windows]** | Decompiled Phone Link 1.26072.257.0. | `W: assembly :: class.method` |
| **[wire]** | Captured traffic, read for structure only. `R:` = `captures/vm-raw-2026-10-09/flows.jsonl`, `P:` = `captures/vm-pairing-2026-10-09/flows.jsonl`; the number is the record `seq`. | `R:158` |
| **[inferred]** | Deduced, not directly confirmed. | |

What the captures contain **[wire]**

| Exchange | Records |
|---|---|
| Full sync: metadata round, PC reply with wanted ids, one content batch (twice in one session) | P:756, 758, 785 and P:789, 793, 827 |
| Incremental push of one deletion right after `/connect/v1` | R:147 (connect), 158 (push), 163 (connect reply), 168 (PC reply) |
| Send one SMS from the PC into an existing thread, phone answer, follow-up incremental push | R:3718, 3721, 3725, 3727 |

Not on the wire in any capture: MMS (messages, parts, attachments), RCS, mark-as-read, on-demand
part download, a send failure, a new *incoming* message. Those parts are code only.

No message text, phone number, contact name, account or device name appears in this document.
Examples use placeholders such as `<text>` and `<number>`.

---

## 1. The feature in one page

| Step | Direction | Route | What |
|---|---|---|---|
| 1 | PC to phone | `/connect/v1` | `configuration` switches messaging on; `sequenceNumbers` tells the phone what the PC already has. |
| 2 | phone to PC | `/legacy/phonecontent`, `contentType` `messaging` | The phone pushes. Either a **full sync** (one metadata message, then content batches) or an **incremental sync** (content batches only). The PC answers every message. |
| 3 | phone to PC | same | Any later change on the phone (new message, read state, deletion, new thread, SIM change) produces another incremental push. |
| 4 | PC to phone | `/chat/v1` | Commands: force a full sync, fetch attachment bytes, send a message, mark a thread read. |

There is one push content type, `messaging`. SMS, MMS, RCS, conversations, SIM subscriptions and
address lookups are sub-objects of the same message, not separate content types. The names
`sms`, `mms`, `conversation`, `subscription`, `rcs_chat`, `rcs_filetransfer`, `rcs_conversation`
are sequence-number keys only.

The phone always initiates the data flow. The PC never pages or queries; it can only ask for a
full resync.

---

## 2. Enablement

### 2.1 `/connect/v1` configuration keys

All Bool unless noted. Read by A: `agents.MessagingConfigHelper.updateDeviceDataWithMessagingConfig`
and A: `agents.ConnectionRequestHandler.processPartnerConfiguration` **[code-android]**. Written by
W: `YourPhone.Messaging.Managed :: Communication.PayloadHelpers.LoadConfiguration` **[code-windows]**.
Observed values from R:147 **[wire]**.

| Key | Observed | Phone default | Effect on the phone |
|---|---|---|---|
| `SequencedContentSyncs` | true | false | Phone reads `sequenceNumbers`. Required. If true and the `sequenceNumbers` object is absent, the connect request is abandoned. |
| `MessagingSync` | true | false | "Combined messaging sync". The sequenced path of section 3 is used only when **both** this and `SequencedContentSyncs` are true (A: `agents.DeviceData.doesPcSupportSequencedSyncs`). Required. |
| `MessagingSend` | true | false | Adds the `acks` object to every messaging push (section 4.9). The phone does not check it before sending a message. Windows sets it from phone capability bit 16. |
| `MessagingMassText` | true | false | Samsung path only: also sync SMS rows that are hidden members of a group send (A: `appmanager.ext.message.ExtSmsProvider.getBaseFilters`). |
| `MessagingRcsReceive` | true | false | PC wants RCS. RCS is synced only if the phone also reports RCS receive available. |
| `MessagingRcsSend` | false | false | PC allows sending as RCS. |
| `MessagingRcsUnsupportedMessageTypes` | Int32Array, 2 entries | absent | RCS system message types the PC cannot render. Windows adds it only with RCS receive. |
| `RcsBlockNewGroupChat` | absent | false | Do not create new RCS group chats on send. |
| `MmsImages` | absent | false | Include MMS attachment bytes inline in automatic syncs (section 4.6). Windows never sends it; see open question 3. |
| `SyncSkipMetadataForAuto` | false | false | When true the phone never runs the metadata round on its own; a PC number of -1 yields a content-only push of everything (section 3.3). |

A change in any of the Bool messaging keys (including `MmsImages` and `RcsBlockNewGroupChat`)
makes the phone drop its recorded sequence numbers for **every** PC and re-subscribe its data
sources (A: `agents.AgentRegister.ensureMessageTriggersStateInSync`;
A: `agents.sync.SyncCoordinatorBase.unsubscribe`). The next change on the phone then produces a
full sync instead of an incremental one **[inferred]**.

The same `configuration` object (messaging keys only) is repeated inside every `/chat/v1`
request and processed the same way **[code-windows]** + **[wire]** R:3718. Send identical
values in `/connect/v1` and in every `/chat/v1` request to avoid that reset.

### 2.2 Phone-side gates **[code-android]**

| Gate | Source |
|---|---|
| Android permissions `READ_SMS`, `READ_CONTACTS`, `SEND_SMS`, `READ_PHONE_STATE` (plus `READ_EXTERNAL_STORAGE` below API 33) all granted. Legacy permission flag value 2 (`PermissionTypes.MESSAGES`). | A: `agents.permissions.PermissionsHelper`; A: `agents.PermissionTypes` |
| Without the permission: connect reply carries no messaging sequence numbers, pushes do not happen, `/chat/v1` answers `result` 7. | A: `ConnectionRequestHandler.setCoordinatorStates`; A: `agents.MessagingRequestHandler.tryProcessRequest` |
| Reactive pushes go to every **active remote app of client type `PL`**. | A: `agents.sync.SyncCoordinatorBase.onChangeDetected` |
| Sync allowed by the phone's metered-connection policy. | A: `agents.ScenarioRequestHandlerBase.handleAsync`; A: `agents.sync.SyncSequence.sendMessageAsync` |
| `/chat/v1` requests need `contractVersion` Double with integer part 3. | A: `ScenarioRequestHandlerBase.handleAsync` |

To ask the user for the permission use `/permission` (spec section 7.6 of the session document)
with `permissionType` Int32 2 **[inferred]** from the flag numbering; not captured.

### 2.3 What the connect reply tells the PC

A: `ConnectionRequestHandler.tryProcessRequest`, `createDeviceCapabilityBlob`,
`createDevicePermissionBlob`; A: `agents.MessagingBuilderHelper.buildSettingsMap` **[code-android]**.
Read by W: `YourPhone.Messaging.Managed :: Sync.MessagingEstablishConnectionPayload.Apply`
**[code-windows]**. Shape confirmed by R:163 **[wire]**.

| Key | Type | Meaning |
|---|---|---|
| `permissions.messaging` | Bool | Messaging permissions granted. Observed true. |
| `capabilities.messaging` | Int32 | Bit mask below. Observed 48. |
| `capabilities.registeredPermissionTypes` | Int32 | Bit 2 set means the phone build supports messaging at all (W: `DeviceCapabilities.Messages`). |
| `settings.capabilities` | Int32 | Same mask as `capabilities.messaging`. |
| `settings.mmsAutoDownloadAvailable`, `settings.mmsAutoDownloadEnabled`, `settings.rcsSendAvailable`, `settings.markAsReadAvailable` | Bool | Observed all false. |
| `sms`, `mms`, `conversation`, `subscription` (top level) | Int64 | The phone's current sequence number per type. Present only with the permission. `rcs_chat`, `rcs_filetransfer`, `rcs_conversation` appear only when RCS is being synced. |

`capabilities.messaging` bits (A: `appmanager.message.MessagingCapability`; W: `YourPhone.AppCore.Managed :: MessagingCapabilities`)

| Bit | Name | Set when |
|---|---|---|
| 1 | MMS auto download available | OEM extension present |
| 2 | RCS receive available | OEM extension present |
| 4 | RCS send available | OEM extension present |
| 8 | Mark as read available | OEM extension present |
| 16 | Send | always |
| 32 | Participants | always |
| 64 | Mark message as read | never by Android (Windows-side name only) |
| 128 | Send requires proximity | market-specific experiment |

Bits 1, 2, 4 and 8 need Samsung's messaging extension **and** Samsung Messages as the default
SMS app (A: `appmanager.ext.ExtMessagingExtensions.refreshCapabilities`). The captured phone
reported 48: plain SMS/MMS, no RCS, no mark-as-read.

The same `settings` object is repeated in every messaging push.

---

## 3. Sync model

### 3.1 Sequence-number keys

| Key | Covers | Item id | Item checksum (phone side) |
|---|---|---|---|
| `sms` | SMS rows | Android SMS `_id` | 1 if read, else 0 |
| `mms` | MMS rows | Android MMS `_id` (separate id space from SMS) | 1 if read, else 0 |
| `conversation` | SMS/MMS threads | Android thread id | hash of (`hasRcs`, `recipientIds`) |
| `subscription` | active SIM subscriptions | Android subscription id | hash of all subscription fields |
| `rcs_chat`, `rcs_filetransfer`, `rcs_conversation` | RCS, only when enabled on both sides | provider ids | provider defined |

A: `agents.message.SmsMediaItem`, `MmsMediaItem`, `ConversationMediaItem`, `SubscriptionItem`
**[code-android]**. A message is identified by (kind, id); a thread id is shared by SMS and MMS.

### 3.2 What a sequence number is **[code-android]**

A: `agents.sync.DataSourceBase`, `agents.sync.ContentViewRepository`.

- Per content type the phone keeps a table of (id, checksum, created-at-sequence,
  modified-at-sequence, tombstone) in a local database. It is one table per phone, not per PC.
- A scan lists the current items (ids and checksums). If anything was added, changed or
  removed, the type's sequence number goes up by exactly 1 and the affected rows are stamped
  with it. Removed rows become tombstones.
- Scans run when Android's SMS/MMS content observers fire, at most one per 1000 ms per type
  (experiment values `SmsMinScanInterval`, `MmsMinScanInterval`).
- Value -1 on the phone means "not scanned yet"; 0 means "scanned, never had an item"
  **[inferred]** from R:163, where `mms` was 0 with no MMS present.
- The numbers are meaningful only for that phone installation. They are not timestamps and
  must not be compared across phones.

What the PC sends in `/connect/v1` `sequenceNumbers` (all Int64; any other type fails the cast):

| PC value for a key | Meaning to the phone |
|---|---|
| -1, or key absent | "I have nothing for this type." |
| N >= 0 | "I hold exactly the phone's state as of sequence N." |

The PC learns N from the `sequenceNumbers` object inside pushes (section 4.9), **not** from the
connect reply. The connect reply values are the phone's *current* numbers; Windows stores them
as the "expected" value to show a syncing state until the pushes catch up
(W: `MessagingEstablishConnectionPayload.Apply`, `Sync.MessagingSyncObserver`) **[code-windows]**.
Windows deliberately sends -1 for `sms` and `mms` (and the RCS message types) when its local
participant table is empty, to force a refetch (W: `MessagingEstablishConnectionPayload.LoadSequenceNumbers`).

The PC never echoes sequence numbers in a reply. The phone records "this PC now has sequence X"
when the whole sync finishes with `result` 0 (A: `SyncCoordinatorBase.lambda$initiateSync$4`).

### 3.3 How the phone chooses what to send **[code-android]**

On `/connect/v1` the phone stores the PC's numbers for the seven messaging keys and starts an
"auto" sync for that PC (A: `appmanager.message.DefaultMessageFeatureController.setSyncState`;
A: `SyncCoordinatorBase.setTargetState`, `determineSyncType`). Every later change detected on
the phone starts the same "auto" sync against the numbers it last recorded for the PC.

| Situation, evaluated per type the phone tracks | Outcome |
|---|---|
| PC value -1 and phone value <= 0 | Type ignored for the decision. |
| PC value -1 or absent, phone value > 0, `SyncSkipMetadataForAuto` false | **Full sync** of all messaging types (section 3.4). |
| Same, `SyncSkipMetadataForAuto` true | **Incremental sync**; for that type every current item is sent with action 0 (create). Not observed. |
| All remaining types equal | Nothing is sent. |
| Otherwise | **Incremental sync** (section 3.5): per type, the changes after the PC's number. |

**[wire]**: P:409 sent all -1 and got the metadata round P:756. R:147 sent `sms` one behind the
phone and got the content-only push R:158 268 ms later, before the connect reply R:163.

### 3.4 Full sync

A: `agents.MessageSyncCoordinator.getFullSyncPayload`; A: `agents.MessagingMessageBuilder`;
A: `agents.sync.SyncSequence` **[code-android]**. Confirmed by P:756 to 785 **[wire]**.

1. Phone sends one **metadata message**: every current id with its checksum, per type
   (section 4.2). It has `metadata` Int32 1 and no `incremental` key.
2. PC replies with the ids it wants (section 4.3) and their total as `itemCount`.
   `itemCount` 0 or absent ends the sync successfully at this point.
3. Phone sends **content batches** (section 4.4) for the requested ids, each as its own request
   on `/legacy/phonecontent` with the same `correlationVector`. It waits for the PC's reply
   before sending the next one. The last batch carries `sequenceNumbers`.
4. A requested id that no longer exists comes back as an entry with action 2 (delete).

Windows decides what to request by diffing ids and checksums against its tables: it requests
ids that are new or whose checksum differs and deletes local rows whose id is not listed
(W: `YourPhone.Utilities :: Extensions.IUpdatableTableExtensions.SynchronizeWithData`;
W: `Processors.MessagingProcessor.SynchronizeSms` and siblings) **[code-windows]**. The metadata
message is therefore also the authoritative "these are all the items" list.

Windows ties batches to the metadata round by `correlationVector` (optionally a `syncID`
string, which Android never sends) (W: `YourPhone.Connectivity.Managed :: PhoneContentHandler.HandleContentPayload`).

### 3.5 Incremental sync

A: `MessageSyncCoordinator.getIncrementalSyncPayload`; A: `DataSourceBase.loadChangesSince`
**[code-android]**. Confirmed by R:158 and R:3725 **[wire]**.

No metadata message. The phone sends content batches directly, each with `incremental` Int32 1.
Per item the action says what happened since the PC's number:

| Row state relative to the PC's number | Action |
|---|---|
| Created after it | 0 create, full item |
| Existed, checksum changed after it | 1 update, full item |
| Tombstoned after it | 2 delete, id only |

The last batch carries `sequenceNumbers` with the phone's new numbers for all synced types.

### 3.6 What is in scope on the phone **[code-android]**

| Rule | Source |
|---|---|
| Only messages dated within the last 30 days (2 592 000 000 ms before now, evaluated at every scan). | A: `MessageSyncCoordinator.getSyncStartDate` |
| SMS: only box type 1 (inbox) and 2 (sent); cell-broadcast alerts excluded. Samsung path also drops scheduled and hidden rows. | A: `agents.message.SmsReader.getBaseFilters`; A: `ExtSmsProvider.getBaseFilters` |
| MMS: only box 1 and 2; delivery reports (`m_type` 134) excluded. | A: `agents.message.MmsReader.getBaseFilters` |
| Conversations: threads with at least one message and a date inside the window. | A: `agents.message.ConversationReader.getBaseFilters` |
| Drafts, outbox, failed and queued messages are never synced. | same filters |

Consequence **[inferred]**: a message that ages past 30 days disappears from the phone's view at
the next scan and is reported to the PC as a deletion (action 2), with no user action. R:158 is
consistent with this (one SMS deletion pushed at connect).

**[wire]** P:756: the conversation id list was roughly two orders of magnitude longer than the
SMS id list. Most synced conversations therefore have no synced message.

### 3.7 Limits **[code-android]**

| Limit | Value | Source |
|---|---|---|
| Estimated size of one content batch | 1 048 576 bytes (`AppServiceMessageMaximumSize`) | A: `agents.PayloadHelpers.getAppServiceMessageSizeLimit` |
| Size estimate per item | SMS: text length + 60 (72 on the Samsung path); MMS: 100 + per part 64 + text length + data bytes; conversation 48; subscription 64 | A: item classes `getPayloadSize` |
| MMS message whose parts exceed this are sent without bytes | 2 097 152 bytes (`MmsPartSizeCapForAutoSync`) | A: `MessageSyncCoordinator.getMmsPartSizeLimit` |
| Messages per sync sequence (metadata + batches) | 50 | A: `agents.sync.SyncExecutor.executeAsync` |

Batches hold messages newest first (merged across SMS, MMS, RCS by date), then deletions, then
conversations, RCS conversations, subscriptions, then individually requested attachment bytes
(A: `MessagingMessageBuilder.MessagingBatchYielder`).

---

## 4. Payload schemas

Types are value-set types. "Array" keys inside one object are **parallel**: same length
(`itemCount`), index i describes item i. Null strings are sent as `""`
(A: `agents.ypp.valueset.ValueSetSerializerUtility.serializeEntry`). Readers on both sides cast
to exact types.

Swift note: `app/Sources/WinPhoneCore/Messaging/ValueSet.swift` has no case for BoolArray
(type 28) or UInt8Array (type 18). They arrive as `.other(Pbvalueset_DataVariant)`; read
`boolArray` and `uint8Array` from the variant.

### 4.1 Keys common to every messaging push

A: `agents.sync.KvpMessageHelpers.getBaseMessageMap`, `createMediaItemMapForSync` **[code-android]**; R:158 **[wire]**.

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `messaging` |
| `contractVersion` | Double | 3.99 |
| `correlationVector` | String | Same for the metadata message and all batches of one sync. For a sync triggered by `/chat/v1` it equals that request's `correlationVector`. |
| `installationId`, `displayName` | String | Phone identity. |
| `dedupeID` | String | Always `""`. |
| `retryCount` | Int32 | 0 |
| `metadata` | Int32 1 | Metadata message only. |
| `itemCount` | Int32 | Metadata message only: total ids listed. |
| `incremental` | Int32 1 | Content batches of an incremental sync and of on-demand requests. Absent in full-sync batches. Windows ignores it. |
| `settings` | Object | Section 2.3. |
| `acks` | Object | Section 4.9. Present when `MessagingSend` is on. |
| `sequenceNumbers` | Object | Section 4.9. Metadata message and last batch. |
| device status keys | various | `batteryPercent` and friends, as on every phone push. |

### 4.2 Metadata message (phone to PC)

A: `MessagingMessageBuilder.getMetadataInternal`, `fetchMetadata` **[code-android]**; P:756 **[wire]**.
All arrays Int64Array. Each ids array is parallel with its checksums array.

| Key | Parallel with | Content |
|---|---|---|
| `messagingSmsIds` | `messagingSmsChecksums` | All in-scope SMS ids. |
| `messagingUnreadSmsIds` | none | Subset of SMS ids that are unread. |
| `messagingMmsIds` | `messagingMmsChecksums` | All in-scope MMS ids. |
| `messagingUnreadMmsIds` | none | Unread MMS ids. |
| `messagingConversationIds` | `messagingConversationChecksums` | Thread ids. |
| `messagingSubscriptionIds` | `messagingSubscriptionChecksums` | Subscription ids. |
| `messagingRcsChatIds`, `messagingRcsFileTransferIds`, `messagingRcsConversationIds` | `...Checksums` | Only when RCS is synced. Absent in P:756. |

`itemCount` is the sum of the ids arrays (unread arrays not counted).

### 4.3 PC reply to the metadata message

W: `MessagingProcessor.AssembleResponseMetadata` **[code-windows]**; P:758 **[wire]**. Read by
A: `MessagingMessageBuilder.getMediaItemMessages` and A: `agents.MessageBuilderBase.getRequestedItemCount` **[code-android]**.

Envelope: route `/internal/response`, headers `_originalRequestId`, `result` (`"0"`),
`_rejectionVersion` (`"1"`).

| Key | Type | Value |
|---|---|---|
| `result` | Int32 | 0 |
| `contentType` | String | `messaging` |
| `contractVersion` | Double | 3.99 |
| `correlationVector` | String | Copied from the metadata message. |
| `itemCount` | Int32 | Number of ids requested in total. **The phone sends content only if this is > 0.** |
| `messagingSmsIds` | Int64Array | SMS ids wanted. |
| `messagingMmsIds` | Int64Array | MMS ids wanted. |
| `messagingMmsPartIds` | Int64Array | MMS part ids whose bytes are wanted. Windows always sends it empty here. |
| `messagingConversationIds` | Int64Array | Thread ids wanted. |
| `messagingSubscriptionIds` | Int64Array | Subscription ids wanted. |
| `messagingRcsChatIds`, `messagingRcsConversationIds` | Int64Array | RCS ids wanted. Windows adds them only with RCS receive. |
| `messagingRcsFileTransferChecksums` | Int64Array | Windows puts its wanted RCS file-transfer ids under this name; the phone reads `messagingRcsFileTransferIds`. See open question 6. |

Send every non-RCS key, with an empty array when nothing is wanted; the phone's handling of a
missing key could not be read reliably from the decompilation.

### 4.4 Content batch: objects

A: `MessagingMessageBuilder.MessagingBatchYielder.next`; A: `agents.MessagingBuilderHelper` **[code-android]**.
Every batch contains **all** of these objects, empty ones with `itemCount` 0 and zero-length
arrays **[wire]** R:158.

| Object key | Section | Holds |
|---|---|---|
| `smsMessages` | 4.5 | SMS items |
| `mmsMessages` | 4.6 | MMS headers |
| `mmsParts` | 4.6 | MMS body parts, optionally with bytes |
| `conversations` | 4.7 | Threads |
| `canonicalAddresses` | 4.7 | Recipient id to address lookup |
| `subscriptions` | 4.8 | SIM subscriptions |
| `rcsChats`, `rcsFileTransfers`, `rcsConversations` | 4.10 | RCS |
| `settings`, `acks`, `sequenceNumbers` | 2.3, 4.9 | |

The phone adds, without being asked, the conversation of every thread and the subscription of
every subscription id referenced by a non-deleted message in the batch, plus the canonical
addresses of all conversations in the batch. Consequences **[wire]** P:785, R:3725:

- `conversations` and `subscriptions` can contain the same id more than once in one batch and
  again in later batches. Treat every entry as an upsert.
- Implicitly added subscriptions carry action -1; implicitly added conversations carry action 1.

Action values in every `actions` array (A: `appmanager.sync.ContentChangeAction`; W: `YourPhone.Utilities :: SyncAction`)

| Value | Android name | Windows name | PC behaviour |
|---|---|---|---|
| -1 | NONE | Sync | upsert |
| 0 | CREATE | Create | upsert; eligible for a "new message" alert |
| 1 | UPDATE_ALL | Update | upsert |
| 2 | DELETE | Delete | delete by id; every other field of the entry is a zero value |

Observed **[wire]**: full-sync messages 1 (P:785); newly sent SMS 0 (R:3725); deletion 2 (R:158).
If `actions` is absent Windows assumes -1.

### 4.5 `smsMessages`

A: `MessagingBuilderHelper.buildSmsMapFromIds`; read by W: `Processors.EntityHelpers.BuildSmsEntitiesFromValueSet`.
Shape **[wire]** P:785, R:3725.

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | Number of entries. |
| `messageIds` | Int64Array | SMS id. Identity together with kind "SMS". |
| `threadIds` | Int64Array | Conversation id. |
| `messageTypes` | Int32Array | Mailbox, see below. Only 1 and 2 occur. |
| `dates` | Int64Array | Milliseconds since the Unix epoch (13-digit values observed). 0 if unknown. |
| `bodies` | StringArray | Text. |
| `fromAddresses` | StringArray | Sender address when `messageTypes` is 1, else `""`. |
| `toAddresses` | StringArray | Recipient address when `messageTypes` is not 1, else `""`. |
| `readFlags` | BoolArray | true = read. Sent messages are read. |
| `checksums` | Int64Array | 1 read, 0 unread. |
| `subscriptionIds` | Int64Array | SIM subscription that carried the message; -1 unknown. |
| `groupIds` | Int64Array | -1 for an ordinary SMS. On the Samsung path, the group id of a multi-recipient ("mass text") send. |
| `subjects` | StringArray | Always `""`. |
| `actions` | Int32Array | Section 4.4. |

Windows requires `messageIds`, `threadIds`, `dates`, `fromAddresses`, `bodies`, `subjects`,
`messageTypes`, `readFlags`; the rest are optional to it.

Mailbox values (`messageTypes`, and `messageBoxTypes` for MMS). W: `YourPhone.Messaging.WinRT.DataStore.MessageMailboxType`; values are Android's.

| Value | Meaning | Synced |
|---|---|---|
| 1 | Inbox (received) | yes |
| 2 | Sent | yes |
| 3 | Draft | no |
| 4 | Outbox | no |
| 5 | Failed | no |
| 6 | Queued | no |

Direction is derived from the mailbox: 1 incoming, 2 outgoing. There is no per-message delivery
status field and no delivery-report data. Addresses are the raw strings stored by Android, not
normalised.

### 4.6 `mmsMessages` and `mmsParts` **[code-android]**, not captured with content

`mmsMessages` (A: `MessagingBuilderHelper.buildMmsMessagesMapFromIds`; A: `agents.message.MmsMediaItem`)

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | |
| `messageIds` | Int64Array | MMS id. |
| `threadIds` | Int64Array | Conversation id. |
| `messageBoxTypes` | Int32Array | Mailbox, table above. |
| `dates` | Int64Array | Milliseconds (the phone multiplies Android's seconds by 1000). |
| `subjects` | StringArray | Subject or `""`. |
| `subjectCharsets` | Int32Array | MIBenum charset of the subject; 0 if no subject. |
| `subscriptionIds` | Int64Array | -1 unknown. |
| `readFlags` | BoolArray | true = read. |
| `fromAddresses` | StringArray | Sender (MMS address type 137), E.164 when the phone can format it. |
| `toAddresses` | StringArray | All To (151) and Cc (130) addresses of the message joined with `,` in **one string per message**. |
| `checksums` | Int64Array | 1 read, 0 unread. |
| `actions` | Int32Array | |

`mmsParts` (A: `MessagingBuilderHelper.buildMmsPartsMapFromIds`; A: `agents.message.MmsMessagePart`, `MmsPartReader`; read by W: `EntityHelpers.BuildMmsPartsWithDataFromValueSet`)

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | Number of parts in this object. |
| `messageIds` | Int64Array | Owning MMS id. |
| `partIds` | Int64Array | Android part id. Used to request bytes. |
| `sequenceNumbers` | Int32Array | Part order within the message (Android `seq`). Not related to sync sequence numbers. |
| `contentTypes` | StringArray | MIME type of the part, for example `text/plain`, `application/smil`, `image/jpeg`. |
| `texts` | StringArray | Text of a text part, else `""`. |
| `contentIds`, `contentLocations`, `names`, `fileNames` | StringArray | Android `cid`, `cl`, `name`, `fn`. |
| `charsets` | Int32Array | MIBenum charset of the part. |
| `sizes` | Int64Array | Byte size of the part's data on the phone; 0 for a text-only part. |
| `contentByteSizes` | Int32Array | Number of bytes of this part included in `contentBytes`, or **-1 = bytes not included**. |
| `contentBytes` | UInt8Array | Concatenation, in array order, of the bytes of all parts whose `contentByteSizes` is >= 0. |

To slice: walk the arrays in order keeping an offset; skip entries with -1.
Parts without bytes are listed first, parts with bytes after them.

How bytes travel

| Case | Behaviour |
|---|---|
| "MMS media" flag off (default) | All parts arrive with `contentByteSizes` -1. Text is still in `texts`. |
| Flag on and the whole message (header + parts) is at most 2 097 152 bytes | Parts arrive with bytes inline in the same batch. Only for supported types: SMIL, text, image, video, audio, and common document types (A: `agents.Utils.isContentTypeSupportedForMessaging`). |
| Flag on, message larger | As if off. |
| On demand | PC requests part ids on `/chat/v1` (section 7.2); the phone pushes a batch whose `mmsParts` has those parts with bytes. |

The flag is the phone preference set by configuration key `MmsImages` and by a `/chat/v1`
full-sync request listing `messagesMmsMedia` in `subcontentTypes` (section 7.1). There is no
separate file-transfer route for MMS attachments; bytes are always inside the value set.

### 4.7 `conversations` and `canonicalAddresses`

A: `MessagingBuilderHelper.buildConversationsMapFromIds`, `buildCanonicalAddressMapFromIds`;
A: `agents.message.ConversationMediaItem`, `CanonicalAddressReader`. Shape **[wire]** P:785.

`conversations`

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | |
| `ids` | Int64Array | Thread id. Matches `threadIds` of SMS and MMS. |
| `recipientIds` | StringArray | Space-separated decimal canonical-address ids of the other participants. One token for a 1:1 thread, several for a group. |
| `hasRcs` | BoolArray | The thread also has RCS messages. Always false without RCS. |
| `checksums` | Int64Array | Phone-side hash; opaque. |
| `actions` | Int32Array | |

A conversation entry has **no** title, snippet, last-message, timestamp or unread count. The PC
derives all of them from the messages it holds for that thread.

`canonicalAddresses`

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | |
| `ids` | **StringArray** | Canonical-address id as a decimal string. |
| `addresses` | StringArray | Phone number, short code, alphanumeric sender id or e-mail address, as stored by Android. |

Join: conversation `recipientIds` tokens to `canonicalAddresses.ids` to `addresses`. Windows
stores the result as participants (W: `MessagingProcessor.ProcessConversations`;
W: `Processors.ParticipantEntityHelpers`).

### 4.8 `subscriptions`

A: `MessagingBuilderHelper.buildSubscriptionsMapFromItems`; A: `agents.message.SubscriptionItem`, `SubscriptionReader`. Shape **[wire]** R:3725.

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | |
| `ids` | Int64Array | Android subscription id. This is the value to send as `subscriptionId` when sending. |
| `simSlotIndices` | Int64Array | Physical slot, 0-based. |
| `names` | StringArray | Display name of the subscription. |
| `numbers` | StringArray | Line number, may be `""`. |
| `countryIsos` | StringArray | |
| `isRoamings` | BoolArray | |
| `isDefaultSubscriptions`, `isDefaultSmsSubscriptions`, `isDefaultDataSubscriptions`, `isDefaultVoiceSubscriptions` | BoolArray | Phone defaults. |
| `isMmsEnableds`, `isGroupMmsEnableds`, `allowAudioAttachments`, `isMultipartSmsEnableds`, `shouldSendMultipartSmsAsSeparateMessages` | BoolArray | Carrier configuration. |
| `maxMessageSizes` | Int32Array | Maximum MMS size in bytes. |
| `maxMessageTextLengths` | Int32Array | Maximum SMS text length; -1 = no limit. |
| `maxSubjectLengths` | Int32Array | |
| `recipientLimits` | Int32Array | Maximum MMS recipients. |
| `maxImageHeights`, `maxImageWidths` | Int32Array | |
| `smsToMmsTextLengthThresholds` | Int32Array | Text longer than this is sent as MMS; -1 = never. |
| `smsMultipartToMmsTextThresholds` | Int32Array | More SMS segments than this is sent as MMS. |
| `isRcsSupported` | BoolArray | RCS send enabled for the subscription. |
| `maxRcsMessageSize`, `maxRcsFileSize` | Int64Array | Note the singular key names. |
| `checksums` | Int64Array | Opaque. |
| `actions` | Int32Array | -1 for entries added implicitly. |

**[wire]** P:785: entries with action 2 have zero values in every other array; the same id can
appear both as a real entry and as a deletion in one batch. Apply in array order **[inferred]**;
see open question 7.

### 4.9 `sequenceNumbers` and `acks`

`sequenceNumbers` (A: `MessagingMessageBuilder.getSequenceMap`; W: `MessagingProcessor.ProcessSequenceNumbers`, `Complete`)

| Key | Type |
|---|---|
| `sms`, `mms`, `conversation`, `subscription` | Int64 |
| `rcs_chat`, `rcs_filetransfer`, `rcs_conversation` | Int64, present in content batches even without RCS (value 0 observed in R:158), absent in the metadata message P:756 |

Present in the metadata message and in the **last** content batch of a sync. The PC persists
the values once it has processed the last batch (or immediately when it answers the metadata
message with `itemCount` 0) and sends them as `sequenceNumbers` in the next `/connect/v1`.
Never persist them from a batch that failed.

`acks` (A: `agents.message.SendResultState.getSuccessIds`; W: `MessagingProcessor.ProcessAcks`)

| Key | Type | Meaning |
|---|---|---|
| `ids` | Int64Array | The `id` values of send requests (section 7.3) that the phone sent successfully. |

**[wire]** R:3725 `acks.ids` held exactly the `id` of R:3718. The phone keeps up to 32 send
results in memory and repeats all successful ids in **every** later messaging push until its
process restarts; the PC must treat repeats as no-ops. Windows deletes its local "sending"
placeholder rows with these ids.

### 4.10 RCS objects **[code-android]**, never observed non-empty

Synced only when `MessagingRcsReceive` is true and capability bit 2 is set.

`rcsChats` (A: `MessagingBuilderHelper.buildRcsChatsMapFromIds`)

| Key | Type | Meaning |
|---|---|---|
| `itemCount` | Int32 | |
| `messageIds`, `threadIds`, `dates`, `checksums`, `subscriptionIds` | Int64Array | `threadIds` is an RCS conversation id; dates in ms. |
| `bodies`, `contentTypes`, `sessionIds`, `recipients` | StringArray | |
| `fromAddresses` | StringArray | Set only when `messageTypes` is 1. |
| `messageTypes` | Int32Array | Mailbox as in 4.5. |
| `rcsMessageTypes` | Int32Array | 0 ordinary message; 1 to 10 group-chat system events (W: `YourPhone.Messaging.WinRT.DataStore.RcsMessageType`). |
| `readFlags`, `isUserActionRequired` | BoolArray | |
| `actions` | Int32Array | |

`rcsFileTransfers` (A: `buildRcsFileTransfersMapFromIds`): the `rcsChats` keys without `bodies`,
plus `fileNames` StringArray, `fileSizes` Int32Array, `fileByteCounts` Int32Array (-1 = bytes not
included) and `fileBytes` UInt8Array, sliced exactly like `mmsParts.contentBytes`.

`rcsConversations` (A: `buildRcsConversationsMapFromIds`): `itemCount`, `ids` Int64Array,
`checksums` Int64Array, `fallbackIds` Int64Array (the SMS/MMS thread used as fallback),
`recipientIds` StringArray (space-separated canonical ids), `rcsConversationTypes` Int32Array
(0 none, 1 one-to-one, 2 active group, 3 inactive group), `actions` Int32Array.

### 4.11 Names for addresses

The messaging payload carries addresses only. Display names come from the separate contacts
sync (content type `contactsV2`, route `/contacts/v2`, sequence keys `contact`, `phonenumber`,
`emailaddress`, ...; A: `agents.ContactsV2MessageBuilder`, `agents.ContactsBuilderHelper`): its
phone-number object pairs `contactIds` with `phoneNumbers` / `displayNumbers`, its contact object
pairs `contactIds` with `displayNames`. That schema is outside this document and was not
verified here. Matching an SMS address to a contact number is done on the PC; Windows normalises
both with the phone's `countryCode` first **[code-windows]** (W: `Processors.ParticipantEntityHelpers`).

---

## 5. What the PC must reply

Every push is a request; the phone waits for the answer before continuing
(A: `SyncSequence.handleSendResult`, `handleSuccessfulResponse`) **[code-android]**.

| Push | Reply value set | Envelope |
|---|---|---|
| Metadata message | Section 4.3. | `/internal/response`, `_originalRequestId`, `result: 0`, `_rejectionVersion: 1` |
| Content batch | `result` Int32 0 only **[wire]** P:797, R:168, R:3727. | same |

How the phone reads the reply

| `result` | Phone behaviour |
|---|---|
| 0 on the metadata message | Reads `itemCount`; 0 or absent completes the sync, otherwise builds the batches from the id arrays. |
| 0 on a batch | Sends the next batch; after the last one the sync is complete and the phone records the new sequence numbers for this PC. |
| absent on the metadata message | Treated as 0. |
| absent on a batch | Treated as 24: logged as unexpected, sync neither completed nor failed. Always send `result`. |
| 19 | Ends all user sessions with this PC. |
| 16 or 17 | Sync ends as "disabled" / "device not resolved". |
| anything else, or no answer | Sync fails. The phone keeps the PC's old numbers, so the same changes are sent again with the next sync. |

Because a failed or interrupted sync is replayed from the old numbers, the PC must apply
batches idempotently (upsert by id, delete by id).

Windows may also answer before processing with 13, 1, 19 or 3 (session document section 7.2).

---

## 6. A new incoming message while connected

**[code-android]**; the outgoing equivalent was captured (R:3725), an incoming one was not.

1. Android's SMS/MMS content observers fire; the phone rescans (at most once per second per
   type); the `sms` (or `mms`) sequence number goes up by 1. A new thread also bumps `conversation`.
2. For each active `PL` remote app the phone starts an auto sync, which resolves to incremental.
3. One `/legacy/phonecontent` request arrives, `contentType` `messaging`, `incremental` 1:

| Object | Content |
|---|---|
| `smsMessages` (or `mmsMessages` + `mmsParts`) | The new message: action 0, mailbox 1, `readFlags` false, `fromAddresses` set. |
| `conversations` | The message's thread (action 1), whether or not it changed. |
| `canonicalAddresses` | Addresses of that thread's recipients. |
| `subscriptions` | The receiving subscription (action -1). |
| `sequenceNumbers` | New numbers. |
| `acks` | Possibly old ids, section 4.9. |

4. PC replies `{result: 0}` and stores the sequence numbers.

Later changes arrive the same way: read on the phone gives action 1 with `readFlags` true and
checksum 1; deleted on the phone gives action 2 with only `messageIds` meaningful; a deleted
thread gives action 2 entries for its messages and for the conversation id.

There is no separate "new message" event, typing indicator or delivery event.

---

## 7. PC to phone: route `/chat/v1`

Handler: A: `agents.MessagingRequestHandler.tryProcessRequest` **[code-android]**. Builders:
W: `YourPhone.Messaging.Managed :: Communication.*Request.BuildRequestMessage` **[code-windows]**.

Envelope: APP request, headers `_requestId` (GUID), `_route` `/chat/v1`, `_rejectionVersion` `1`.

Keys common to all requests (R:3718 **[wire]**)

| Key | Type | Value |
|---|---|---|
| `contentType` | String | `messaging` (not checked by the phone) |
| `contractVersion` | Double | 3.99. Mandatory. |
| `correlationVector` | String | Any unique string. |
| `requestType` | Int32 | Table below. Absent means 0, or 1 when `requestedItems` is present. |
| `configuration` | Object | Messaging keys of section 2.1. Optional for the phone (absent = switches untouched). When present it **replaces** the stored switches: an omitted Bool key becomes false, and any change triggers the reset described in 2.1. |
| `isuserinitiated` | Bool | Optional; raises the phone's send priority. |
| `ignoreResponse` Bool false, `transportType` Int32 0, `displayName`, `appVersion`, `installationId` | | Added by Windows to every legacy request. |

| `requestType` | Windows name | Android | Section |
|---|---|---|---|
| 0 | Sync | full sync | 7.1 |
| 1 | RequestItems | push specific items | 7.2 |
| 2 | Send | send a message | 7.3 |
| 3 | MarkConversationAsRead | mark thread read | 7.4 |
| 4 | MarkMessageAsRead | **not handled**: reply `result` 2 | 7.5 |
| 5 | GetMessage | **not handled**: reply `result` 2 | 7.5 |

Every reply contains `result` Int32 and `contractVersion` Double 3.99 and has no `result`
header. Missing messaging permission: `result` 7 for every type.

### 7.1 Type 0: force a full sync **[code-android] + [code-windows]**, not captured

Request (W: `Communication.MessagingRequest`): common keys, no `requestType`, plus
`subcontentTypes` StringArray. Windows sends `messages`, `messagesMms`, `conversations`,
`subscriptions`; adds `messagesMmsMedia` when the user enabled MMS attachment download; adds
`messagesRcsChat`, `messagesRcsFileTransfer`, `conversationsRcs` with RCS.

Phone: sets the "MMS media" flag to whether `messagesMmsMedia` is listed, then runs the full
sync of section 3.4 toward the sender. The other strings do not select what is synced.

Reply: sent **after** the whole sync finished. 0 success; 7 needs permission; 8 blocked by
metered connection; 11 superseded by another sync; 10 cancelled or sync not allowed; 21
two-phone mode; otherwise 1
(A: `agents.AppServiceProviderHelpers.createResponseFromPayloadProcessingResult`). The PC must
answer the pushes while this request is still pending.

Windows uses it for a manual refresh and as a fallback (W: `ViewModels.MessagingNodeViewModel.RequestAllMessagesFromPhoneAsync`).

### 7.2 Type 1: fetch attachment bytes **[code-android] + [code-windows]**, not captured

Request (W: `MessagingRequest` second constructor; W: `Attachments.MissingPartViewModel`)

| Key | Type | Value |
|---|---|---|
| `subcontentTypes` | StringArray | `["messagesMmsMedia"]` |
| `requestedItems` | Int32 | 1 |
| `messagingMmsPartIds` | Int64Array | MMS part ids (from `mmsParts.partIds`). |
| `messagingRcsFileTransferMediaIds` | Int64Array | RCS file-transfer ids, instead of or in addition. |

Phone: pushes one or more `messaging` batches (`incremental` 1, same `correlationVector`, no
`sequenceNumbers`) whose `mmsParts` (or `rcsFileTransfers`) holds the requested items with bytes;
the 2 MiB cap of automatic sync is not applied here. Then answers the request with the sync
result as in 7.1. The id arrays `messagingSmsIds`, `messagingMmsIds`, `messagingConversationIds`
... are honoured here too (same reader as the metadata reply), so the PC can re-request
individual items.

### 7.3 Type 2: send a message

Request. W: `Communication.SendMessageRequest.BuildRequestMessage`; read by
A: `agents.MessageSendManager.buildFromMap`, `getRecipients`, `getSubscriptionId`. R:3718 **[wire]**
for the text-only, existing-thread case.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `requestType` | Int32 | yes | 2 |
| `tempId` | String | recommended | PC-chosen unique id of this send attempt (Windows: a GUID). The phone de-duplicates concurrent sends by it and uses it in the MMS transaction id. If absent the phone invents one. |
| `id` | **Int64** | recommended | PC-chosen number for this send (Windows: local row id, 1, 2, ...). Returned in `acks.ids`. Absent reads as -1. |
| `threadId` | **Int64** | for a reply | Existing conversation id. Omit for a new conversation (Windows omits it when it is -1). |
| `recipients` | StringArray | for a new conversation | Destination addresses. If absent and `threadId` is given, the phone takes the thread's recipients. Windows sends it only without a thread (and for one RCS special case). |
| `toAddresses` | String | no | Alternative to `recipients` when there is no thread: addresses joined with `,`. Windows never sends it. |
| `subscriptionId` | **Int32** | no | SIM to use, a value of `subscriptions.ids`. -1 or absent = the phone's default SMS subscription. |
| `body` | String | for SMS | Text. Windows omits the key when empty. An SMS without `body` fails with `result` 1. |
| `subject` | String | no | MMS subject. Windows never sends it. |
| `partCount` | Int32 | for attachments | Number of attachments. |
| `partNames` | StringArray | with parts | File name per attachment. |
| `partContentTypes` | StringArray | with parts | MIME type per attachment. |
| `partByteCounts` | UInt32Array (Windows) | with parts | Byte length per attachment. The phone accepts Int32Array as well. |
| `partBytes` | UInt8Array | with parts | All attachment bytes concatenated in order. |
| `partContentIds` | StringArray | no | Content id per attachment; default `""`. |
| `partUris` | StringArray | no | Instead of bytes (count 0): a `content`, `file`, `http` or `https` URI the phone reads itself. Windows never sends it. |

Types are exact: `id` and `threadId` as Int32, or `subscriptionId` as Int64, raise a cast error
on the phone and the reply is `result` 1 **[code-android]**. Attachments travel inline; there is
no separate upload.

Constraints and routing on the phone (A: `MessageSendManager.ensureCanSend`, `determineMessageType`; A: `agents.message.SmsSender`, `MmsSender`, `RcsSender`). The decompilation of `determineMessageType` is partly garbled; the conditions below are a reconstruction **[inferred]** where marked.

| Check | Result |
|---|---|
| Airplane mode on and Wi-Fi off | failure 1 |
| No SIM | failure 2 |
| No recipients resolvable | exception on the phone, `result` 1 without a reason |
| `subscriptionId` given but the thread requires a different one (RCS threads) | exception, `result` 1 without a reason |
| RCS send available, allowed by the PC and by the thread or recipients, within RCS size limits | sent as RCS |
| More than one recipient, or the recipient is an e-mail address, or any attachment | sent as **MMS** |
| Text needs more SMS segments than `smsMultipartToMmsTextThresholds`, or multipart SMS is disabled and the text needs more than one segment, or the text is longer than `smsToMmsTextLengthThresholds` | sent as **MMS** **[inferred]** |
| Otherwise | sent as **SMS** to the first recipient only |
| SMS: `maxMessageTextLengths` > 0 and text longer | failure 3 |
| MMS: disabled by carrier 5; group MMS disabled 6; too many recipients 7; no recipients 18; subject too long 8; audio not allowed 9; encoded message larger than `maxMessageSizes` 3; carrier transaction limit 10 | failure code |

The PC cannot choose SMS versus MMS explicitly. Long texts are split into SMS segments by the
phone (`SmsManager.divideMessage`); the PC sends the whole text in one `body`.

Reply (A: `MessagingRequestHandler.tryProcessRequest`; W: `Conversations.ViewModels.ConversationViewModel` send path)

| Outcome | Reply |
|---|---|
| Android reported every part as sent | `result` 0. No other key **[wire]** R:3721, 3.1 s after the request. |
| Known failure | `result` 1 and `sendMessageFailureReason` Int32. |
| Other error | `result` 1. |

The phone blocks up to 60 s per send waiting for Android's "sent" broadcast, so the PC must
allow well over 60 s for the reply. `result` 0 means handed to the radio network, not delivered:
the phone requests no delivery report and there is no later delivery or read status.

`sendMessageFailureReason` (W: `Communication.SendMessageFailureReason`; values produced by Android in parentheses)

| Value | Name | Value | Name |
|---|---|---|---|
| 0 | NoFailure | 10 | MMSTransactionSizeExceeded |
| 1 | AirplaneMode | 11 | Unknown (any other Android send error) |
| 2 | NoSim | 12 | ActionRequired |
| 3 | MessageSizeExceeded | 13 | Empty |
| 4 | MMSNotSupported | 14 | RcsSendUnavailable |
| 5 | MMSDisabled | 15 | PhoneTimeout (no "sent" result within 60 s) |
| 6 | MMSGroupMessageDisabled | 16 | RadioOff |
| 7 | MMSTooManyRecipients | 17 | NoService |
| 8 | MMSSubjectSizeExceeded | 18 | NoRecipients |
| 9 | MMSAudioNotAllowed | 19 | BluetoothNotConnected (proximity gate) |

How the sent message reaches the PC's store

1. While sending, the phone hides new non-inbox rows of that thread from its scans
   (A: `agents.message.SmsDataSource.freezeSentMessages`), so no intermediate outbox state leaks.
2. After the reply, the normal incremental push arrives **[wire]** R:3725, 1.6 s after R:3721:
   `smsMessages` with the real message (action 0, `messageTypes` 2, `toAddresses` set,
   `fromAddresses` `""`, `readFlags` true, real `messageIds` and `threadIds`), its conversation,
   its subscription, new `sequenceNumbers`, and `acks.ids` containing the request's `id`.
3. The PC shows a local placeholder from the moment of sending and removes it when its `id`
   appears in `acks.ids`. Nothing links the real message to `tempId`; the ack and the new row
   simply arrive in the same push. For a new conversation the real thread id is learned here.

The `messageAck` content type (`tempId`, `messageId`, `messageKind`, `threadId`, `resultCode`)
exists in both code bases but is not emitted on this path: every sender is built with the ack
flag off, and Windows documents its processor as Bluetooth-only
(A: `agents.MessageAckMessageBuilder`; W: `Processors.MessageAckProcessor`).

### 7.4 Type 3: mark a conversation as read **[code-android] + [code-windows]**, not captured

Request (W: `Communication.MarkConversationAsReadRequest`; A: `agents.MarkAsReadManager.markAsRead`)

| Key | Type | Meaning |
|---|---|---|
| `requestType` | Int32 | 3 |
| `threadId` | Int64 | Conversation id. Mandatory. |
| `timestamp` | Int64 | Date in ms of the newest message the PC has shown. Mandatory. |

Phone: if the thread has any message newer than `timestamp`, does nothing. Otherwise marks the
thread read through the OEM client. Reply `result` 0 in both cases, 1 on error.

Only effective when capability bit 8 (`settings.markAsReadAvailable`) is set; on other phones the
client is a no-op that still answers 0 (A: `appmanager.message.NullMarkAsReadClient`). The
captured phone reported it unavailable. When it works, the read state returns through the
normal incremental push (action 1).

### 7.5 What does not exist

| Operation | Status |
|---|---|
| Delete a message or a conversation from the PC | No request type, no handler. Deletions flow phone to PC only. |
| Mark a single message read (type 4), get one message (type 5) | Built by Windows, not handled by Android (`result` 2). |
| Edit, schedule, drafts, typing, reactions | Nothing in either code base. |

---

## 8. Minimum viable client

Assumes the session is up and the client is seen as an active `PL` remote app.

### 8.1 Always

1. In `/connect/v1` send `configuration` with `SequencedContentSyncs` true, `MessagingSync`
   true, `MessagingSend` true, `MessagingMassText` true, `MessagingRcsReceive` false,
   `MessagingRcsSend` false, and `sequenceNumbers` with Int64 `sms`, `mms`, `conversation`,
   `subscription` (stored values, or -1).
2. From the reply read `permissions.messaging`; if false, stop (optionally ask via `/permission`).
3. Register a handler for `/legacy/phonecontent` with `contentType` `messaging` and answer
   every such request.

### 8.2 (a) List conversations with their last message

| Step | Action |
|---|---|
| 1 | Connect with all four numbers -1. Expect the metadata message. |
| 2 | Reply `{result 0, contentType "messaging", contractVersion 3.99, correlationVector <copied>, itemCount <n>, messagingSmsIds <all>, messagingMmsIds <all>, messagingMmsPartIds [], messagingConversationIds <all>, messagingSubscriptionIds <all>}` with header `result: 0`. |
| 3 | For each content batch: upsert `subscriptions`, `canonicalAddresses`, `conversations`, `smsMessages`, `mmsMessages`, `mmsParts`; apply deletions; reply `{result 0}`. |
| 4 | On the batch that has `sequenceNumbers`, persist them. |
| 5 | Conversation list = threads that have at least one stored message, ordered by the newest message date; last message = that newest SMS or MMS (MMS text = its `text/plain` parts); unread = any incoming message with `readFlags` false; title = addresses resolved through `recipientIds` and `canonicalAddresses`, then through contacts if available. |

On later connects send the persisted numbers; expect either nothing or content-only batches.
A client with no persistence can send -1 every time and repeat steps 1 to 4.

### 8.3 (b) Show a thread

No further protocol. All SMS and MMS with that `threadIds` value, sorted by `dates`; outgoing
when the mailbox value is 2. Keep handling incremental pushes to stay current. MMS attachments
are optional: request part bytes with section 7.2 when the user opens one.

### 8.4 (c) Send an SMS

| Step | Action |
|---|---|
| 1 | Send `/chat/v1` with `contentType` `messaging`, `contractVersion` 3.99, `correlationVector`, `requestType` Int32 2, `tempId` <new GUID>, `id` Int64 <local counter>, `body` <text>, `subscriptionId` Int32 (-1 or a known id), the `configuration` object of 8.1, and either `threadId` Int64 (reply) or `recipients` StringArray with one address (new conversation). |
| 2 | Wait up to about 90 s. `result` 0 = sent; `result` 1 = failed, reason in `sendMessageFailureReason` if present. |
| 3 | The real message arrives in the next incremental push; drop the placeholder when `acks.ids` contains the `id`. |

---

## 9. Differences between the two code bases

| Topic | Windows | Android |
|---|---|---|
| `partByteCounts` | UInt32Array | reads as int array; Int32Array also accepted |
| Wanted RCS file-transfer ids in the metadata reply | key `messagingRcsFileTransferChecksums` | reads `messagingRcsFileTransferIds` |
| Request types 4 and 5 | built | unhandled |
| `messageAck` content | Bluetooth-only processor | builder exists, never triggered |
| `incremental` | ignored | set on content-only syncs |
| `syncID` | read to key a sync | never sent; `correlationVector` is used |
| `MmsImages` configuration key | never sent | read on every configuration update |
| Capability bit 2 (RCS receive) | forced on locally (`num \| 2`) | set only with the OEM extension |

---

## 10. Open questions

1. **Incoming message and MMS on the wire.** No capture has a newly received message, any MMS,
   or attachment bytes. Sections 4.6, 6 and 7.2 are code only.
2. **`PL` identity.** Pushes target active `PL` remote apps. Whether our single client is counted
   as one is the open question 1 of the session document; messaging adds nothing new to it.
3. **Lifetime of the "MMS media" flag.** The phone resets it to the value of `MmsImages`
   (default false) on every configuration it processes, including the `configuration` inside
   every `/chat/v1` request, and sets it from `subcontentTypes` on a type-0 request. With Windows
   it therefore seems to hold only until the next request. Whether sending `MmsImages` true in
   every configuration keeps inline attachments on is untested.
4. **`SyncSkipMetadataForAuto` true.** Would let a simple client skip the metadata round
   (everything arrives as action-0 content). Derived from code, never observed.
5. **Phone database reset.** If the phone's sequence database is recreated, its numbers restart
   and a PC holding larger numbers would receive an empty incremental sync with lower numbers.
   No recovery logic was found on the phone; how Windows detects it was not traced. A cautious
   client falls back to -1 when the phone's number is lower than its own.
6. **RCS.** Nothing observed. The metadata-reply key mismatch for file transfers, the exact
   condition under which the phone reads RCS ids from the reply (garbled decompilation), RCS
   send results and the provider-defined checksums are unverified.
7. **Subscriptions listed as deleted.** In P:785 the two subscription ids requested from the
   metadata round came back with action 2 while the same batch carried live subscriptions with
   action -1. Whether the ids differ or the by-id lookup fails on that phone was not determined
   (ids were not compared, to avoid handling values).
8. **Conversation count.** Why the phone lists far more conversations than the 30-day message
   window explains (thread date semantics on that phone) is unknown. Harmless, but the list is
   large.
9. **Missing keys in the metadata reply.** The phone's null handling for absent id arrays could
   not be read reliably; the spec says to always send them.
10. **Phone-side timeout** for an unanswered push, and whether the 50-message cap can strand a
    very large first sync, were not determined.
11. **Samsung-only fields.** `groupIds` semantics and the hidden/scheduled filters come from the
    OEM path; behaviour on non-Samsung phones (group id always -1) is code only.
12. **Permission request.** `permissionType` 2 for messaging on `/permission` follows from the
    flag numbering; Windows' own messaging permission handler in this build is the Bluetooth
    variant, so the relay-side prompt was not confirmed.
