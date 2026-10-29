# Instant Hotspot

Status on 2026-10-10: built from the code of both sides (the phone's `agents/hotspot` and
`ypp/sidechannel`, Phone Link's `YourPhone.Hotspot.Managed` and `YourPhone.YPP.SideChannel`),
tested against a phone played from that code. **Never run against the phone.** Nothing here
was recorded.

The computer asks the phone to switch on its Wi-Fi hotspot and to say the network's name and
password, then joins it. The request does not use the relay: it goes over a Bluetooth serial
connection to a service the phone keeps open for its linked computers (the "side channel").

## 1. Preconditions on the phone

- Capabilities `HOTSPOT` and `HOTSPOT_ACCOUNT_SECRET` (device), YPP capability
  `SIDE_CHANNEL_OEM_SUPPORT`; the hotspot handler exists only where the maker's service says the
  phone can (`IOemFeature.isHotspotSupported()`, Samsung).
- The user's consent, and the maker's Bluetooth channel open. Both are in the phone's status
  value set as `hotspotUserConsent` and `oemBluetoothRfcommServerOpen`, and arrive again as a
  phone command of type 3 (`hotspotUserConsent`, `oemBluetoothPermission`,
  `oemBluetoothRfcommEnabled`) on `/legacy/phonecontent` when the user answers.
- Asking for consent: APP request on `/hotspotsetupnotificationrequest`, value set
  `{"isuserinitiated": true}`. The phone opens the Link to Windows settings, or posts a
  notification that leads there. The reply only says whether that was shown.
  (`/hotspotdevicedatasyncrequest {"HotspotCompletedFTU": bool}` just stores a flag.)
- Bluetooth on, the computer bonded with the phone.

No check of the computer's client type was found anywhere on these paths. What Samsung's own
Bluetooth host (`com.samsung.android.mdx`) requires of the connecting device is not in the code
we have: **the open question of this feature.**

## 2. Transport

Bluetooth classic, RFCOMM, the computer connects. Service UUID
`111FAB8F-00A2-4935-B6B4-ACA388CDD473`. Each message is preceded by its length as a protobuf
varint. One request (`SideChannelClientRequest`), one answer (`SideChannelServerMessage`), then
the computer closes. Phone Link allows 30 s to find the service, 15 s for the channel to open,
10 s for the answer, and retries a credentials request twice.

## 3. Messages (`protocol/recovered/android/side_channel/v1`)

- `SideChannelClientRequest`: 1 `context` (trace ids), 5 `hotspot_request {1 type}`,
  4 `authorization {1 signed_jwt_payload}`. Types: 1 capable status (switches nothing on),
  2 credentials, 3 credentials encrypted with the account secret.
- `SideChannelServerMessage {1 request_response}`; `SideChannelServerResponse`: 1 `ok`,
  2 `error {1 type, 2 msg}`, 5 `hotspot_response`, 6 `authorization`, 7 `context`,
  8 `hotspot_encrypted_response`.
- `SideChannelHotspotResponse`: 1 `status` (1 success, 2 other error, 3 untrusted, 4 unknown
  command, 5 not hotspot capable), 2 `reservation {1 capable status, 3 nonce}`, 3 `type`.
  Capable status 2 is "supported"; 3 to 17 are the phone's reasons (airplane mode, data saver,
  no hotspot password, SIM, DeX, Smart View, Link to Windows off, Bluetooth permission, ...).
- On failure: `ok` false, `error.type` 3, the hotspot response attached, no authorization.

## 4. Signing and encryption (the way Windows uses by default: type 2)

- The request's `authorization` is the trust-key JWT also used for wake
  (`identity-enrollment-trust.md`), `Scope` = `hotspot.request`, `SourceId` = the computer's DCG
  id, `Data` = a JSON map of strings: `DCG-Environment` = `Prod`, `nonce` = Base64 of 128 random
  bytes, `publicKey` = Base64 DER `SubjectPublicKeyInfo` of an RSA key made for this request.
- The phone finds the trust relationship by `SourceId`, checks the signature with the stored
  certificate, switches the hotspot on (Samsung's provider, `method_enable_hotspot`) and answers
  with a JWT signed by its own trust key, `Scope` = `hotspot.response`, whose `Data` map holds
  `encryptedCredentials` (Base64; RSA-OAEP with SHA-256 of the UTF-8 text name followed by
  password) and `encryptedSsidLength` (how many characters of that text are the name), and the
  same for a device status. The nonce comes back in `reservation.nonce`.
- The computer checks the nonce, the signature and the scope, decrypts, and takes a name of
  1 to 32 and a password of 8 to 63 characters.
- Type 3 uses a 32-byte secret both sides fetch from
  `GET /SecretDistribution/AccountSecret/Get?api-version=1.0.0` (MSA bearer token) and AES-256-GCM.
  Not built: type 2 needs no such call.
- Nothing switches the hotspot off again from the computer.

## 5. The Mac client [built]

- `Features/InstantHotspot.swift`: `HotspotExchange` (request, one-time key, reading and
  checking the answer), `SideChannelFraming`, `HotspotReadiness`; `PhoneStatus.hotspot`.
- `LinkController.requestHotspotSetup`, `hotspotExchange` (Phone Link identity).
- `Sources/WinPhone/Mac/HotspotChannel.swift`: SDP query for the UUID, RFCOMM, the request in
  pieces of the connection's size, the framed answer. `Mac/WiFiJoin.swift`: joins the network
  (the system's call, then `networksetup`), looking for it for a while.
- The hotspot button on the phone's card and Phone › Connect to Phone's Hotspot
  (`LiveActions.connectHotspot`). Tests: `InstantHotspotTests`, `HotspotAppTests`, `WiFiJoinTests`.

## 5a. First live look (2026-10-11 00:07 to 00:10)

- `performSDPQuery(_:uuids:)` naming the wanted UUID got no callback at all (twice 25 s). The
  plain `performSDPQuery(_:)` is answered at once. The client uses the plain form, looks first
  at the services the Mac already knows, and looks again after 10 s whatever was reported.
- The phone (connected for calls) lists 19 services, **the side channel not among them**, and
  its status says nothing of `hotspotUserConsent` or `oemBluetoothRfcommServerOpen`. This fits
  the code: Samsung's host opens the service only after the user allows the feature
  (`enableRfComm(SERVICE_UUID, HOTSPOT)`). So a missing service now leads to the set-up request
  (`/hotspotsetupnotificationrequest`), not to an error. Whether the service appears for the Mac
  once the user has allowed it is the next thing to learn.

## 5b. The set-up request needs the common fields (2026-10-11 10:03)

A bare `{"isuserinitiated": true}` got no answer in 20 s, three times. The phone's handler base
(`ScenarioRequestHandlerBase.handleAsync`) reads `contractVersion` from every such request
before anything else and fails without it, answering nothing. Phone Link's `SendKvpRequestAsync`
adds the fields every request of this kind carries; the Mac now sends them too
(`LinkController.hotspotSetupRequest`). The answer's `result` is 0 where the phone showed its
settings or a notification, another number where it would not (hotspot not supported there, or
nothing could be shown).

## 5c. Allowed on the phone, still not offered to the Mac (2026-10-11 10:13 to 10:17)

- After the Mac sent `HotspotCompletedFTU: true` on `/hotspotdevicedatasyncrequest` (the phone
  had answered the first consent with "Complete setup on your PC") and `/hotspotsetupnotificationrequest`
  (result 0), the phone pushed a phone command of type 3 and the status showed consent.
- The phone's Bluetooth services stayed at 19, the side channel not among them, over repeated
  system lookups, looks after 7 s, and the Mac's `performSDPQuery`. An own SDP question over an
  L2CAP connection to PSM 1 got no answer in 6 s (macOS keeps that service for itself).
- So the phone does not publish the service to this Mac. The code points at Samsung's host
  (`com.samsung.android.mdx`) opening it on `enableRfComm(SERVICE_UUID, HOTSPOT)` after consent
  *and* the OEM Bluetooth permission; the flags the phone sends (`oemBluetoothPermission`,
  `oemBluetoothRfcommEnabled`) are now logged to see which of the two is missing.

## 5d. The phone says its channel is open; the Mac still cannot see it (2026-10-11 10:23, 2026-10-12)

- After consent the phone reports `hotspotUserConsent` true, `oemBluetoothPermission` true,
  `oemBluetoothRfcommEnabled` true, and its status carries `oemBluetoothRfcommServerOpen` true:
  by its own account the server is open.
- The Mac's list of the phone's Bluetooth services is unchanged: 19, the 4 unnamed ones being
  the Device ID (0x1200), Generic Access (0x1800), Generic Attribute (0x1801) and one 128-bit
  vendor identifier, none with a serial channel. The side channel is not listed, also when
  asked for by its identifier the way Windows asks.
- So Samsung's server is open but not discoverable to this Mac by the service directory.
  What is left untried: probing serial channel numbers blindly, which is not done: the
  channel numbers of the listed services are known, and a blind probe sends a signed
  request to services that were never meant to get it.

## 5e. The channels were tried one by one: nothing (2026-10-12 16:34)

At the user's wish every serial channel from 1 to 30 that belongs to no listed service (23 of
them) was opened and sent the question that switches nothing on. None answered as the side
channel does. One, channel 3, answered 13 bytes of something else, and **the phone asked its
user to let the Mac read messages**: an unlisted channel of the phone's message access. So a
blind probe has a cost on the phone, and it found nothing; the probe was removed from the
code again. The feature is out of reach from a Mac: Samsung's host says its channel is open
and serves it neither through the service directory nor on any channel that can be reached.

## 5f. The Mac's service list is a remembered one (2026-10-12 19:23 to 19:30)

The user asked whether we are simply doing it wrong, since Windows does reach the service.
Looked at with the system's own log (`log show`, process `bluetoothd`):

- `performSDPQuery(_:)` and `performSDPQuery(_:uuids:)` cause **no service query at all**: the
  daemon logs nothing but "sending sdp data" (its remembered records going to the app), and the
  app's callback comes within a millisecond. So "19 services, the side channel not among them"
  says what macOS remembered, most likely from pairing, which was before Instant Hotspot was
  allowed on the phone. It is not evidence that the phone does not publish the service.
- The remembered list is incomplete in any case: the probe found serial channels 2, 3, 6, 9
  and 10 open on the phone and in no record (3 is message access). Given 16 s each, 2, 6, 9 and
  10 took the whole request and sent nothing back: other services, not the side channel. The
  side channel may sit on a channel the remembered list gives to something else.
- An own query over L2CAP PSM 1 connects (the daemon logs result 0, twice) and is closed by
  the system in the same millisecond: IOBluetooth frees its channel object right after making
  it ("No known channel ... with psm 1"), with the call that reports back later and with the
  one that waits. Not usable on macOS 27; removed.
- Windows asks the phone afresh (`GetRfcommServicesForIdAsync(uuid, Uncached)`).

What is left, and is the proper test: remove the phone from the Mac's Bluetooth and pair it
again now that the phone has the service open. Pairing makes macOS read the phone's services
anew; if the side channel is published at all, the existing code then finds it.

## 5g. After re-pairing: found, opened, delivered, no answer (2026-10-12 19:35 to 19:48)

Re-pairing refreshed the Mac's remembered service list: the side channel is there as a
record named `InstantHotspot` on RFCOMM channel 10, the Mac opens it in under a second
and the request goes out whole. Nothing comes back, and the phone leaves the connection
open. Tried, each with silence until our own time limit:

| Request | Size | Result |
|---|---|---|
| credentials (type 2), signed as Phone Link | 1,373 bytes | none in 25 s |
| capable status (type 1), signed as Phone Link | 816 bytes | none in 20 s |
| capable status (type 1), signed as cross-device | 816 bytes | none in 20 s |
| capability request (field 3, unsigned, empty) | 3 bytes | none in 12 s |

The last row rules out signature, scope, source id and environment: the phone answers an
unsigned capability request without any trust check (`SideChannelCapabilityServiceHandler`),
and anything it does not know with `UNKNOWN_REQUEST_TYPE` (`SideChannelUnknownRequestHandler`).
Silence to it means Link to Windows never reads what arrives.

What the phone's code says of the way in (Samsung `com.samsung.android.mdx` 3.6.01.2 and
Link to Windows 1.26082.130.0):

1. Samsung's `HotspotRFCommService` owns the server (`listenUsingRfcommWithServiceRecord
   ("InstantHotspot", uuid)`), accepts anyone bonded, makes two pipes, pumps the socket
   into them (1,024 bytes at a time) and broadcasts
   `com.samsung.android.mdx.bluetoothtransport.ACTION_BT_SOCKET_CONNECTED` with the client's
   address to Link to Windows. It applies no policy of its own.
2. Link to Windows' `OemRfcommSideChannelBroadcastReceiver` fetches the two pipe ends from
   Samsung's provider (`method_get_bluetooth_socket_info`), asks `SideChannelSessionManager`
   to start a session (`OemSideChannelSessionPolicy`: Bluetooth permission, app enabled,
   bond state 12), and only then puts the pipes on `OemRfcommSocketQueue`. A refused
   session is logged as "ignoring" and the pipes are queued all the same, where nobody
   takes them: silence with the connection open, which is what is seen.
3. `RfcommServerChannelGenericOem.doBeginRead` blocks in `queue.take()`; a `CloserSocketData`
   taken there ends reading without re-arming it. Framing is varint32 + `SideChannelClientRequest`
   (checked against the generated classes: fields 1 context, 2 wake, 3 capability,
   4 authorization, 5 hotspot, 6 instant hotspot; our messages match).
4. A request that fails to parse is logged and not answered, with the connection left open;
   ours parse (same `.proto`), so this is not it.
5. `SideChannelHotspotHandler.handleChannelRead` waits 3 s for the trust check and only logs
   on timeout; the answer is still written when the check completes.

Which of the steps in 2 and 3 stops the connection cannot be told from the Mac. The phone's
own log would show it (tags `Server`, `BluetoothServerSocket`, `InstantHotspotSettingFetcher`
from Samsung; `OemRfcommSideChannelBroadcastReceiver` from Link to Windows).

Development aid: `SideChannelCapabilities.request` is part of the `hotspot.selfcheck` run.

## 5h. The likely cause: Link to Windows' own Bluetooth permission (2026-10-12 20:31)

The phone's answer to the connect handshake carries its permissions. Two of them are about
Bluetooth and are not the same thing:

| Key | What it is | This phone |
|---|---|---|
| `oem_bluetooth` | Samsung's service may use Bluetooth (`OemBluetoothPermissionAdapter`); also `oemBluetoothPermission` in the hotspot status | true |
| `bluetooth` | Link to Windows itself holds `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_SCAN` (Android's "Nearby devices") | **false** |

`OemSideChannelSessionPolicy` checks the second one first (`BluetoothPermissionHelper`),
answers `BLUETOOTH_PERMISSION_NOT_GRANTED`, the session manager logs "ignoring", and the
pipes are queued unread: the silence of 5g. Phone Link on Windows has the phone ask for this
permission when calls are set up; this app does calls through the Mac's own Bluetooth and
never made the phone ask. [Not yet confirmed live: the user has to allow it on the phone.]

The user found "Nearby devices" shown as allowed in Android's settings while the phone still
reports `bluetooth: false` (20:31). Both can hold: the entry stands for three permissions,
Link to Windows wants all three, and Android's settings show the group as allowed when part
of it is granted [inference, not seen on the phone]. Phone Link closes the gap with a
permission request, APP `/permission` with type 26 as a bit (`1 << 25`), the same request as
for the notification listener (type 7, 64) and sensitive notifications (type 32, top bit).
The hotspot button now sends it first when the phone reports `bluetooth: false`
(`LinkController.requestPhoneBluetoothAccess`), and goes on when the phone says allowed.

The app keeps the value (`LinkController.Event.phoneBluetoothAccess`) and, when the request
times out while it is false, says where to allow it instead of "could not be reached".

## 5i. First answers from the phone; the Mac closes the wrong channel (2026-10-12 20:45 to 20:55)

**The permission request works.** `/permission` with type bit `1 << 25` was answered
"accepted" in about two seconds without a dialog on the phone, the phone then reported
`bluetooth: true`, and the very next request over the side channel was answered in 180 ms.
5h was the cause of the silence. [confirmed live]

**Answers seen since** (all within 0.3 s of the request):

| Request | Answer |
|---|---|
| capability (unsigned) | 10 bytes, capabilities `[2, 1]` (hotspot, wake) |
| capable status, signed as Phone Link | 653 bytes, success, signature and nonce check out |
| capable status, signed as cross-device | the same: the phone accepts either identity |
| credentials (the user's click, 20:45:30) | 139 bytes: `ok` false, hotspot status 2 (`ERROR_OTHER`), error type 3 |

Error type 3 (`SCENARIO_SERVICE_ERROR`) is what the phone puts on every hotspot answer that
is not a success. Status `ERROR_OTHER` with the phone's own state at "supported" or
"unknown" comes from three places in `handleStartHotspotRequestAsync`: no `publicKey` or
`nonce` in the request (ruled out: the status request reads the same map), an exception
while starting, or Samsung's `method_enable_hotspot` answering "no" without a reason, which
is `SemWifiManager.setWifiApEnabled(null, true)` returning false. The refusal's own fields
(reservation status, request type) are logged from now on to tell these apart. [open]

**macOS 27 closes the wrong RFCOMM channel.** With the calls link (hands-free, channel 4)
and the side channel (10) both open from this app, `IOBluetoothRFCOMMChannel.close()` on
the side channel made `bluetoothd` log `handleCloseRFCOMMChannel rfcommChannelID: 10` and
then disconnect channel 4. Channel 10 stayed connected, the app was not told that the calls
link had gone, and the next `openRFCOMMChannelAsync` for channel 10 never reached
`bluetoothd` at all: every later request timed out. Built against it:

- only one of the two channels is open at a time: the calls link is stopped before a
  side-channel request and started again after it (`LiveActions.askOverSideChannel`), and
  the hotspot is not asked for during a call;
- 1.5 s between the two: the connection under the last channel ends about half a second
  after it, and an opening begun meanwhile fails inside the system ("connect failure 560")
  without a callback;
- an opening not heard of in 4 s is begun anew, twice at most (`HotspotChannel.openWatch`).

Checked live at 20:54: three requests in a row answered, the calls link back each time.

## 5j. The hotspot came on; joining it failed (2026-10-12 20:55)

The user's click at 20:55:49: the first opening was lost and begun anew after 4 s, the
1,373-byte credentials request was answered in 230 ms with 1,781 bytes, signature, nonce
and decryption all good: "the phone switched its hotspot on and said how to join". The
user saw the hotspot come on. So the refusal of 20:45 (5i) was a one-off, not a standing
obstacle. [confirmed live]

Joining failed: `CWInterface.scanForNetworks(withName:)` took 7 s and found the network,
`associate(to:password:)` then failed with -3900. The Wi-Fi service's log shows why: the
association was "for WiFi network (null)". An app without Location permission gets
`CWNetwork` objects with the name taken off, and joining one drops the current network
and fails. The Mac went back to its own network by itself.

Built: a found network without a name is not used; the Mac's `networksetup
-setairportnetwork` is given the name and password instead, and is also tried when the
system call finds and does not join. The tool was checked on this system with a name that
does not exist ("Could not find network", current network untouched). Not yet run against
the hotspot. If it fails too, the remaining way is to ask for Location permission.

## 5k. Joined; leaving is watched; no way to switch it off (2026-10-12 ~21:10)

The next click joined the phone's network through `networksetup` [confirmed by the user].
The whole way works: permission request, side channel, credentials, join.

**Leaving.** The sign stayed on after the user picked another network by hand. The app
cannot ask for the network's name (5j), so `HotspotWatch` remembers the Wi-Fi interface's
router, the Mac's address there and the system's `NetworkSignature` (it holds the router's
hardware address) from `State:/Network/Service/*/IPv4` once the join has settled, and looks
again three seconds after any Wi-Fi event (`ssidDidChange`, `linkDidChange`,
`powerDidChange`), any path change, and every 20 s. Anything else than what was remembered
is "left". [built, not yet seen live]

**Switching the hotspot off from the computer is not in the protocol.** The request types
are capable status, credentials and encrypted credentials; none stops. The phone's
`stopInstantHotspot()` (Samsung: `method_enable_hotspot` with false, refused while more
than one station is connected) has no caller in Link to Windows 1.26082.130.0, and the
newer `instant_hotspot_request` (field 6) has no handler at all. The phone's own setting
switches the hotspot off after a time with nothing connected.

## 5l. Leaving by the button (2026-10-12 ~21:25) [built, not yet run against the hotspot]

Clicking the green button (or Phone › Leave Phone's Hotspot) takes the Mac off the phone's
network: `CWInterface.disassociate()`, after which the system joins a network it remembers.
Found on the way:

- `networksetup -setairportnetwork` puts the joined network among the Mac's remembered
  ones, so the Mac could go straight back to the hotspot. A network the Mac did not
  remember before the app joined it is therefore taken off again on leaving
  (`-removepreferredwirelessnetwork`, which needs no administrator here). One the Mac knew
  already is left alone. Which ones the app added is kept over launches as fingerprints,
  not names (`hotspot.networksAddedHere`).
- The name of the network the Mac was on before cannot be had without Location permission
  (`networksetup -getairportnetwork` answers "not associated"), so the Mac is not sent back
  to a named network; the system chooses.
- No network of its own after eight seconds: Wi-Fi is switched off and on once.
- Back on the hotspot all the same (same route as when joined): said so, with the advice
  to pick another network in the Wi-Fi menu.

## 6. Open

1. Whether Samsung's Bluetooth host lists the service to a Mac and lets it connect.
2. Whether consent given for a Windows PC covers this Mac, and what the status says now.
3. The RSA key size the phone accepts (2048 sent).
4. How soon the Mac sees the network, and how long the hotspot stays up unused.
