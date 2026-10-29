# Phone Mac Link: test checklist (begun 2026-10-09, 17:30)

Everything below was built while the phone was unattended. Nothing here was sent to the phone
without you: no texts, no ring, no setting changes, no dialogs, no deletions. The app that is
running is the current build (`app/build/Phone Mac Link.app`).

If something goes wrong, the log is one click away: **Phone Mac Link › Settings › General › Show Log
in Finder** (`~/Library/Logs/Phone Mac Link/phone-mac-link.log`). It holds steps and error codes only.

Order: safest first. Each item says what to do and what should happen.

## Still to test (as of 2026-10-10)

**If there are only ten minutes**, in this order, since these tell the most:

1. Phone Screen: tick "Show in a window of its own", start it, turn the phone on its side,
   take a screenshot (F5: J1, J3, J4).
2. Phone Storage: open the section and wait for the folders; download one small file (F6).
3. A call: drag the card, Hold and Resume.
4. Photos: drag one to the Desktop. Apps: add a favorite. Press ⌘2, ⌘5, ⌘7.

- [ ] **Notifications, new on 2026-10-12**: with two fingers on the trackpad, swipe a
      notification to the left. It follows the fingers with a red "Dismiss" strip behind it;
      let go past about a third of its width and it is dismissed, earlier and it comes back.
      Scrolling up and down must work as before. (Tried only with made-up events so far.)
- [x] **Notification buttons** (such as "Mark as read"): work since 2026-10-13, pressed the
      way Phone Link does it. Not while the phone's screen is shown in the app.
- [ ] **When the phone stops answering** (new on 2026-10-15): after about a minute without an
      answer the sidebar says since when, and offers **Show QR Code**. Scanning it with the
      phone links it again; as with Windows on 2026-10-15 nothing else should be asked, and the
      app should connect by itself. Only try this when the phone is really stuck.
- [ ] **Instant Hotspot, leaving** (new on 2026-10-12): while the button is green, click it.
      The Mac should go back to its own Wi-Fi within a few seconds. Also: pick another network
      by hand while it is green; the button should go out by itself in about five seconds.
      Afterwards the phone's network should not be among the Mac's remembered networks
      (System Settings › Wi-Fi › Known Networks) unless it was there before.
- [ ] **Phone screen and files away from the same Wi-Fi**: section F4 (I1 to I7). Needs "Sync
      over mobile data" on; start with a small file.
- [ ] Calls on this Mac: an incoming call (panel, answer, decline) and a call answered on the
      phone while the Mac is connected: section F2 (H4 to H10).
- [ ] Links, phone to Mac: in Chrome or Maps on the phone, Share › Copy (or copy a link any
      other way). A Mac notification offers to open it; it is also listed under **Links**.
      Settings › General can make it open at once.
- [ ] The new call card: place or receive a call. Drag the card somewhere else (press anywhere
      on it and move); the next call should show it there. During a call: **Hold**, then
      **Resume**. There is no Mute for this phone: it does not offer one over this link.
- [ ] **Phone screen, new on 2026-10-10 afternoon** (section F5):
      turning the phone, the window of its own, screenshots, files dropped on the picture.
- [x] **Instant Hotspot**: works since 2026-10-12 (phone switches its hotspot on, the Mac joins).
- [x] **Phone Storage**: listing works live (2026-10-10 20:08, 10,743 entries in 3 batches,
      about 20 s). Still to try: previews, search, a change on the phone showing up, and
      **download** (F6: K4 to K6).
- [ ] Phone screen started on a locked phone, then unlocked from the Mac: on 2026-10-10 20:07
      the picture stayed black after the passcode. Changed since: the replacement session
      waits a moment, and an awake phone without a picture is asked again by itself. Try again.
- [ ] Apps: right-click an app › Add to Favorites; opened apps appear under "Recently Opened".
- [ ] Menu bar: View › sections with ⌘1 to ⌘9; the new **Phone** menu (Show Phone Screen ⇧⌘P,
      own window, screenshot ⌥⌘S / ⌥⌘C, Ring Phone, Do Not Disturb, Send Files to Phone… ⇧⌘O).
      While the phone's picture has the keyboard, Command shortcuts go to the phone instead.
- [ ] Photos: drag a photo from the grid to the Desktop, Finder or another app (it is fetched
      from the phone when dropped, so allow a second or two); right-click › Save to Downloads
      and Copy without opening the photo.
- [ ] Files: drop one or several files on the app's **Dock icon**. Expected: they are sent to
      the phone as one transfer and the Files section comes forward. (If the Dock icon does not
      take the drop, tell me; nothing else depends on it.)
- [ ] Contacts (new sidebar section): search, a contact's Message and Call buttons.
- [ ] Notifications grouped by app (toolbar switch "Group by App"; Clear per app).
- [ ] Battery alerts (Settings › General › Phone): low at 20 % and 10 %, optionally "charged".
- [ ] The app icon in the Dock and in Finder.
- [ ] Sync over mobile data: the switch and the sidebar note: section F3.
- [ ] Notifications per app: the gear in Notifications (or Settings › Notifications). The switch
      hides an app here; the sliders button beside it turns off its Mac notification, its
      sound, or its count on the Dock icon. Right-click a notification for the same choices.
- [ ] Phone screen: Back closing an app's session; right and middle click.
- [ ] Phone screen with the phone locked: open Phone Screen while the phone is locked. The
      picture stays dark with a note (a locked phone sends none); type the PIN on the Mac and
      press Return, or unlock on the phone. Within about two seconds the picture should come,
      if need be after a short "Connecting…". Does the phone light up by itself when the
      screen was off?
- [ ] Device controls, sending a text, picture messages, deleting a photo: sections B, C, D.
- [ ] Files: the stop button during a transfer.
- [ ] Phone switcher with a second phone; linking a phone from the Mac.

## 0. Receive a file on the Mac (works: small file 20:58, 25 MB and 380 MB at 21:47 on 2026-10-09)

Built from the recording of 2026-10-09 and tested only against scripted phones. Both devices
must be on the same Wi-Fi.

| # | Do | Expect |
|---|---|---|
| 0.1 | Open Phone Mac Link and its **Files** section | "No files yet" |
| 0.2 | On the phone: open a small file or photo, Share, Link to Windows | This Mac is listed. It may appear twice under the same name |
| 0.3 | Choose the Mac | The first time, macOS asks whether Phone Mac Link may find devices on the local network: allow it, then share once more |
| 0.4 | Watch Files | "…is sharing a file", then the name with a progress bar, then the file in the list; a Mac notification; the file in Downloads |
| 0.5 | If Files says the phone used "this Mac's other entry" | Share again and pick the other of the two entries |
| 0.6 | If it fails any other way | Tell me the time; the log has `[files]` lines that say how far it got |
| 0.7 | Several files in one share (5 files, 115 MB, worked on 2026-10-09 22:04), a file over 1 GB (1.23 GB at 22:02) | Each arrives in Downloads |
| 0.8 | Cancelling on the phone midway (worked twice on 2026-10-09 21:59, with files written to disk) | Files says the share was cancelled; nothing is left in `~/Library/Caches/Phone Mac Link/Incoming` |

## 0b. Send a file to the phone (worked on 2026-10-09 22:22 with two small files)

| # | Do | Expect |
|---|---|---|
| 0b.1 | Files, **Send Files…**, or drop a file on the window | "Sending …" with a bar, then the file listed as "Sent to phone"; on the phone it is in Downloads, "Received from PC" |
| 0b.2 | Several files at once (3 files, worked 22:24), a 19.8 MB file (3.1 s, worked 22:25) | Each arrives |
| 0b.3 | Still to try: a file of hundreds of MB, cancelling on the phone midway, sending while the phone is receiving something else | It arrives; a cancel or a busy phone is said in Files |

## A. Look, do not touch (no effect on the phone)

| # | Do | Expect |
|---|---|---|
| A1 | Open the Phone Mac Link window | Sidebar footer shows battery, signal and Wi-Fi, a ringer symbol, a moon, and a **Ring** button |
| A2 | Start music or a podcast on the phone | A "now playing" card appears above the status row, with the title and album art. It does not appear in Notifications and makes no Mac banner |
| A3 | Open Messages, type in the search field | The conversation list narrows to matching names and texts |
| A4 | Phone Mac Link › Settings (Cmd+,) › Notifications | Every phone app with its icon and a switch |
| A4b | Click each sidebar section in turn | Each opens. The selection code was touched today, so this is worth ten seconds |
| A5 | Switch one noisy app off, then get a notification from it | Nothing on the Mac; it is back after switching the app on again |
| A6 | Wait ten minutes, then search the log for `heartbeat` | `push heartbeat ... answered 0` |

## B. Device controls (new, never sent before; each acts on the phone)

No capture of Windows doing any of these exists. If one does nothing or shows an orange note,
that is the finding; tell me which. A control gives up after about 12 seconds.

| # | Do | Expect |
|---|---|---|
| B1 | Click **Ring** | Phone vibrates about 3 s, then sounds its alarm tone at full volume. Button shows "Stop" with a 20 s countdown |
| B2 | Click **Stop** while it rings | Ringing stops at once |
| B3 | Ringer menu: Vibrate, then Silent, then Sound | Phone follows; the symbol changes within a second or two |
| B4 | Click the moon | Do Not Disturb turns on on the phone; click again to turn it off |
| B5 | With music playing: pause, play, next, previous on the card | Phone follows; the card updates |

## C. Messages

| # | Do | Expect |
|---|---|---|
| C1 | Open a conversation with a blue dot | The dot clears and stays cleared after a relaunch |
| C2 | Send a short text to yourself or a test number | Grey "Sending…" bubble, then the real message. This was built against Windows' captured request but has not been sent live from the Mac |
| C3 | Open a conversation that has a picture message. It shows an "Attachment · Click to load" chip; click it | The chip turns into "Picture · Click to load"; clicking that loads the picture into the thread; clicking the picture opens it. Both steps are new and uncaptured |
| C4 | Optional, costs an MMS: the picture button left of the text field, choose a picture, send | Goes out as a picture message; pictures are shrunk to under 280 KB each, two at most. Never tried |

## D. Photos

| # | Do | Expect |
|---|---|---|
| D1 | Open a photo you do not need, click **Delete…**, confirm | It disappears from the grid and from the phone's gallery. Never tried; the confirmation says it cannot be undone |

## E. Notifications (carried over)

| # | Do | Expect |
|---|---|---|
| E1 | Notifications › **Set Up** on the "hidden" banner, then **Allow** on the phone | Banner disappears; sensitive notifications arrive |
| E2 | Reply to a messenger notification from the Mac banner or the list | The reply is sent by the phone app |
| E3 | Press an action button on a notification | The phone performs it |

## F. Calls (off until you switch it on)

Switching this on changes a setting on the phone that it shares with the Windows VM, and the
exchange has never been seen on the wire. Do it while watching.

| # | Do | Expect |
|---|---|---|
| F1 | Settings › General › **Show recent calls (experimental)** | The app reconnects; a **Calls** section appears and fills with the last 30 days of calls, with contact names |
| F2 | If the app stays on "Reconnecting" for more than a minute | Switch it off again and tell me: that would be the handshake hazard the spec warns of |
| F3 | Click the phone symbol on a row | The phone's dialer opens with the number. It does not place the call |
| F4 | Without the switch: open a one-to-one conversation in Messages and click the phone symbol in its header | Same: the phone's dialer opens with that number |

## F2. Calls on this Mac over Bluetooth (connection and a call from the Mac worked on 2026-10-10 11:38)

Control only: macOS does not let an app carry a call's sound, so you talk on the phone
(`protocol/specs/calls-bluetooth.md`, section 5). Have a second phone to call from.

| # | Do | Expect |
|---|---|---|
| H1 | Settings › General › **Calls on this Mac** (worked: chosen by hand among 4 paired phones, connected in 3 seconds) | "Connected over Bluetooth…"; a **Calls** section |
| H4 | Call the phone from another phone | A panel at the top right of the screen with the caller and two round buttons; the same bar at the top of Calls and in the menu bar item |
| H5 | Click the green button | The call is answered; you talk on the phone |
| H6 | During the call: the dial pad's keys in Calls (they send their tones), the red button | The red one ends the call and the panel goes |
| H7 | Call again and click the red button while it rings | The call is declined |
| H8 | Calls: a number or a name on the dial pad and the green button, or the phone symbol on a row of the history (worked) | The phone places the call at once; the bar shows "Calling…", "Ringing…", then the timer |
| H9 | Answer a call on the phone itself while the Mac is connected | You hear it on the phone as usual. If it is silent, the phone chose Bluetooth as its sound route: tell me |
| H10 | Walk away with the phone, come back | "not in Bluetooth reach", and "Connected" again by itself some time after you are back |

## F3. Sync over mobile data (new on 2026-10-10)

| # | Do | Expect |
|---|---|---|
| M1 | Settings › General › **Sync over mobile data** | Off, as Phone Link shows it for this phone |
| M2 | Switch it on, then look at the same switch in Phone Link or in Link to Windows on the phone | On there too: it is one setting on the phone |
| M3 | Turn the phone's Wi-Fi off | With the switch on, notifications keep arriving. With it off, the sidebar says the phone is on mobile data and not syncing, with a button to allow it |

## F4. Phone screen and files away from the same Wi-Fi (new on 2026-10-10, not yet tried with the phone)

Proven without the phone: the code reads and reproduces the recorded Windows session, and it
ran against Microsoft's real relay servers from this Mac. Spec: `protocol/specs/nano-ice.md`.
Mobile data note: the phone's screen can use about 1 MB a second. Start with a small file.

| # | Do | Expect |
|---|---|---|
| I1 | Settings › General › **Sync over mobile data**: on | Needed, or the phone refuses everything while off Wi-Fi |
| I2 | On the phone: turn Wi-Fi off (mobile data), or join another Wi-Fi than the Mac's | The sidebar still shows the phone connected |
| I3 | Files: send a small file to the phone | It arrives in the phone's Downloads. In the log: `not on one network; trying over the internet`, `[ice] gathered 3 candidates`, `[ice] path chosen: ...`, `connection over the internet open` |
| I4 | Share a photo from the phone to the Mac (Link to Windows, this Mac) | It arrives in Downloads the same way |
| I5 | Phone Screen › Show Phone Screen, for a few seconds | The picture comes, a little later than on Wi-Fi; mouse and keys work |
| I6 | Back on the same Wi-Fi: the same again | As before: `direct connection open`, no `[ice]` lines |
| I7 | If any of it fails | Tell me the time. The `[ice]` lines say which pairs were tried and how each ended |


## F5. Phone screen: turning, own window, screenshots, drops (built 2026-10-10, phone unattended)

Built from the phone's and Phone Link's code and tested against a scripted phone, a real
H.264 stream made on the Mac, and the real windows in demo mode. None of it has met the phone.

- [ ] J1. **Turning, whole screen.** Show the phone screen, switch auto-rotate on, open
      something that turns (Gallery, YouTube, the browser) and turn the phone on its side.
      Expected: the picture takes the lying shape within a second and clicks land where you
      point. Turn back: upright again. If the picture stays upright with black bars, or clicks
      land elsewhere, the log lines to send me are those with `screen` and `nano` from that
      moment ("the phone's screen is now …", "the picture is now …", "video offered").
- [ ] J2. **Turning, one app.** Apps › open an app that lies on its side by itself (a game, a
      video player in full screen). Expected: the picture is shown turned, clicks land right.
      Log: "the phone asks for the picture turned by …".
- [ ] J3. **Own window.** On the Phone Screen start page tick "Show in a window of its own"
      (or, while the screen shows, the window button in the toolbar). Expected: a window in the
      phone's shape with Recents, Home, Back on the left and screenshot, pin, "back into the
      main window" on the right. Resizing keeps the shape from any edge; the pin keeps it above
      other windows; turning the phone (J1) lays the window on its side; closing it stops the
      mirroring; the choice is remembered for the next time and for apps.
- [ ] J4. **Screenshot.** The camera button: a click saves `Phone Screen <date> at <time>.png`
      to Downloads (the note at the bottom of the picture opens Finder there); its menu has
      Copy. Expected: the picture as shown, turned if the picture is turned. "No picture to
      take yet" means the system gave none: tell me, there is another way to build it.
- [ ] J5. **Drop files on the picture.** Drag a small file from Finder onto the phone's
      picture. Expected: "Send to Phone" appears while over it, and the file goes as from the
      Files page (progress shows there). Not known yet: whether the phone accepts a file
      transfer while its screen is being shown.

Nothing to test, but new: the yearly renewal of the device's key with Microsoft's service
(`/Auth/RotateKeys`) is built. It is not due before April 2027 and does nothing until then.

## F6. Phone Storage: the phone's folders and files (built 2026-10-10, never run against the phone)

Opening the section is what asks the phone; until then nothing is sent. Nothing on the phone is
changed. The list holds names, sizes, dates and small previews; a file itself comes only when
you download it (K6).

- [ ] K1. Click **Phone Storage** in the sidebar. Expected: "Asking the phone for its files…",
      then a count going up, then the top folders (DCIM, Download, …). With tens of thousands
      of files this may take a while.
- [ ] K2. If it says **"The Phone Has Not Allowed It"**: on the phone, Link to Windows needs
      "access to all files" (Android: Settings › Apps › Link to Windows › Permissions, or the
      prompt the phone may show). Once given, the list should appear by itself.
- [ ] K3. Double-click through folders; the path bar on top goes back; the order menu (Name,
      Newest First, Largest First); search for part of a file name (results say where each
      lies; right-click › Show in Its Folder).
- [ ] K4. Pictures, videos and music show a small preview in the row; double-click a file for
      a larger one. It is the phone's thumbnail, not the file.
- [ ] K5. Take a photo or download something on the phone while the section is open. Expected:
      it appears within a few seconds without Refresh.
- [ ] K6. **Download.** Right-click a small file › Download to This Mac (or the button in its
      preview). Both devices on the same Wi-Fi. Expected: progress at the bottom of the
      section, the file in Downloads and under Files. This step is the least certain of the
      section: the exchange is the one of a share from the phone, asked for the other way
      round, and has never met the phone. If it fails, the note at the bottom says why.
- [ ] If K1 ends with "This phone does not offer its files to a computer" or with no answer:
      one thing left untried on purpose is announcing the Mac to Microsoft's service as able
      to show phone files (the `PHONE_FILES` capability of the cross-device identity). It
      changes what the account's device list says about this Mac, so I left it for you to
      decide. Tell me and I will switch it on.
- [ ] If anything fails, the lines with `files` and `phone files` in the log say how far it got
      (they hold counts and status numbers only, no names).

## F7. Instant Hotspot (built 2026-10-10 from both sides' code, never run)

The button with the hotspot sign on the phone's card in the sidebar (also Phone › Connect to
Phone's Hotspot). It switches the phone's hotspot on over Bluetooth and joins it with this
Mac's Wi-Fi. Know before trying: once joined, this Mac's internet goes through the phone's
mobile data, and the phone itself is then on mobile data, so the rest of the app only keeps
syncing if "Sync over mobile data" is on. To leave, choose your usual network in the Wi-Fi
menu; the phone's hotspot is switched off on the phone.

- [ ] L1. Click the hotspot button. If the phone has not been asked before, the phone opens
      Link to Windows' settings (or shows a notification): allow Instant Hotspot there, then
      click the button again.
- [ ] L2. Expected then: "Asking the phone…", "Joining the phone's network…", and the button
      turns green with the network's name under it.
- [ ] L3. If it fails, the line under the buttons says why. The most likely first failure is
      "The phone is not offering its hotspot to this Mac": whether Samsung's Bluetooth service
      accepts a Mac is the one thing the code could not tell. The log lines with `hotspot` say
      how far it got (no names, no passwords).

## F8. Banners and the Dock (built 2026-10-19)

- [ ] M1. Click the Mac banner of an SMS: the window opens on Messages with that conversation
      selected, and the notification stays on the phone.
- [ ] M2. Close the main window (and the phone's screen, if open): the Dock icon goes; the menu
      bar icon stays. "Open Phone Mac Link" there, a banner click, or opening the app from
      Finder or Spotlight brings the window and the Dock icon back.
- [ ] M3. In the menu bar panel, a section, a recent notification, Send Files, Settings or
      "Open Phone Mac Link" closes the panel as the window opens.

## G. Connection (carried over; these interrupt the link)

| # | Do | Expect |
|---|---|---|
| G1 | Sleep the Mac for a minute, wake it | "Reconnecting", then connected within a few seconds, list intact |
| G2 | Wi-Fi off, wait, on | Same |
| G3 | Remove the phone in Devices, then link it again from the Mac with the QR code | The full link process. Last, because it unlinks |

## One choice for you (decided 2026-10-19)

Clicking a Mac banner of a phone notification asks the phone to open that app, which also
removes the notification on the phone. That is unchanged. Settings › General now has
**Clicking a notification**, where "Shows it in Phone Mac Link" brings this app's window forward
instead. Try both and keep the one you prefer. Since 2026-10-19 "Shows it in Phone Mac Link" is the
default: opening the app on the phone removed the notification before it could be read.

## Captures that would settle open questions

Each needs the Windows VM with the proxy on (`C:\winphone\proxy-on.cmd`), a minute or two each:

1. In Phone Link: ring the phone, cycle the ringer, toggle Do Not Disturb, press the media keys.
2. In Phone Link: open a picture message and click its attachment; send a picture.
3. In Phone Link: turn on Calls consent and let the call history sync.
4. In Phone Link: delete one photo.

5. For file transfer, the next large piece (`protocol/specs/nano-scoping.md`): record the
   peer-to-peer traffic between the VM and the phone. This morning's capture shows Windows
   setting up such a connection at every start of its session, so no file needs to be sent:
   start the recording, then quit and reopen Phone Link on the VM. A second run while one
   small file is sent from the phone to the PC would add the file channels. The recording needs
   your password, so it is yours to run, on the Mac:

```bash
sudo tcpdump -i vmenet3 -w captures/nano-udp-2.pcap udp
```

   `vmenet3` is the bridge member that carries the VM (the entry with a MAC starting `0:c:29`
   in the address cache that `ifconfig bridge101` prints; the number can change when the VM
   restarts). Recording on `bridge101` itself shows only the Mac's own packets: the first try
   on 2026-10-09 caught nothing from the VM.

   Stop it with Ctrl+C after a minute. The key that decrypts this traffic travels in a
   relay message the proxy already records, so the recording can be read afterwards.
   This then says whether the first layer of the decoder is right (counts and packet kinds
   only):

```bash
app/.build/debug/winphone-probe nano-check captures/nano-udp-2.pcap captures/vm-raw-2026-10-09/flows.jsonl
```


To compare a recording of items 1 to 4 with what the Mac sends, note where the capture ends, do the
actions in Phone Link, then print the structure of what was recorded (no content is shown):

```bash
tools/capture/controls-check.sh mark vm-raw-2026-10-09
```

```bash
tools/capture/controls-check.sh show vm-raw-2026-10-09 <number printed by mark>
```

The capture proxy from this morning is still running. If you are done with the VM for today,
run `C:\winphone\proxy-off.cmd` in it.
