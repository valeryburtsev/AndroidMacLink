# Screen mirroring ("Phone screen")

How Phone Link shows the phone's screen, from one session recorded on 2026-10-09 with Windows
mirroring a Samsung S21+ (`captures/nano-udp-4.pcap` with the relay capture
`captures/vm-raw-2026-10-09`). Everything below is **[wire]** unless marked. The recording holds
the screen's picture; none of it is reproduced here.

The Mac client implements this in `app/Sources/WinPhoneCore/Nano/` (`NanoMedia.swift`,
`NanoMirrorSession.swift`, `PhoneScreenMirror.swift`) and `app/Sources/WinPhone/Mac/ScreenVideo.swift`.

## 1. Signalling on the relay

The Phone Link client sends APP `/nanohandshake` as for file transfer (`file-transfer.md` 2.3)
with `workflow` = `permission`. Windows sent four such requests within a second, each with a
longer `handshake` (715 to 3,369 bytes: one transport offer more each time), and opened four
Nano connections; only the first carried anything beyond its launcher channel. The keys of
each connection are in the phone's answer (`security.key`, `security.salt` at the top level).

## 2. Control messages on the connection

All are messages on `Messaging` channels with JSON bodies. `PC>` is Windows.

| # | Dir | Channel (properties) | Path | Body |
|---|---|---|---|---|
| 1 | PC> | launcher (`workflow=launcher`) | `/workflow` | `{"workflow":"permission","workflowId":<guid>}` |
| 2 | PH | | | creates a channel `workflow=permission` |
| 3 | PC> | permission | `/permission/requestPermission` | `{"permission":"screenScrape"}` |
| 4 | PH> | permission | `/permission/permissionStatus` | `{"status":"inProgress"}` while the phone asks its user (a notification), then `{"status":"accept"}`; `deny` is the other outcome **[inferred]** from `checkPermissionResult` |
| 5 | PC> | permission | `/permission/checkPermission`, `/permission/showPermission` | `{"permission":"oemAudio" or "audio","transactionId":<guid>}`; answered on `…Result` with `status` and the same id. For sound only |
| 6 | PC> | launcher | `/workflow` | `audio`, then `remote` |
| 7 | PH | | | creates `workflow=audio` and `type=orchestrator&workflow=remote` |
| 8 | PC> | orchestrator | `/mirror/phone/config` | `{"maxMainDisplayFps":0,"appsFeatureType":2,"width":2038,"height":1622,"dpi":192,"hostDisplayWidth":2048,"hostDisplayHeight":1834}` (the PC's window area and display) |
| 9 | PC> | orchestrator | `/mirror/phone/alwaysInExpandedLayoutChanged` | `{"isAlwaysInExpandLayout":false}` |
| 10 | PC> | orchestrator | `/mirror/phone/launchApp` | `{"packageName":"yourphone.phonescreen","sessionId":<guid>,"targetScreenLayout":0,"flags":3}` |
| 11 | PH> | orchestrator | `/mirror/phone/setLockedState` | `isLocked`, `isFolded`, `canDraw`, `isScreenOn`, `isSecureLocked`, `isAlwaysUnlockedDisplay`, `isVirtualDeviceStreamingSupported`; repeated whenever one changes |
| 12 | PH> | orchestrator | `/mirror/phone/appLaunchResult` | `{"result":"success","sessionId":…}` |
| 13 | PH | | | creates four channels with `packageName=yourphone.phonescreen&sessionId=…&setId=phonescreen&type=container&workflow=remote`: `Messaging`, `Blob`, `Input`, `Video` (the video one also `syncId`) |
| 14 | PH> | container | `/mirror/phone/deviceResolutionChanged` `{"width":1080,"height":2400}`, `/mirror/phone/screenLayoutStatus`, `/mirror/phone/appReady` | |
| 15 | PH> | orchestrator | `/mirror/phone/requestBlackScreenState` | (4 bytes, not JSON); Windows answers `/mirror/phone/blackScreen` `{"blackScreenToggleState":true}` |
| 16 | PC> | launcher | `/stopWorkflow` | the same objects as in 1 and 6, one per workflow, at the end; the phone sends its own for `permission` and `remote` |

**Waking a locked phone** **[code-windows]** + **[code-android]**, not in the recording (the
phone was unlocked): the PC sends `/mirror/phone/wakeScreen` on the orchestrator channel with
an empty JSON object, when its window opens and when the user acts on a locked picture
(W: RemotingFlowManager.SendWakeScreen, Session.Services.WakeDeviceHandler, UnlockDeviceHandler).
The phone switches its screen on and, if the keyguard is up, starts an activity that calls
`KeyguardManager.requestDismissKeyguard` (A: screenmirroringsrc.appremote.wake.
WakeScreenNoKeyguardHandler, KeyguardDismissActivity): a lock without a secret goes away, one
with a secret shows its prompt. Nothing in either program sends the secret itself. The Mac
client sends the request once when the phone first reports "locked or screen off", again on a
click or key while that lasts (at most every two seconds), and from the label on the locked
picture.

**A session begun on a locked phone** **[live]** 2026-10-10, Galaxy S21+, three times: the
phone reports `isLocked` true with `isSecureLocked`, answers `launchApp` with success, creates
all channels and offers video, but sends **no frame**, neither while locked nor after it is
unlocked. Keys do arrive: the PIN typed on the Mac's keyboard unlocked the phone, unseen. A
session begun right after, on the unlocked phone, has its picture at once. The Mac client
therefore asks for the stream a second time when the phone reports "unlocked" and no frame has
come, and if 1.5 seconds later there is still none, ends the session and starts a new one (at
most twice). Whether the second request alone helps is not known yet; the log says which of
the two it was.

Sound: `/audio/pcStreamingAllowed` `{"isAudioStreamingAllowed":true}` from the PC, `/audio/phoneConfig`
`{"frameLengthMs":40}`, `/audio/volumeChanged`, `/audio/streamReady` from the phone, and a channel
of class `Audio` whose packets (payload types 36, 37, 38) are not decoded.

## 3. Video channel (class `Video`)

Packets: u32 kind, u32 1, u32 length of the rest; little-endian.

| Kind | From | Rest |
|---|---|---|
| 1 offer | phone | u32 version (6), u32 width (720), u32 height (1600), u32 frames a second (60), u64 clock in ms, u32 count, then per format: u32 rate, u32 width, u32 height, u32 codec (0 = H.264) |
| 2 answer | PC | u32 the number its frame reports start at, one format |
| 3 control | both | u32 flags, then by flag: 0x30 "start, with a whole frame" (nothing); 0x81 "frame shown": u32 frame, u64 clock in µs, sent for every frame; 0x02 and 0x122 "frames lost": u32 first, u32 last. The phone sends 0x1000 once with 32 bytes (not understood) |
| 4 data | phone | u32 flags (6 a frame decodable alone, 4 one that builds on others), u32 frame, u64 time in µs, u32 0, u32 total size, u32 number of pieces, u32 offset, u32 length + metadata (empty), u32 length + bytes (1,275 a piece) |

Frames are H.264 with start codes: first a frame of the two parameter sets alone, then a whole
picture, then pictures that build on it. Frame numbers go on from the PC's number plus one.
1,283 of 1,301 frames arrived whole in 90 s (about 14 a second on a mostly still screen);
Windows reported the gaps and the phone answered with whole pictures.

The sequencer header's first byte is 4 on both handshakes, 5 on the PC's start request, and
the usual chain (3, naming the packet before) on the rest.

## 4. Input channel (class `Input`)

Packets: u32 kind, u32 length of the rest.

| Kind | From | Rest |
|---|---|---|
| 5 offer | phone | u32 4, u32 8, u32 width and u32 height of the screen in its own pixels (1080 x 2400), u32 touches (10), u32 number before the first input frame |
| 6 answer | PC | u32 4, u32 8, u32 10, u64 clock in ms |
| 7 frame | PC | u32 frame number, u64 clock in µs, body |
| 3 ack | phone | u32 frame number |

Pointer frame body, 39 bytes: `00 01 00 00 00 00` (one pointer entry), then the entry: one zero
byte; the left button as a count of its presses and releases (odd while held); seven zero
bytes; u32 x, u32 y in the phone's pixels; two i32 running wheel totals in Windows' units of
120 to a notch (the first taken as horizontal, the second as vertical **[inferred]**); eight
zero bytes. Windows sends a frame for every move of the pointer, pressed or not, with the
sequencer byte 1 and no dependency.

Key frame body, 18 bytes: `00 00 00 01 00 00`, then `00 01`, a key code and its count of
presses and releases, eight zero bytes. Codes seen: 0x06, 0x2C, 0x6E (twice, about when the
window's Back button was used). The code table is **not known**.

## 4a. Addendum, 2026-10-10: first live session, and the phone's own tables

The Mac client mirrored the phone live on the first try (2026-10-10 08:01): permission
answered "accept" at once (it had been given the evening before), video 0.4 s after the
request for the screen, the session ended cleanly on `/stopWorkflow`. **[live]**

From the phone app's code (`com.microsoft.mmx.screenmirroringsrc.InputInjector`,
`InputKeyMapping`, `nano.jni.channel.IInputTargetChannelDelegate`) **[code-android]**:

- **Keys are USB keyboard usage numbers** (4 is A, 0x28 Return, 0x2C Space, 0xE0 to 0xE7 the
  modifiers); the phone maps them to Android key codes and scan codes. Three numbers are its
  own: **106 Home, 109 Recents, 110 Back** (0x6E is what the window's Back button sent).
- **Mouse buttons** are numbered 0 left, 1 middle, 2 right. The pointer entry is taken to hold
  their counts in that order after its first byte **[inferred]**; only the left one was recorded.
- **The wheel totals are x then y**, each divided by 120 on the phone and given to Android as
  horizontal and vertical scroll.
- The phone turns a move without a button into a hover, and with one into a drag.

Sound, from the recording's handshake only (nothing played in it): the `Audio` channel's
packets carry no kind inside; the datagram's payload type is 35 plus the kind. 36 offer: u32
version (7), u64 clock, u32 count, per format u32 channels (2), u32 sample rate (48,000), u32
codec (0, taken to be Opus). 37 answer: u32 first frame number, one format. 38 control: u32
flags, 0x10 start. The data packet (39 **[inferred]**) was not recorded; the client assumes
flags, frame number, time, then the frame with its length, and logs sizes if that is wrong.

## 4a-2. A session begun right after the unlock (live, 2026-10-10 20:07)

The session begun on the locked phone was ended 1.5 s after the unlock, as built, and the next
one opened at once. That one got every channel, a video offer and "unlocked, screen on", and
no frame for twelve seconds, until it was stopped by hand; a session begun one second after
that showed the picture. So two more rules in the Mac client: a session that ended itself is
replaced only after 1.2 s (`PhoneScreenMirror.restartPause`), and any session whose phone is
awake but has sent no frame 3 s after the stream was started asks for the stream again and,
failing that, ends itself to be replaced (`NanoMirrorSession.watchForTheFirstPicture`), up to
three times. Why the phone stays dark there is not known; its putting the old session away
while the new one starts is a guess.

## 4b. Turning the phone (2026-10-10, from both sides' code; not in the recording, not yet tried live)

The phone has two ways to say that what it shows changed shape, both on the container's
message channel:

1. **The whole screen, or an app whose display the phone resizes.** The phone's
   `AppContainer.onBoundsChanged` starts the video source again with the new size
   (`IVideoSourceChannel.Reinitialize(width, height, fps)`) and sends
   `/mirror/phone/deviceResolutionChanged {"width":..,"height":..}`. Phone Link takes the
   picture's new size from the video channel and counts pointer positions in the new device
   resolution; a picture size that is upright while the device resolution lies on its side (or
   the reverse) it holds back until the other arrives (`VideoService.IsVideoOrientationStale`).
   What `Reinitialize` puts on the wire was not recorded: a new offer on the video channel, or
   only new parameter sets in the stream.
2. **An app that lies on its side on a display that stays upright** (the Samsung app
   container): `/mirror/phone/orientationChanged {"orientationInfo": n}`, n = 0 to 3. The
   picture is not changed; Phone Link shows it turned by n quarter turns against the clock
   (`SetRotation(-90 * n)`), swaps width and height of the device resolution for odd n, and
   sends positions in that turned shape. While n is not 0 the phone ignores bounds changes.

The Mac client [built]: `NanoMirrorSession` keeps the device resolution (from the input
offer, then from the message) and the quarter turns, reports `.inputSize` in the turned
shape and `.rotation`; a second video offer on the channel is answered like the first and
its frames counted afresh; the app also reads the picture's size from the stream's parameter
sets, so either form of `Reinitialize` is followed; the view turns the picture layer and
takes the turned shape. Tests: `testThePictureFollowsThePhoneWhenItIsTurned`,
`ScreenTurnTests`.

## 5. Open

- Which wheel total is which axis, and the direction; the other mouse buttons.
- Key codes; text input.
- Sound.
- What `blackScreenToggleState` does to the phone's own display.
- Opening a single app instead of the whole screen (`packageName` of the app, `appsFeatureType`).
- The display description the phone needs: the Mac sends the recorded numbers unchanged.


## Pressing a notification's button: the "early launch" workflow (2026-10-13)

Found because the plain notification command (`/notifications`, operation 5 with
`actionIndex`) was answered "needs permission" (result 7) every time on the S21+, although
the phone holds every permission (asked silently: appear on top, notification access and
Bluetooth all held). Phone Link on Windows pressed the same button without trouble. A
capture of that click (`captures/vm-notification-button-2-2026-10-13`, relay decrypted)
shows **no** `/notifications` request at all: four APP `/nanohandshake` requests with
`workflow` of eleven characters, answered `result 0`, and nothing else. [observed]

From both clients' code [inferred from code, then built]:

- Windows picks a handler by priority. `PhoneScreenNotificationLaunchHandler` (priority 2)
  takes notification buttons whenever the phone shows its apps on the computer
  (`IsPhoneScreenAppsSupportedAndEnabled`), before the plain command's handler is asked.
  It calls `LaunchPhoneAppWithNotification`, which `NotificationLauncher` carries out over
  the workflow for "permission independent launches": `earlyLaunch`.
- The connection is opened like the screen's (`/nanohandshake`), with `workflow`
  `earlyLaunch`. On the launcher channel: `/workflow {"workflow":"earlyLaunch","workflowId":<guid>}`.
  The phone creates a messaging channel with `workflow=earlyLaunch`.
- On that channel: `/mirror/phone/launchNotification`
  `{"transactionId":<guid>,"key":<the notification's key>,"actionIndex":<n>}`.
  The phone answers `/mirror/phone/launchNotificationResult {"transactionId","launchResult"}`:
  0 launched on a virtual display, 1 on the phone's own display (Windows then opens the
  phone's screen), 2 failed, 3 error, 4 already used.
- On the phone this reaches `EarlyLaunchDelegate.startNotificationLaunch(..., allowDirectAction: true)`:
  a button whose intent is not an activity is fired directly (`sendActionDirectly`,
  strategy `directPendingIntent`). No transparent activity, no background launch, which is
  what fails on the plain command's path (`BackgroundNotificationLauncher`).
- The same message is also taken on the orchestrator channel of a running screen session.

Built: `Nano/NotificationLaunch.swift`, `RoleSession.pressNotificationButton`,
`LinkController.invoke` tries this first and the plain command after it. Not while the
phone's screen is shown here (one such connection at a time): then the plain command, and
a note to close the screen if that fails. Checked against a scripted phone, and live on 2026-10-13 10:21: two presses of "Mark as
read", each answered `launchResult 0` about 0.2 s after the connection opened; the user
saw them take effect. [confirmed live]

Capture note: the relay connection of Phone Link on Windows is held by
`CrossDeviceService`, not by the app's window; restarting the window does not make it
re-read the proxy setting. The recorder must also be told to decrypt `*.signalr.net`.


## A picture that breaks and stays broken (2026-10-16)

Seen live: over a lossy local network the phone gave up resending 584 video packets in a
minute; of 697 frames only 5 were whole, the last about 16:30:28, and the picture stayed
frozen. The app reported each gap (`0x122` with the lost range) but asked again only when a
later frame arrived, and a still screen sends almost none. Built: while the picture is
broken the connection repeats the `0x122` report once a second; the session asks for the
stream afresh (`0x30`, the start request) after 3 s and every 3 s after that, and starts a
new session after 10 s (`restartWanted`). A session that showed the screen for 30 s or more
no longer counts towards the three restarts. Checked with a scripted phone that breaks
its picture (mended by asking again, or not at all); not yet seen live.


## Same network, Windows against this app (2026-10-16, `captures/mirror-compare-2026-10-16.pcap`, headers only)

Phone Link in the VM and this app mirrored the phone one after the other over the same
Wi-Fi, recorded on the Mac's interface (128-byte snapshots; packets counted by the RTP
sequence in the clear):

| | Windows (VM) | this app |
|---|---|---|
| seconds | 78.6 | 28.4 |
| from the phone | 375 packets/s, 3.8 Mbit/s | 530 packets/s, 5.5 Mbit/s |
| never arrived (air loss) | 2.10 % in 75 gaps | 0.29 % in 14 gaps |
| to the phone | 54 packets/s | 81 packets/s |

The network was not the difference; the app received more and lost less. The app's own
counters showed the cost: about one frame in 75 given up and the picture stalled until a
whole one came. The reason: the frame assembler handed over frame N+1 the moment it was
whole and dropped frame N, still waiting for one resent piece, which the phone sends a few
milliseconds after the loss report. Built: `NanoVideoAssembler.take` holds whole frames that
follow a missing one for up to 60 ms (`reorderWait`), shows them in order when it completes
and only then counts a gap; a whole picture never waits. The log counts "mended in time".

Correction the same evening: the wait mended none of 11 gaps in the next run ("0 mended in
time"), so the phone does not send lost video again; it answers the loss report with a whole
picture. The waiting is off (`reorderWait` zero). What made the picture stall was this app
holding every frame after a loss until that whole picture arrived (156 of 1,819 frames held
back). `ScreenVideo` now draws on through a loss and counts it ("drawn past a missing one");
the loss report and the request for a whole picture still go out. Whether the decoder's
smudge until then is acceptable is the user's call; not yet seen live.


## Protected app screens

An app that protects its screen (Android's secure windows: banking, payment, password and some
streaming apps) is blanked by Android for every capture, Link to Windows included, so the video
stays black while it is in front. Link to Windows says so on the orchestrator channel:
`PH> /mirror/phone/secureContentChanged {"isSecureContent": true|false}` (code: the container
message channel adapters' `sendSecureContentChange`; the platform channel sends the same as a
protobuf message with field 1 `isSecureContent`). Nothing on the PC side can restore the picture;
the client shows why it is black until the flag goes back to false.
