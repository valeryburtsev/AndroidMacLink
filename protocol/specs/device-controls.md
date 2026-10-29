# Device controls: ring my phone, ringer mode and Do Not Disturb, media keys, open on phone

Implementation-grade specification of the Phone Link features in which the PC acts on the
phone. The reader implements them in Swift for a PC-side client that an Android phone running
Link to Windows (LTW) treats like Windows.

Revision 1, 2026-10-09.

Transport, envelopes, the DeviceResourceManager (DRM), publish/subscribe and `/connect/v1` are
specified in `session-clipboard-notifications.md` (called **SCN** below; sections 1, 2, 5, 7, 8)
and are not repeated here.

## 0. Sources, tags, and what is confirmed

| Abbreviation | Source |
|---|---|
| `A:` | Decompiled Link to Windows 1.26082.130.0 (jadx). `agents` = `com.microsoft.mmx.agents`, `am` = `com.microsoft.appmanager`. |
| `W:` | Decompiled Phone Link 1.26072.257.0, `corpus/windows/decompiled/`. Cited as assembly :: class.member. |
| `P:` | Recovered proto sources, `protocol/recovered/android/`. |
| `C-raw:` | `captures/vm-raw-2026-10-09/flows.jsonl`, record `seq`, read with `winphone-probe app-messages ... --shape` (structure only). |
| `S:` | This project's Swift sources under `app/Sources/WinPhoneCore/`. |

Every fact carries one of four tags: **[code-android]**, **[code-windows]**, **[wire]**,
**[inferred]**. Captured traffic was read for structure only; no captured value appears here.

What the capture contains for these features **[wire]** (C-raw, about 5.5 hours, one phone):

| Item | Seen | Records |
|---|---|---|
| `/ringmyphone` request | no | |
| `/devicestatus` with request type UPDATE | no | |
| APP `/command/devicestatus`, APP `/command/audio`, APP `/devicestatus` | no | |
| `/notifications` operation 5 (open on phone) | no | SCN limit 2 |
| `/devicestatus` GET and its answer | yes, once | 13 (request, type GET, 19-byte DRM message), 20 (answer, `response_type` success, 42-byte inner message) |
| Publish tag 8 (device status), phone to PC | yes, 33 times | 231, 336, 440 ... 5928; one every 600 s, each a 128-byte publish |
| `ringMyPhoneCapabilities` Int32 and `statusCapabilities` Int32 inside `capabilities` of the `/connect/v1` reply | yes | 163, 5136 |
| `ringerMode` Int32, `doNotDisturbStatus` Int32, `doNotDisturbRuleEnabled` Bool as top-level keys of phone APP messages | yes | all 67 `/legacy/phonecontent` pushes and both connect replies |

So the **commands in this document are code-only**. What is wire-confirmed is the reading side
(status values, the periodic publish) and the capability keys.

Second limit: the Windows process that speaks PLATFORM for the `WEA` role, Cross Device
Experience Host (CDEH), is not decompiled (SCN, limit 1). Everything said about a `WEA` sender
comes from the phone's handler and the proto, and is tagged accordingly.

## 1. Overview

| Feature | Sender on Windows | Carrier | Route or path | Message | Wire |
|---|---|---|---|---|---|
| (a) Ring my phone | `PL` (Phone Link) | PLATFORM, DRM | `/ringmyphone`, UPDATE | `RingMyPhoneRequestMessage` | no |
| (b) Ringer mode, DND, legacy | `PL` | APP value set | `/command/devicestatus` | `deviceStatusCommandType` + `deviceStatusCommandValue` | no |
| (b) Ringer mode, DND, protobuf | `WEA` (CDEH) | PLATFORM, DRM | `/devicestatus`, UPDATE | `DeviceStatusRequestMessage` | no (GET only) |
| (c) Media keys | `PL` | APP value set | `/command/audio` | `audioCommandValue` + `key` | no |
| (c) Volume | none over the relay | mirroring channel only | `/audio/setVolume` | section 4.6 | no |
| (d) Open the notification's app | `PL` | APP value set | `/notifications` | `operation` 5 + `key` | no |
| (d) Open an arbitrary app | none over the relay | mirroring only | section 5.3 | | no |

Phone Link itself sends DRM requests, not only CDEH **[code-windows]**: a request whose content
implements `IDrmContent` and whose headers carry `x-drm-resource-type` or `x-drm-resource-path`
plus `x-drm-resource-request-type` is routed to the DRM sender, provided the signed-in account
equals the device's account (W: YourPhone.Connectivity.YPP.Managed :: Communication.DrmRequestSender.CanSatisfySendCriteriaAsync,
SendRequestAsync). Those `x-drm-*` headers are internal to Windows and never reach the wire.

The phone does not look at the sender's client type in any handler of this document
**[code-android]** (the DRM handlers ignore their `dcgClientId` argument; the APP handlers
inherit A: agents.ScenarioRequestHandlerBase.handleAsync, which only looks up the sender for
telemetry). **[inferred]** each command can therefore be sent on either role's session; the
"sender" column says what Windows does.

Common preconditions for APP (value-set) commands **[code-android]** (A: agents.ScenarioRequestHandlerBase.handleAsync):

| Check | Outcome |
|---|---|
| Sync allowed (A: agents.AgentConnectivityManager.getSyncAllowed) | otherwise reply `result` 13 all features disabled, 21 two-phone mode, 8 metered connection (plus keys `wifiState` Bool, `syncOverMeteredConnection` Bool), 23 non-default user profile, 1 other; the handler returns **no response** when the connectivity manager is not initialised (A: agents.AgentConnectivityHelper.getSyncNotAllowedResponse) |
| `contractVersion` Double present and `floor` equal to 3 | otherwise `result` 3. The key is read with an unchecked cast, so it must be present. |
| Handler threw | `result` 1 |
| Handler returned nothing | `result` 2 |

Every APP reply is a value set with `result` Int32 and `contractVersion` Double 3.99
**[code-android]** (A: agents.AppServiceProviderHelpers.createAppServiceResponse). Result names:
SCN 7.5 (`ScenarioResult`).

Keys Windows adds to every legacy APP request **[code-windows]** (W: YourPhone.Connectivity.Managed :: RemoteAppClient.SendLegacyRequestAsync, SendKvpRequestImplAsync):
`isuserinitiated` Bool, `ignoreResponse` Bool, `transportType` Int32 0, `displayName` String,
`appVersion` String, `installationId` String, `contractVersion` Double 3.99. Envelope headers of
a PC APP request: `_requestId` (GUID), `_route`, `_rejectionVersion` `1`, no content type
**[wire]** (SCN limit 2, section 2.3).

Common failure cases for DRM commands (SCN 5.2) **[code-android] + [code-windows]**:

| Case | What the PC sees |
|---|---|
| No handler for the path on the phone | `DeviceResourceManagerResponseMessage{response_type 2}`, empty payload (A: agents.ypp.ambientexperience.deviceresource.signalr.SignalRDeviceResourceManager.respondWithNoCallbackErrorAsync). Windows maps it to `UnsupportedResourceType`. |
| Handler threw | No reply; the exception is rethrown after logging (A: SignalRDeviceResourceManager.invokeRegisteredCallbackAsync; agents.transport.ResourceRequestCallbackBase.processRequest). The PC times out. |
| Platform rejection | `_rejectedReason` `AllSyncDisabled` / `MeteredSyncDisabled` / `NotSubscribedToRoute` map to `RemoteAllSyncDisabled` / `RemoteMeteredSyncDisabled` / `UnsupportedResourceType` (W: YourPhone.YPP :: DeviceResourceManagement.DeviceResourceManagerUtils). When the phone emits the first two was not traced. |
| No session with the phone | `DisconnectedFromPeer` locally (W: YourPhone.YPP :: DeviceResourceManagement.SignalR.SignalRDeviceResourceProvider.SendRequestAsync). |

---

## 2. (a) Ring my phone

### 2.1 Sender, gate, discovery

| Fact | Tag and pointer |
|---|---|
| Sent by Phone Link (`PL`) through the DRM. | [code-windows] W: YourPhone.Devices.Managed :: ViewModels.Indicators.RingMyPhoneIndicatorViewModel.SendRingRequestAsync |
| Whether CDEH (`WEA`) also sends it is unknown. | [inferred] CDEH not decompiled |
| The phone advertises support in the `/connect/v1` reply: `capabilities` Object, key `ringMyPhoneCapabilities` Int32, bit 1 = `RING_MY_PHONE_SUPPORTED`. The phone always sets every bit it knows, so the value is the constant 1. | [code-android] A: agents.ConnectionRequestHandler (key literal); am.ringmyphone.api.RingMyPhoneCapabilities |
| The key is present with type Int32. | [wire] C-raw: 163, 5136 |
| Windows shows the button only when all hold: the stored value is a defined enum member (0 or 1) with bit 1; remote feature `EnableRingMyPhonePL`; device platform Android; the signed-in account equals the device's account. | [code-windows] W: YourPhone.Devices.Managed :: Sync.SyncDeviceStatusEstablishConnectionPayload.ApplyCapabilities; RingMyPhoneIndicatorViewModel.UpdateIsSupported |
| Stopping from the PC is a separate Windows feature flag, `EnableStopRingMyPhonePL`. | [code-windows] RingMyPhoneIndicatorViewModel.isStopRingFromPCEnabled, OnFlyoutDismissClicked |
| No DCG capability string exists for this feature (the phone's list has `RINGER_MODE` but nothing for ringing). | [wire] SCN section 1 (phone capability list) |
| The phone registers the handler unconditionally with its other DRM handlers; no experiment or permission gates it. | [code-android] A: am.DaggerMainApplication_HiltComponents_SingletonC (handler set); agents.transport.DeviceResourceManagerWrapper |

### 2.2 Request

PLATFORM request on `/DeviceResourceManager` (headers and envelope: SCN 2.3, 5.2).

`DeviceResourceManagerMessage`

| # | Field | Value | Tag and pointer |
|---|---|---|---|
| 1 | `resource_type` | 7 `RING_MY_PHONE` as Windows sends it. 4 `UNKNOWN` works equally, because the path selects the handler. | [code-windows] header `x-drm-resource-type` = `RingMyPhone`, W: YourPhone.YPP :: DeviceResourceManagement.DeviceResourceManagerUtils.ToProtobuf. [code-android] A: SignalRDeviceResourceManager.parseIncomingRequest |
| 2 | `request_type` | 2 `UPDATE` | [code-windows] header `x-drm-resource-request-type` = `Update`. [code-android] required, section 2.5 |
| 3 | `payload` | serialized `RingMyPhoneRequestMessage` | [code-windows] W: YourPhone.Devices.Managed :: Communication.RingMyPhoneContent |
| 4 | `resource_path` | `/ringmyphone` | [code-windows] W: YourPhone.YPP :: DeviceResourceManagement.DeviceResourceManager.SendRequestAsync builds `"/" + lowercase(type name)`. [code-android] A: am.ringmyphone.RingMyPhoneResourceRequestHandler.getResourcePath |

`RingMyPhoneRequestMessage` (P: ring_my_phone/v1/update.proto; identical descriptor in
`protocol/recovered/windows/YourPhone.Devices.Protocol/ring_my_phone/v1/update.proto`) **[code-android] + [code-windows]**

| # | Field | Type | Values |
|---|---|---|---|
| 1 | `request_type` | enum `RingMyPhoneRequestType` | 0 `UNSPECIFIED`, 1 `ON` (start ringing), 2 `OFF` (stop ringing) |

Serialized: ON is the two bytes `08 01`, OFF is `08 02` **[inferred]** (protobuf encoding of the
schema above).

Windows request options: reply timeout 120 s, user initiated **[code-windows]**
(RingMyPhoneIndicatorViewModel.DefaultRequestTimeoutInSeconds).

### 2.3 Answer and follow-up

`DeviceResourceManagerResponseMessage{payload = RingMyPhoneResponseMessage, response_type 1}`.

`RingMyPhoneResponseMessage`

| # | Field | Type | Values |
|---|---|---|---|
| 1 | `status` | enum `RingMyPhoneResponseStatus` | 0 `UNSPECIFIED`, 1 `OK`, 2 `FEATURE_NOT_SUPPORT`, 3 `UNRECOGNIZED_PAYLOAD`, 4 `INVALID_REQUEST_TYPE` |

| Fact | Tag and pointer |
|---|---|
| The answer is produced synchronously, before any sound: `OK` means "request accepted", not "the phone is audible". | [code-android] A: RingMyPhoneResourceRequestHandler.handleRequestInternal; am.ringmyphone.RingMyPhoneManager.startRingMyPhone starts playback in a separate coroutine |
| There is **no push** when ringing ends, whether by timer or by the user on the phone. | [code-android] RingMyPhoneManager.stopAll sends only a local broadcast |
| Windows never parses `status`. It treats transport success as success and runs its own countdown of 20 steps of 1000 ms, then shows "not ringing". | [code-windows] RingMyPhoneIndicatorViewModel.CountdownValue, TimerInterval, OnTimedEvent |
| When an OFF request fails to send, Windows restores the ringing state and restarts its countdown. | [code-windows] SendStopRequestAsync (`restoreOnFailure`), RestoreRingingState |
| On the PC the first click on the dismiss button while ringing only asks for confirmation; the second sends OFF. | [code-windows] OnFlyoutDismissClicked (`hasAcknowledgedRing`) |

### 2.4 What the phone does

All **[code-android]**, A: am.ringmyphone.RingMyPhoneManager, RingMyPhoneAudioManager,
RingMyPhoneNotificationManager, RingMyPhoneNotificationReceiver, RingMyPhoneRingingPageActivity,
unless tagged otherwise.

ON

1. (Re)starts a timer of `RING_MY_PHONE_DURATION` = 20000 ms; on expiry everything is stopped.
2. If audio is already playing it stops here: a repeated ON only **extends** the ring to 20 s
   from the new request.
3. Otherwise it starts playback asynchronously and creates a fresh session id (telemetry only).
4. If the LTW app is in the foreground it opens a full-screen "ringing" page with a stop button;
   otherwise, if LTW may post notifications, it posts a sticky high-priority notification
   (tag `ring_my_phone_notification`, id 110, category `alarm`) with a stop action. If LTW is in
   the background and may not post notifications there is no on-phone stop control.

Playback

| Step | Detail |
|---|---|
| Sound source | Default alarm sound (`RingtoneManager` type 4); if none, default ringtone (type 1); if neither, **nothing plays and nothing vibrates**, yet the answer was already `OK`. |
| Player | `MediaPlayer`, looping, audio attributes usage 4 (alarm) and content type 2, partial wake lock. |
| Volume | Reads the alarm stream (stream 4) volume, sets it to the stream maximum, and restores the saved value on stop. |
| Order | One-shot vibration of `VIBRATE_TIME` = 3000 ms at default amplitude, a 3000 ms wait, then the sound starts. So about 3 s of vibration followed by about 17 s of sound. |

Stop, any of

| Trigger | Path |
|---|---|
| OFF request | `stopRinging`: cancels the playback job and the timer, then stops |
| 20 s timer | `stopAll` |
| Stop button on the ringing page, or leaving the page | activity `onDestroy` calls `stopRinging` |
| Stop action on the notification, or swiping it away | broadcast actions `CLICK_TO_STOP_RINGING`, `SWIPE_TO_STOP_RINGING` |

Stopping cancels the vibration, stops and releases the player, restores the alarm volume,
closes the ringing page (local broadcast `FINISH_ACTIVITY`) and removes the notification. An OFF
when nothing is ringing is harmless and answers `OK`.

Silent mode and Do Not Disturb

| Fact | Tag |
|---|---|
| The code never touches the ringer mode or the interruption filter; it relies on the alarm stream at maximum volume. | [code-android] |
| Ringer mode silent or vibrate does not mute the alarm stream, so the phone is audible. | [inferred] Android audio policy, not LTW code |
| Under Do Not Disturb the result follows the user's policy: alarms pass in the default priority mode and in "alarms only", and are muted in "total silence". LTW does not override it. | [inferred] Android audio policy |
| Vibration is requested without audio attributes and may be suppressed by system vibration settings. | [inferred] |

Permissions on the phone: none is checked or requested. Posting the stop notification needs
LTW's notification permission; ringing does not **[code-android]**
(RingMyPhoneManager.showRingMyPhoneNotification). The handler does not check the sync-allowed
state either, unlike `/devicestatus` **[code-android]**.

### 2.5 Failure cases

| Case | Answer | Tag and pointer |
|---|---|---|
| DRM `request_type` other than UPDATE | `status` 2 `FEATURE_NOT_SUPPORT` | [code-android] RingMyPhoneResourceRequestHandler.handleRequestInternal |
| Payload is not a parseable protobuf | `status` 3 `UNRECOGNIZED_PAYLOAD` | [code-android] same, `tryParse` |
| `request_type` 0, absent (empty payload) or unknown | `status` 4 `INVALID_REQUEST_TYPE` | [code-android] same |
| Phone build without the handler | DRM `response_type` 2 | [code-android] section 1 |
| No default alarm or ringtone, or the player failed to start | `status` 1 `OK`, silent phone | [code-android] RingMyPhoneAudioManager.play |
| Transport failure, timeout | no answer | section 1 |

---

## 3. (b) Ringer mode and Do Not Disturb

Two independent commands reach the same Android calls. They differ in carrier, in how failures
are reported, and in which Windows process uses them.

### 3.1 Shared model: values the phone reports

| Quantity | Values | Tag and pointer |
|---|---|---|
| Ringer mode | Android `AudioManager` ringer mode: 0 silent, 1 vibrate, 2 normal. **-5 = not supported**, reported when the OEM layer says the phone has a hardware three-stage slider. | [code-android] A: agents.DeviceStatusBuilderHelper.getRingerMode, isRingModeSupported, addDeviceIndicatorsToMap. [code-windows] W: YourPhone.Devices.Managed :: Indicators.RingerMode (`NotSupported` -5, `Silent` 0, `Vibrate` 1, `Normal` 2; -4 to -2 are local "turning" states, -1 unknown) |
| Do Not Disturb | Android current interruption filter: 0 unknown, 1 all (DND **off**), 2 priority, 3 none, 4 alarms (2 to 4 = DND **on**). | [code-android] DeviceStatusBuilderHelper.getDoNotDisturbStatus; A: agents.DoNotDisturbUtils.isAndroidDndEnabled. [code-windows] Indicators.DoNotDisturbStatus |
| DND rule enabled | Bool. False when LTW has notification-policy access and an automatic zen rule whose id starts with `implicit` exists and is disabled; true otherwise. Sent only while the phone experiment for Android 15 DND is on. When false the phone refuses to change DND. | [code-android] DoNotDisturbUtils.isAppRuleEnabled; DeviceStatusBuilderHelper.isAndroid15DoNotDisturbEnabled. P: device_info/v1/status.proto, comment on field 18 |

Where they appear

| Carrier | Names | Tag |
|---|---|---|
| Value set (connect reply, every `/legacy/phonecontent` push) | `ringerMode` Int32, `doNotDisturbStatus` Int32, `doNotDisturbRuleEnabled` Bool; present only when the PC sent `DeviceIndicators` true in `/connect/v1` `configuration` | [code-android] DeviceStatusBuilderHelper.addDeviceInfoToMap. [wire] names and types, C-raw (section 0) |
| Protobuf `DeviceStatus` (P: device_info/v1/status.proto; all fields SCN 5.5) | 5 `do_not_disturb_status` int32, 10 `ringer_mode` int32, 18 optional `do_not_disturb_rule_enabled` bool (absent reads as enabled) | [code-android] DeviceStatusBuilderHelper.buildResponseMessage. [wire] the message decodes from C-raw: 20 and from every tag 8 publish |

### 3.2 Sender, gate, discovery

| Fact | Tag and pointer |
|---|---|
| Phone Link (`PL`) uses only the value-set command `/command/devicestatus`. It contains no code for the protobuf set requests. | [code-windows] W: YourPhone.Devices.Managed :: Utilities.DeviceStatusManager.SendDeviceStatusCommandInnerAsync; no reference to `DeviceStatusRequestMessage` anywhere in the decompiled assemblies |
| The protobuf command (`/devicestatus` UPDATE) belongs to CDEH (`WEA`): the proto's C# namespace is `CrossDevice.Devices.Protocol.V1` and its comment on field 18 names CDEH as the consumer. | [code-android] P: device_info/v1/status.proto. [inferred] that CDEH sends the set requests; never seen on the wire |
| Phone-side capability strings in DCG device info: `DEVICE_STATUS` when experiment `LTW_ENABLE_DEVICE_STATUS_PUBLISH` is on; `RINGER_MODE` when that experiment is on **and** the phone is not a three-stage-slider device. | [code-android] A: am.devicestatus.DeviceStatusModule. [wire] both strings in the phone's registered list, SCN section 1 |
| How a `WEA` client learns support: `RINGER_MODE` in the phone's capability list (from `GetDeviceInfoList`), and `ringer_mode` not equal to -5 in the status. | [inferred] from the two facts above; CDEH's actual test is unknown |
| How `PL` learns support: the mere presence of `ringerMode` / `doNotDisturbStatus` in a phone message sets the `RingerIndicator` (0x80) / `DoNotDisturbIndicator` (0x20) bits of its stored status capabilities; a ringer value of -5 hides the ringer button. | [code-windows] W: YourPhone.Devices.Managed :: Data.DeviceStatusPayloadHelper.ApplyDeviceStatus; ViewModels.Indicators.RingerModeIndicatorViewModel.UpdateStatus; YourPhone.AppCore.Managed :: StatusCapabilities |
| Windows sends neither command unless the phone reported notification-listener access (`permissions.notifications` in the connect reply); otherwise it shows a hint and offers to request permission type 64 (SCN 7.6). | [code-windows] RingerModeIndicatorViewModel.ToggleRingerIndicator; DoNotDisturbIndicatorViewModel.TeachingTipToShow |
| Reason: Android grants notification-policy access to an app with an enabled notification listener, and both silent mode and DND need that access. | [inferred] Android platform behaviour. [code-android] consistent with DoNotDisturbUtils.getDoNotDisturbSettingsIntent, which opens the listener settings when policy access is missing |
| For DND Windows also requires `doNotDisturbRuleEnabled` true (when its feature `Android15DoNotDisturb` is on, default on); otherwise it offers command type 9. | [code-windows] DoNotDisturbIndicatorViewModel.TeachingTipToShow, SendLaunchDoNotDisturbSettingsCommand |
| The phone checks no capability of the PC before serving either command. | [code-android] both handlers, sections 3.3 and 3.4 |

### 3.3 Value-set command: APP route `/command/devicestatus` (`PL`)

Request (W: YourPhone.Devices.Managed :: Utilities.DeviceStatusCommandRequest.BuildRequestMessage;
A: agents.DeviceStatusCommandRequestHandler.tryProcessRequest)

| Key | Type | Value | Tag |
|---|---|---|---|
| `contentType` | String | `deviceStatusCommand` | [code-windows] W: YourPhone.AppCore.Managed :: MediaTypeEx. [code-android] A: agents.MediaType.toString |
| `deviceStatusCommandType` | Int32 | table below | [code-windows] + [code-android] |
| `deviceStatusCommandValue` | Int32 | per type | [code-windows] + [code-android] |
| `correlationVector` | String | trace id | [code-windows] |
| common keys | | section 1; Windows sends `isuserinitiated` true here | [code-windows] DeviceStatusManager (`IsUserInitiated = true`) |

The phone reads both integers with unchecked casts to Int32; a missing key or another variant
type ends in `result` 1 **[code-android]**.

`deviceStatusCommandType` (same numbering on both sides: W: Indicators.DeviceStatusCommandType;
A: DeviceStatusCommandRequestHandler.DeviceStatusCommandTypes)

| Type | Name | `deviceStatusCommandValue` | Phone action | Reply `result` |
|---|---|---|---|---|
| 0 | None / NOT_VALID | | nothing | 0 |
| 1 | Bluetooth | 12 = turn on, anything else = turn off | enables the adapter if its state is 10, disables it if 12, when LTW holds the Bluetooth permission | 0 |
| 2 | DoNotDisturb | target interruption filter: **1 = DND off, 2 = DND on** (3, 4 are passed through) | `NotificationManager.setInterruptionFilter(value)` | 0 done; **7** no notification-policy access; **14** the app's DND rule is disabled |
| 3 | Ringer | **0 silent, 1 vibrate, 2 normal** | `AudioManager.setRingerMode(value)`, no checks | 0; **1** if Android threw (for example `SecurityException` without policy access) |
| 4 | AudioIndicator | | nothing on the phone | 0 |
| 5 | SyncOverMeteredConnection | 0 or 1 | stores the setting; processed even while sync is disabled | 0 or the sync-disabled code |
| 6 | LtwUpdateGentle | | update reminder | 0 |
| 7 | EnableLtw | 0 or 1 | 1 re-enables features; processed even while sync is disabled | 0 or the sync-disabled code |
| 8 | A2DMigrationTermsReviewGentle | | migration notice | 0 |
| 9 | LaunchDoNotDisturbSettings | 0 | when the Android 15 DND experiment is on: opens the DND settings screen (or the listener settings when policy access is missing); if a background launch is refused, posts a notification leading there | 0 |

All rows **[code-android]** A: DeviceStatusCommandRequestHandler.tryProcessRequest, handleAsync;
agents.DeviceStatusCommandHelper; DoNotDisturbUtils.setAppRuleInterruptionFilter, launchDndSettings.
What Windows sends **[code-windows]**: Ringer cycles normal to vibrate to silent to normal
(RingerModeIndicatorViewModel.OnActionIndicatorClickedAsync); DoNotDisturb sends 2 when the
current status is 1 and 1 otherwise (DoNotDisturbIndicatorViewModel.OnActionIndicatorClickedAsync).

Other replies: wrong `contentType` gives `result` 1; the common gates of section 1 apply
**[code-android]**.

Windows ignores the reply except for telemetry **[code-windows]** (DeviceStatusManager). It shows
a transitional state and waits for the status push to confirm the change. Without a push it
puts the button back to the previous state: after 20 s for the ringer, after 5 s for DND. For a
DND "off" that was not confirmed, and while the stored status is not 1, it also shows a failure
dialog that offers command type 9 (RingerModeIndicatorViewModel.ToggleRingerIndicator;
DoNotDisturbIndicatorViewModel.StartDndRequestTimeoutTimer, CancelIndicatorLoadingState).

### 3.4 Protobuf command: DRM path `/devicestatus`, UPDATE (`WEA`)

`DeviceResourceManagerMessage{resource_type 4, request_type 2 UPDATE, resource_path "/devicestatus", payload}`
**[code-android]** (A: agents.deviceinfo.DeviceStatusResourceRequestHandler.getResourcePath,
handleRequestAsync). There is no legacy resource type for device status, so the path is required.

`DeviceStatusRequestMessage` (P: device_info/v1/status.proto) **[code-android]**

| # | Field | Type | Values |
|---|---|---|---|
| 1 | `request_type` | optional enum `DeviceStatusRequestType` | 0 `UNSPECIFIED`, 1 `GET`, 2 `SET_DO_NOT_DISTURB_ON`, 3 `SET_DO_NOT_DISTURB_OFF`, 4 `SET_RINGER_NORMAL`, 5 `SET_RINGER_VIBRATE`, 6 `SET_RINGER_SILENT` |

Serialized, the request is two bytes: `08 02` ... `08 06` **[inferred]** (protobuf encoding).

Phone action per value **[code-android]** (DeviceStatusResourceRequestHandler.handleUpdateRequest)

| `request_type` | Action |
|---|---|
| 2 | `setInterruptionFilter(2)` (priority), through the same routine as command type 2 |
| 3 | `setInterruptionFilter(1)` (all) |
| 4 | `setRingerMode(2)` |
| 5 | `setRingerMode(1)` |
| 6 | `setRingerMode(0)` |
| 0, 1, absent, unknown | none; answer status 8 |

Answer: `DeviceStatusResponseMessage{1 status, 2 info}`. For every UPDATE except the
sync-disabled case, `info` is a full `DeviceStatus` read **after** the attempt, so a successful
answer already carries the new state **[code-android]** (DeviceStatusResourceRequestHandler.buildDndResponse).

`DeviceStatusResponseStatus` as used by this handler **[code-android]**

| Status | When |
|---|---|
| 1 `OK` | change applied (or GET served) |
| 5 `SYNC_DISABLED` | the phone's sync-allowed check failed; `info` absent; applies to GET and UPDATE |
| 6 `FEATURE_NOT_SUPPORTED` | no `AudioManager`; a non-security runtime error from `setRingerMode`; DND refused because the app's DND rule is disabled |
| 7 `UNRECOGNIZED_PAYLOAD` | payload is not a parseable protobuf |
| 8 `INVALID_REQUEST_TYPE` | `request_type` not 2 to 6 |
| 9 `NEEDS_PERMISSION` | no notification-policy access (DND), or `SecurityException` from `setRingerMode`. The phone also starts its own permission flow for `PermissionTypes.DO_NOT_DISTURB` (A: agents.permissions.PermissionsOrchestrator.requestPermissionsAsync). |
| 2, 3, 4 | defined in the proto, never produced here |

DRM request types other than GET and UPDATE make the handler throw, so there is no reply
**[code-android]** (handleRequestAsync, default branch; section 1).

GET on the same path returns status 1 with `info`; the payload of a GET is not read, so
`request_type` 1 is never needed **[code-android]** (handleGetRequest). **[wire]** Windows sends
GET with no payload (C-raw: 13; SCN 4.1). The first GET also starts the phone's 600 s publish
timer (section 3.5).

The phone refuses nothing on the grounds of `ringer_mode` -5: a set-ringer request on a
three-stage-slider phone is passed to Android as is **[code-android]**. **[inferred]** the PC
must not offer the control when the status says -5.

A PC that needs to ask for the DND permission ahead of time has the DRM path `/permissions`
with `PermissionsRequestMessage{feature_permissions [5]}`
(`FEATURE_PERMISSIONS_DO_NOT_DISTURB`; P: permissions/v1/permissions_message.proto;
A: agents.permissions.PermissionsRequestHelper) **[code-android]**; its flow is outside this
document and was not traced.

### 3.5 Follow-up pushes after a change

The phone listens for Android's own change broadcasts, so pushes follow **any** change,
whoever caused it **[code-android]** (A: agents.DeviceStatusChangeReceiver.onReceive; actions
`android.media.RINGER_MODE_CHANGED`, `android.app.action.INTERRUPTION_FILTER_CHANGED`, and on
API 30+ with the Android 15 DND experiment `android.app.action.AUTOMATIC_ZEN_RULE_STATUS_CHANGED`).

| Push | To | Condition | Content |
|---|---|---|---|
| APP `/legacy/phonecontent`, `contentType` `deviceStatus` | active `PL` remote apps | the PC's connect `configuration` had `DeviceIndicators` true and, for a ringer change, `DeviceIndicatorsVolume` true; for a DND change, `DeviceIndicatorsDND` true | common push keys (SCN 7.2) plus `batteryPercent`, `batteryCharging`, `batteryPowerSave`, `bluetoothState`, `doNotDisturbStatus`, `doNotDisturbRuleEnabled`, `networkOperator`, `networkSignalStrength`, `networkSignalStrengthMax`, `mobileDataStatus`, `ringerMode`, `wifiSignalLevel`, `wifiState`, `networkDataType`, `syncOverMeteredConnection`, `airplaneMode`, `networkIndicatorApiSupport`, `bluetoothName` |
| PLATFORM `/Context/Publish`, tag 8 | every partner with a session | always, for these three broadcasts | `MsaepMessage{message_tag 8, payload = PubSubPayload{additional = DeviceStatusResponseMessage{status 1, info}}}` |

| Fact | Tag and pointer |
|---|---|
| Value-set push builder and its keys. | [code-android] A: agents.DeviceStatusMessageBuilder; DeviceStatusBuilderHelper.addDeviceInfoToMap, addBluetoothNameToMap |
| No dedicated `deviceStatus` push is in the capture (no message carries `bluetoothName`); the same status keys ride on every other push. | [wire] C-raw, section 0 |
| PC answer to the value-set push: `{result 0}`. | [code-windows] W: YourPhone.Devices.Managed :: Indicators.DeviceStatusProcessor.ProcessItem |
| Tag 8 body is `DeviceStatusResponseMessage` in `additional`. | [code-android] A: agents.deviceinfo.DeviceStatusPublisher.publishDeviceStatus; agents.transport.BaseCloudPublisher. [wire] the 33 publishes decode that way |
| Tag 8 is also published every 600 s once any PC has sent a GET (first one 600 s after that GET), until no trusted device remains. | [code-android] DeviceStatusResourceRequestHandler.ensureSchedulerInitialized, onTrustedDeviceStateChanged. [wire] 33 publishes 600 s apart, C-raw: 231 ... 5928 (5048 is about 50 s late) |
| PC answer to a publish: `text/json` `{}`. | [wire] SCN 5.3 |
| Side effect: when the PC enabled `DeviceIndicators` and `DeviceIndicatorsDND` and the phone's DND goes off by any means, the phone also sets its own filter to 1. | [code-android] DeviceStatusChangeReceiver.onReceive, last block |
| A `PL` client can ask for a fresh value-set status with APP `/devicestatus`: `contentType` `deviceStatus`, `correlationVector`, `relatedCorrelationIds` StringArray of one, `subcontentTypes` StringArray [`deviceStatus`]; the phone multicasts the push above and replies with the mapped sync result (wrong `contentType`: `result` 2). | [code-windows] W: YourPhone.Devices.Managed :: Communication.DeviceStatusRequest. [code-android] A: agents.DeviceStatusRequestHandler |

Note **[code-android] + [code-windows]**: Android writes `batteryPowerSave`, Phone Link reads
`batteryPowersave` (DeviceStatusPayloadHelper.BatteryPowerSaveKey). Not a concern for a client
that reads the phone's spelling.

### 3.6 What the phone does, and permissions

| Topic | Fact | Tag and pointer |
|---|---|---|
| Ringer | Plain `setRingerMode`. Nothing else changes; in particular LTW does not touch DND. | [code-android] DeviceStatusCommandHelper.sendRingerModeCommand; DeviceStatusResourceRequestHandler.handleSetRingerMode |
| Ringer permission | Android refuses changes into or out of silent without notification-policy access (`SecurityException`). Protobuf path: status 9. Value-set path: `result` 1. | [code-android] handlers. [inferred] the Android rule itself |
| DND | `setInterruptionFilter` with 2 (on) or 1 (off) from LTW's context. On Android 15 and later this drives LTW's own implicit zen rule rather than the global switch, hence the "rule enabled" flag. | [code-android] DoNotDisturbUtils.setAppRuleInterruptionFilter. [inferred] the Android 15 semantics, supported by the proto comment on field 18 |
| DND order of checks | rule disabled gives 14 (value set) or 6 (protobuf); then no policy access gives 7 or 9; then the call. | [code-android] DoNotDisturbUtils.setAppRuleInterruptionFilter; DeviceStatusResourceRequestHandler.handleSetDndResult |
| DND off limits | Setting filter 1 only releases LTW's own rule. If another rule or the user's manual DND is active the reported status stays above 1. | [inferred] from the Android 15 rule model and from Windows' failure dialog (section 3.3) |

---

### 3.7 Sync over mobile data

Phone Link's connection card has a switch "Sync over mobile data". It is a setting on the phone
(A: agents.DeviceData.getMeteredConnectionSetting), also offered in Link to Windows' own
settings, and one value serves every computer the phone is linked to.

- **Effect** **[code-android]** (A: agents.AgentConnectivityManager.getSyncAllowed): sync is
  allowed when the phone has an unmetered network, or a metered one and the setting is on. With
  the setting off on a metered network (mobile data, also a Wi-Fi marked as metered) the relay
  connection stays up, but requests are answered with `result` 8 plus `wifiState` and
  `syncOverMeteredConnection`, and the phone sends no content pushes.
- **Reading it**: field 14 `sync_over_metered_connection` of the status message, and key
  `syncOverMeteredConnection` in the value-set status (W: Connectivity.Managed ::
  PhoneContentHandler). The recorded status has no field 14, which is how the format writes
  false **[capture]**; Phone Link showed the switch as off for that phone.
- **Changing it** **[code-windows]** (W: Devices.Managed :: SyncOverMeteredConnectionService):
  command type 5 of 3.3 with value 1 or 0. `result` 0 is success; `result` 8 is success when
  switching off (the phone is on mobile data and now refuses). Windows then takes the new value
  as current without waiting for a report, and after switching on asks for a new sync session.
- **From the phone**: when changed in Link to Windows, the phone pushes `phoneCommand` type 0
  with `syncOverMeteredConnection` Bool (A: agents.phonecommand.PhoneCommandCoordinator).

The Mac client has the switch in Settings, General, and says so in the sidebar while the phone
is on mobile data with it off. Since the phone is silent in that state, the sign taken for it
is a refusal: any answer rejected with `MeteredSyncDisabled`, or a value-set answer with
`result` 8 or 12 (`PeerMessenger.onMeteredRefusal`). The hint goes when a full status says the
phone is on another network again. Not tried live.

## 4. (c) Media controls

### 4.1 Model

The phone exposes no media-session API. "What is playing" is a media-style **notification**
pushed over the notification sync (SCN section 7), and a transport command names that
notification by its key **[code-android] + [code-windows]** (A: agents.notifications.requestsHandlers.AudioCommandRequestHandler;
W: YourPhone.Audio :: Managers.NotificationAudioSessionManager, Session.NotificationPhoneAudioSession).

### 4.2 Sender, gate, discovery

| Fact | Tag and pointer |
|---|---|
| Sent by Phone Link (`PL`) on APP route `/command/audio`. | [code-windows] W: YourPhone.Audio :: ViewModels.AudioControlsViewModel.SendAudioCommandRequestAsync; AudioConstants.AudioCommandsRoute |
| No protobuf or `WEA` counterpart exists: the protobuf `NotificationInfo` (SCN 7.7) has no playback state and no DRM path takes media commands. | [code-android] P: notification/v1/notification.proto; list of DRM handlers |
| The PC must send `AudioInfoSyncEnabled` true in `/connect/v1` `configuration`; otherwise the phone filters media notifications out. The flag reaches the listener process when the phone's agent service next initialises. | [code-android] A: agents.ConnectionRequestHandler (key literal); agents.AgentService; agents.notifications.PhoneNotificationsPublishFilter.isMediaStyleNotificationFiltered |
| Windows sets that flag only if the phone's `capabilities.registeredPermissionTypes` has bit 0x4000 (`AudioControl` = permission type 15). | [code-windows] W: YourPhone.Notifications.Managed :: Utilities.NotificationsFeatures.IsAudioInfoSyncEnabled, Sync.SyncNotificationsEstablishConnectionPayload; YourPhone.Devices.Managed :: Store.Device.AudioControlDeviceCapability. [code-android] A: agents.PermissionTypes.AUDIO_CONTROL |
| Windows shows the player only when also: its local audio toggle is on, the phone reported notification-listener access, and features are not disabled. | [code-windows] AudioControlsViewModel.IsAudioPlayerSupportedAndEnabled |
| On the phone, notification-listener access is the only permission involved: the command is executed inside the listener service using the session token found in the notification. | [code-android] A: agents.PhoneNotificationsListenerService.commandMediaSession |

Which notifications are media sessions

| Fact | Tag and pointer |
|---|---|
| The phone publishes a media notification when its template is `android.app.Notification$MediaStyle`, it carries the extra `android.mediaSession`, the session's playback state is 0, 1, 2 or 3, and the session supports play (action bit 4) or pause (bit 2). Such a notification bypasses the "must be clearable" rule. | [code-android] PhoneNotificationsPublishFilter.isSupportedMediaStyleNotification; A: agents.notifications.AudioCommandHelper.getIsSupportedMediaSession, isSupportedPlaybackState, isPlayPauseSupported |
| In the notification JSON a media session has `notificationClass` 2, `playbackState` (number), and `largeIcon` / `smallIcon` (Base64 JPEG): album art and app icon. Title and text come from `title` and `text`. | [code-android] A: agents.notifications.models.NotificationItem.toJson, getLargeIcon, getSmallIcon; SCN 7.3. [code-windows] W: YourPhone.Notifications.Managed :: NotificationEntity.IsMediaStyleNotification (reads `notificationClass`); NotificationPhoneAudioSession |
| `playbackState` is Android's `PlaybackState` value: 0 none, 1 stopped, 2 paused, 3 playing, 4 fast forwarding, 5 rewinding, 6 buffering, 7 error, 8 connecting, 9 skipping to previous, 10 skipping to next, 11 skipping to queue item. | [code-android] AudioCommandHelper.getMediaPlaybackState. [code-windows] W: YourPhone.Audio :: Utils.PlaybackState (same numbering) |
| The schema has no position, duration, volume or shuffle/repeat. | [code-android] NotificationItem.toJson |

### 4.3 Request: APP route `/command/audio`

(W: YourPhone.Audio :: Communication.AudioCommandRequest.BuildRequestMessage; A: AudioCommandRequestHandler.tryProcessRequest)

| Key | Type | Value | Tag |
|---|---|---|---|
| `audioCommandValue` | Int32 | 0 `CheckPermission`, 1 `Play`, 2 `Pause`, 3 `Next`, 4 `Previous` | [code-windows] W: YourPhone.Audio :: Utils.AudioCommandType. [code-android] AudioCommandHelper.sendMediaControllerCommand |
| `key` | String | the media notification's `key` | [code-windows] `NotificationId`. [code-android] |
| `correlationVector` | String | trace id | [code-windows] |
| common keys | | section 1; `isuserinitiated` false | [code-windows] default `RequestOptions` |

There is **no** `contentType` key **[code-windows] + [code-android]** (the phone does not read
one). There is no play/pause toggle: the PC picks 1 or 2 from the last `playbackState`.

A second form of the same Windows class, with keys `amsCommandTypeValue` and `amsCommandValue`
and header `x-bt-content`, is the Bluetooth path for iPhones (commands include `VolumeUp` and
`VolumeDown`); the Android handler does not understand it **[code-windows]** (AudioCommandRequest;
W: YourPhone.Audio :: Protocol.Fields.AudioRemoteCommandId) **[code-android]** (the handler
requires `audioCommandValue`).

### 4.4 Answer and follow-up

| Fact | Tag and pointer |
|---|---|
| Reply `result` 0 as soon as the command has been handed to the listener service. It does **not** confirm that anything happened: an unknown or stale `key`, or a notification without a session token, is ignored silently. | [code-android] AudioCommandRequestHandler.tryProcessRequest; PhoneNotificationsListenerService.commandMediaSession |
| The effect arrives as an ordinary notification update: operation 1 on `/legacy/phonecontent` for the same `key` with the new `playbackState` (and new title, text, art after a skip), produced when the media app updates its notification. | [code-android] NotificationItem.toJson; SCN 7.2. [inferred] that apps update the notification |
| Windows keeps its buttons in a "commanding" state for up to 20 s or until such an update arrives. | [code-windows] AudioControlsViewModel.SendAudioCommandRequestAsync |

### 4.5 What the phone does, and failure cases

| `audioCommandValue` | Action |
|---|---|
| 1 | `MediaController.TransportControls.play()` |
| 2 | `pause()` |
| 3 | `skipToNext()` |
| 4 | `skipToPrevious()` |
| 0 | opens the notification-listener settings screen on the phone (only reached when `key` names an active media notification) |
| other | nothing |

For two apps, identified by the SHA-256 of their package name, the phone instead dispatches
media-button key-down events (key codes 126 play, 127 pause, 87 next, 88 previous)
**[code-android]** (AudioCommandHelper.fallbackActionList, sendMediaControllerCommand).

| Case | Reply | Tag |
|---|---|---|
| `audioCommandValue` missing | `result` 1 | [code-android] AudioCommandRequestHandler |
| `audioCommandValue` not Int32 | `result` 1 (cast failure) | [code-android] section 1 |
| Listener service not reachable (exception while forwarding) | `result` 1 | [code-android] AudioCommandRequestHandler |
| Unknown `key`, no token, app ignores the command | `result` 0, no effect | [code-android] |
| Listener access missing | not checked by this handler; the forward either fails (1) or is lost (0) | [inferred] |
| Common gates | section 1 | [code-android] |

### 4.6 Volume

| Fact | Tag and pointer |
|---|---|
| No command sets the phone's media volume over the relay session, in either carrier. | [code-android] no handler among the APP routes (A: am.DaggerMainApplication_HiltComponents_SingletonC, route map) or DRM handlers; `setStreamVolume` is called only by ring-my-phone and by the mirroring audio code |
| The only "set volume" message is `/audio/setVolume` inside an app-streaming (mirroring) session: JSON `{"packageName": string, "volume": int}` on the older message channel, or protobuf `VolumeMessage{1 package_name, 2 volume}` on the platform channel. `volume` is 0 to 100, mapped to the music stream index; it needs an existing audio stream for that package. The phone reports changes on `/audio/volumeChanged`. | [code-android] A: com.microsoft.mmx.screenmirroringsrc.audio.channel.AudioMessageChannelAdapter; ...platform.channeladapter.PlatformOrchestratorMessageChannelAdapter.handleSetVolume; audio.handler.AudioVolumeHandler; com.microsoft.deviceExperiences.audio.SystemAudioVolumeControl. P: phone_mirroring/v1/app_remoting_message.proto :: VolumeMessage |
| That channel is a peer-to-peer mirroring channel, not the hub relay, and is out of scope. | [inferred] from the channel classes (Nano message channel) |
| The connect switch `DeviceIndicatorsVolume` is about **ringer-mode** notifications (section 3.5), not media volume. | [code-android] DeviceStatusChangeReceiver.onReceive |
| The DRM path `/media` and publish tag 6 are photo metadata (`photos.md` section 8), not audio. | [code-android] A: agents.MediaInfoResourceRequestHandler |

---

## 5. (d) Open an app on the phone

### 5.1 Open the notification's app: not a separate command

Opening a notification's app is `operation` 5 on the APP route `/notifications`, fully specified
in SCN 7.5. Summary for this document:

| Item | Value | Tag and pointer |
|---|---|---|
| Sender | `PL` | [code-windows] SCN 7.5 |
| Gate | notification-listener access on the phone (else `result` 7); Windows offers it when the notification's `featureFlags` has bit 2 (the phone always writes 3) | [code-android] A: agents.notifications.requestsHandlers.PhoneNotificationRequestHandler.tryProcessRequest; SCN 7.3 |
| Request | `contentType` `notifications`, `contractVersion` 3.99, `correlationVector`, `operation` Int32 5, `key` String, **no** `actionIndex` and no `inlineReplyMessage`, plus the common keys | [code-android] PhoneNotificationRequestHandler.performNotificationLaunch |
| Phone action | fires the notification's content intent from the listener service, then dismisses the notification; a removal push (operation 2) follows | [code-android] A: agents.PhoneNotificationsListenerService.launchNotification; SCN 7.5 |
| Reply | `result` 0 immediately; it does not confirm that an activity appeared | [code-android] performNotificationLaunch |
| With `actionIndex` | presses that action button instead; reply deferred: 20 an app came to the foreground, 0 nothing launched, 7 the phone needs its "appear on top" permission | [code-android] SCN 7.5; PhoneNotificationRequestHandler.onSystemAlertWindowPermissionDenied |
| Screen state | whether the phone wakes or unlocks was not traced | open question |
| Wire | not captured | SCN limit 2 |

`S:` already implements this as `NotificationSync.openOnPhone(key:)` and `invoke(action:key:)`.

### 5.2 Other "launch" commands that exist over the relay

| Command | What it opens | Tag and pointer |
|---|---|---|
| `/command/devicestatus` type 9 | the phone's DND (or listener) settings | [code-android] section 3.3 |
| `/command/audio` value 0 | the listener settings | [code-android] section 4.5 |
| `/permission` with `silent` false | a permission prompt | SCN 7.6 |
| `/calling/dial` | dial on phone; calling feature, out of scope | [code-android] route map |

### 5.3 Opening an arbitrary app

No relay-level command launches an app by package name **[code-android]**: the APP route
`/applications` is the installed-apps sync (A: agents.PhoneAppsRequestHandler), and the launch
routes (`/mirror/phone/launchApp`, `/mirror/phone/appOpenInMainDisplay`,
`/mirror/phone/launchNotification`, `/message/launchApp`) belong to screen mirroring and app
streaming (`protocol/windows-catalog.md`, "Screen mirroring and app streaming")
**[code-windows]**. They require a mirroring session and are out of scope.

---

## 6. Smallest request to ...

"DRM" rows are a PLATFORM request on `/DeviceResourceManager` carrying
`DeviceResourceManagerMessage{resource_type 4, request_type 2, resource_path, payload}`; with
`S:` that is `DeviceResources.request(path, type: .update, payload:)`. "APP" rows are a value
set on the named route; every APP row also needs `contractVersion` Double 3.99 (section 1) and
should carry `correlationVector`. None of these rows is wire-confirmed; all are **[code-android]**
on the receiving side, and **[code-windows]** on the sending side except where marked `WEA`.

| Action | Carrier and route | Smallest message | Success | Sender on Windows |
|---|---|---|---|---|
| Ring the phone | DRM `/ringmyphone` | `RingMyPhoneRequestMessage{request_type 1}` (`08 01`) | inner `status` 1 | `PL` |
| Stop ringing | DRM `/ringmyphone` | `RingMyPhoneRequestMessage{request_type 2}` (`08 02`) | inner `status` 1 | `PL` |
| Ringer silent | DRM `/devicestatus` | `DeviceStatusRequestMessage{request_type 6}` (`08 06`) | `status` 1, `info.ringer_mode` 0 | `WEA` [inferred] |
| | APP `/command/devicestatus` | `contentType` `deviceStatusCommand`, `deviceStatusCommandType` Int32 3, `deviceStatusCommandValue` Int32 0 | `result` 0, then a status push | `PL` |
| Ringer vibrate | DRM `/devicestatus` | `request_type 5` (`08 05`) | `status` 1, `info.ringer_mode` 1 | `WEA` [inferred] |
| | APP `/command/devicestatus` | type 3, value 1 | `result` 0 | `PL` |
| Ringer sound | DRM `/devicestatus` | `request_type 4` (`08 04`) | `status` 1, `info.ringer_mode` 2 | `WEA` [inferred] |
| | APP `/command/devicestatus` | type 3, value 2 | `result` 0 | `PL` |
| Do Not Disturb on | DRM `/devicestatus` | `request_type 2` (`08 02`) | `status` 1, `info.do_not_disturb_status` > 1 | `WEA` [inferred] |
| | APP `/command/devicestatus` | type 2, value 2 | `result` 0 | `PL` |
| Do Not Disturb off | DRM `/devicestatus` | `request_type 3` (`08 03`) | `status` 1, `info.do_not_disturb_status` 1 | `WEA` [inferred] |
| | APP `/command/devicestatus` | type 2, value 1 | `result` 0 | `PL` |
| Toggle Do Not Disturb | either of the two above | read the last status: 1 means off, so send "on"; anything above 1 means on, so send "off". There is no toggle command. | | |
| Play | APP `/command/audio` | `audioCommandValue` Int32 1, `key` String | `result` 0, then operation 1 with `playbackState` 3 | `PL` |
| Pause | APP `/command/audio` | `audioCommandValue` Int32 2, `key` String | `result` 0, then `playbackState` 2 | `PL` |
| Play/pause | APP `/command/audio` | 1 if the last `playbackState` is not 3, else 2. No toggle command. | | `PL` |
| Next | APP `/command/audio` | `audioCommandValue` Int32 3, `key` String | `result` 0, then an updated notification | `PL` |
| Previous | APP `/command/audio` | `audioCommandValue` Int32 4, `key` String | `result` 0, then an updated notification | `PL` |
| Set volume | none over the relay | section 4.6 | | |
| Open the notification's app | APP `/notifications` | `contentType` `notifications`, `operation` Int32 5, `key` String | `result` 0 | `PL` |
| Read ringer and DND state | DRM `/devicestatus`, GET, no payload | | `status` 1 with `info` | `WEA` **[wire]** |

Choice between the two ringer/DND carriers **[inferred]**: the protobuf command answers with the
reason for a failure and with the new state in the same message, and it starts the phone's
permission flow on its own; the value-set command reports a ringer failure only as `result` 1
and needs the follow-up push to learn the state. A client holding both roles should prefer the
protobuf command and fall back to the value-set one when the DRM answer is `response_type` 2.

---

## 7. Swift building blocks

Generated protobuf types that exist under `S: Generated/`

| File | Types relevant here |
|---|---|
| `ring_my_phone_v1_update.pb.swift` | `RingMyPhone_V1_RingMyPhoneRequestMessage` (`requestType`), `RingMyPhone_V1_RingMyPhoneRequestType` (`.unspecified`, `.on`, `.off`), `RingMyPhone_V1_RingMyPhoneResponseMessage` (`status`), `RingMyPhone_V1_RingMyPhoneResponseStatus` (`.ok`, `.featureNotSupport`, `.unrecognizedPayload`, `.invalidRequestType`) |
| `device_info_v1_status.pb.swift` | `DeviceInfo_V1_DeviceStatusRequestMessage` (`requestType`, `hasRequestType`), `DeviceInfo_V1_DeviceStatusRequestType` (`.get`, `.setDoNotDisturbOn`, `.setDoNotDisturbOff`, `.setRingerNormal`, `.setRingerVibrate`, `.setRingerSilent`), `DeviceInfo_V1_DeviceStatusResponseMessage` (`status`, `info`, `hasInfo`), `DeviceInfo_V1_DeviceStatusResponseStatus` (`.ok`, `.syncDisabled`, `.featureNotSupported`, `.unrecognizedPayload`, `.invalidRequestType`, `.needsPermission` ...), `DeviceInfo_V1_DeviceStatus` |
| `platform_sdk_v1_device_resource_manager.pb.swift` | `PlatformSdk_V1_DeviceResourceManagerMessage`, `PlatformSdk_V1_DeviceResourceManagerResponseMessage`, `PlatformSdk_V1_ProtoDeviceResourceType` (`.ringMyPhone` = 7, `.unknown` = 4), `PlatformSdk_V1_ProtoDeviceResourceRequestType` (`.update` = 2) |
| `platform_sdk_v1_msaep_message.pb.swift`, `platform_sdk_v1_pub_sub_payload.pb.swift` | tag 8 publications |
| `permissions_v1_permissions_message.pb.swift` | `Permissions_V1_PermissionsRequestMessage`, `Permissions_V1_FeaturePermissions` (DND = 5); only for the optional permission request of section 3.4 |
| `value_set_valueset.pb.swift` | `Pbvalueset_ValueSet`, `Pbvalueset_DataVariant`, wrapped by `S: Messaging/ValueSet.swift` |
| `phone_mirroring_v1_app_remoting_message.pb.swift` | `PhoneMirroring_V1_VolumeMessage`; mirroring only, not usable here |
| `remote_control_v1_control_message.pb.swift` | `RemoteControl_V1_*`: the opposite direction (phone locks or shuts down the PC, DRM path `/remotecontrol`); not part of this document |

There are no generated types for media commands or for `/command/devicestatus`: both are value sets.

Existing code to build on

| Need | Existing piece | Gap |
|---|---|---|
| Send a DRM UPDATE | `DeviceResources.request(_:type:payload:trace:)`; throws `ResourceError.unsupportedResource` on `response_type` 2. It always sends `resource_type` 4, which the phone accepts (section 2.2). | none |
| Ring, stop | | new: encode the request, decode `RingMyPhone_V1_RingMyPhoneResponseMessage`, run a local 20 s countdown because no push ends the ring (section 2.3) |
| Read ringer and DND | `DeviceStatusSync.refresh()`, tag 8 subscription, `PhoneStatus.ringer`, `PhoneStatus.isDoNotDisturbOn` | `PhoneStatus` drops `do_not_disturb_rule_enabled`, and `ringer` maps -5 to `.normal`; both are needed to hide or disable the controls |
| Set ringer and DND | | new: UPDATE on `DeviceStatusSync.phonePath`; feed the `info` of the answer into the same `update` path; map statuses 5, 6, 9 to user-visible reasons |
| Value-set commands | `PeerMessenger.appRequest(route:payload:)`, `ValueSet`, `ScenarioResult`; `NotificationSync.commandPayload` shows the common keys | new routes `/command/devicestatus`, `/command/audio` |
| Media sessions | `NotificationSync` already parses `notificationClass`; `ConnectExchange.configuration` already sends `AudioInfoSyncEnabled` and the `DeviceIndicators*` switches | `PhoneNotification` does not keep `playbackState`, `largeIcon`, `smallIcon` |
| Capabilities | `ConnectExchange.PhoneInfo.capabilities["ringMyPhoneCapabilities"]`, `["registeredPermissionTypes"]` (bit 0x4000), `permissions["notifications"]` | none |
| Open on phone | `NotificationSync.openOnPhone(key:)` | none |

---

## 8. Open questions

1. **No command in this document has been seen on the wire.** A capture in which the user rings
   the phone, cycles the ringer, toggles Do Not Disturb and presses the media keys in Phone Link
   and in the Windows 11 Start-menu phone panel would settle items 2 to 5.
2. **Which Windows surface sends the protobuf ringer/DND requests.** Attributed to CDEH from the
   proto alone. Not established: whether CDEH tests `RINGER_MODE`, `DEVICE_STATUS`, both, or
   only the status fields before offering the controls.
3. **Whether the phone accepts every command on either role's session.** No client-type test was
   found in the handlers, but the lower layers (session tracker, connection sharing) were not
   traced for these routes. Matters to a client that runs `PL` and `WEA` as two separate sessions.
4. **Ring my phone from CDEH.** Unknown whether the `WEA` client has its own ring button and, if
   so, whether it sends `resource_type` 7 or only the path.
5. **Platform-level rejections.** When the phone answers a DRM request with `_rejectedReason`
   `AllSyncDisabled` or `MeteredSyncDisabled` instead of reaching the handler was not traced.
   Phone Link sends DRM requests with an "ignore device disabled" option on its own side.
6. **Missing `contractVersion` in an APP request.** The unchecked cast throws before a reply is
   built; whether the PC then gets `result` 1, another code, or nothing was not traced.
7. **Ring audibility under Do Not Disturb, and the vibration,** are inferred from Android's audio
   policy, not from LTW code or a test. Needs a live test in "total silence" mode.
8. **Ringer changes without notification-policy access.** That Android throws for changes into or
   out of silent is platform knowledge; the vibrate-to-normal case without access was not tested.
9. **Android 15 DND semantics.** That `setInterruptionFilter` drives an app-owned implicit rule,
   and that "off" cannot end a DND started elsewhere, are inferred from the "rule enabled" flag,
   the proto comment and Windows' failure dialog.
10. **`AudioInfoSyncEnabled` timing** (also SCN open question 6): whether media notifications
    start flowing in the session that first sends the flag.
11. **Media command acknowledgement.** `result` 0 carries no information about the effect; the
    only confirmation is a later notification update. Whether every common player updates its
    notification after next/previous was not tested.
12. **`/command/audio` value 0** is named `CheckPermission` on Windows but opens a settings
    screen on the phone and only when `key` is a live media notification. Its intended use, and
    whether Windows still sends it, were not determined.
13. **Screen state on "open on phone".** Whether the content intent wakes or unlocks the phone,
    and what the PC gets when the launch is blocked in the background (operation 5 without
    `actionIndex` always answers 0), were not traced.
14. **Phone-initiated DND permission flow.** After status 9 the phone starts
    `requestPermissionsAsync`; what it shows and what it publishes (tag 3) was not read.
15. **One late periodic publish** (C-raw: 5048) is about 50 s off the 600 s grid and the slot
    before it is empty. Most likely a delayed timer; a change-driven publish replacing a missed
    one would look the same. No change-driven publish can be identified in the capture.
