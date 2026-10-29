# Calls over Bluetooth: the Mac as the phone's hands-free unit

Status on 2026-10-10: **control works live** with the user's Galaxy S21+ on macOS 27 (connection
at the first try through the system's class, a call placed from the Mac, its states dialling,
ringing, active, and ended from the Mac). **The call's sound cannot come to the Mac**: section
5. `calls.md` section 9 explains why this is Bluetooth and not the relay: Phone Link makes the
PC a Hands-Free unit of the phone, as a car kit is, and the phone's side is Android's own
Bluetooth stack, not Link to Windows.

Tags: **[profile]** the Bluetooth Hands-Free Profile specification (public), **[macos]** read
from the system's headers and the framework's code, **[built]** what the Mac client does,
**[live]** seen with the phone.

## 1. What is needed

- The phone paired with the Mac in System Settings, Bluetooth (classic pairing, once). The
  user's phone already is.
- Bluetooth permission for the app (the system asks when the switch is first turned on), and
  microphone permission once a call's sound comes to the Mac.
- No message on the relay. The relay only gives the linked phone's name, used to pick the right
  one among the paired phones.

## 2. The dialogue [profile]

A serial channel (RFCOMM) to the phone's "Handsfree Audio Gateway" service (service class
0x111F; its channel number is in the phone's service list). Text lines, each command ended with
a carriage return, each answer wrapped in carriage return and line feed. One command at a time;
the phone ends each with `OK` or `ERROR` (or `+CME ERROR: n`).

Opening exchange, in this order:

| Sent | Answer | Meaning |
|---|---|---|
| `AT+BRSF=54` | `+BRSF: <n>` | Features of each side. 54 = three-way calling, caller's number, remote volume, enhanced call status. No codec negotiation (bit 7), so the sound, if any, is plain narrow-band. |
| `AT+CIND=?` | `+CIND: ("call",(0,1)),("callsetup",(0-3)),...` | The phone's indicators, in its own order. |
| `AT+CIND?` | `+CIND: 0,0,1,4,0,3,0` | Their values now. |
| `AT+CMER=3,0,0,1` | | Report every change as `+CIEV: <position>,<value>`. |
| `AT+CHLD=?` | `+CHLD: (0,1,2,3)` | Only when the phone's features have bit 0 (three-way calling). |

After that: `AT+CLIP=1` (caller's number with each ring), `AT+CCWA=1`, `AT+CMEE=1`.

The call, from three indicators:

| `call` | `callsetup` | `callheld` | State |
|---|---|---|---|
| 0 | 1 | | incoming, the phone rings (`RING` and `+CLIP: "<number>",<type>` repeat) |
| 0 | 2 | | outgoing, being dialled |
| 0 | 3 | | outgoing, the other side rings |
| 1 | any | 0 or 1 | active |
| 1 | any | 2 | held |
| 0 | 0 | | none |

Commands: `ATA` answer; `AT+CHUP` hang up, decline, or give up dialling; `ATD<number>;` dial;
`AT+VTS=<key>` keypad tone; `AT+CLCC` lists the calls (`+CLCC: <index>,<direction>,<status>,
<mode>,<conference>,"<number>",<type>`), used to learn with whom a call is when the indicators
changed before any `+CLIP`.

The call's sound is a separate synchronous connection (SCO) that the phone opens when a call is
answered or placed with a hands-free unit connected.

## 3. On macOS [macos]

- `IOBluetoothHandsFreeDevice` (IOBluetooth, since 10.7) is this role ready-made: it runs the
  dialogue itself on a channel it opens, reports the indicators to a delegate, and has
  `acceptCall`, `endCall`, `dialNumber`, `sendDTMF`. On macOS 27 it connects and reports calls
  **[live]**.
- `IOBluetoothRFCOMMChannel` gives the plain serial channel for the dialogue of section 2, the
  fallback if the class should stop working.

## 4. The Mac client [built]

- `WinPhoneCore/Calls/HandsFree.swift`: `HandsFreeLink`, the dialogue of section 2 as text in
  and text out, with `CallIndicators` and `LiveCall`. Tested in `HandsFreeTests` against a
  scripted audio gateway.
- `WinPhone/Mac/BluetoothCalls.swift`: asks for Bluetooth permission, finds the linked phone
  among the paired ones (a stored choice, else by name, else the only one), then holds a
  connection: the system's class first, the own dialogue as the fallback; tries again by itself,
  at once when the phone connects to the Mac. Default `calls.backend` = `system` or `own` pins
  one.
- Interface: Settings, General, "Calls on this Mac"; a floating panel while a call lasts
  (answer, decline, end); the same bar at the top of the Calls section, which has a dial pad
  beside the history; the pad and the history's call buttons place the call directly while
  connected, and the pad's keys send their tones during a call; the menu bar item offers the
  same buttons.
- The log (`[calls] bluetooth: ...`) says each step and never a number, a name or an address.

## 5. The call's sound: not possible on current macOS [live] [macos]

Tried on 2026-10-10, macOS 27.0.1, during an active call placed from the Mac:

- `transferAudioToComputer` (which calls `connectSCO`) reported `scoConnectionOpened` with
  status 0xE00002C7, "unsupported", in the same millisecond; the framework logged "Failed to
  open SCO connection". The phone kept the sound on its own earpiece.
- The methods of `IOBluetoothHostController` that would set up or accept a synchronous
  connection (`BluetoothHCISetupSynchronousConnection...`, `...EnhancedSetup...`,
  `...AcceptSynchronousConnectionRequest...`, `...EnhancedAccept...`) are, in this system's
  IOBluetooth, two instructions long: return zero, do nothing. There is no other call for a
  synchronous connection in the framework, public or not.

- The phone does offer the sound connection: at the moment the call was placed, the system's
  own Bluetooth service logged `SCO/eSCO reject (HOST_REJ_RESOURCES) ... SCO connect-accept
  declined` (`log show`, process `bluetoothd`, 11:38:30.900). The link is refused below
  anything an app can reach, so no sound ever arrives that could be decoded; what the app
  receives over Bluetooth is the text dialogue of section 2 and nothing else.

So an app cannot open the sound connection, and cannot accept the one the phone offers. The
Mac client therefore offers control only and says so; the code that would have bridged the
phone's sound device was removed.

**The mirroring sound channel does not carry the call** **[live]** 2026-10-10 13:11: with
the phone's screen shown and sound on, a call placed from the Mac ran for 19 seconds without a
single audio frame arriving; the first frames came ten seconds after the call had ended. The
phone's own "share audio" switch, pressed during the call, changed nothing either. This matches
the phone app's capture, which records one app's playback (Samsung
`AudioManager.setupAppAudioRecord(uid)`), not the voice path.

Other ways that were considered and do not exist: the relay carries no call audio (`calls.md`
9); the screen-mirroring sound channel carries what the phone plays, which on Android excludes
calls, and has no way back for a microphone.

### 5.1 Final review of software-only routes (2026-10-10 13:20)

Checked and closed; none needs new recordings:

| Route | Finding |
|---|---|
| The system's hands-free class | `connectSCO` answers unsupported at once; `bluetoothd` has an HFP implementation for headsets only (strings: `HFPAudioDevice`, `Handsfree AG`; no hands-free-unit role). While the phone is connected for calls, the Mac lists no audio device for it (`system_profiler SPAudioDataType`: built-in microphone and speakers only). |
| The phone's audio link | Offered by the phone, refused by `bluetoothd` (`SCO connect-accept declined`), below any app. |
| The mirroring sound channel | Live: no frame during a 19-second call; the phone's own share-audio switch does nothing during a call. The phone app records one app's playback (Samsung `setupAppAudioRecord(uid)`), and no `/audio/*` route goes from the PC to the phone. |
| The Windows VM with Phone Link | The VM is VMware Fusion; Fusion 13.6 removed Bluetooth hub passthrough and never had it on Apple silicon; Parallels 26 removed shared Bluetooth. Both point to a USB adapter, which is hardware. |
| Other apps that did this (Dialogue, HandsFree 2, Phone Amego) | Gone or turned to other means; their guides name no macOS version where it stopped, so the reason is inferred: the same hands-free class. |
| Microsoft's relay, Samsung's own cross-device calls, LE Audio | No call audio on the relay; Samsung's needs Samsung devices on both ends; the Mac is only a LE Audio central and the S21+ has no LE Audio. |

Conclusion: with the Mac's own Bluetooth there is no software-only way to carry a call's sound,
in either direction. Hardware (a USB adapter the app drives, or a bridge board) is the only
remaining route. Calls stay control-only.

### 5.2 Hold and mute

- **Hold** is the profile's own: `AT+CHLD=2` puts the active call on hold and takes a held one
  back; the `callheld` indicator then says which. On the call card and the Calls bar.
- **Mute** is not in the profile: a hands-free unit mutes its own microphone, and here the
  microphone in use is the phone's. The general modem command `AT+CMUT` is asked about once at
  connection (`AT+CMUT=?`); a phone that offers it answers with a `+CMUT:` line and gets a Mute
  button. **The Galaxy S21+ does not answer it** **[live]** 2026-10-10 13:44 (only its own
  `+CNMI` line came), so no Mute button shows for it.

## 6. Still to try

1. An incoming call: the panel, the caller's number, answer and decline from the Mac.
2. A call answered on the phone itself while the Mac is connected: the sound should stay on
   the phone; if the phone picks "Bluetooth" as its sound route, that would be silence.
3. The phone leaving and coming back into reach.
