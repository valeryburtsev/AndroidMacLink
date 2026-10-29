# Links across the two devices

Status on 2026-10-10: built and tested against scripted phones; **not yet tried with the
phone**. What the protocol offers here is narrower than it sounds, so this note starts with
what does not exist.

Tags as elsewhere: **[code-android]**, **[code-windows]**, **[capture]**, **[built]**.

## 1. What Phone Link and Link to Windows offer

| Wish | Finding |
|---|---|
| Share a link on the phone to the computer | **Refused by the phone.** Link to Windows' share screen takes files only: for `text/plain` with text it shows "unsupported content" and sends nothing **[code-android]** (A: appmanager.filetransfer.ui.FileTransferActivity.sendFile, string `web_link_share_error_unsupported_content`). |
| The older "shared content" sync | Windows still has it (`sharedContentV2` with `customTypes` 1 = shared URI, opened with `Launcher.LaunchUriAsync` when auto-launch is on; W: SharedContent.Managed :: Processors.SharedContentProcessor) **[code-windows]**, but nothing on the phone sends it any more: `SharedContentCustomType.SHARED_URI` has no user **[code-android]**. |
| Open a link on the phone from the computer | **No message for it.** The phone's handlers take a package name (`/mirror/phone/launchApp`, inside a mirroring session), a named settings screen (`/mirror/phone/launchCustomIntent` with `intentKey`), a notification's own action, or a number for the dialler; none takes an address **[code-android]** (every `RegisterHandler` of screenmirroringsrc and every `ACTION_VIEW` under agents). |
| What the user is doing on the phone | **Exists: app contexts.** Section 2. |

## 2. App contexts ("continue on PC")

Apps that support Microsoft's cross-device continuity tell Link to Windows what the user has
open; the phone pushes that to the computer **[capture]** (records 3066, 3252, 14602 ... of
`vm-raw`; in the recording only Samsung Notes did, with type `ResumeActivity`).

APP `/legacy/phonecontent`, `contentType` `continuityAppContext`, with the common keys and:

| Key | Type | Meaning |
|---|---|---|
| `appContextItemCount` | Int32 | entries in the arrays |
| `appContextSequenceNumber` | Int64 | counts up by one per push |
| `appContextIds` | Int64Array | |
| `appContextAppIds` | StringArray | package name |
| `appContextContextIds` | StringArray | the app's own name for the thing |
| `appContextTypes` | StringArray | `ResumeActivity`; `BrowserHistory` for a page in a browser **[code-android]** |
| `appContextTitles`, `appContextWebLinks`, `appContextIntentUris`, `appContextExtrases`, `appContextTeamIds` | StringArray | a web link where the app gives one; the intent address is the app's own scheme (`sec-uap-samsungnotes:OpenNote?...` in the recording) |
| `appContextActions` | Int32Array | 0 new or changed, 2 gone |
| `appContextCreateTimes`, `appContextLastUpdatedTimes`, `appContextLifeTimes`, `appContextTaskIds` | Int64Array | life time 300000 ms, -1 or 0 seen |

Windows answers `{result: 0}`. Sent because the connect request has `TaskContinuity` and
`BrowserHistory` true (`session-clipboard-notifications.md`).

Which browsers report pages **[code-android]**: those that declare
`com.microsoft.crossdevice.browserContextProvider` or `...browserContextService`
(A: agents.taskcontinuity.subscriber.BrowserHistoryHandler). Which installed browsers do is
not known; Chrome is not expected to.

## 3. The Mac client [built]

**From the phone**
- A link copied on the phone arrives with the clipboard (already synced). Text that is a web
  address, a short text with exactly one in it, or a `geo:` place counts as a link
  (`PhoneLinks.link(inCopied:)`).
- App contexts with a web address (`PhoneAppContext`, `NotificationSync.Change.appContexts`).
- Either is listed under Links and, as set in Settings, announced with a Mac notification that
  opens it, or opened at once.

**To the phone** (switched off: `AppModel.linkSendingEnabled` is false since 2026-10-10; the
user did not like a file arriving for a link. The code and its tests stay.)
- With no message for it, a link travels as a small HTML page over the file-transfer path
  (`PhoneLinks.page(for:)`, "Link to <site>.html"): the phone shows its "file received"
  notification, and opening the file leads to the address (refresh, script, and a visible
  button for viewers that follow neither).
- Entry points: the Links section (type, paste or drop), the menu bar item when a link is on
  the Mac's clipboard, the Services menu of any app when a web address is selected, and
  `winphone://send?url=...`.

## 4. Open questions

1. Does tapping the phone's notification open the page in a browser, and does that browser
   follow the redirect?
2. Does any browser on the phone report pages as `BrowserHistory`?
3. A real "open now" on the phone would have to drive the phone's screen (open the browser
   through a mirroring session, paste, Return): possible, not built.
4. A Share-menu entry on the Mac needs an app extension; only Services exists.
