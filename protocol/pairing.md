# Linking a phone: the pairing service as observed

Source: live capture `captures/vm-pairing-2026-10-09` (Phone Link 1.26072.257.0 on Windows 11 ARM,
Link to Windows 1.26082.130.0 on a Samsung SM-G996B), plus the decompiled clients. Identifiers and
secrets are replaced by placeholders. Flow captured: QR code (`QRLINK_CHALLENGEPIN_SIGNIN`).
Manual pairing (`SIGNIN_PIN`) is not captured yet.

## Unlink

`POST https://dcg.microsoft.com/DeviceAuthProxy/UnlinkDevice?api-version=1.5.0&device-id=<phone DCG id>`
with `Authorization: Bearer <MSA token>`, `Authorization-Type: MSA` and `Dcg-Token`. Returns 200.

Unlinking the phone also invalidates the PC's own registrations. The next `SetDeviceInfo` from each
Windows client returned `403 {"error":{"code":"DeviceUnlinked","categoryCode":13}}`. The client
reacts by creating a fresh identity, not by signing in to the old one.

## Order of calls for a first link

| Step | Call | Notes |
|---|---|---|
| 1 | `GET /EnvironmentDiscovery/UserServiceEnvironment` | |
| 2 | `POST /Auth/GenerateNonce`, `POST /Auth/CreateIdentity` | new DCG identity |
| 3 | `PUT /Registration/Register?api-version=2.0.0` | push channel |
| 4 | `POST /DeviceAuthProxy/EnrollDevice?api-version=1.5.0` | response lists 1 device: the PC itself |
| 5 | `POST /DevicePairingProxy/PairingSessions?Api-Version=3.0.0` | about 1 s after enrollment |
| 6 | `GET /DevicePairingProxy/PairingSessions/{id}` repeatedly | until `DEVICE_PAIRED` |
| 7 | relay negotiate, `Dispatcher/Wake`, normal session | |

Enrollment comes before pairing. No `/Complete` call was made in this flow: the service moved from
`PENDING_PAIRING_PERMISSION_APPROVE` to `DEVICE_PAIRED` on its own.

## Creating the session

Request headers: `Authorization: Bearer <MSA token>`, `Authorization-Type: MSA`,
`clientRegionName: <two-letter region>`, `AuthorizationPortal: FirstPartyAppsRepo`, and the standard
`DCG-AppId`, `DCG-AppVersion`, `DCG-OS`, `DCG-OSVersion`, `DCG-RingName` set. **No `Dcg-Token`.**

Request body:

```json
{"flow": "QRLINK_CHALLENGEPIN_SIGNIN", "optionalPermission": ["ALL"]}
```

Response fields: `pairingSessionId`, `pairingSessionExpireTime` (15 minutes ahead),
`currentServiceTime`, `flow`, `optionalPermission`, `state`, `pairingLink`,
`pairingLinkExpireTime` (10 minutes ahead), `pairingLinkForSignInPINFlow` (`aka.ms/PairPC`), `region`.

## The pairing link (what the QR code contains)

```
https://dcg.microsoft.com/dl?mvc=<int>&cpsi=<uuid>&vm=101&et=<unix seconds>&r=5&ti=<32 hex>
```

- It is generated entirely by the service. The PC only renders it.
- `cpsi` is a UUID different from `pairingSessionId`.
- `et` equals the session expiry as Unix seconds.
- `ti` is 32 hex characters, the shape of a trace ID.
- `mvc`, `vm` and `r` are not understood yet. They do not need to be, since we never build the link.

## States seen while polling

| Seconds after create | State | Extra fields |
|---|---|---|
| 0 | `PENDING_PAIRING_LINK_VISIT` | |
| 5 | `PENDING_CHALLENGE_PIN_VALIDATE` | `challengePIN` (6 uppercase letters), `challengePINExpireTime` (about 3 minutes), `clientAppId=com.microsoft.appmanager` |
| 12 | `PENDING_PAIRING_PERMISSION_APPROVE` | |
| 28 to 62 | `PENDING_PAIRING_PERMISSION_APPROVE` | polled every 15 to 17 s |
| 80 | `DEVICE_PAIRED` | `partnerDcgClientId`, `partnerDeviceKey` (`PartnerDeviceKey~<64 chars>`) |

Poll requests carry the same headers as the create request, minus `clientRegionName`.

## What this settles

- The link needs nothing Windows-specific from the client.
- Session creation is authorized by the Microsoft account token alone.
- The client must be enrolled first.
- The QR flow needs no explicit completion call.

## Still open

- The manual flow (`SIGNIN_PIN`): states, the `pairingPIN`, and whether it needs `/Complete`.
- When `READY_FOR_COMPLETE` occurs, since the code handles it but this run never saw it.
- Whether the service accepts a session from a client that is not Windows in any way it can tell.
  The only way to know is to try it from the Mac.
