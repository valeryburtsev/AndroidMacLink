#!/bin/bash
# Capture real notification traffic between the phone and the VM.
#
#   tools/capture/notification-test.sh check            is Link to Windows allowed to read notifications?
#   tools/capture/notification-test.sh settings         open the phone's notification-access settings page
#   tools/capture/notification-test.sh post [n]         post n test notifications from the adb shell (default 3)
#   tools/capture/notification-test.sh decode <session> print the notification messages captured in captures/<session>
#
# The capture proxy must be running with raw WebSocket recording (WINPHONE_RAW_WS=true) and the VM
# must be routed through it. Test notifications come from the shell package, so no real
# notification of the user's is involved; the phone forwards them like any other app's.
set -euo pipefail
cd "$(dirname "$0")/../.."
listener="com.microsoft.appmanager/com.microsoft.mmx.agents.PhoneNotificationsListenerService"

case "${1:-}" in
  check)
    if adb shell settings get secure enabled_notification_listeners | tr ':' '\n' | grep -q '^com.microsoft.appmanager/'; then
      echo "Link to Windows has notification access"
    else
      echo "Link to Windows does NOT have notification access; grant it on the phone (settings command opens the page)"
      exit 1
    fi
    ;;
  settings)
    adb shell am start -a android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS >/dev/null
    echo "opened Notification access on the phone; allow Link to Windows there"
    ;;
  post)
    n="${2:-3}"
    for i in $(seq 1 "$n"); do
      adb shell cmd notification post -S bigtext -t "\"WinPhone test $i\"" "winphone$i" "\"Hello from the Mac, message $i\"" >/dev/null
      sleep 2
    done
    echo "posted $n test notifications; the first dismissal from the PC side produces a removal message"
    ;;
  decode)
    session="${2:?session name}"
    app/.build/debug/winphone-probe app-messages "captures/$session/flows.jsonl" --route /legacy/phonecontent --content-type notifications
    echo "--- commands from the PC"
    app/.build/debug/winphone-probe app-messages "captures/$session/flows.jsonl" --route /notifications
    ;;
  *)
    sed -n 2,9p "$0"
    exit 2
    ;;
esac
