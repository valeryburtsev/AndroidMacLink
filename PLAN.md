# Phone Link for macOS: reverse-engineering and implementation plan

Goal: a macOS app that an Android phone running **Link to Windows** (`com.microsoft.appmanager`)
treats exactly like a Windows PC running **Phone Link**, including linking a phone that has never
been linked before (QR code or PIN), so the phone's existing app works unchanged.

Revision 3, 2026-10-09. Changes from revision 2: the implementation is our own, written in Swift
as a single native macOS app. No third-party Phone Link client is forked or vendored. LinkMyPhone
remains a reference document only. Phase 1 is reorganized around building our own stack, verified
offline against our captures before anything goes live. Every factual statement below is backed by
an entry in `evidence/claims.jsonl`.

---

## 1. Status

| Item | State |
|---|---|
| Tooling on the Mac (Go, jadx, apktool, ilspycmd, Frida, mitmproxy, tshark, adb) | Done |
| Windows 11 ARM VM in VMware Fusion, reachable over SSH with a project-only key | Done |
| Phone Link 1.26072.257.0 pulled and decompiled (77 managed assemblies, unobfuscated) | Done |
| Link to Windows 1.26082.130.0 pulled from a Samsung S21+ and decompiled (34k Java files, readable) | Done |
| Protocol corpus: 63 REST endpoint templates, 172 routes, 29 Windows schemas, 69 Android `.proto` sources | Done |
| VM and phone paired; redacted snapshot of the paired state saved | Done |
| Live traffic capture from the VM (startup, relay, unlink, QR pairing) | Done |
| Mac-side implementation | **Live since 2026-10-09 13:36**: the Mac app signed in, enrolled, woke the phone, connected both roles and received a notification. 149 offline tests (134 library, 15 app). See section 1.1 |

### 1.1 Implementation status (2026-10-09)

`app/` holds a Swift package with a protocol library, the app, and 274 passing tests. Details and
the list of what each layer was checked against are in `app/README.md`.

| Phase 1 step | State |
|---|---|
| 1. Project skeleton, generated schemas, fixtures from captures | Done |
| 2. Codecs: MessagePack, SignalR, DCG packets, envelopes | Done; real frames re-encode byte for byte |
| 3. Identity and enrollment client | Done: `Identity/IdentityService.swift` runs discovery, nonce, create or sign-in, enrollment, device-list trust sync and wake, with the retry and unlink rules of the spec; checked against a scripted service that verifies our proofs |
| 4. Trust store and persistent state | Done: `Identity/StateStore.swift`, one JSON document in a login-keychain item (`KeychainStateStore`, round trip verified on the real keychain), with file and memory stores for the probe and tests |
| 5. Relay client | Done against a scripted hub; not yet run against the real one |
| 6. Sign-in and first live call | `Account/AccountSession.swift` caches and refreshes the account token; `Session/LinkController.swift` ties sign-in, pairing, both roles and reconnection together; the app runs on it. Nothing has gone live |
| 7. Clipboard | Protocol engine, pasteboard integration and session wiring done; not live |
| 8. Notifications | Protocol engine, Notification Center integration and session wiring done; not live. Real pushes, removals and the PC commands (permission, reconcile, dismiss, clear all) were captured on 2026-10-09; our messages match them |
| 9. Resilience | Reconnect with backoff per role; token renewal on 401; identity recreated after `DeviceUnlinked`; sign-in requested again when the refresh token dies |
| 10. Content features | `/connect/v1` handshake with Windows' exact configuration; photos (`PhotoSync`), messages (`MessageSync`) with encrypted on-disk caches so later launches ask only for changes; phone status; Android 15 sensitive-notification permission flow |

**Two client roles (decided 2026-10-09).** The phone pushes notifications only to a peer whose
DCG metadata says `clientType` `PL`, and attaches its clipboard listener only for an active `WEA`
peer that lists `CLIPBOARD` (Link to Windows: `SyncExecutor`, `ClipboardListenerManager`,
`RemoteAppUtil`). Windows satisfies both with two enrolled clients that share one socket through
"connection sharing", which needs both to carry the same service-assigned `distinguishedDeviceId`,
a value we cannot control. The phone's session tracker accepts concurrent sessions from different
client types (`canAddSessionWithoutConflict` succeeds whenever the client type is known), so the
Mac enrolls **two identities**, `PL` and `WEA`, and runs one relay session per role. Cost: two
sockets and two wakes. A cheaper alternative is built in behind `--single-client`: one `PL`
client that also lists `CLIPBOARD` (`ClientProfile.unified`). LinkMyPhone's notes (2026-10-05)
report that this worked live on a Samsung S23 for both features; Windows never enrolls that
combination and we have not verified it. The first live run should try both.

**Sign-in (2026-10-09).** Device-code grant with Phone Link's client ID, shown inside the app:
`SignInWebView` loads `microsoft.com/link` in a non-persistent `WKWebView` and enters the code.
Passing the code in the address (`?otc=`) fails for a signed-out visitor with a "first party
application" error whatever the code is, so the code is typed into the page's field instead.

| 11. Device controls and the rest of 2026-10-09 | Ring my phone, ringer mode, Do Not Disturb, media keys with a "now playing" card (`Features/DeviceControls.swift`); picture-message attachments in and out; per-app notification switches and a settings window; contacts and app icons; photo delete; call history with "dial on phone" (off by default, `protocol/specs/calls.md`). The controls and picture messages are built from the decompiled handlers only: no capture, not yet tried live |

Also done ahead of order: the pairing client and state machine (Phase 2), and the app's
interface with onboarding, QR code, PIN and notification screens (Phase 4), running on demo data.

Steps 3 and 4 stopped when a safety system halted the work on 2026-10-09 while that code was
being written. They are left for a decision by the project owner. Everything live depends on them.

Three implementation-level specs now exist in `protocol/specs/`, each fact tagged as seen in
code, seen on the wire, or inferred.

Settled live on 2026-10-09: the service accepts our client with a device-code token, and two
roles connect side by side. Still open: the manual pairing flow, pairing a phone from the Mac
(the test phone was already linked), the native Nano library, and the Samsung
companion packages (pulled, not yet decompiled). The two-role question is settled in section 1.1.

---

## 2. What we are replicating

Phone Link is **cloud-relayed**. The PC and the phone both sign in to the same Microsoft account and
meet in Microsoft's Device Connectivity Gateway (DCG). There is no LAN discovery step.

### 2.1 Stack, bottom to top (observed in both clients)

1. **Microsoft account token.** Windows uses WAM with scope `service::msatoken.dcg.microsoft.com::MBI_SSL`.
   We use the device-code flow with Phone Link's client ID
   `8CF55838-E496-42C5-829B-F8D6945288F3` and scope `https://dcg.microsoft.com/DCG.ReadWrite offline_access`,
   which LinkMyPhone reports working.
2. **DCG identity.** `/Auth/GenerateNonce`, `/Auth/CreateIdentity`, `/Auth/SignIn` with an ES384 nonce
   JWT over a self-signed P-384 certificate. Yields a DCG token and the PC's DCG client ID.
3. **Enrollment and trust.** `/DeviceAuthProxy/EnrollDevice` registers a second "trust" certificate.
   The client then holds an **A2D** trust with the account (type 4) and an **AsyncD2D** trust with each
   linked phone (type 3), stored as `trust_<dcg client id>` pairs. Phone trust is built from
   `/DeviceAuthProxy/GetDeviceInfoList`, not stored by the pairing flow.
4. **Pairing service.** `/DevicePairingProxy/...` links a phone to the account. See section 4.
5. **Wake.** `/Dispatcher/Wake` (push), signed by the trust identity.
6. **Hub Relay.** SignalR over WSS at `relayhub/`, MessagePack protocol. Hub methods
   `SendMessageAsync`, `SendSessionBasedMessageAsync`, `SendConnectedAsync`.
7. **DCG fragments and ACKs**, then **PLATFORM** and **APP** envelopes, then `MSAEP` for PubSub.
   Schemas are identical on Windows and Android.
8. **Session validation.** Capabilities are exactly `SESSION_VALIDATION=1`,
   `PERSISTENT_MESSAGE_CHANNEL=2`, `NANO_TRANSPORT_PREFERENCE=3`.
9. **Features**, each on a named route: `/chat/v1` messaging, `/media/v1` photos, `/contacts/v2`,
   `/calling`, `/devicestatus`, `/command/audio`, `/notifications`, `/fileTransfer`, `/connect/v1`,
   and about 130 routes for screen mirroring and app streaming.

### 2.2 Peer-to-peer transport ("Nano")

Used for screen mirroring, app streaming, drag-and-drop and blobs. Both clients ship the same native
library (`LibNanoAPI.dll`, `liblibnanoapi.so`). Nine channel types exist (video, audio, input, blob,
messaging and others), created through `/Channel/ProtoCreatePlatformChannelRequest`. STUN and TURN
servers come from `/CloudRelay/Relay`. Inferred, not yet captured: the connection is ICE-style and
can fall back to carrying Nano fragments over the hub relay.

Scoping study of 2026-10-09 (`protocol/specs/nano-scoping.md`, from code and the native
library's symbols; no Nano traffic has been captured): one native library on both sides, of the
same family as the Xbox streaming protocol but not known to be byte compatible. The simplest
case, both devices on one network, needs no ICE, STUN, TURN or certificates: the PC asks on
`/nanohandshake`, the phone answers with an address, a port and an SRTP key, and the PC opens
plain UDP. Because that key travels in a relay message the capture pipeline already decodes, a
recorded session can be decrypted offline. Recommended path: that same-network case with the
Message and Blob channels only, enough for file transfer, estimated at 19 to 28 working days
with a go/no-go after one capture. The study corrects two statements above: the channel type
list has eight values, and the "fragment transport" appears to carry relay fragments over Nano
rather than Nano over the relay.

A first pass at the packet layouts followed the same day (`protocol/specs/nano-wire-notes.md`,
static reading of the Android library): a plain 12-byte RTP header, SRTP with AES-128-GCM and
the RFC 3711 key derivation, an inner sequence number carried encrypted, then keep-alive, a
rate-control layer that resembles MS-RDPEUDP2, and the channel multiplexer. The header and
encryption are implemented in `app/Sources/WinPhoneCore/Nano/NanoPacket.swift`. That evening a
recording of a real phone-to-PC file transfer confirmed them: 443 of 444 datagrams opened with
keys from the relay capture. The go/no-go gate of the study is passed. The layers above the
encryption were then read in the clear and implemented as decoders and encoders
(`Nano/NanoLayers.swift`, `Nano/NanoTrace.swift`): the whole recorded share, from channel setup
to the reassembled file, decodes with no packet left over. The sending side followed the
same night: signalling on the cross-device session (`Nano/NanoSignalling.swift`), the connection
engine (`Nano/NanoConnection.swift`) and the receiver (`Nano/NanoFileReceiver.swift`), tested
end to end against scripted phones and wired into the app (Files section, Downloads, a
notification). The first live share from the phone to the Mac succeeded at 20:58 that night, after one
correction found live (the phone's size probes must be answered). The phone chose the Phone
Link client as its target, so the path confirmed live is that one.

### 2.3 Feature transport summary

| Feature | Path | Confidence |
|---|---|---|
| Notifications, clipboard, messages, contacts, photos, status, media, phone apps list | Cloud relay | Observed in code; clipboard and notifications validated live by LinkMyPhone |
| Linking a phone (QR, PIN) | Cloud pairing service | Observed in code; not yet captured |
| Calls audio | Bluetooth | Microsoft docs; VM has no Bluetooth radio |
| File transfer | Offer and control on the relay, bytes over Nano in both directions; OneDrive is the iPhone path only | `protocol/specs/file-transfer.md`, from code; no transfer captured |
| Screen mirroring, app streaming, drag-and-drop | Nano peer-to-peer | Inferred from names; needs capture |

---

## 3. Strategy

**Our own implementation, in Swift, as one native macOS app.** Nothing from another Phone Link
client is forked, vendored or copied. The sources of truth are the decompiled Windows client, the
schema files recovered from both clients, and our live captures. LinkMyPhone's documentation is
used as a cross-check and credited as a reference.

### 3.1 Shape

One app bundle, `WinPhone.app`, built with Xcode and Swift Package Manager:

| Target | Role | Frameworks |
|---|---|---|
| `WinPhoneCore` (library) | Protocol stack: account sign-in, DCG identity and enrollment, trust, pairing, relay, fragments, envelopes, feature codecs. No UI. Fully testable offline. | Foundation, CryptoKit, Security |
| `WinPhone` (app) | Menu-bar app plus main window: onboarding (sign-in, QR code, PIN), notifications, messages, photos, files, settings. | SwiftUI, AppKit, UserNotifications |
| `WinPhoneCoreTests` | Fixture tests built from redacted captures, plus round-trip tests against the recovered schemas. | XCTest |

The app runs as a login item through `SMAppService`. There is no separate daemon: the protocol stack
lives in the app process, which also owns the pasteboard, notifications and Keychain without any
inter-process bridge.

### 3.2 Platform mapping

| Need | Implementation |
|---|---|
| HTTPS to DCG | `URLSession` |
| Relay WebSocket | `URLSessionWebSocketTask` |
| P-384 keys and ES384 signatures | CryptoKit `P384.Signing` |
| Secrets (refresh token, keys, DCG token) | Keychain through the Security framework |
| Protobuf codecs | SwiftProtobuf, generated from our own `.proto` files written from the recovered schemas |
| MessagePack (SignalR hub protocol) | A small in-house encoder and decoder; the hub uses a handful of types |
| Clipboard | `NSPasteboard`, polled for change count, text, HTML and images |
| Notifications with reply and actions | `UNUserNotificationCenter` with categories |
| QR code rendering | Core Image `CIQRCodeGenerator` |
| Photos and files | Photos not required; files land in `~/Downloads` via `FileManager` |
| Media controls | `MPRemoteCommandCenter` and Now Playing |
| Video for screen mirroring (later) | VideoToolbox, Metal or AVSampleBufferDisplayLayer |
| Peer-to-peer transport (later) | Network.framework, with an ICE implementation decided in Phase 3 |

### 3.3 Rules

- Every protocol constant, field number and route traces to an entry in `evidence/claims.jsonl`.
- Codecs are proven against captured bytes before they are used live.
- Live steps go from least to most side-effectful: sign-in, enrollment, linked-device listing,
  relay, session validation, features, and only then pairing.
- Microsoft's `.proto` sources and all decompiled code stay out of the repository. The `.proto`
  files we commit are ours, rewritten from field names and numbers.

## 4. Authorization and linking design

Two cases must both work. The app decides between them after sign-in by listing linked devices.

### 4.1 Sign-in and enrollment (always)

1. The app starts the device-code flow and shows the code plus a QR code of the verification URL.
   The user signs in on any browser. The app receives access and refresh tokens.
2. The daemon creates the DCG identity, enrolls as a Phone Link device with Windows-compatible
   metadata, and stores both key pairs and the refresh token in the Keychain.
3. It calls `GetDeviceInfoList` with the filter `isLinked eq true`.

### 4.2 Case A: the phone is already linked to this account

No user action on the phone. The daemon builds AsyncD2D trust from the phone's certificate, opens
the hub relay, wakes the phone and runs session validation. LinkMyPhone reports this working live;
we have not reproduced it yet.

### 4.3 Case B: no phone is linked yet (the full link process)

The PC side of the pairing service, as implemented by Phone Link:

1. `POST /DevicePairingProxy/PairingSessions?Api-Version=3.0.0` with headers
   `Authorization: Bearer <MSA token>`, `Authorization-Type: MSA`, `clientRegionName`, and a body of
   `flow` plus `optionalPermission` (`Files.Read`, `Files.Write`, `Camera`, `SMS.Read`, `SMS.Send`,
   `Contacts.Read` or `ALL`).
2. The response carries `pairingSessionId`, `pairingLink`, `challengePIN`, `pairingPIN`, expiry
   times, a polling interval and later `partnerDcgClientId`.
3. The app shows `pairingLink` as a **QR code**, with a countdown to its expiry and a refresh action.
4. The daemon polls `GET PairingSessions/{id}` and drives the UI from the state:

   | Service state | What the Mac shows |
   |---|---|
   | `PENDING_PAIRING_LINK_VISIT` | QR code, or the link and PIN for manual entry |
   | `PENDING_CHALLENGE_PIN_VALIDATE` | The challenge PIN for the user to confirm on the phone |
   | `CHALLENGE_PIN_VALIDATE_FAILED`, `CHALLENGE_PIN_EXPIRED` | Error with `RefreshChallengePIN` |
   | `PENDING_PAIRING_PIN_VALIDATE` | The pairing PIN (manual flow) |
   | `PENDING_PAIRING_PERMISSION_APPROVE` | "Approve permissions on your phone" |
   | `PAIRING_ACCOUNT_MISMATCHED` | "The phone is signed in to a different account" |
   | `READY_FOR_COMPLETE` | Daemon calls `POST PairingSessions/{id}/Complete` |
   | `DEVICE_PAIRED` | Success; continue as Case A with `partnerDcgClientId` |
   | `PAIRING_LINK_EXPIRED`, `PAIRING_PIN_EXPIRED`, `PAIRING_SESSION_EXPIRED`, `PAIRING_FAILED` | Restart offer |

5. After `DEVICE_PAIRED` the daemon refreshes linked devices and builds trust as in Case A.

**Flows to implement.** The service accepts eleven flow names; Phone Link uses three.

| Flow | Mac support | Why |
|---|---|---|
| `QRLINK_CHALLENGEPIN_SIGNIN` | Yes, default | QR code; the phone signs in itself and confirms a PIN |
| `SIGNIN_PIN` | Yes, fallback | Manual pairing for when scanning fails |
| `QR_TransferMSA_V2` | No | Transfers the sign-in to the phone through Windows' account manager with `response_type=qrcode`; there is no macOS equivalent |

**The phone side needs no work from us.** Link to Windows already implements it against
`/DevicePairingProxy/PinSessions` (`QRScanned`, `PINTyped`, `ValidateTrustInfo`) and handles
`ms-phone://connect` links. We only have to present a link it accepts.

**Settled by the pairing capture of 2026-10-09** (details in `protocol/pairing.md`)

- The pairing link is a plain `https://dcg.microsoft.com/dl?...` URL generated by the service. The
  client only renders it, so nothing Windows-specific is needed.
- Session creation is authorized by the Microsoft account token alone. No DCG token is sent.
- The client enrolls first, then creates the pairing session about a second later.
- The QR flow needs no `/Complete` call. The service moves to `DEVICE_PAIRED` by itself and returns
  `partnerDcgClientId`.
- Unlinking the phone invalidates the PC's registrations too. The client must then create a new
  identity and enroll again, so the daemon has to handle `403 DeviceUnlinked` at any time.

**Still open**

- The manual flow (`SIGNIN_PIN`): its states, the pairing PIN, and whether it needs `/Complete`.
- Whether the service accepts a session from our client at all. It sees a device-code token and
  our headers instead of Windows' account manager. Only an attempt from the Mac can answer this,
  which makes it the first thing to test in Phase 2.
- The silent re-pairing endpoints (`SilentPairingWake`, `SilentPairingLookupId`,
  `AccountPairingWake`): when Phone Link uses them and whether we need them.

**Unlinking** uses `/DeviceAuthProxy/UnlinkDevice` and `DeleteCryptoTrustRelationship`. The Mac app
exposes "Remove this phone" and "Sign out", which also deletes the Keychain items.

---

## 5. Phases

### Phase 0: lab and tooling. Done.

### Phase 1: our own core, running on macOS (3 to 5 weeks)

Milestone: **Case A works. The Mac shows up as a linked PC; clipboard and notifications work.**

Steps 1 to 5 need no sign-in and are verified offline against captures. Step 6 is the first live call.

1. **Project skeleton.** Xcode project with the three targets, SwiftProtobuf dependency, our
   `.proto` files for the platform layer (DCG base, fragment, ack, PLATFORM message, session
   validation, device resource manager, MSAEP, PubSub, value set), fixture loader for redacted
   captures.
2. **Codecs.** PLATFORM envelope (both header-length conventions), APP envelope and PBValueSet,
   DCG fragment and ack properties, MessagePack, SignalR framing (handshake, length prefix, hub
   message shapes, trace object). Test: every frame in `captures/vm-relay-2026-10-09` round-trips.
3. **Identity and enrollment client.** Device UUID, P-384 key pairs, self-signed certificate,
   ES384 nonce JWT, the DCG header set, and the request and response models for
   `EnvironmentDiscovery`, `Auth/*`, `Registration/Register`, `DeviceAuthProxy/*`,
   `Dispatcher/Wake`, `CloudRelay/Relay`. Test: requests match the captured ones field for field.
4. **Trust store.** A2D and AsyncD2D relationships keyed `trust_<id>`, built from the account
   certificate and the linked-device list; Keychain-backed.
5. **Relay client.** Negotiate, redirect to Azure SignalR, handshake, presence, fragmentation
   with per-target sequence numbers, ack tracking separate from hub completion, reassembly limits,
   keepalive and reconnect. Test: a scripted fake hub replays the captured session.
6. **Sign-in.** Device-code flow with Phone Link's client ID and scope; tokens into the Keychain.
   First live call. Then enrollment, linked devices, trust, relay, wake, session validation
   against the user's S21+.
7. **Clipboard** (`/Context/Publish` tag 9, `clipboard.v1`, STATUS and CONTENT negotiation,
   generation and echo handling) with `NSPasteboard`, text, HTML and images.
8. **Notifications** (`/legacy/phonecontent` contract 3.99, operations 1 to 5) with
   `UNUserNotificationCenter`, including dismiss, actions and inline reply.
9. **Resilience.** Token refresh, `403 DeviceUnlinked` recovery, sleep and network loss.

### Phase 2: the full link process (1 to 2 weeks, starts with a capture)

Milestone: **Case B works. A phone that was never linked can be linked from the Mac alone.**

1. **Capture real pairings.** QR flow: done, see `protocol/pairing.md`. Manual flow: still to capture.
2. **Try a pairing session from the Mac** as soon as Phase 1 gives us a token and an enrolled
   identity. This is the go or no-go test for the whole link process.
3. Implement the pairing client and state machine in `WinPhoneCore`, with fixture tests built
   from the redacted capture.
4. Build the onboarding UI: QR rendering with expiry countdown, challenge PIN and pairing PIN
   screens, permission-pending screen, every error state, and "pair manually instead".
5. Validate on the S21+ by unlinking and re-linking from the Mac only, in both flows. Confirm
   Windows still works afterwards with the same account.
6. Implement unlink and sign-out.

### Phase 3: features (each 1 to 3 weeks)

Loop per feature: read the schema and both implementations, capture on Windows, write codec and
fixtures, implement the macOS side, validate live, document.

State on 2026-10-09 in brackets.

1. Device status, ringer, battery. [Status live. Ring my phone, ringer mode and Do Not Disturb
   built from code, not yet tried live.]
2. Messages: `/chat/v1`, with attachments. [Sync live. Sending, picture messages in and out
   built, not yet tried live.]
3. Contacts. [Live, over the legacy content route.]
4. Photos: `/media/v1`. [Live. Delete built, not yet tried.]
5. Phone files and file transfer. [Blocked on item 8: the bytes travel only over Nano. There
   is no OneDrive path for Android. `protocol/specs/file-transfer.md`.]
6. Media controls: `/command/audio`. [Built with a "now playing" card, not yet tried live.]
7. Calls: control over the relay first. Audio needs the Mac to act as a Bluetooth hands-free unit,
   which macOS does not expose publicly. Decide after the control path works. [The relay offers
   the call history and "open the dialer with this number", nothing more: no placing, answering
   or ending a call, no call state. Both built, off by default. `protocol/specs/calls.md`.]
8. Nano transport: analyse the native library, capture a session, then choose between
   reimplementing the transport and an interoperable ICE stack.
9. Screen mirroring and app streaming on top of Nano, with a VideoToolbox viewer and input channel.

### Phase 4: the app surface (3 to 4 weeks, overlaps Phases 2 and 3)

Menu-bar item with connection state, main window with sidebar (Messages, Photos, Files,
Notifications, Calls, Apps), onboarding from Phase 2, settings with "Remove this phone" and
"Sign out", login item through `SMAppService`, signed and notarized bundle.

### Phase 5: hardening and release (2 weeks)

Token renewal and revoked-credential handling, sleep and network-loss recovery, several phones on
one account, a non-Samsung test phone, security review of stored secrets and inbound parsing.

---

## 6. Risks

- **Service-side control.** The Mac impersonates a Windows Phone Link client. Microsoft can disable
  device-code sign-in for that client ID, tighten enrollment or change the pairing service at any time.
- **Pairing may check more than we see.** If session creation or completion is tied to something
  only Windows can produce, Case B needs another route. The capture in Phase 2 step 1 is the test.
- **Account transfer is out of reach.** The smoothest Windows flow cannot be reproduced, so the user
  always signs in on the phone themselves during first linking.
- **Calls audio** depends on a Bluetooth role macOS does not offer publicly.
- **Screen features** depend on the native Nano library and are vendor-gated on the phone.
- **Copyright.** Microsoft's `.proto` sources and all decompiled code stay out of the repository.
- **Terms of use.** Development uses a throwaway Microsoft account.

---

## 7. Milestones

| # | Milestone | Effort | State |
|---|---|---|---|
| 0 | Lab, both clients decompiled, protocol corpus | 1 week | Done |
| 1 | Case A: already-linked phone connects; clipboard and notifications | 3 to 5 weeks | **Done and confirmed live on 2026-10-09** (banner, dismiss, clipboard text and images both ways) |
| 2 | Case B: full link process from the Mac, QR and manual | 1 to 2 weeks | Built and replay-tested; live test deferred by the user so the phone stays linked |
| 3a | Status, messages, contacts, photos, files, media controls | 4 to 6 weeks | Status, photos, messages, contacts and app icons live on 2026-10-09. Built the same day from code alone and waiting for a first live try: sending texts, picture messages, device controls, media keys, photo delete. Files wait for Nano |
| 3b | Calls control, then audio decision | 2 weeks plus unknown | Call history and "dial on phone" built, off by default, not yet tried live. The relay has no call control beyond that |
| 3c | Nano transport, then screen mirroring and app streaming | 6 to 10 weeks | Scoped on 2026-10-09: same-network file transfer first, 19 to 28 days, starting with one UDP capture |
| 4 | App surface, onboarding, packaging | 3 to 4 weeks, parallel | Main window, menu bar item, onboarding, settings with per-app notification switches and login item exist; not notarized |
| 5 | Hardening and release | 2 weeks | |

---

## 8. Where things are

- `protocol/windows-catalog.md`: endpoints, hub methods, routes by feature, schema index.
- `protocol/recovered/windows/`: schemas rebuilt from embedded descriptors.
- `protocol/recovered/android/`: Microsoft's original `.proto` sources (git-ignored).
- `protocol/specs/`: implementation-level specifications, each fact tagged as code, wire or
  inferred: `identity-enrollment-trust`, `relay-transport`, `session-clipboard-notifications`,
  `photos`, `messages`, `contacts`, `phone-apps`, `device-controls`, `calls`, `file-transfer`,
  and the scoping study `nano-scoping`.
- `TEST-CHECKLIST.md`: what to try live next, safest first.
- `evidence/claims.jsonl`: every finding with its status and the hash of its source binary.
- `corpus/`: binaries and decompiled code (git-ignored, read-only).
- `tools/README.md`: how to rerun every step.
- `third_party/linkmyphone/`: read-only clone of LinkMyPhone, kept as reference documentation only.

Sources: LinkMyPhone (https://github.com/YMGPwcca/linkmyphone), Microsoft `[MS-CDP]`
(https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cdp/f5a15c56-ac3a-48f9-8c51-07b2eadbe9b4),
Phone Link privacy analysis (https://www.ctrl.blog/entry/microsoft-phone-link-privacy/), and the
two decompiled clients.
