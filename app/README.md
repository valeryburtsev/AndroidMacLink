# Phone Mac Link

A native macOS client for Microsoft's Phone Link service, written from the protocol as observed in
the real clients. Swift 6 toolchain, Swift Package Manager, macOS 14 or later.

## Layout

| Path | What it is |
|---|---|
| `Sources/WinPhoneCore` | The protocol library. No UI. |
| `Sources/WinPhone` | The app: SwiftUI views, pasteboard and Notification Center integration. |
| `Sources/winphone-probe` | Command-line companion: decodes relay traffic from the capture proxy with the library's codecs (`winphone-probe app-messages <flows.jsonl>`). |
| `Protos` | Our `.proto` files, rendered from the recovered descriptor set. |
| `Sources/WinPhoneCore/Generated` | Swift generated from `Protos` by `protoc-gen-swift` 1.38.1. |
| `Tests/WinPhoneCoreTests/Fixtures` | Sanitized real traffic: hub frames, request shapes, one pairing. |
| `Screens` | Renders of every screen, produced by the app's snapshot mode. |

## Commands

```bash
./build.sh            # build
./build.sh test       # run all tests
./bundle.sh           # build/Phone Mac Link.app, signed ad hoc and marked as built with the current SDK so macOS draws it in its current look
```

`"build/Phone Mac Link.app/Contents/MacOS/WinPhone" --demo` opens the app with sample data.
With `--demo --apps-first --demo-feed <folder>` the sample notifications arrive one by one, as
a real start brings them, and pictures of the window are saved (this is what showed rows cut
off in the system's list on macOS 27); adding `--swipe` also tries a two-finger swipe over the
first notification and writes what happened to `swipe.txt`.
`... --snapshot <dir>` renders every screen to PNG and exits.

## What exists, and how it was checked

| Layer | Files | Checked against |
|---|---|---|
| MessagePack codec | `Wire/MessagePack.swift` | 215 real hub frames re-encode byte for byte |
| SignalR framing and hub messages | `Wire/SignalR.swift` | the same frames, as typed messages |
| DCG packets and trace context | `Wire/DcgPacket.swift` | our packets equal Phone Link's, including its fixed 32-bit integers |
| Message envelope | `Wire/PlatformEnvelope.swift` | every captured envelope, both header-length conventions |
| Certificates and JWTs | `Crypto/` | structure of a real Phone Link certificate; token lengths of five real wake requests and the 1160-character nonce token |
| Device tokens | `Identity/DeviceTokens.swift` | as above |
| Persistent state | `Identity/StateStore.swift` | round trip through a file and through the real login keychain (`WINPHONE_KEYCHAIN_TESTS=1`) |
| Identity, enrollment, trust, wake | `Identity/IdentityService.swift` | a scripted service that verifies every proof we send: the first-run call order of the spec, sign-in on later runs, recovery after `DeviceUnlinked`, device-ID collisions, wake tokens verified with the enrolled certificate |
| DCG REST client | `DCG/` | verb, path, query, header order and body shape of 14 captured calls |
| Microsoft account sign-in | `Account/` | scripted responses: device code, refresh-token rotation, dead refresh token |
| Sessions and the controller | `Session/` | the whole stack against the scripted service and two scripted phone sockets: both roles connect, clipboard and status and notification features run, a dropped socket reconnects, sign-out wipes |
| Pairing | `Pairing/` | a replay of the QR pairing captured on 2026-10-09 |
| Hub connection and relay | `Relay/` | a scripted in-memory hub |
| Presence, wake and heartbeat supervision | `Relay/PhoneConnection.swift` | a scripted hub replaying the captured start sequence |
| Routed messaging | `Messaging/` | a scripted phone; real APP payloads decode when the local capture is present |
| Resource manager, publish and subscribe, session validation | `Platform/` | real request and response bytes from the capture |
| Clipboard sync | `Features/ClipboardSync.swift` | real request bytes; behaviour against a scripted phone |
| Notification sync | `Features/NotificationSync.swift` | real traffic captured on 2026-10-09: pushes, removals and the permission push parse and our replies equal Windows' byte for byte; our permission, reconcile and dismiss requests equal the ones Windows sent field for field. Open-on-phone, action buttons and reply rest on the decompiled code |
| Device status | `Features/DeviceStatusSync.swift` | real request and response bytes; our answer equals the one Windows sent |
| Photos | `Features/PhotoSync.swift`, `Sources/WinPhone/Views/PhotosView.swift` | the list sync, thumbnail batches and image fetch against a scripted phone; the real captured thumbnail and image replies parse (local capture); live on 2026-10-09 the phone sent its list of 91 photos |
| Session handshake | `Features/ConnectExchange.swift` | our configuration equals the one Windows sent, value for value (local capture); live reply parsed |
| Messages | `Features/MessageSync.swift`, `Sources/WinPhone/Views/MessagesView.swift` | list sync, updates, deletions, MMS text, send with placeholder and acknowledgement against a scripted phone; our send request equals the one Windows sent and the real follow-up push parses (local capture); live on 2026-10-09 the phone synced 38 conversations |
| Sensitive notifications | `Features/NotificationSync.swift` (`requestPermission`, `applyPhoneCommand`) | our request equals the one Windows sent when Setup was pressed, and our answer to the phone's "denied" command equals Windows' byte for byte (local capture) |
| Contacts | `Features/ContactSync.swift` | list sync limited to contacts, numbers and e-mail; number matching; the real first contact sync from the pairing capture parses (local); live on 2026-10-09: 100 contacts in 2 s |
| App catalogue and icons | `Features/AppCatalogSync.swift` | the real first app sync from the pairing capture parses (local); live on 2026-10-09: 115 apps with icons in 8 s, cached afterwards |
| Device controls | `Features/DeviceControls.swift`, `Features/DeviceStatusSync.swift` (`apply`) | ring my phone, ringer mode, Do Not Disturb and the media keys against a scripted phone, message for message as `protocol/specs/device-controls.md` gives them. **No capture of Windows sending any of these exists and none has been tried live.** Ringer and Do Not Disturb first use the status update that answers with the new state, then fall back to the command Phone Link sends |
| Now playing | `PhoneNotification.isMediaSession`, `Sources/WinPhone/Views/MainView.swift` (`NowPlayingCard`) | media notifications are kept out of the notification list and shown as a player in the sidebar; scripted only |
| Picture messages | `Features/MessageSync.swift` (`readParts`, `attachmentData`, `OutgoingAttachment`) | parts become attachments, bytes are fetched when the user clicks, a preview is kept, a picture can be sent; scripted only, the capture holds no picture message. Opening is limited to media and document types and files are named from their declared type |
| Call history and dial | `Features/CallLogSync.swift`, `Sources/WinPhone/Views/CallsView.swift` | list round, batches, incremental actions, cache, forced resync and "dial on phone" against a scripted phone, as `protocol/specs/calls.md` gives them. **Off by default** (Settings, "Show recent calls"): it sets the phone-wide `CallLogs` switch, Windows had it off in every capture, and nothing of the exchange has been seen on the wire or tried live. Dial only opens the phone's dialer; the relay cannot place, answer or end a call |
| Calls over Bluetooth | `Calls/HandsFree.swift`, `Sources/WinPhone/Mac/BluetoothCalls.swift`, `Views/LiveCallView.swift`, `Views/CallsView.swift` (`DialPad`) | the Hands-Free dialogue against a scripted audio gateway (`HandsFreeTests`); choosing the paired phone. **Off by default** (Settings, "Calls on this Mac"). Live on 2026-10-10: connection and a call placed and ended from the Mac. Control only: macOS has no working call for the sound connection (`protocol/specs/calls-bluetooth.md`, section 5) |
| Away from the local network | `Nano/Ice/Stun.swift`, `IceDescription.swift`, `IceAgent.swift`, `IceSocket.swift`, `Nano/NanoConnector.swift` | every message of the recorded Windows session reads, verifies and writes back byte for byte (`IceRecordingTests`); two agents on a simulated internet with plain and strict routers and a relay (`IceTests`, `IceTestNetwork`), up to a file arriving through the relay; live against the real servers with `ice.selftest`. Not yet tried with the phone |
| Links across devices | `Features/PhoneLinks.swift`, `Sources/WinPhone/Views/LinksView.swift`, `Mac/LinkService.swift` | link detection in copied text, app contexts from a push, the page a link travels in (`PhoneLinksTests`). The phone's share sheet refuses links and the protocol has no "open on phone" (`protocol/specs/continuity.md`), so: copied links and app contexts from the phone, a link file to the phone. Not tried with the phone |
| Phone screen: turning, own window, screenshots | `Nano/NanoMirrorSession.swift` (`deviceResolutionChanged`, `orientationChanged`), `Sources/WinPhone/Mac/ScreenVideo.swift` (`whenPictureSizeChanges`, `ScreenShots`), `Views/ScreenWindow.swift`, `Views/ScreenView.swift` (`LivePicture`) | a scripted phone that turns both ways (`testThePictureFollowsThePhoneWhenItIsTurned`); the picture's geometry and screenshots (`ScreenTurnTests`); a real H.264 stream from the Mac's encoder shown, followed through a change of size and read back (`ScreenVideoTests`, read-back skipped while the display sleeps); the window's sizing and behaviour (`ScreenWindowTests`). From both sides' code; not tried with the phone |
| Mac conveniences of 2026-10-10 | `Views/MainView.swift` (`AppCommands`), `Views/ScreenView.swift` (`AppsView.shelves`), `Views/PhotosView.swift` (`PhotoExport`), `AppModel.gatherFileToSend`, `bundle.sh` (`CFBundleDocumentTypes`) | sections on Command-1 to 9 and a Phone menu (listed from the real menu bar in demo mode); favorite and recently opened apps (`ScreenWindowTests`); photos dragged out as file promises, saved and copied from the grid (`PhotoExportTests`, the promise kept end to end); files dropped on the Dock icon gathered into one transfer. The drags themselves are not exercised by tests |
| Phone Storage | `Features/PhoneFilesSync.swift` (`PhoneFilesSync`, `PhoneFileTree`), `Sources/WinPhone/Views/StorageView.swift` | the phone's file index on `/filesmetadata` (`protocol/specs/file-transfer.md` 6 and 6.4a) against a phone scripted from its code: configuration, batched full list, restart, incremental changes, permission, thumbnails (`PhoneFilesTests`); the flat list as folders; one file fetched by its address over the share's exchange (`NanoFileReceiver.fetch`, `testAFileOfThePhonesStorageIsFetchedByItsAddress`). Nothing on the phone is changed. Never run against the phone |
| Instant Hotspot | `Features/InstantHotspot.swift`, `Sources/WinPhone/Mac/HotspotChannel.swift`, `Mac/WiFiJoin.swift`, `LiveActions.connectHotspot` | the signed request, the one-time RSA key and the reading of the phone's signed, encrypted answer against a phone played from its code, with forged, misdirected and refusing answers (`InstantHotspotTests`); readiness from the phone's status; the network tool's answers (`WiFiJoinTests`). The Bluetooth connection and the joining are not exercised by tests. `protocol/specs/hotspot.md`. Never run against the phone |
| Identity key renewal | `Identity/IdentityService.swift` (`rotateKeysIfDue`), `DCGClient.rotateKeys` | `/Auth/RotateKeys` against a scripted service that checks both proofs: renewed, refused, answer lost, request lost, stale candidate, date fallback (`KeyRotationTests`). From Phone Link's code; not due before April 2027, never run against the service |
| Sync over mobile data | `DeviceControls.setSyncOverMobileData`, `PhoneStatus.syncOverMobileData` | command type 5 and its results against a scripted phone; the setting read from the recorded status. Not tried live |
| Phone status on pushes | `PhoneStatus.init(push:base:)`, `NotificationSync.noteStatus` | every content push carries battery, signal, ringer and Do Not Disturb (structure from the capture); the `deviceStatus` push is answered result 0 |
| Photo delete | `PhotoSync.delete` | request shape per `protocol/specs/photos.md` 6.1 against a scripted phone; behind a confirmation in the app; not captured, not tried live |
| Nano, first layer | `Nano/NanoPacket.swift` | the packet header, session key derivation and the encryption around each datagram of the peer-to-peer transport, from `protocol/specs/nano-wire-notes.md`. The key derivation reproduces the test vector of RFC 3711 appendix B.3; sealing and opening agree with each other. **Confirmed on a recording of 2026-10-09**: 443 of 444 datagrams of a real phone-to-PC file transfer open and authenticate with keys taken from the relay capture. Nothing in the app uses this code yet. `Nano/PacketCapture.swift` reads UDP datagrams from a `tcpdump` file, and `winphone-probe nano-check <recording.pcap> <flows.jsonl>` tries the decoder on a recording with the keys from the relay capture taken alongside, printing counts and packet kinds only. All 136 key sets in the capture of 2026-10-09 parse as 16-byte keys and 14-byte salts written in hexadecimal |
| Nano, the layers above | `Nano/NanoLayers.swift`, `Nano/NanoTrace.swift` | probing, keep-alive, rate-control handshake and header, channel multiplexer, sequencer header, Message and Blob channel packets, with encoders; a decoder that follows a recorded connection. Checked on the recording of 2026-10-09: the whole phone-to-PC file share decodes with no packet left over and the file comes out at its announced size (`winphone-probe nano-file`). **Decoding only**: nothing yet opens a connection or sends |
| Receiving files | `Nano/NanoConnection.swift`, `Nano/NanoFileReceiver.swift`, `Nano/NanoSignalling.swift`, `Sources/WinPhone/Views/FilesView.swift` | the PC's side of a phone-to-PC share: the announcement on the relay, the request for a direct connection, UDP to the phone, the start sequence, acknowledgements and retransmission, accepting the phone's channels, the three messages the PC contributes, saving to Downloads. Tested against scripted phones built from the same codecs: a whole share from announcement to bytes, with every fifth packet lost, a refused channel, a silent phone, a wrong key; the UDP socket against a local listener. **Confirmed live on 2026-10-09 20:58: a file shared from the phone arrived on the Mac** (33,726 bytes, saved to Downloads), over the Phone Link form of the exchange, which the phone chose and which had never been captured; the cross-device form is tested against scripted phones and the Windows recording only. **Large files confirmed live at 21:47 the same day** (25.9 MB in 4.6 s, 380 MB in 47 s): `Nano/NanoReliability.swift` keeps the book of arrivals, acknowledges only up to the first missing packet, reports what is missing with an acknowledgement vector and follows the phone when it gives old numbers up; tested with the vector path and the timer path each alone. The cross-device identity now announces `FILE_TRANSFER` (Settings, "Receive files shared from my phone", on by default); the service accepted that enrollment on 2026-10-09 |
| Heartbeat | `Features/NotificationSync.swift` | the phone's ten-minute `heartbeat` push is answered with result 0, as Phone Link's processor does (seen live 2026-10-09, where it had been answered "unknown type") |
| Settings | `Sources/WinPhone/Views/SettingsView.swift` | per-app notification switch, Mac notifications on or off, open at login (`SMAppService`); model behaviour tested, login item not exercised |
| Caches | `Support/EncryptedFile.swift` | messages, photos, contacts and apps are kept between launches in files sealed with a key from the Keychain; wrong key and tampering are rejected |
| App views | `Sources/WinPhone/Views` | rendered to `Screens/` and inspected |
| Pasteboard, Notification Center | `Sources/WinPhone/Mac` | a private pasteboard; action mapping |
| In-app sign-in | `Sources/WinPhone/Views/SignInWebView.swift` | Microsoft's device sign-in page in a web view that keeps no data; the app enters the one-time code itself. Checked against a local copy of the page's form: the code goes only into the code field, only on an HTTPS Microsoft host. Not yet run against the live page |
| Live backend | `Sources/WinPhone/LiveActions.swift` | compiles and drives the controller; not yet run against the service |
| Robustness | `Tests/WinPhoneCoreTests/RobustnessTests.swift` | audit of 2026-10-09: garbled certificate times, abandoned partial messages, stale acknowledgements, a silent relay |

**First live connection: 2026-10-09.** The app signed in through the in-app page, created and
enrolled both identities, woke the phone, brought both roles online in about two seconds, and
showed a notification posted on the phone a second after it was posted. The log of that run is
`evidence/live/2026-10-09-first-connection.log`. The same day the user confirmed
the banner, clipboard text and screenshots in both directions, and dismissing from the Mac.
HEIF photos do not sync because Link to Windows does not announce that format. Not yet
exercised live: reply and action buttons, and pairing a phone that is not linked.

The app writes a diagnostics log to `~/Library/Logs/Phone Mac Link/phone-mac-link.log` (steps, hosts, status
codes and error codes; never tokens, bodies, notification text or clipboard content). The app without `--demo` now uses the real
stack: it stores its state in the login keychain (item `com.winphone.app`), signs in with a device
code, pairs, and connects.

## Two client roles

Windows runs two clients side by side: Phone Link (`PL`) carries notifications over APP messages,
and the Cross Device service (`WEA`) carries the clipboard over PLATFORM messages. The phone
offers notifications only to a `PL` peer and its clipboard only to a `WEA` peer that lists
`CLIPBOARD`, and it accepts concurrent sessions from both types. The Mac therefore enrolls two
identities, one per role (`ClientProfile.phoneLink`, `ClientProfile.crossDevice`), and
`LinkController` runs one `RoleSession` per role over its own relay socket. The reasoning is in
`PLAN.md`, section 1.1.

Launching with `--single-client` instead enrolls one Phone Link client that also lists `CLIPBOARD`
(`ClientProfile.unified`). The LinkMyPhone project reports from live runs that a phone gives such
a client both features; we have not verified it. It is the first thing to try if two roles
misbehave live.

## What does not exist yet

- Writing to the phone's storage (browsing and downloading exist: Phone Storage). Connections when the two devices are not on one network exist
  (`Nano/Ice/`, `Nano/NanoConnector.swift`, `protocol/specs/nano-ice.md`): checked against the
  recording and against the real relay servers, not yet tried with the phone; IPv4 only. Screen mirroring exists (`protocol/specs/mirroring.md`, confirmed live on
  2026-10-10); calls over Bluetooth work as control only: the call's sound cannot come to the Mac
  (`protocol/specs/calls-bluetooth.md`, section 5). Sending files to the phone exists (`Nano/NanoFileSender.swift`,
  Files, Send Files… or drop; confirmed live on 2026-10-09 22:22 with two small files). Received
  files are written to `~/Library/Caches/Phone Mac Link/Incoming` as they arrive and moved to
  Downloads when whole; a share larger than the free disk space is declined on the Mac.
  Photos: deleting from the Mac is not built. Media volume cannot be set over the relay.
- Content caches live in `~/Library/Application Support/Phone Mac Link/`, encrypted; signing out
  drops their key. Read marks for conversations are in the app's preferences.
- `Registration/Register`: there is no push channel on a Mac, so the phone cannot wake us; we
  hold the relay connection open instead.
- Second audit of 2026-10-09 (feature code): fixed four crashes reachable from phone data
  (size sums, SIM and action numbers beyond 32 bits, a date at the end of time), a draft that
  could follow the selection to another conversation, send numbers that restarted at each
  launch, photos hidden after a mere timeout, PIN digits in the log, banners and caches that
  outlived sign-out or unlink, and the HTML importer run on outside markup.
- Third audit of 2026-10-09 (the afternoon's code): no crash path found. Fixed: a session
  replaced while still connecting could end its successor's event forwarding or attach the
  shared features to a dead connection (forwarders are now kept per session, and a session
  checks that it is still wanted before each step); switching the call history off could be
  undone by a late push; attachments are opened only for a named list of media and document
  types, saved files and temporary copies carry the download quarantine mark, and unknown
  file endings get `.download`; unlinking now clears that phone's caches, notifications and
  banners and moves on to another phone; picture previews decode only everyday formats; the
  HTML-to-text step is one linear pass. Device controls give up after 12 seconds.
