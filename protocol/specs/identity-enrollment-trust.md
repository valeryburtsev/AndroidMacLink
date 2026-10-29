# Identity, enrollment, trust and wake: implementation spec

Status: draft 1, 2026-10-09. Written from primary sources only. No decompiled code is reproduced;
identifiers, string literals and numeric constants are quoted because an interoperable client needs
them. No secret or personal value appears here: account names, device IDs, host names and tokens are
replaced by placeholders such as `<pc-dcg-id>`.

## 0. Sources and conventions

| Tag | Meaning |
|---|---|
| **[C]** | Observed in code: decompiled Phone Link 1.26072.257.0 under `corpus/windows/decompiled/`. Pointer format `Assembly: Class.Method`. |
| **[W]** | Observed on the wire. `B#n` = `captures/vm-baseline-2026-10-09/flows.jsonl` record `seq` n, `P#n` = `captures/vm-pairing-2026-10-09/flows.jsonl`, `R#n` = `captures/vm-relay-2026-10-09/flows.jsonl`. |
| **[I]** | Inferred or uncertain. The reasoning is stated. |
| **[X]** | Cross-check against `third_party/linkmyphone/docs/protocol/authentication.md` (third party, may be wrong). |

Assembly short names: `Auth` = YourPhone.YPP.Auth, `Kiota` = YourPhone.YPP.Kiota, `YPP` = YourPhone.YPP,
`Common` = YourPhone.YPP.Common, `Sdk` = YourPhone.YPP.PlatformSdk, `Push` = YourPhone.YPP.PushNotifications,
`ConnMgd` = YourPhone.Connectivity.YPP.Managed, `DevMgd` = YourPhone.Devices.Managed.

Two Windows clients appear in the captures. They share the same platform libraries but are separate
DCG clients:

| Client | `ClientType` | `DCG-AppId` | Where captured |
|---|---|---|---|
| Phone Link | `PL` | `Microsoft.YourPhone_8wekyb3d8bbwe` | P#188 to P#233 |
| Cross Device Experience Host | `WEA` | `MicrosoftWindows.CrossDevice_cw5n1h2txyewy` | all of baseline, most of pairing and relay |

Every `Dispatcher/Wake` record in the three captures was sent by the WEA client. Phone Link's own
wake has not been captured; the wake section relies on shared code plus the WEA records.

Redacted lengths in the captures: for headers, `len` is the byte length of the header value; for JSON
fields, `len` is the length of the JSON-encoded string, so subtract 2 for the quotes
(`tools/capture/wire.py: redacted, redact_json`).

---

## 1. Overview and order of calls

### 1.1 Layers

1. Microsoft account (MSA) access token for the DCG resource (section 4).
2. Service environment discovery (section 5).
3. DCG identity: a random device ID plus a P-384 key and self-signed certificate, proven with a nonce
   JWT. Yields the DCG access token (sections 6 to 8).
4. Push channel registration (section 9). Optional for the caller, fire-and-forget on Windows.
5. Enrollment: a second "trust" certificate `CN=trust_<pc-dcg-id>` is uploaded with device metadata
   (section 10).
6. Trust sync: list linked devices, store one relationship per peer plus one with the account
   (sections 11 and 12).
7. Wake: ask the service to push a signed wake to the phone (section 13).

### 1.2 First run, as captured

| Step | Call | Auth | Evidence |
|---|---|---|---|
| 1 | `GET /EnvironmentDiscovery/UserServiceEnvironment?api-version=1.0.0` | MSA | P#195, B#1 |
| 2 | `POST /Auth/GenerateNonce?api-version=1.1.0` | MSA | P#197, B#2 |
| 3 | `POST /Auth/CreateIdentity?api-version=1.1.0` | MSA | P#198, B#3 |
| 4 | `PUT /Registration/Register?api-version=2.0.0` | DCG token | P#200, B#4 |
| 5 | `POST /DeviceAuthProxy/EnrollDevice?api-version=1.5.0&pop-device-key=` | MSA + `Dcg-Token` | P#202, B#5 |
| 6 | `GET /DeviceAuthProxy/GetDeviceInfoList?api-version=1.5.0&filter=&top=20` | MSA | P#203, B#6 |
| 7 | `GET /DeviceAuthProxy/GetAccountCert?api-version=1.0.0` | MSA | P#205, B#7 |
| 8 | relay negotiate, then `POST /Dispatcher/Wake?api-version=1.5.0` | DCG token | B#11, B#16 |

Step 4 is started by an event when the identity is created and runs concurrently with the rest
**[C]** (`YPP: DeviceIdProvisionedRegistrationMediator`). Steps 6 and 7 repeat many times in the
captures because several UI components each trigger a refresh **[W]** (B#6 to B#24).

### 1.3 Later runs

The DCG device ID and both certificates persist; DCG access tokens do not **[C]**
(`Auth: DcgAuthStorage` restores an identity with an empty token map). The first component that needs
a DCG token therefore causes `GenerateNonce` + `SignIn` **[W]** (P#188, P#189, triggered by the cloud
relay adapter). No `CreateIdentity`, no `EnrollDevice`.

### 1.4 After an unlink

`SetDeviceInfo` answered `403 DeviceUnlinked`; about 1.4 s later Phone Link ran the first-run sequence
again and received a new device ID **[W]** (P#194 then P#195 to P#202). Details in section 14.

---

## 2. Literal values used by Phone Link (`PL`)

| Item | Value | Source |
|---|---|---|
| Service base (Prod) | `https://dcg.microsoft.com/` | **[C]** `Common: PlatformConfiguration.ServicesBaseProd` |
| Service base (Beta) | `https://dcg-beta.microsoft.com/` | **[C]** `ServicesBaseBeta` |
| Service base (Dogfood) | `https://dcg-df.microsoft.com/` | **[C]** `ServicesBaseDogFood` |
| Client type | `PL` | **[C]** `ConnMgd: YppPlatformOptionsBuilder.Build`; **[W]** P#202 |
| App name (certificate friendly name on Windows) | `Microsoft Your Phone` | **[C]** same |
| MSA client ID and app ID | `8CF55838-E496-42C5-829B-F8D6945288F3` | **[C]** same, `ConnMgd: YppConstants.MsaAppId` |
| DCG token scope label (client-side only) | `general` | **[C]** `Auth: AuthConstants.DefaultScope` |
| Trust client ID prefix | `trust_` | **[C]** `Auth: TrustConstants.TrustPartnerClientIdPrefix` |
| Wake collapse key | `YPPWake` | **[C]** `YPP: DispatcherConstants`; **[W]** B#16 |
| Capabilities | `FILE_TRANSFER_ONEDRIVE`, `UNLINKABLE_V1`, `UNLINKABLE_V2` | **[C]** `ConnMgd: YppCapabilityProvider`; **[W]** P#202 |

API versions: Auth endpoints `1.1.0`; EnvironmentDiscovery `1.0.0`; Registration `2.0.0`;
EnrollDevice, SetDeviceInfo, GetDeviceInfoList, UnlinkDevice, DeleteDeviceInfo `1.5.0`;
GetAccountCert `1.0.0`; Dispatcher/Wake `1.5.0` **[C]** (constants named `ApiVersion` in
`Auth: AuthServiceCryptoHelper`, `Auth: EnvironmentDiscoveryManager`, `YPP: RegistrationManager`,
`Sdk: DeviceManagementManager`, `YPP: TrustHelper`, `YPP: DispatcherManager`), all confirmed **[W]**.

---

## 3. Standard request headers

### 3.1 Headers added to every DCG REST request

Added by a delegating handler, only when not already present **[C]**
(`Common: CustomHeadersBuilder.AddCustomHeaders`, `Common: AppInformationProvider`).

| Header | Derivation **[C]** | Phone Link value **[W]** P#189 |
|---|---|---|
| `DCG-LogicalDeviceId` | Standard base64 of SHA-256 over the bytes of the Windows publisher-scoped system ID (`SystemIdentification.GetSystemIdForPublisher`). Empty string if the system ID is unavailable. | 44 characters of base64 (32 bytes). Differs between PL and WEA on the same PC because the publishers differ. |
| `DCG-AppVersion` | Package version `major.minor.build.revision` | `1.26072.257.0` |
| `DCG-AppId` | Package family name | `Microsoft.YourPhone_8wekyb3d8bbwe` |
| `DCG-SessionId` | One random GUID per process, lowercase with hyphens | a GUID, constant across the run |
| `DCG-RingName` | Flight ring from cached remote configuration. Known names: `Team`, `Canary`, `Canary_EarlyAccess`, `PreProd`, `PreProd_EarlyAccess`, `Public` (`Common: RingNameConstants`). | `Public` |
| `DCG-OS` | Enum name of the client OS: `Windows`, `Android`, `iOS` | `Windows` |
| `DCG-OSVersion` | `major.minor.build` from `RtlGetVersion` | `10.0.26200` |

### 3.2 `AuthorizationPortal`

Default header on every DCG HTTP client: `FirstPartyAppsRepo` when the feature
`EnableMSAPortalMigrationForPlatform` is on, otherwise `MSM` **[C]**
(`Kiota: IHttpClientBuilderExtensions.ConfigureDcgDefaults`, `Common: HeaderValues`).

**[W]** WEA sends `FirstPartyAppsRepo` (B#1). Phone Link sends the value twice in one header line,
`FirstPartyAppsRepo, FirstPartyAppsRepo` (P#188 and every other PL record). The code adds it once per
client, so the duplication is unexplained; see section 15.

The same feature flag selects the MSA scope (section 4), so the header value and the token type are
coupled **[C]** (`Common: PlatformOptions.EnableMSAPortalMigrationForPlatform` setter).

### 3.3 Trace headers

Added per request **[C]** (`Kiota: RequestHeadersExtensions.AddTraceContext`, `Common: TraceContext`).

| Header | Format |
|---|---|
| `traceparent` | `00-<traceId>-<correlationId>-<flags>`. `traceId`: 32 lowercase hex (16 random bytes, not all zero). `correlationId`: 16 lowercase hex (8 random bytes); note it is the correlation ID, not the parent ID, that goes in the third field. `flags`: two hex digits of the trace-flags byte. |
| `tracestate` | The trace-state dictionary as `key=value` joined by `,` in insertion order, then `,yppHttpParent=<correlationId>` (no leading comma if the dictionary is empty). |
| `DCG-TraceState` | Identical to `tracestate`. |

Dictionary keys: `ypScenarioId`, `ypTriggerId` (`Common: TraceContextConstants`), plus free-form keys
set by features. **[W]** Phone Link examples: `ypTriggerId=CurrentAccountChanged,isuserinitiated=False,yppHttpParent=<16 hex>` (P#197);
`ypScenarioId=PL.Onboarding,ypTriggerId=AllDevicesRemoved,ATv2=0,yppHttpParent=<16 hex>` (P#202).
Flags are `00` for PL (P#189) and `01` for WEA (B#2).

**[I]** These are telemetry correlation values. Nothing in the client depends on the service echoing
them, and no response field refers to them. A client should send well-formed values; whether the
service rejects requests without them is untested.

### 3.4 `baggage`

Not produced by any code in the YPP assemblies **[C]** (no writer found; only a reader in
`Common: TraceContextUtils.CreateFromCurrentActivity`). **[W]** WEA sends
`baggage: ypScenarioId = <name>, ypTriggerId = <name>` (B#1); Phone Link sends no `baggage` header at
all (P#188 to P#233). **[I]** In WEA it comes from .NET activity propagation. A Phone Link-compatible
client should omit it.

### 3.5 Other headers and order

**[W]** P#189 header order for an MSA-authenticated POST: `Host`, `UserIdentityType`,
`UserIdentityToken`, `Authorization`, `Authorization-Type`, `traceparent`, `tracestate`,
`DCG-TraceState`, `Accept`, `AuthorizationPortal`, `DCG-LogicalDeviceId`, `DCG-AppVersion`,
`DCG-AppId`, `DCG-SessionId`, `DCG-RingName`, `DCG-OS`, `DCG-OSVersion`, `Accept-Encoding`,
`Content-Type`, `Content-Length`.

- `Accept: application/json`, `Content-Type: application/json`, `Accept-Encoding: gzip, deflate, br`.
- No `User-Agent` header is sent on REST calls.
- Request bodies are compact JSON; properties with null values are omitted **[W]** (P#202 lacks the
  optional metadata fields listed in section 10.3).

### 3.6 Authentication header patterns

| Pattern | Headers | Used by |
|---|---|---|
| MSA only | `Authorization: Bearer <msa>`, `Authorization-Type: MSA` | EnvironmentDiscovery, GetDeviceInfoList, GetAccountCert |
| MSA identity | the two above plus `UserIdentityType: MSA`, `UserIdentityToken: <msa>` (same token, no `Bearer`) | GenerateNonce, CreateIdentity, SignIn, RotateKeys |
| MSA + DCG | `Authorization: Bearer <msa>`, `Authorization-Type: MSA`, `Dcg-Token: <dcg token>` (no `Bearer`) | EnrollDevice, SetDeviceInfo, UnlinkDevice, DeleteDeviceInfo |
| DCG only | `Authorization: Bearer <dcg token>` and no `Authorization-Type` | Registration/Register, Dispatcher/Wake, CloudRelay, relay negotiate |

**[C]** `Auth: AuthServiceCryptoHelper`, `Auth: EnvironmentDiscoveryManager`, `Sdk: DeviceManagementManager`,
`YPP: TrustHelper.GetAndUpdateAccountCertInternalAsync`, `Kiota: DcgIdentityAuthenticationProvider`.
**[W]** Lengths agree: `UserIdentityToken` 1780 and `Authorization` 1787 = 7 + 1780 (P#189);
`Dcg-Token` 841 and DCG `Authorization` 848 = 7 + 841 (P#202, P#200).

---

## 4. Microsoft account token

### 4.1 Observed in code

- Provider `https://login.microsoft.com`, authority `consumers`, silent request through the Windows
  web account manager (`Auth: MsaTokenProvider`, `Auth: AuthConstants`).
- Requested scope string: `<scope>&api-version=2.0&clientid=<MsaAppId>`, client ID `MsaClientId`,
  request property `api-version` = `2.0`. Both IDs are `8CF55838-E496-42C5-829B-F8D6945288F3` for PL.
- `<scope>` depends on the environment and on `EnableMSAPortalMigrationForPlatform`
  (`Common: EnvironmentTypeMappingUtils.GetDcgScopeFromEnvironment`):

| Environment | Flag off | Flag on |
|---|---|---|
| Prod | `service::msatoken.dcg.microsoft.com::MBI_SSL` | `https://dcg.microsoft.com/DCG.ReadWrite` |
| Beta | `service::msatoken.dcg-beta.microsoft.com::MBI_SSL` | `https://dcg-beta.microsoft.com/DCG.ReadWrite` |
| Dogfood | `service::msatoken.dcg-df.microsoft.com::MBI_SSL` | `https://dcg-df.microsoft.com/DCG.ReadWrite` |

- A second "strong auth" scope exists: `...::SAPI` (flag off) or `.../DCG.ReadWrite.SAPI` (flag on)
  (`GetDcgSapiScopeFromEnvironment`). Phone Link requests it interactively only after silent
  enrollment fails with `Unauthorized` or `MsaTokenUserInteractionRequired`, then enrolls with that
  token (`DevMgd: AccountManager.TrySwitchAccountInteractiveInternalAsync`,
  `Sdk: AccountManager.EnrollInteractivelyAsync`).
- The token is the first response token, used verbatim. The account's customer ID (CID) is read from
  the web account property `SafeCustomerId` and stored with trust relationships as `MsaCid`
  (`YPP: TrustHelper.CollectAccountInfo`).
- Retry: one retry after 2 s for transient token failures (`AuthServiceMsaTokenRetryAttempts` = 1,
  `AuthServiceMsaTokenRetrySeconds` = 2). `UserInteractionRequired` or `AccountSwitch` invalidates
  the cached token and surfaces as `MsaTokenUserInteractionRequired`.

### 4.2 Observed on the wire

`AuthorizationPortal` is `FirstPartyAppsRepo` for both clients (B#1, P#188), so the flag is on in this
build and flight. The MSA token itself is redacted; its length was 1780 bytes for PL (P#189) and 1737
to 1759 for WEA (B#2, B#1).

### 4.3 Inferred

**[I]** Because the flag couples header and scope, the tokens in the captures were issued for
`https://dcg.microsoft.com/DCG.ReadWrite`, not for `MBI_SSL`. The token contents (format, claims)
cannot be confirmed from redacted captures.

**[X]** LinkMyPhone reports that a device-code grant with client ID `8CF55838-E496-42C5-829B-F8D6945288F3`
and scope `https://dcg.microsoft.com/DCG.ReadWrite offline_access` yields a token the service accepts.
That is consistent with the above but not reproduced by us. A non-Windows client must send
`AuthorizationPortal: FirstPartyAppsRepo` with such a token.

---

## 5. Environment discovery

### 5.1 Request

`GET {EnvironmentDiscoveryBase}/EnvironmentDiscovery/UserServiceEnvironment?api-version=1.0.0`,
MSA-only headers (section 3.6), no body. `EnvironmentDiscoveryBase` is always the Prod base, and the
MSA token is always requested for the Prod scope **[C]** (`Auth: EnvironmentDiscoveryManager`,
`Common: PlatformConfiguration.EnvironmentDiscoveryBase`). **[W]** P#195, B#1.

### 5.2 Response

`200`, `Content-Type: application/json`, body `{"serviceEnvironment": "<value>"}` where the value is
`Production` or `Beta` **[C]** (`Kiota: ServiceEnvironmentResponse_serviceEnvironment`). **[W]**
`{"serviceEnvironment":"Production"}`, 35 bytes (P#195).

### 5.3 Effect

| Result | Client behavior **[C]** |
|---|---|
| `Production` | Environment `Prod`: base `https://dcg.microsoft.com/`. |
| `Beta` | Environment `Beta`: base `https://dcg-beta.microsoft.com/`; MSA tokens are then requested for the Beta scope; a separate DCG identity is kept per environment. |
| 401 of any category, or token retrieval failure | Status `Unauthorized`; no default is applied and provisioning stops. |
| Any other failure | Defaults to `Prod`, unless trust relationships already exist, in which case the previously saved environment is kept. |

The chosen environment is saved (`SavedDcgEnvironment`) and reused on later starts ("snapped")
(`Common: EnvironmentManager`, `Common: EnvironmentContainerManager`). A debug override
`ServicesBaseOverride` skips the call. The environment name also appears in the wake data as
`DCG-Environment` (`Prod`, `Beta`, `Dogfood`).

---

## 6. DCG identity

### 6.1 Device ID

A fresh random GUID, lowercase with hyphens, generated on the client immediately before
`GenerateNonce` **[C]** (`Auth: AuthServiceCryptoHelper.CreateIdentityAsync`). The same string is the
`deviceId` in the nonce request, the certificate common name, the JWT `iss`, and afterwards the "DCG
client ID" used everywhere. **[W]** The service echoes it as `deviceId` (B#3, P#198).

If `CreateIdentity` answers 403 with a category other than 7 or 13, the client treats it as a device
ID collision, picks a new GUID and retries, up to 3 retries **[C]** (`AuthServiceRecoverRetryAttempts` = 3).

### 6.2 Key

ECDSA on NIST P-384, created for signing only **[C]** (`Auth: KeyManager.GenerateNewSigningKey`). A
new key is generated for every new certificate; the key container name is a random GUID.

### 6.3 Certificate

**[C]** `Auth: CryptoManager.GenerateNewKeyOwnershipProofRequest`, `Auth: CertificateManager.GenerateCertificateInner`.

| Field | Value |
|---|---|
| Version | v3 |
| Subject and issuer | `CN=<device-id>`, identical (self-signed) |
| Signature algorithm | ECDSA with SHA-384 (`1.2.840.10045.4.3.3`) |
| Public key | `id-ecPublicKey` with named curve `secp384r1`, uncompressed point |
| notBefore | now minus `CertificateClockDriftTime` (12 hours) |
| notAfter | now plus `CertificateExpirationTime` (365 days) |
| Extension 1 | Basic Constraints, not critical, CA false, no path length |
| Extension 2 | Key Usage, not critical, `digitalSignature` only |
| Serial | not set by the app; chosen by the certificate library |
| Encoding when sent | DER, then standard base64 without line breaks |

**[W]** The identity certificate travels only inside the redacted JWT, but the trust certificate
(section 10.1) is built by the same routine and is visible in P#202. Its DER structure: 528 bytes;
version 2 (v3); serial is a 9-byte INTEGER (a leading zero byte plus 8 bytes); both names are a
single `commonName` attribute; validity as two UTCTime values exactly 365 days and 12 hours apart
with notBefore 12 hours before the request time; SPKI as above (98-byte BIT STRING); extensions in
the order Basic Constraints (value `30 00`) then Key Usage (value `03 02 07 80`), both without the
critical flag; signature algorithm `ecdsa-with-SHA384`.

**[I]** Name string type. The trust certificate's CN is a BMPString on the wire (P#202), which is how
Windows encodes a name containing `_`. A bare GUID fits PrintableString, and the nonce JWT length
arithmetic in section 7.4 matches a 432-byte identity certificate, which is what PrintableString
gives. The phone's own certificate uses UTF8String and the service accepted it (B#5), so the string
type is evidently not enforced for trust certificates; for the identity certificate this is untested.

### 6.4 Storage on Windows (for reference only)

- Private keys: CNG, Microsoft Software Key Storage Provider, per user (`Auth: KeyManager`).
- Certificates: current-user `My` store, tagged with friendly name `Microsoft Your Phone`; or, when
  `StoreCertificatesInFile` is on, a JSON file `YppCertificates.json` holding `KeyName` and
  `CertificateData` per entry (`Auth: CertificateRepository`). When several certificates share a
  subject, the one with the latest notBefore is used (`Auth: CertificateManager.RetrieveCertificateLocked`).
- Identity record: app settings container `YPP.Config.DcgAuth` (and a per-environment sibling) with
  `DeviceId`, `ServiceEnvironment`, `LastAccessed`, `NextKeyRotation`, `KeyValidityRemainingDays`
  (`Auth: DcgAuthStorage`, `Auth: AuthStorageConstants`). Access tokens are held in memory only.
- The certificate is persisted only after `CreateIdentity` succeeds; saving deletes any older
  certificate with the same subject (`Auth: CryptoManager.PersistCertificateAsync`).

---

## 7. The nonce JWT (`certificateJWT`)

### 7.1 Observed in code

Built with the Microsoft JWT handler from a token descriptor **[C]**
(`Auth: CryptoManager.CreateJwtTokenForNonceInner`).

| Part | Content |
|---|---|
| Signing algorithm | ECDSA P-384 with SHA-384, requested by the URI `http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha384`, which the library maps to JOSE `ES384` |
| Issuer | The certificate's issuer name with the leading `CN=` removed, that is the device ID |
| Claim `Nonce` | The `nonce` string from `GenerateNonce`, unchanged |
| Claim `Certificate` | Standard base64 of the DER certificate, no line breaks |
| notBefore | now minus `JWTClockDriftTime` (12 hours) |
| expires | now plus `JWTExpirationTime` (12 hours) |
| Audience | none |

Claim names are case-sensitive: `Nonce` and `Certificate` start with a capital letter.

### 7.2 Resulting token

| Element | Value | Basis |
|---|---|---|
| JOSE header | `{"alg":"ES384","typ":"JWT"}`; no `kid`, no `x5t` | **[I]** library behavior for a bare ECDSA key; length check below |
| Payload claims | `Nonce` (string), `Certificate` (string), `nbf`, `exp`, `iat` (integers, Unix seconds), `iss` (string) | `iat` is **[I]**: not set by the app, added by the library with the current time; length check below |
| Signature | Raw `r || s`, 48 bytes each, 96 bytes total. Not DER. | **[I]** library behavior; length check below; **[X]** agrees |
| Encoding | Three base64url segments without padding, joined by `.`; signature computed over `<header>.<payload>` in ASCII | JWS compact form |

Claim order inside the payload is not observable (the token is redacted). **[I]** The library writes
the custom claims first and the registered claims after them. JSON object order has no meaning to a
JWT verifier, so it should not matter.

### 7.3 Time window

`nbf` = now − 12 h, `exp` = now + 12 h, `iat` = now. The service returns its clock as
`epochTimeStamp` with the nonce, but the client ignores it and uses its own clock **[C]**
(`AuthServiceCryptoHelper.CreateNonceFromResponse` reads only `nonce`). The ±12 h window tolerates
large clock error.

### 7.4 Wire check by length

**[W]** `certificateJWT` is 1160 characters in both B#3 (CreateIdentity, WEA) and P#189 (SignIn, PL).
With a 27-byte header (36 characters), a 96-byte signature (128 characters) and two dots, the payload
is 994 characters, that is 745 bytes. A payload with a 44-character nonce, a 576-character
certificate (430 to 432 DER bytes), a 36-character issuer and three 10-digit timestamps, with `+`
and `/` not escaped in the JSON, is exactly 745 bytes. The same payload without `iat` (728 bytes) or
with a DER-encoded signature (102 to 104 bytes) cannot produce 1160. This supports: header as above,
`iat` present, raw signature, base64 characters not JSON-escaped.

---

## 8. Auth endpoints

All four: `POST`, `api-version=1.1.0`, MSA identity headers (section 3.6), JSON body, base URL of the
selected environment **[C]** (`Auth: AuthServiceCryptoHelper`, `Kiota: Auth/*RequestBuilder`).
Variants `CreateIdentityCryptoWithMSA`, `SignInCryptoWithMSA`, `RotateKeysWithMSA` exist in the
generated client but nothing calls them **[C]**.

### 8.1 `/Auth/GenerateNonce`

| | |
|---|---|
| Request body | `{"deviceId": "<device-id>"}` (51 bytes) **[W]** B#2 |
| Response `200` | `{"epochTimeStamp": <int64 Unix seconds>, "nonce": "<string>"}` **[W]** B#2: 84 bytes; nonce is 44 characters of standard base64 (32 bytes) |

Called before each of CreateIdentity, SignIn and RotateKeys with a fresh nonce. For a new identity
the device ID does not exist on the service yet; the call still succeeds **[W]** (B#2 precedes B#3).

### 8.2 `/Auth/CreateIdentity`

| | |
|---|---|
| Request body | `{"certificateJWT": "<jwt>"}` (1181 bytes) **[W]** B#3 |
| Response `200` | see below |

| Response field | Type | Observed **[W]** B#3, P#198 | Use **[C]** |
|---|---|---|---|
| `accessToken` | string | 841 characters, opaque (redacted) | The DCG access token |
| `deviceId` | string | equals the requested device ID | Stored as the DCG client ID |
| `tenantId` | string | `00000000-0000-0000-0000-000000000000` | Not read |
| `epochExpirationTime` | int64, Unix seconds | nonce timestamp + 86401 (24 hours) | Token expiry |
| `keyValidRemainingDays` | int64 | `364` | Drives key rotation; treated as −1 when absent |

On success the client persists the certificate, stores the identity with next key rotation = now +
`NextKeyRotationTime`, and raises the "device ID provisioned" event that starts registration.

### 8.3 `/Auth/SignIn`

Same body and response shape as CreateIdentity **[W]** (P#189: request 1181 bytes, response 1020
bytes, same five fields). The JWT is built from the stored certificate and key with a new nonce. The
client accepts the response only if `deviceId` equals the stored device ID **[C]**
(`AuthServiceCryptoHelper.SignInAsync`).

### 8.4 `/Auth/RotateKeys`

| | |
|---|---|
| Request body | `{"newCertificateJWT": "<jwt>", "oldCertificateJWT": "<jwt>"}` **[C]** `Kiota: RotateKeysBody` |
| Response | No body is parsed; any 2xx is success |

Both JWTs carry the same nonce. `oldCertificateJWT` is signed with the current certificate;
`newCertificateJWT` with a newly generated key and certificate for the same `CN=<device-id>`. On
success the new certificate replaces the old one locally **[C]**
(`CryptoManager.GenerateKeyRotationRequest`, `AuthServiceCryptoHelper.PerformKeyRotationAsync`).
Not seen in any capture.

When it is called **[C]** (`Auth: DcgAuthManager.RefreshAccessTokenWithSignedJWTLockedAsync`,
`IsKeyRotationNeeded`): only directly after a successful SignIn, and only if

- `keyValidRemainingDays` ≥ 0 and ≤ 182 (the whole days of `DcgAuthKeyRotationMinimumInterval`, which
  Phone Link sets to half the certificate lifetime, 182.5 days; 3 days in the `Team` ring), or
- the value is unknown (negative) and the stored next-rotation time has passed.

After success, next rotation = now + 182.5 days. After failure, the next check is in 1 day
(`FailedKeyRotationCheckTime`).

Both calls of the exchange carry the MSA identity headers and `api-version=1.1.0`; an
`InvalidNonce` answer is retried with a new nonce like the other `/Auth` calls **[C]**
(`AuthServiceCryptoHelper.PerformKeyRotationAsync`).

**The Mac client (built 2026-10-10 from the above, never run against the service: the identity's
key is not due before April 2027).** `IdentityService.rotateKeysIfDue` runs after a successful
SignIn when the service's count is 182 days or less (or, without a count, when the certificate's
own dates say so), at most once a day. The new key is written to the state *before* the service
is asked and promoted on a 2xx. A 4xx drops it. Anything else (no answer) keeps it: if the next
SignIn with the old key is refused (whatever the refusal is called, a stale nonce or account
token aside: how the service turns down a replaced key was never seen), the kept key is tried
before the identity is given up, so a replacement whose answer was lost does not cost the device its
identity; if the old key goes on working for two days, the kept key is forgotten; a later try
offers the kept key again instead of making another. A failure never fails the sign-in.
Sign-ins asked for at the same time share one exchange (`IdentityService.signIn` is
single-flight), so the service is never offered two keys at once. Tests: `KeyRotationTests`.

### 8.5 CreateIdentity versus SignIn

| Situation | Call | Source **[C]** |
|---|---|---|
| No stored identity | CreateIdentity | `DcgAuthManager.EnsureIdentityIsEstablishedLockedAsync` |
| Stored identity not accessed for more than `IdentityExpirationTime` (180 days) | CreateIdentity | `DcgAuthManager.TryGetIdentity`, `IdentityInformation.IsExpired` |
| Stored account ID differs from the account being provisioned | Clear, then CreateIdentity | `EnsureIdentityIsEstablishedLockedAsync` |
| Identity exists, no DCG token in memory (every process start) | SignIn | `RefreshIdentityLockedAsync`, reason `NewToken` |
| Token within 10 minutes of expiry (`TokenExpirationLeewayTime`) | SignIn | reason `Expired` |
| Caller forces a refresh (the relay does after an auth failure) | SignIn | reason `ForceRefresh`; `YPP: SignalRResiliencyPolicyFactory` |
| SignIn or CreateIdentity returned `InvalidCertificate` (400) or `DeviceUnlinked` (403/13); or the local certificate or private key is missing | Identity cleared; the next provisioning pass does CreateIdentity | `DcgAuthManager` exception handlers |

Establishing an identity is only attempted as part of account provisioning or enrollment
(`Sdk: AccountManager.ProvisionIdentityAsync`); a plain token request with no identity fails with
`NoActiveIdentity` rather than creating one.

### 8.6 Retries

Up to 3 retries of the whole nonce + call sequence when the answer is 400 with `error.code` =
`InvalidNonce`, or on a transient key-store failure. Error code names the client recognizes on 400:
`InvalidRequest`, `IdentityNotYetCreated`, `InvalidAuthHeader`, `InvalidParameters`,
`InvalidCertificate`, `InvalidJWT`, `InvalidNonce` **[C]** (`Auth: AuthServiceErrorCategory`). None of
these was seen on the wire.

---

## 9. `/Registration/Register`

### 9.1 Observed in code

`PUT {base}/Registration/Register?api-version=2.0.0`, DCG-only auth **[C]**
(`YPP: RegistrationManager.RegisterInnerLockedAsync`, `Kiota: RegistrationServiceClientFactory`).

| Body field | Type | Value sent by Windows |
|---|---|---|
| `applicationId` | string | Client type name: `PL` |
| `channelId` | string | The WNS channel URI of the app, as returned by Windows |
| `channelType` | enum string | `WNS` (hard-coded). The schema also allows `FCM` and `APNS`. |
| `deviceId` | string | Own DCG client ID |
| `isDisabled` | bool | In the schema, never set, so omitted |
| `version` | int | In the schema, never set, so omitted |

The response body is not parsed. Related: `DELETE /Registration/DeviceChannel?DcgClientId=&SourceClient=&api-version=`
exists in the generated client (`SourceClient`: `PhoneLink`, `CDEH`, `Unknown`) and is never called.

When it runs:

- When an identity is created (forced), and when the environment changes (forced)
  (`YPP: DeviceIdProvisionedRegistrationMediator`, `YPP: EnvironmentMediator`).
- From triggers on channel URI change and network availability change, not forced, and only while
  at least one trust relationship exists (`YPP: Registration/Triggers`,
  `YPP: RegistrationCapabilityProvider`).
- Skipped when the last registration is under 7 days old (`TimeUntilDataRefreshNeeded`) and the hash
  of channel URI + environment name is unchanged (`YPP: RegistrationState`, `RegistrationStateHasher`).
- If there is no push channel, the client makes no request and reports `ErrorNoChannel`; if the
  channel is expired, `ErrorChannelExpired`.

The call is fire-and-forget. Neither identity creation nor enrollment waits for it or checks its
result **[C]** (the mediator only logs a faulted task).

### 9.2 Observed on the wire

**[W]** P#200: `{"applicationId":"PL","channelId":"https://<wns host>.notify.windows.com/?token=<redacted here>","channelType":"WNS","deviceId":"<pc-dcg-id>"}`,
313 bytes; response `200` with empty body. B#4 is the same with `applicationId` `WEA`.

### 9.3 What it registers

The WNS channel through which the service delivers pushes to this PC. The payload the PC expects is
JSON with a `data` object containing `DCG-Command` = `Wake`, `DCG-SourceId`, `DCG-TraceState`,
`DCG-TraceParent`, and normally `DCG-CryptoWakeJwt`, `DCG-HubRegion`, `DCG-Environment` **[C]**
(`Push: PushNotificationProcessor`, `Push: PushNotificationConstants`). So registration is what lets
the phone wake the PC.

### 9.4 A client with no push channel

Known:

- The Windows client itself skips the call when it has no channel, and continues with enrollment.
- Nothing in the client-side enrollment, trust or wake-sending code depends on a registration.
- **[X]** LinkMyPhone's documented flow has no Register call and reports working sessions.

Guessed:

- That the service does not require a registration before `EnrollDevice` or before this client sends
  `Dispatcher/Wake`. This follows from the two points above but has not been tested by us.
- That a client without a registration simply cannot be woken by the phone, with no other penalty.
  What the service answers to the phone's wake in that case is unknown.

Unknown: whether the service validates `channelId` (for example that it is a real WNS URI for the
Phone Link package), and whether it would accept `FCM` or `APNS` for `applicationId` `PL`. No
"minimal acceptable" dummy value is known. Recommendation that follows from the facts: skip the
call, and rely on holding the relay connection open, until a real push path exists.

---

## 10. Enrollment: `/DeviceAuthProxy/EnrollDevice`

### 10.1 Trust certificate

Before enrolling, the client obtains the certificate for the "trust client ID"
`trust_<pc-dcg-id>` **[C]** (`Auth: TrustManager.GetCryptoTrustClientId`,
`YPP: TrustHelper.GetDeviceCertToRegisterUnderLock`).

- Subject and issuer `CN=trust_<pc-dcg-id>`; everything else as in section 6.3 (same routine, new
  P-384 key). **[W]** P#202, decoded in section 6.3.
- An existing certificate is reused unless it is missing, its private key is missing, or now is later
  than notAfter minus `CryptoTrustKeyRotationBeforeExpirationTime` (182 days; 364 in the `Team`
  ring). In those cases a new one is generated.
- A newly generated certificate is persisted only after the service call succeeds.

This is a different key from the DCG identity key. The identity key proves the device to `/Auth`;
the trust key signs peer-facing JWTs (section 12.4).

### 10.2 Request

`POST {base}/DeviceAuthProxy/EnrollDevice?api-version=1.5.0&pop-device-key=<key>` with MSA + DCG
headers (section 3.6) **[C]** (`Sdk: DeviceManagementManager.EnrollDeviceAsync`).

- `pop-device-key`: always present. Empty in normal operation **[W]** (P#202, B#5). A non-empty value
  must match `^PartnerDeviceKey~[a-zA-Z0-9]{64}$`, otherwise the client blanks it **[C]**
  (`YPP: TrustHelperUtils.IsPopDeviceKeyValid`). Phone Link takes such a key from a Windows registry
  value written by out-of-box setup (`HKCU\Software\Microsoft\Windows\CurrentVersion\Mobility`,
  `PairingContext`, JSON field `pairingToken`) on first-time provisioning only **[C]**
  (`YourPhone.Utilities: RegistryKeyRetriever`, `DevMgd: AccountManager`). The QR pairing result also
  carries a `partnerDeviceKey` (see `protocol/pairing.md`), but no enrollment with it followed in the
  capture **[W]** (after P#226 only list and certificate calls).
- `Authorization` carries the MSA token of the enrollment attempt, which may be the strong-auth
  (SAPI) token; `Dcg-Token` carries the current DCG access token.

Body **[C]** (`DeviceManagementManager.ConvertToEnrollRequestBody`, `Sdk: DeviceMetadataBuilder`),
**[W]** P#202 (1081 bytes):

```json
{
  "certificates": { "SelfSigned": ["<base64 DER of the trust certificate>"] },
  "metadata": {
    "capabilities": ["FILE_TRANSFER_ONEDRIVE", "UNLINKABLE_V1", "UNLINKABLE_V2"],
    "clientType": "PL",
    "clientVersion": "1.26072.257.0",
    "consentVersion": 0,
    "customData": "",
    "displayName": "<host name>",
    "isEnabled": true,
    "manufacture": "Unknown",
    "modelName": "Unknown",
    "modelVersion": "Unknown",
    "osName": "Windows",
    "osVersion": "10.0.26200"
  }
}
```

### 10.3 Field reference

`certificates` is a free-form map from certificate kind to an array of strings.

| Key | Meaning |
|---|---|
| `SelfSigned` | The only kind Windows sends: exactly one entry, standard base64 of the certificate DER, no line breaks (704 characters in P#202) |
| `PKI` | Recognized when reading peers, preferred over `SelfSigned` (section 12.2). Never sent by Windows. |
| `CTSelfSigned` | Recognized when reading peers, otherwise unused. Never sent by Windows. |

Key names are the enum member names of `Sdk: CertificateType`, case-sensitive.

| `metadata` field | Type | Windows value **[C]** |
|---|---|---|
| `capabilities` | string array | From the capability provider. PL: the three strings above. WEA sends nine: `DEVICE_STATUS`, `UNLINKABLE_V1`, `FILE_TRANSFER`, `FILE_TRANSFER_ONEDRIVE`, `FILE_TRANSFER_ONEDRIVE_WNS_PUSH`, `CLIPBOARD`, `REMOTE_CONTROL`, `REMOTE_CONTROL_V2`, `HOTSPOT` **[W]** B#5. |
| `clientType` | enum string | `PL` (others: `WEA`, `LTW`) |
| `clientVersion` | string | Same as `DCG-AppVersion`; must be non-empty |
| `consentVersion` | int | `0` |
| `customData` | string | Empty string |
| `displayName` | string | First network host name up to the first `.`, else the machine name; must be non-empty |
| `isEnabled` | bool | `true` |
| `manufacture`, `modelName`, `modelVersion` | string | `Unknown` each |
| `osName` | string | `Windows`; must not be `Unknown` |
| `osVersion` | string | Same as `DCG-OSVersion`; must be non-empty |
| `distinguishedDeviceId`, `globalDeviceId` | string | Present in the request schema, never set by Windows, so omitted. The service assigns them (section 11.1). |

The "must" notes are client-side checks in `DeviceMetadataBuilder.Build`; what the service enforces
is unknown.

### 10.4 Response

**[W]** P#202 (7833 bytes), B#5. **[C]** `Kiota: EnrollDeviceResponseBody`.

| Field | Type | Content | Used by the client |
|---|---|---|---|
| `devices` | array of device items (section 11.1) | All devices of the account, including the caller. First enrollment of an emptied account returned one item, the caller (P#202); with a linked phone it returned three (B#5). | Not read |
| `accountCert` | string | Base64 DER of the account certificate (section 12.1) | Yes: becomes the A2D trust relationship |
| `accountInfo` | object | `signInName`, `firstName`, `lastName` (strings), `accountKey` (44-character base64, 32 bytes) | Not read by the trust code; purpose of `accountKey` unknown |
| `rootCertificateChain` | string array | Four base64 DER certificates, leaf first: a certificate for `ct-rootcert-deviceauthproxy.dcg.microsoft.com`, then `Microsoft TLS G2 ECC CA OCSP 02`, `Microsoft TLS ECC Root G2`, `DigiCert Global Root G3` | Not read anywhere in the Windows client |

On success the client loads `accountCert`, creates or rotates the account relationship, marks the
account `Enrolled` and stores a hash of the metadata it sent **[C]**
(`YPP: TrustHelper.ProcessEnrollDeviceSuccessUnderLockAsync`). If `accountCert` cannot be parsed the
enrollment fails with `AccountTrustSyncFailure`.

### 10.5 When enrollment runs

**[C]** `Sdk: AccountManager.EnrollSilentlyAsync`, `YPP: TrustHelper.EnrollClientAsync`.

- Only one account can be provisioned at a time.
- If the stored account is already `Enrolled` for the same DCG client ID and environment, nothing is
  sent.
- Otherwise: environment discovery, identity (section 8.5), then EnrollDevice.
- Enrollment happens before any pairing session is created **[W]** (P#202 at 114.3 s, pairing session
  P#207 at 115.4 s).

---

## 11. Device and certificate endpoints

### 11.1 `/DeviceAuthProxy/GetDeviceInfoList`

`GET {base}/DeviceAuthProxy/GetDeviceInfoList?api-version=1.5.0&filter=&top=20`, MSA-only headers, no
body. `filter` is always empty and `top` always 20; there is no paging **[C]**
(`Sdk: DeviceManagementManager.GetDeviceMetadataListAsync`). **[W]** B#6, P#203.

Response: a JSON array of device items. The caller's own entry is included **[W]** (P#203).

| Item field | Type | Observed **[W]** B#6 |
|---|---|---|
| `id` | string | DCG client ID of the device (GUID) |
| `registrationTime` | int64 Unix seconds | |
| `distinguishedDeviceId` | string | `l:<16 digits>` for both Windows clients on the same PC (same value for PL and WEA); `a:<16 hex>` for the Android phone |
| `globalDeviceId` | string or null | `g:<16 digits>` for Windows; `null` for the phone |
| `name` | string | The `displayName` given at enrollment |
| `osName`, `osVersion` | string | `Windows` / `10.0.26200`; `Android` / `15` |
| `manufacture`, `modelName`, `modelVersion` | string | `Unknown` for Windows; real values for the phone |
| `clientType` | enum string | `PL`, `WEA`, `LTW` |
| `clientVersion` | string | |
| `isLinked` | bool | `true` on every item seen |
| `consentVersion` | int | `0` for Windows, `4` for the phone |
| `isEnabled` | bool | `true` on every item seen |
| `lastSeenTime` | int64 Unix seconds | |
| `capabilities` | string array | Phone: `PHONE_APPS`, `DEVICE_STATUS`, `HOTSPOT_ACCOUNT_SECRET`, `CONTINUITY`, `CAMERA_STREAMING`, `PHONE_FILES`, `FILE_TRANSFER`, `CLIPBOARD`, `RINGER_MODE`, `HOTSPOT`, `SEND_MESSAGE`, `REMOTE_CONTROL` |
| `customData` | string | Empty for Windows. For the phone, a JSON document serialized as a string with keys `platform`, `market`, `flightRing`, `defaultLocale`, `assetCategory`, `androidSdkVersion`, `yppCapabilities`, `clientModelName`, `clientModelRevision`, `statusCapabilities`, `deviceResolution`, `registeredPermissionTypes` |
| `certificates` | map of kind to string array | Only `SelfSigned` seen, one entry each |

Parsing rules **[C]** (`DeviceManagementManager.TryConvertToPlatformPeerDeviceMetadata`):

- A `certificates` key other than `CTSelfSigned`, `SelfSigned`, `PKI` makes the conversion of that
  item fail, and then the whole list call is treated as failed.
- Missing `manufacture`, `modelName`, `modelVersion` become `Unknown`; missing `customData` becomes
  empty; `isLinked` and `isEnabled` are true only when the JSON value is `true`.
- The phone's certificate string contains line breaks (MIME-style base64, 572 characters including
  breaks) **[W]** B#6. A decoder must ignore whitespace.

`yppCapabilities` is a bit mask inside the phone's `customData`. The Windows client tests two bits
**[C]**: `0x20` for async trust (`Auth: TrustConstants.AsyncTrustCapability`,
`YPP: TrustHelper.DoesPeerClientSupportAsyncTrust`) and `0x40` for intentional disconnects
(`YPP: PlatformConnection.UpdateIntentionalDisconnectsCapability`). The Android app's own enum
(`corpus/android/.../com/microsoft/mmx/agents/YppCapability.java`) names all bits:

| Bit | Name |
|---|---|
| 1 | `CRYPTO_TRUST` |
| 2 | `PAIRING` |
| 4 | `MANUAL_CONNECT` |
| 8 | `SIDE_CHANNEL_OEM_SUPPORT` |
| 16 | `A2D_MIGRATION` |
| 32 | `ASYNC_TRUST` |
| 64 | `INTENTIONAL_DISCONNECT` |

**[W]** The captured phone reports `127`, all seven bits.

### 11.2 `/DeviceAuthProxy/GetAccountCert`

`GET {base}/DeviceAuthProxy/GetAccountCert?api-version=1.0.0`, MSA-only headers. Response
`{"accountCert": "<base64 DER>"}` (558 bytes) **[W]** B#7. The value is the same certificate that
EnrollDevice returns **[W]** (same leading bytes in B#5, B#7 and P#202). Called after every
successful cloud refresh of the device list **[C]**
(`YPP: TrustHelper.UpdateAccountAfterGetPeersSuccessAsync`).

### 11.3 `/DeviceAuthProxy/SetDeviceInfo`

`POST {base}/DeviceAuthProxy/SetDeviceInfo?api-version=1.5.0&pop-device-key=` with MSA + DCG headers.
Body has the same shape as the EnrollDevice body (section 10.2): `certificates` with `SelfSigned`,
and `metadata` **[C]** (`DeviceManagementManager.ConvertToRequestBody`). **[W]** P#194 (1105 bytes).
The response body is not parsed.

When it is called **[C]**:

- After a device-list refresh, if the caller's own entry is missing, has no `SelfSigned`
  certificate, or its first `SelfSigned` certificate is not one the client holds
  (`TrustHelper.MatchLocalMetadataAsync`).
- Periodically: when the account is enrolled and either the metadata hash changed, or the last
  successful update is older than 7 days and the last attempt older than 1 day
  (`Sdk: ClientInfoObserver`; `UpdateClientInfoTimeInterval`, `AttemptUpdateClientInfoTimeInterval`).
- It is also the path that publishes a rotated trust certificate (section 12.5).

Outcomes: `Unauthorized` requests a deprovision of the account; `403 DeviceUnlinked` triggers the
unlink handling in section 14.3. If the update fails after the own entry or its certificate was
missing, the account is deprovisioned and the refresh reports that enrollment expired.

### 11.4 `/DeviceAuthProxy/GetRootCertificateChain`

`GET {base}/DeviceAuthProxy/GetRootCertificateChain?api-version=<v>`, response: JSON array of strings
**[C]** (`Kiota: GetRootCertificateChainRequestBuilder`). No code in the Windows client calls it, and
no capture contains it. The API version it expects is therefore unknown. The same data arrives as
`rootCertificateChain` in the EnrollDevice response (section 10.4) and is ignored there too.

### 11.5 Other endpoints in this area

| Endpoint | Shape **[C]** (`Kiota`) | Called by the Windows client |
|---|---|---|
| `POST /DeviceAuthProxy/UnlinkDevice?api-version=1.5.0&device-id=<dcg-id>` | No body; MSA + DCG headers | Yes. **[W]** P#181 (sent by WEA for the phone), `200`, empty body |
| `DELETE /DeviceAuthProxy/DeleteDeviceInfo?api-version=1.5.0&device-id=` | Empty `device-id`; MSA + DCG headers | Only on deprovision when `UnenrollDuringDeprovision` is on |
| `GET /DeviceAuthProxy/GetDeviceInfo?api-version=&device-id=` | Returns one device item | No |
| `POST /DeviceAuthProxy/SetTrustedPartner` | Body `partnerDcgClientId`; response `partnerEnrollStatus`: `PendingEnroll` or `Enrolled` | No |
| `GET /DeviceAuthProxy/GetAccountDcgClientId` | Response `dcgClientId` | No |
| `GET /DeviceAuthProxy/IsAccountLinked` | Response `state` (bool) | No |
| `GET /DeviceAuthProxy/GenerateNonce?device-id=` | Response: a string | No |
| `GET /DeviceAuthProxy/GetCryptoTrustRelationship` | Response `selfClientId`, `ttl` (int) | No |
| `POST /DeviceAuthProxy/ValidateCryptoTrustRelationship` | Body `selfClientId`, `partnerClientId`, `partnerDcgClientId`, `selfCertificateThumbprint`, `partnerCertificateThumbprint`; response `ttl` | No |
| `POST /DeviceAuthProxy/RotateCryptoTrustRelationship?device-id=` | Body `jwt`; response `jwt` | No |
| `DELETE /DeviceAuthProxy/DeleteCryptoTrustRelationship` | No body | No |
| `DELETE /DeviceAuthProxy/DeletePartnerDeviceInfo?partner-device-key=` | No body | No |

"No" means no call site exists outside the generated client in the decompiled assemblies.

---

## 12. Trust model

### 12.1 Relationship types and the account certificate

`CryptoTrustType` **[C]** (`Auth: CryptoTrustType`, `Auth: CryptoUtils`):

| Value | Name | Serialized name | Meaning |
|---|---|---|---|
| 0 | `Unknown` | `Unknown` | |
| 1 | `ClassicPairingD2D` | `LegacyD2D` | Old device-to-device pairing |
| 2 | `AccountPairingD2D` | `AccountPairingD2D` | Device-to-device trust from account pairing |
| 3 | `AsyncD2D` | `AsyncD2D` | Peer trust derived from the account's device list |
| 4 | `A2D` | `A2D` | Trust between this device and the account |

Account certificate **[W]** (decoded from P#202 / B#7): 404 bytes DER, v3, self-signed,
`CN=<account-dcg-id>` (a GUID, PrintableString), P-384 key, ECDSA with SHA-384, no extensions,
validity 365 days and 12 hours, 9-byte serial. It was identical before and after the account-wide
unlink in the pairing capture (B#5 and P#202).

### 12.2 How relationships are created

A2D **[C]** (`YPP: TrustHelper.UpdateTrustWithAccountAsync`), on enrollment and after each list
refresh:

- The account's DCG client ID is the subject common name of the account certificate.
- If no relationship exists for that DCG client ID in this environment: add one of type `A2D`.
- If one exists and the certificate thumbprint differs: rotate the partner certificate (section 12.5).

AsyncD2D **[C]** (`TrustHelper.ProcessRefreshedPeerListAsync`, `SyncTrustStorageWithRemotePeerMetadataAsync`,
`AddRemotePeersToTrustStorageAsync`), on each cloud refresh of the device list:

1. Candidates: items with `isLinked` true and `id` different from the caller's own DCG client ID.
   The filter is not limited to phones: another PC client of the same account becomes a peer too.
2. Remove every stored `AsyncD2D` relationship whose partner is no longer among the candidates.
3. For each candidate pick the certificate: the first entry of `PKI` if that kind is present,
   otherwise the first entry of `SelfSigned`. Skip the candidate if neither exists.
4. If a relationship with partner client ID `trust_<peer-dcg-id>` exists: rotate its partner
   certificate when the thumbprint differs; fill in the account CID and type `AsyncD2D` when they
   were empty.
5. Otherwise, if some other relationship already maps this peer DCG client ID (for example an old
   pairing trust): replace it only when the peer supports async trust (its OS is `iOS`, or
   `yppCapabilities` has bit `0x20`); if not, skip the peer.
6. Otherwise add a new relationship of type `AsyncD2D`.

A cloud refresh happens when forced, or when the last one is older than 1 day; otherwise the cached
list is returned (`TrustHelper.GetTrustedPeerClientsUnderUpdateLockAsync`). An incoming wake from an
unknown or unverifiable sender forces a refresh, at most 5 times per sender per hour
(`YPP: PeerClientUpdater`; `AuthPairingClientUpdatingThreshold` = 5).

**[W]** The stored state of the paired VM shows exactly these two types: 4 with the account and 3
with the phone (`captures/vm-state/2026-10-09-paired-device.redacted.json`).

### 12.3 Stored fields

File `YppCryptoTrustRelationships` in the app's local cache folder: `ConfigVersion` and
`TrustedClients`, a map keyed by partner client ID **[C]** (`Auth: CryptoTrustRelationshipStoragePayload`,
`Auth: CryptoTrustRelationshipPayload`); field list confirmed **[W]** by the VM state snapshot.
At most 100 relationships.

| Field | Content |
|---|---|
| `SelfClientId` | `trust_<pc-dcg-id>` |
| `PartnerClientId` | `trust_<peer-dcg-id>` or `trust_<account-dcg-id>` |
| `PartnerCertificate` | Base64 DER |
| `PartnerTemporaryCertificate` | Base64 DER of the previous partner certificate during a rotation grace period, else null |
| `PartnerKeyExpirationTime` | The earlier of the certificate's notAfter and (time added + 365 days). Adding fails if the certificate is already expired. |
| `PartnerTemporaryKeyExpirationTime` | Rotation time + `PartnerTemporaryCertificateExpirationTime` (10 minutes) |
| `RelationshipLastAccessTime` | Updated on use, at most once per 12 hours |
| `Attributes` | String map. One entry per environment giving the partner's DCG client ID: key `dcg_prod_client_id`, `dcg_beta_client_id`, `dcg_df_client_id`, or legacy `dcg_client_id` |
| `MsaCid` | Account customer ID; empty for legacy device-to-device relationships |
| `TrustType` | Numeric `CryptoTrustType` |

A second file, `DeviceMetadataStorage.json`, caches the linked device items per account
(`Sdk: DeviceMetadataCacheRepository`).

### 12.4 What the trust key signs

The trust key (`CN=trust_<pc-dcg-id>`) signs compact JWTs addressed to a peer **[C]**
(`Auth: CryptoPayloadProvider.GenerateSignedJwtPayloadAsync`, `Auth: CryptoManager.GenerateSignedJWTByCertificateInner`).

| Element | Value |
|---|---|
| Algorithm | `ES384`, same header and signature encoding as the nonce JWT (section 7.2) |
| `iss` | The trust client ID, `trust_<pc-dcg-id>` (issuer CN of the signing certificate) |
| Claim `Data` | A string. For wake and side-channel requests: the JSON text of a string-to-string map (section 13.3) |
| Claim `SourceId` | The signer's DCG client ID, `<pc-dcg-id>` |
| Claim `Scope` | `wake`, `hotspot.request` or `hotspot.response` (`Auth: AuthConstants`) |
| `nbf`, `exp`, `iat` | now − 12 h, now + 12 h, now |
| `aud` | Not set |

Empty claims are omitted. Uses found in code: the wake JWT (`YPP: DispatcherManager`) and hotspot
side-channel requests (`YourPhone.YPP.SideChannel: SideChannelClientRequestBuilder`). A signed and
RSA-encrypted variant exists (`RSA-OAEP` with `A256CBC-HS512`, `CryptoManager.GenerateSignedJWEByCertificateInner`).

If the signing certificate cannot be found and cannot be recovered, the relationship with that
partner is removed and no JWT is produced.

### 12.5 Validation rules

How the Windows client validates a JWT received from a peer **[C]**
(`Auth: AuthPairingValidation.GetDataIfJwtSignedByTrustedPartnerInnerAsync`,
`Auth: CryptoManager.GetDataIfJwtValidByCertificate`):

1. Read `iss` without verification; look up the relationship whose `PartnerClientId` equals it.
   No relationship means `UntrustedPartner`.
2. If a scope is expected, claim `Scope` must exist and match exactly. Wake pushes received by the PC
   are validated without a scope requirement.
3. Verify the signature with the public key of `PartnerCertificate`; if that fails and an unexpired
   `PartnerTemporaryCertificate` exists, try it.
4. `iss` must equal the common name of the certificate used.
5. Lifetime is checked with a clock skew of 12 hours (`JWTClockDriftTime`).
6. `aud` is optional; if present it must equal the verifier's own `SelfClientId`.
7. The result is the `Data` claim, which must be a string.
8. For wake: the push's `DCG-SourceId` must be one of the DCG client IDs stored in the signing
   relationship's `Attributes` (`Push: PushNotificationProcessor.ProcessCryptoWakeCommandInnerAsync`).

How a relationship is judged valid when looked up **[C]** (`Auth: TrustManager`):

- Unexpired means `PartnerKeyExpirationTime` > now and `RelationshipLastAccessTime` +
  `CryptoTrustRelationshipExpirationTime` > now. Phone Link's effective value is 180 days (see
  section 15, item 6). Expired relationships are deleted when touched.
- An `AsyncD2D` relationship is usable only if the `A2D` relationship with the same `MsaCid`, when
  one exists, is itself unexpired.

What is not checked **[C]**: peer and account certificates are never chain-validated, their
notBefore is not checked, and no extension is required. A certificate is trusted because the service
returned it over TLS in response to an MSA-authenticated request. The only certificate-level check
when adding a relationship is that notAfter is in the future.

**[I]** The phone presumably applies the mirror image of rules 1 to 8 to our wake JWT, using the
certificate we enrolled. The Android side is outside this document's sources.

### 12.6 Key rotation

Three separate mechanisms **[C]**:

| What rotates | How | When |
|---|---|---|
| DCG identity key | `/Auth/RotateKeys` (section 8.4) | After a SignIn, when the remaining key validity is 182 days or less |
| Own trust certificate, account-based trust | A new certificate is generated and sent in `SetDeviceInfo` (or `EnrollDevice`), then persisted on success. Peers pick it up at their next device-list refresh and keep the old one valid for 10 minutes. | At the next SetDeviceInfo or EnrollDevice after the certificate has less than 182 days left |
| Own trust certificate, legacy device-to-device trust (relationships with empty `MsaCid`) | Over the relay, not REST: routes `/CryptoTrustKeyRotationCheck` (response keys `CryptoKeyRotationResult`, `TimeToExpireInSeconds`) and `/CryptoTrustKeyRotation` (request key `Certificate` = base64 DER; response `CryptoKeyRotationResult`, `ResultDetails`). Result `0` is success, `1` is "relationship not found". | On an incoming app message from such a partner, at most once per day per partner (`CryptoTrustKeyRotationMinimumInterval`), when the partner reports under 182 days left |

The REST endpoints `RotateCryptoTrustRelationship`, `ValidateCryptoTrustRelationship` and
`GetCryptoTrustRelationship` are not used by this client (section 11.5).

The client also answers the two relay routes for its partners (`YPP: CryptoTrustKeyRotationHandler`).
A client that only holds account-based relationships never initiates them.

---

## 13. Wake: `/Dispatcher/Wake`

### 13.1 Request

`POST {base}/Dispatcher/Wake?api-version=1.5.0`, DCG-only auth (`Authorization: Bearer <dcg token>`),
standard and trace headers **[C]** (`YPP: DispatcherManager.WakeAsync`,
`Kiota: DispatcherServiceClientFactory`). **[W]** B#16, P#9, P#245, R#10: all `200` with empty body.

There is no wake JWT header on this request. The constant `DCG-CryptoWakeJwt` is also defined as a
header name (`Common: CustomHeaderNames.CryptoWakeJwt`), but on this endpoint the JWT travels inside
the body's `data` object **[C]** **[W]**.

### 13.2 Body

**[W]** B#16 (894 bytes), key order as sent:

```json
{
  "collapseKey": "YPPWake",
  "data": {
    "DCG-Environment": "Prod",
    "IgnoreDeviceDisabledStatus": "True",
    "DCG-RequestNewSession": "True",
    "DCG-HubRegion": "<region name>",
    "DCG-CryptoWakeJwt": "<jwt>"
  },
  "deviceId": "<phone-dcg-id>",
  "priority": "normal",
  "ttl": 20
}
```

| Field | Type | Value **[C]** (`YPP: WakeParams`, `WakeProvider`) |
|---|---|---|
| `collapseKey` | string | Always `YPPWake` |
| `deviceId` | string | DCG client ID of the target |
| `priority` | string | `normal` on the first attempt of a wake cycle, `high` on retries. Wakes sent outside the retry policy (cancel wake, Nano wake) use `high`. |
| `ttl` | integer (JSON number) | Whole seconds. Default 20 (`DefaultWakeNotificationTimeToLive`). Alternates with 2700 (`LongRunningWakeNotificationWindow`, 45 minutes) after an attempt ends in "device unreachable". Cancel wake: 1. Nano wake: 30. |
| `data` | object, all values strings | See 13.3 |

### 13.3 The `data` object

Built in two steps **[C]** (`WakeParams.BuildWakeData`, `DispatcherManager.WakeAsync`).

Step 1, the wake data map, in this order:

| Key | Value | Present |
|---|---|---|
| `DCG-Environment` | `Prod`, `Beta` or `Dogfood` (target's environment) | Always |
| `IgnoreDeviceDisabledStatus` | `True` or `False` (capitalized) | Always |
| `DCG-RequestNewSession` | `True` or `False` | Always |
| `DCG-HubRegion` | Region name reported by the relay hub in its on-connected payload | When known. **[W]** values seen: `PolandCentral`, `NorthEurope`, `WestEurope` |
| `DCG-NoOp` | `True` | Only for a cancel wake |
| `ApnsLocalizedAlert`, `AppleNotificationType`, `MutableContent`, `Payload` | strings | Only for iOS-specific wakes |
| `NanoConnectionString` | Base64 of a compressed JSON document | Only for Nano wakes |

Step 2: sign the map (section 13.4) and add `DCG-CryptoWakeJwt` = the JWT as the last key. The JWT
itself is not part of what is signed. Exception: when `NanoConnectionString` is set, the outgoing
`data` contains only `DCG-CryptoWakeJwt`; the other keys travel solely inside the signed claim.

If no trust relationship exists for the target, or there is no active identity, the JWT is null and
the key is set to null rather than left out **[C]**. An interoperable client should never reach that
state.

Option flags behind the two booleans (`YPP: WakeOptions`): `IgnoreDeviceDisabledStatus` = 1,
`RequestNewSession` = 2, `CancelPrevious` = 4. `RequestNewSession` is set when the connection policy
asks for a new session or the feature `ShouldBlockSessionStopFeature` is on
(`YPP: PlatformConnectionNextTryPolicyManager.BuildWakeParams`, `YPP: SignalRFragmentTransport.BuildWakeParams`).

### 13.4 The wake JWT

A trust JWT as in section 12.4 with:

| Claim | Value |
|---|---|
| `iss` | `trust_<pc-dcg-id>` |
| `SourceId` | `<pc-dcg-id>` |
| `Scope` | `wake` |
| `Data` | The step 1 map serialized as JSON text |
| `nbf`, `exp`, `iat` | now − 12 h, now + 12 h, now |

Signing key: the trust certificate named by the `SelfClientId` of the relationship found for the
target DCG client ID **[C]** (`CryptoPayloadProvider`).

Form of the `Data` string. **[C]** The map is converted to a JSON object and rendered with the
node's default string conversion. **[W]** **[I]** Length check on B#16: the body is 894 bytes, the
rest of the body accounts for 260, so the JWT is 634 characters. That equals header 36 + payload +
signature 128 + 2 dots only if `Data` is the indented rendering (two-space indent, `": "` after
keys, CRLF line breaks), embedded with `\"`, `\r`, `\n` escapes, and `iat` is present. The compact
rendering gives 592, LF line breaks give 621. So `Data` looks like this before JSON string escaping:

```
{<CR><LF>
  "DCG-Environment": "Prod",<CR><LF>
  "IgnoreDeviceDisabledStatus": "True",<CR><LF>
  "DCG-RequestNewSession": "True",<CR><LF>
  "DCG-HubRegion": "<region name>"<CR><LF>
}
```

**[I]** The receiver parses `Data` as JSON (the Windows receiver does, section 12.5), so whitespace
should not matter to a verifier. Matching the Windows form exactly is the conservative choice.

### 13.5 When wake is sent

**[C]** `YPP: SignalRPartnerConnectionService`, `YPP: WakeProvider`, `YPP: WakeResiliencyPolicyFactory`.

1. The relay hub connection for the target is open (out of scope here).
2. The client invokes the hub method `SendConnectedAsync(<target-dcg-id>)` and waits for it.
3. It waits up to 10 s for the hub's on-connected payload and copies its region name into
   `DCG-HubRegion`.
4. It sends the wake, then waits for the partner to appear on the hub for max(ttl, 10 s)
   (`MinimumWaitForPartnerConnectionTime`).
5. If the partner does not appear ("device unreachable"), it retries up to 2 times
   (`WakeRetryAttempts`) with priority `high`.
6. A circuit breaker per target opens when a 5-minute window holds at least 15 results and all of
   them are "unreachable" while the network is up, and stays open for 1 minute
   (`DeviceUnreachableEventsBeforeCircuitOpens`, `WakeCircuitBreakerSamplingDuration`,
   `WakeCircuitBreakerDurationOfBreak`); it resets on session unlock and on resume from sleep.
7. If the caller cancels while waiting, a cancel wake is sent: ttl 1, `DCG-NoOp` `True`.
8. Concurrent wake cycles for the same target are merged into one.

Triggers: opening a platform connection to a partner that is not present on the hub, and sending a
message fragment to an absent partner. **[W]** B#11 (negotiate) precedes B#16 (wake) by about 1 s;
trigger names in the trace state include `AutomaticReconnectWake` and `ShareServiceStarted` (P#9, P#245).

A Bluetooth wake path exists in parallel when a Bluetooth device ID is known; it is outside this
document.

### 13.6 Wake errors

**[C]** `DispatcherManager.ConvertFailureToDispatcherResult`: 404 means device not found; 400 with
category 10 means incompatible region; 401 means unauthorized; 403 with category 7 means the phone
app is disabled (`LtwDisabled`); anything else is a generic failure. None was seen on the wire.

---

## 14. Token lifetimes, refresh and errors

### 14.1 DCG access token

| Fact | Value | Source |
|---|---|---|
| Lifetime | 24 hours (expiry = issue time + 86401 s) | **[W]** B#2/B#3, P#188/P#189 |
| Client expectation | Expiry in the future and at most 24 hours ahead (`TokenExpirationTime`); otherwise it only logs | **[C]** `AuthServiceCryptoHelper.CreateAccessTokenFromResponse` |
| Refresh point | When expiry − 10 minutes has passed, checked each time a token is requested | **[C]** `DcgAuthManager.IsAccessTokenExpiredLocked` |
| Refresh method | `GenerateNonce` + `SignIn`. There is no refresh token. | **[C]** |
| Persistence | Not persisted; one SignIn per process start | **[C]** `DcgAuthStorage`; **[W]** P#188 |
| Format | Opaque to the client, 841 characters | **[W]** |

Tokens are cached per scope label; the only label used is `general`.

### 14.2 Other lifetimes

| Item | Value **[C]** |
|---|---|
| Nonce JWT and trust JWT window | −12 h to +12 h |
| Identity and trust certificate | 365 days (+12 h backdating) |
| Identity key validity reported by service | 364 days right after creation **[W]** |
| Identity considered stale | 180 days without use (`IdentityExpirationTime`) |
| Trust relationship unused | 180 days (section 15, item 6) |
| Device-list cache | 1 day |
| Client info refresh (SetDeviceInfo) | 7 days, retry no sooner than 1 day |
| Push registration refresh | 7 days |

### 14.3 HTTP error handling

Error body **[C]** (`Kiota: ErrorResponse`, `ODataError`), **[W]** P#194:
`{"error": {"code": "<string>", "message": "<string>", "categoryCode": <int>, "details": [...]}}`.

Status mapping **[C]** (`Kiota: ServiceRequestResultMappingUtils`):

| HTTP | `categoryCode` | Internal status | Typical reaction |
|---|---|---|---|
| 400 | 10 | `UnsupportedMarketError` | Fail |
| 400 | other | `BadRequest` | On auth calls, look at `error.code`: `InvalidNonce` retries, `InvalidCertificate` clears the identity |
| 401 | 1 | `MsaUnauthorizedRequest` | Treated as unauthorized |
| 401 | 4 | `StrongAuthUnauthorizedRequest` | Treated as unauthorized; Phone Link may then ask for the SAPI token interactively |
| 401 | other | `UnauthorizedRequest` | Treated as unauthorized |
| 403 | 7 | `LtwDisabled` | Phone app disabled |
| 403 | 13 | `UnlinkedDevice` | Unlink handling, below |
| 403 | other | `ForbiddenDcgRequest` | On CreateIdentity: device ID collision, retry with a new GUID |
| 404 | | `NotFoundError` | |
| 429 | | `TooManyRequests` | REST callers just fail. The relay layer backs off 15 s plus up to 30 s of jitter (`TooManyRequestsBaseDefaultDelayTime`, `TooManyRequestsMaxVarianceOnDelayTime`; `YPP: ResiliencyUtils`) |
| 500 to 600 | | `ServiceError` | |
| other | | `ClientError` | |

If the error body cannot be parsed, only the HTTP status is used and 403 becomes
`ForbiddenDcgRequest`.

Unauthorized results **[C]**: token acquisition reports `Unauthorized` to the caller; on
SetDeviceInfo it requests deprovisioning of the account (`TrustHelper.UpdateClientUnderLockAsync`);
on environment discovery it stops provisioning. The relay layer forces one DCG token refresh
(a new SignIn) on the first retry after an HTTP 401 from the hub
(`YPP: SignalRResiliencyPolicyFactory.RefreshAccessTokenIfNecessaryAsync`).

The HTTP clients also carry the stock .NET resilience handler and the Kiota retry and redirect
handlers (`Kiota: IHttpClientBuilderExtensions.ConfigureDcgDefaults`); their parameters are library
defaults and were not examined.

### 14.4 `DeviceUnlinked`

**[W]** P#194: `POST /DeviceAuthProxy/SetDeviceInfo` answered `403` with
`{"error":{"code":"DeviceUnlinked","message":"The device has been unlinked.","categoryCode":13}}`.
P#192 shows the same for the WEA client.

Context **[W]**: WEA unlinked the phone with `UnlinkDevice` (P#181). The next list still showed both
PC clients (P#182); about 55 s later the list was empty for both clients (P#191, P#193). Each client
then tried SetDeviceInfo, because its own entry was missing, and got the 403.

Client reaction **[C]**: the client keys on `categoryCode` 13 with HTTP 403, not on the `code`
string. Every call site in `Auth: AuthServiceCryptoHelper` and `Sdk: DeviceManagementManager`
publishes an "unlinked" event for the environment. Two subscribers act on it:

- `Auth: DcgAuthManager` clears the stored identity and account ID and raises "device ID
  deprovisioned", upon which all trust relationships whose `SelfClientId` is `trust_<old-id>` are
  removed.
- `Sdk: AccountManager` deprovisions every stored account: removes the account record, the trust
  relationships with that account's CID, the trust certificate `CN=trust_<old-id>`, and the device
  cache.

Recovery **[W]**: Phone Link then ran environment discovery, GenerateNonce and CreateIdentity with a
new device ID, Register, and EnrollDevice (P#195 to P#202). It did not attempt SignIn with the old
identity. After relinking, the phone also had a new DCG client ID (P#227 compared with P#162).

A client must therefore treat 403/13 as "discard device ID, both certificates and all trust state,
then start again from section 1.2".

---

## 15. Disagreements and corrections

1. **`AuthorizationPortal` duplicated for Phone Link.** Code adds the default header once
   (`Kiota: ConfigureDcgDefaults`); the wire shows `FirstPartyAppsRepo, FirstPartyAppsRepo` on every
   PL request (P#188) and a single value for WEA (B#1). Cause unknown. The service accepts both.
2. **MSA scope.** `PLAN.md` section 2.1 states Windows uses `service::msatoken.dcg.microsoft.com::MBI_SSL`.
   That is the code default with the migration flag off. The captured clients send the portal value
   that the code ties to the migrated scope `https://dcg.microsoft.com/DCG.ReadWrite` (section 4).
3. **`baggage`.** Listed among the standard headers in the task notes and in claim C0031's capture;
   it is sent by WEA only. Phone Link does not send it.
4. **Unused endpoints.** `protocol/windows-catalog.md` lists `RotateCryptoTrustRelationship`,
   `ValidateCryptoTrustRelationship`, `GetCryptoTrustRelationship`, `GetRootCertificateChain`,
   `SetTrustedPartner`, `IsAccountLinked`, `GetAccountDcgClientId`, `DeviceAuthProxy/GenerateNonce`
   and the `...WithMSA` auth variants. They exist only in the generated client; nothing calls them.
5. **When phone trust is created.** Claim C0011 says the type 3 relationship is "created at
   pairing". In code it is created by the device-list sync (section 12.2), as C0020 already notes.
6. **Trust relationship expiry.** `Common: PlatformOptions` defaults
   `CryptoTrustRelationshipExpirationTime` to 179 days, but `ConnMgd: YppPlatformOptionsBuilder`
   overrides it with a remote setting whose fallback is the identity expiration time, 180 days.
7. **Third-party notes [X].** LinkMyPhone's description differs from Windows in three places: it
   does not list `iat` in the JWTs (Windows tokens contain it, by length); it says `pop-device-key`
   is sent only when present (Windows always sends the parameter, empty); it gives wake priority
   `high` (Windows sends `normal` first). None of these is known to matter to the service.

---

## 16. Minimum behavior for an interoperable client

Derived from the facts above; items marked **[I]** rest on inference.

1. Generate once and persist: a GUID device ID; a P-384 identity key with a certificate per
   section 6.3; later a P-384 trust key with a certificate `CN=trust_<device-id>`.
2. Send the header set of section 3 with Phone Link's literals, `AuthorizationPortal: FirstPartyAppsRepo`,
   and an MSA token for `https://dcg.microsoft.com/DCG.ReadWrite` **[I]**.
3. Call environment discovery; use the Prod base unless it says `Beta`.
4. GenerateNonce, build the JWT of section 7, CreateIdentity. Persist only after success.
5. Skip Register **[I]** (section 9.4).
6. EnrollDevice with the body of section 10.2; store `accountCert` as the A2D relationship.
7. GetDeviceInfoList; build AsyncD2D relationships per section 12.2; decode peer certificates
   tolerating whitespace; GetAccountCert.
8. On later starts: GenerateNonce + SignIn; refresh 10 minutes before expiry.
9. To reach the phone: after the relay steps in section 13.5, POST the wake of sections 13.2 to 13.4.
10. On 403 with category 13 anywhere: wipe and start over (section 14.4).
11. Once the trust certificate has under 182 days left, send a new one with SetDeviceInfo; once the
    service reports 182 or fewer key days left after SignIn, call RotateKeys.

---

## 17. Open questions

1. Does the service accept this sequence from a non-Windows client with a device-code MSA token?
   Only a live attempt can tell (same as claim C0039).
2. Is `Registration/Register` required for anything other than receiving pushes? What does the
   phone see when it wakes a client with no registration? Would the service accept `FCM` or `APNS`
   or an arbitrary `channelId` for `applicationId` `PL`?
3. Does the service derive `distinguishedDeviceId` and `globalDeviceId` from `DCG-LogicalDeviceId`,
   from the MSA token, or from something Windows-specific? Both Windows clients on one PC received
   the same pair although their `DCG-LogicalDeviceId` values differ. What would a Mac receive, and
   does the phone group or filter devices by these values?
4. Does the service or the phone enforce anything about our certificates beyond what Windows
   checks: name string type, the two extensions, serial length, the 365-day lifetime?
5. Exact claim order and JSON escaping inside the JWTs cannot be seen in redacted captures. The
   length checks fix the content but not the order. Presumably irrelevant.
6. Does the phone verify that `Data` in the wake JWT equals the outer `data` values, and does it
   require `iat`? Needs the Android sources or a live test.
7. What is `accountInfo.accountKey`, and what does the account's key sign? Windows stores the
   account certificate as a trust partner but no captured or decompiled path shows a JWT issued by
   the account.
8. What are `rootCertificateChain` and the `PKI` and `CTSelfSigned` certificate kinds for? The chain
   leaf is a certificate for `ct-rootcert-deviceauthproxy.dcg.microsoft.com`; nothing in the Windows
   client consumes it.
9. `/Auth/RotateKeys`, the 401 categories and the 400 auth error codes were never seen on the wire;
   their descriptions are code-only.
10. Why did the phone-only unlink empty the whole device list after roughly a minute? The service
    behavior is observed (section 14.4) but its rule is not known.
11. Phone Link's own `Dispatcher/Wake` has not been captured; all wake evidence is from the WEA
    client, which shares the code.
