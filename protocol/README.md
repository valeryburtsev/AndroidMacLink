# The protocol

How Phone Link and Link to Windows talk to each other and to Microsoft's services, as observed in
both clients and in their traffic. Each document is written as a specification for building a
client, and says which parts were seen live and which were read from the clients.

## Linking and connecting

| Document | Covers |
|---|---|
| [identity-enrollment-trust.md](specs/identity-enrollment-trust.md) | Device identity, enrollment with the device service, trust between PC and phone, waking the phone, key rotation |
| [pairing.md](pairing.md) | Linking a new phone by QR code or PIN |
| [relay-transport.md](specs/relay-transport.md) | The relay hub: SignalR framing, DCG fragments, the PLATFORM and APP envelopes |
| [session-clipboard-notifications.md](specs/session-clipboard-notifications.md) | Starting a session; clipboard and notification sync |

## Features

| Document | Covers |
|---|---|
| [messages.md](specs/messages.md) | SMS, MMS and RCS: sync and sending |
| [calls.md](specs/calls.md) | Call history, dialling on the phone |
| [calls-bluetooth.md](specs/calls-bluetooth.md) | Live calls with the Mac as a Bluetooth hands-free unit |
| [contacts.md](specs/contacts.md) | Contact names and photos |
| [photos.md](specs/photos.md) | Recent photos, thumbnails, full images |
| [file-transfer.md](specs/file-transfer.md) | Files in both directions, the phone's storage |
| [phone-apps.md](specs/phone-apps.md) | The phone's apps, their names and icons |
| [device-controls.md](specs/device-controls.md) | Ring the phone, ringer mode, Do Not Disturb, media keys, opening on the phone |
| [continuity.md](specs/continuity.md) | Links between the two devices |
| [mirroring.md](specs/mirroring.md) | The phone's screen and single apps: video, input, sound |
| [hotspot.md](specs/hotspot.md) | Instant Hotspot over Samsung's Bluetooth side channel |

## The direct connection ("Nano")

| Document | Covers |
|---|---|
| [nano-scoping.md](specs/nano-scoping.md) | What the peer-to-peer UDP transport is and where it is used |
| [nano-wire-notes.md](specs/nano-wire-notes.md) | Packet layouts, acknowledgements, channels |
| [nano-ice.md](specs/nano-ice.md) | Connecting away from the local network: candidates, checks, the relay |

## Reference

| Path | What it is |
|---|---|
| [windows-catalog.md](windows-catalog.md) | Phone Link for Windows: routes, endpoints and message types found in the app |
| `recovered/windows/` | Message schemas rebuilt from the descriptors embedded in Phone Link for Windows |

The app's own `.proto` files are in [`app/Protos`](../app/Protos), rendered from those schemas.
